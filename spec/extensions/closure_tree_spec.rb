# frozen_string_literal: true
require_relative "spec_helper"
require 'tmpdir'
require 'fileutils'

describe Sequel::Model, "closure_tree plugin" do
  before(:all) do
    @dir = Dir.mktmpdir('sequel_closure_tree_spec')
    @db_file = File.join(@dir, 'closure_tree.db')
    @db = Sequel.sqlite(@db_file)
    @db.create_table(:nodes) do
      primary_key :id
      String :name
      Integer :parent_id
    end
    @db.create_table(:nodes_hierarchy) do
      Integer :ancestor_id, null: false
      Integer :descendant_id, null: false
      Integer :depth, null: false
      primary_key [:ancestor_id, :descendant_id]
      index [:descendant_id]
    end
    @c = Class.new(Sequel::Model(@db[:nodes]))
    @c.class_eval do
      def self.name; 'Node'; end
      plugin :closure_tree
    end
  end

  after(:all) do
    @db.disconnect
    FileUtils.remove_entry(@dir)
  end

  before do
    @db[:nodes_hierarchy].delete
    @db[:nodes].delete
    # n1 -> n2 -> n3
    # n4 -> n5
    @n1 = @c.create(name: 'n1')
    @n2 = @n1.add_child(name: 'n2')
    @n3 = @n2.add_child(name: 'n3')
    @n4 = @c.create(name: 'n4')
    @n5 = @n4.add_child(name: 'n5')
  end

  # Compute the expected closure table rows by walking the adjacency list
  # (parent pointers) upwards from every node, and compare them row by row
  # with the actual closure table contents.  Raises if the adjacency list
  # contains a cycle.
  def check_closure_table
    by_id = {}
    @db[:nodes].all.each{|n| by_id[n[:id]] = n}
    expected = []
    by_id.each_value do |node|
      depth = 0
      current = node[:id]
      seen = {}
      until current.nil?
        raise "cycle detected in adjacency list at node #{current}" if seen[current]
        seen[current] = true
        expected << {ancestor_id: current, descendant_id: node[:id], depth: depth}
        depth += 1
        current = by_id[current][:parent_id]
      end
    end
    expected.sort_by!{|r| [r[:ancestor_id], r[:descendant_id]]}
    @db[:nodes_hierarchy].order(:ancestor_id, :descendant_id).all.must_equal expected
  end

  it "should define the tree associations and closure table attributes" do
    @c.associations.sort_by{|x| x.to_s}.must_equal [:children, :parent]
    @c.closure_table.must_equal :nodes_hierarchy
    @c.ancestor_column.must_equal :ancestor_id
    @c.descendant_column.must_equal :descendant_id
    @c.depth_column.must_equal :depth
    @c.closure_table_dataset.count.must_equal @db[:nodes_hierarchy].count
  end

  it "should maintain closure rows including zero-depth self rows on create" do
    check_closure_table
    @db[:nodes_hierarchy].where(depth: 0).select_order_map(:descendant_id).sort.must_equal [@n1.id, @n2.id, @n3.id, @n4.id, @n5.id].sort
    @db[:nodes_hierarchy].where(ancestor_id: @n1.id, descendant_id: @n3.id).get(:depth).must_equal 2
    @db[:nodes_hierarchy].where(ancestor_id: @n1.id, descendant_id: @n2.id).get(:depth).must_equal 1
  end

  it "should read ancestors and descendants with a single query each" do
    @n3.ancestors.must_equal [@n2, @n1]
    @n1.descendants.must_equal [@n2, @n3]
    @n2.ancestors.must_equal [@n1]
    @n2.descendants.must_equal [@n3]
    @n3.root.must_equal @n1
    @n1.root.must_equal @n1
    @n3.level.must_equal 2
    @n2.level.must_equal 1
    @n1.level.must_equal 0
    @c.roots.sort_by{|x| x.id}.must_equal [@n1, @n4].sort_by{|x| x.id}
  end

  it "should reject moving a node to itself or to its own descendant" do
    _{@n1.move_to(@n1)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    _{@n1.move_to(@n2)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    _{@n1.move_to(@n3)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    _{@n2.move_to(@n3)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    @c[@n1.id].parent_id.must_be_nil
    @c[@n2.id].parent_id.must_equal @n1.id
    check_closure_table
  end

  it "should roll back the parent pointer when a move fails" do
    _{@n2.move_to(@n3)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    @n2.parent_id.must_equal @n1.id
    @c[@n2.id].parent_id.must_equal @n1.id
    check_closure_table
  end

  it "should invalidate cached associations of the instances involved when a move fails" do
    @n2.parent.must_equal @n1
    @n1.children.must_equal [@n2]
    @n3.children.must_equal []
    _{@n1.move_to(@n3)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    @n1.associations.wont_include :parent
    @n1.associations.wont_include :children
    @n3.associations.wont_include :children
    @n1.parent_id.must_be_nil
    @n1.children.must_equal [@n2]
  end

  it "should move a whole subtree across roots with correct depths" do
    @n2.move_to(@n5)
    @n2.parent_id.must_equal @n5.id
    @c[@n2.id].parent_id.must_equal @n5.id
    @c[@n3.id].parent_id.must_equal @n2.id
    check_closure_table
    @db[:nodes_hierarchy].where(ancestor_id: @n4.id, descendant_id: @n2.id).get(:depth).must_equal 2
    @db[:nodes_hierarchy].where(ancestor_id: @n4.id, descendant_id: @n3.id).get(:depth).must_equal 3
    @db[:nodes_hierarchy].where(ancestor_id: @n5.id, descendant_id: @n3.id).get(:depth).must_equal 2
    @db[:nodes_hierarchy].where(ancestor_id: @n1.id).count.must_equal 1
    @n3.ancestors.must_equal [@n2, @n5, @n4]
    @n3.root.must_equal @n4
    @n3.level.must_equal 3
  end

  it "should move a subtree to a new root" do
    @n2.move_to_root
    @n2.parent_id.must_be_nil
    @c[@n2.id].parent_id.must_be_nil
    check_closure_table
    @db[:nodes_hierarchy].where(descendant_id: [@n2.id, @n3.id], ancestor_id: @n1.id).count.must_equal 0
    @n3.ancestors.must_equal [@n2]
    @n3.root.must_equal @n2
    @c.roots.sort_by{|x| x.id}.must_equal [@n1, @n2, @n4].sort_by{|x| x.id}
  end

  it "should be a no-op when moving to the current parent" do
    @n2.move_to(@n1).must_equal @n2
    @n1.move_to_root.must_equal @n1
    check_closure_table
  end

  it "should delete a whole subtree" do
    @n1.delete_subtree
    @c.all.sort_by{|x| x.id}.must_equal [@n4, @n5].sort_by{|x| x.id}
    check_closure_table
    @n4.delete_subtree
    @c.count.must_equal 0
    @db[:nodes_hierarchy].count.must_equal 0
  end

  it "should remove closure rows when a single node is destroyed" do
    @n3.destroy
    check_closure_table
    @db[:nodes_hierarchy].where(ancestor_id: @n3.id).or(descendant_id: @n3.id).count.must_equal 0
  end

  it "should raise when operating on unsaved nodes" do
    _{@c.new.add_child(name: 'x')}.must_raise(Sequel::Plugins::ClosureTree::Error)
    _{@c.new.move_to(@n1)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    _{@c.new.delete_subtree}.must_raise(Sequel::Plugins::ClosureTree::Error)
  end

  it "should support custom key, closure table, and column names" do
    @db.create_table(:folders) do
      primary_key :id
      Integer :pid
    end
    @db.create_table(:paths) do
      Integer :a, null: false
      Integer :d, null: false
      Integer :l, null: false
      primary_key [:a, :d]
    end
    c = Class.new(Sequel::Model(@db[:folders]))
    c.class_eval do
      def self.name; 'Folder'; end
      plugin :closure_tree, key: :pid, closure_table: :paths, ancestor_column: :a, descendant_column: :d, depth_column: :l
    end
    f1 = c.create
    f2 = f1.add_child
    f3 = f2.add_child
    _{f1.move_to(f3)}.must_raise(Sequel::Plugins::ClosureTree::Error)
    @db[:paths].order(:a, :d).all.must_equal [
      {a: f1.id, d: f1.id, l: 0},
      {a: f1.id, d: f2.id, l: 1},
      {a: f1.id, d: f3.id, l: 2},
      {a: f2.id, d: f2.id, l: 0},
      {a: f2.id, d: f3.id, l: 1},
      {a: f3.id, d: f3.id, l: 0},
    ]
    f3.ancestors.must_equal [f2, f1]
    @db.drop_table(:paths)
    @db.drop_table(:folders)
  end

  it "should serialize concurrent intersecting moves on the same database without cycles or lost paths" do
    # Use a zero busy timeout for the second connection, so its attempt to
    # acquire the write lock fails immediately instead of blocking the whole
    # process inside SQLite's busy handler.
    db2 = Sequel.sqlite(@db_file, timeout: 0)
    c2 = Class.new(Sequel::Model(db2[:nodes]))
    c2.class_eval do
      def self.name; 'Node'; end
      plugin :closure_tree
    end

    q1 = Queue.new
    q2 = Queue.new
    q3 = Queue.new
    # First connection moves n2 (with its subtree) under n5, and holds its
    # transaction open while the second connection attempts the conflicting
    # inverse move of n5 under n2.
    t1 = Thread.new do
      begin
        @db.transaction(mode: :immediate) do
          @c[@n2.id].move_to(@c[@n5.id])
          q1.push(true)
          q2.pop
        end
      ensure
        q3.push(true)
      end
    end
    t2 = Thread.new do
      q1.pop
      retried = false
      begin
        c2[@n5.id].move_to(c2[@n2.id])
      rescue Sequel::DatabaseError
        # The first connection holds the write lock, so this attempt fails
        # with a busy error.  Busy errors are transient, so wait for the
        # first connection's move to commit and retry, so the move can be
        # validated against the current state.
        raise if retried
        retried = true
        q3.pop
        retry
      end
      :moved
    rescue Sequel::Plugins::ClosureTree::Error
      :rejected
    end
    # Give the second connection time to attempt its move while the first
    # connection holds the write lock, then let the first move commit.
    sleep 0.2
    q2.push(true)
    t1.value
    t2.value.must_equal :rejected
    db2.disconnect

    # The first move must have been applied, the conflicting second move
    # must have been rolled back, and the closure table must match the
    # adjacency list exactly.
    @c[@n2.id].parent_id.must_equal @n5.id
    @c[@n5.id].parent_id.must_equal @n4.id
    check_closure_table
  end
end
