# frozen_string_literal: true
require_relative "spec_helper"
require "tempfile"

describe Sequel::Model, "closure_tree plugin" do
  before do
    @tempfile = Tempfile.new(["sequel-closure-tree-", ".sqlite"])
    @tempfile.close
    @db = Sequel.sqlite(@tempfile.path, timeout: 30000)
    @db.create_table :nodes do
      primary_key :id
      Integer :parent_id
      String :name
    end

    @node_class = Class.new(Sequel::Model(@db[:nodes])) do
      def self.name; "Node"; end
      plugin :closure_tree
    end
    @node_class.create_closure_table
  end

  after do
    @db.disconnect
    File.delete(@tempfile.path) if @tempfile && File.exist?(@tempfile.path)
  end

  def node(name, parent=nil)
    @node_class.create(name: name.to_s, parent: parent)
  end

  def closure_rows
    @db[:nodes_closures].order(:ancestor_id, :descendant_id).map do |row|
      [row[:ancestor_id], row[:descendant_id], row[:depth]]
    end
  end

  def expected_closures
    rows = []
    nodes = @node_class.order(:id).all

    nodes.each do |current|
      rows << [current.id, current.id, 0]
      depth = 1
      parent_id = current.parent_id
      while parent_id
        rows << [parent_id, current.id, depth]
        parent = nodes.find { |candidate| candidate.id == parent_id }
        raise "missing parent #{parent_id}" unless parent
        parent_id = parent.parent_id
        depth += 1
      end
    end

    rows.sort
  end

  def assert_closure_matches_adjacency
    closure_rows.must_equal expected_closures
  end

  it "creates zero-depth and parent closure rows in one transaction" do
    root = node(:root)
    child = node(:child, root)
    grandchild = node(:grandchild, child)

    root.ancestors.must_equal []
    root.self_and_ancestors.map(&:id).must_equal [root.id]
    child.ancestors.map(&:id).must_equal [root.id]
    grandchild.ancestors.map(&:id).must_equal [child.id, root.id]

    root.descendants.map(&:id).must_equal [child.id, grandchild.id]
    grandchild.self_and_descendants.map(&:id).must_equal [grandchild.id]
    assert_closure_matches_adjacency
  end

  it "supports custom closure table and column names" do
    @db.create_table :items do
      primary_key :item_id
      Integer :parent_item_id
      String :name
    end

    item_class = Class.new(Sequel::Model(@db[:items])) do
      def self.name; "Item"; end
      plugin :closure_tree,
        key: :parent_item_id,
        primary_key: :item_id,
        closure_table: :item_paths,
        ancestor_column: :upper_id,
        descendant_column: :lower_id,
        depth_column: :distance
    end
    item_class.create_closure_table

    parent = item_class.create(name: "parent")
    child = item_class.create(name: "child", parent: parent)

    child.ancestors.map(&:item_id).must_equal [parent.item_id]
    parent.descendants.map(&:item_id).must_equal [child.item_id]
    @db[:item_paths].order(:upper_id, :lower_id).all.must_equal [
      { upper_id: parent.item_id, lower_id: parent.item_id, distance: 0 },
      { upper_id: parent.item_id, lower_id: child.item_id, distance: 1 },
      { upper_id: child.item_id, lower_id: child.item_id, distance: 0 }
    ]
  end

  it "moves a full subtree across roots and recalculates every depth" do
    first_root = node(:first_root)
    parent = node(:parent, first_root)
    child = node(:child, parent)
    grandchild = node(:grandchild, child)
    second_root = node(:second_root)

    parent.move_to(second_root)

    parent.ancestors.map(&:id).must_equal [second_root.id]
    child.ancestors.map(&:id).must_equal [parent.id, second_root.id]
    grandchild.ancestors.map(&:id).must_equal [child.id, parent.id, second_root.id]
    first_root.self_and_descendants.map(&:id).must_equal [first_root.id]
    second_root.self_and_descendants.map(&:id).must_equal(
      [second_root.id, parent.id, child.id, grandchild.id]
    )
    assert_closure_matches_adjacency
  end

  it "can move a subtree to a root and back under another node" do
    first_root = node(:first_root)
    parent = node(:parent, first_root)
    child = node(:child, parent)
    second_root = node(:second_root)

    parent.move_to(nil)
    assert_closure_matches_adjacency
    parent.ancestors.must_equal []
    child.ancestors.map(&:id).must_equal [parent.id]

    parent.move_to(second_root.id)
    assert_closure_matches_adjacency
    child.ancestors.map(&:id).must_equal [parent.id, second_root.id]
  end

  it "rejects moving a node under itself or one of its descendants" do
    root = node(:root)
    parent = node(:parent, root)
    child = node(:child, parent)

    proc { parent.move_to(parent) }.must_raise \
      Sequel::Plugins::ClosureTree::ClosureTreeCycleError
    proc { parent.move_to(child) }.must_raise \
      Sequel::Plugins::ClosureTree::ClosureTreeCycleError
    proc { child.update(parent_id: child.id) }.must_raise \
      Sequel::Plugins::ClosureTree::ClosureTreeCycleError

    assert_closure_matches_adjacency
  end

  it "deletes a complete subtree" do
    root = node(:root)
    parent = node(:parent, root)
    child = node(:child, parent)
    sibling = node(:sibling, root)

    parent.destroy_subtree

    @node_class.order(:id).map(&:id).must_equal [root.id, sibling.id]
    closure_rows.must_equal [
      [root.id, root.id, 0],
      [root.id, sibling.id, 1],
      [sibling.id, sibling.id, 0]
    ]
  end

  it "restores in-memory values and association caches when a move rolls back" do
    root = node(:root)
    parent = node(:parent, root)
    child = node(:child, parent)
    target = node(:target)

    root.children.to_a
    parent.children.to_a
    target.children.to_a

    def parent.rebuild_closure_for_move
      raise Sequel::DatabaseError, "boom"
    end
    proc { parent.move_to(target) }.must_raise Sequel::DatabaseError

    parent.reload
    parent.parent_id.must_equal root.id
    parent.ancestors.map(&:id).must_equal [root.id]
    root.children.to_a.must_include(parent)
    target.children.to_a.must_equal []
    assert_closure_matches_adjacency

    proc { child.move_to(child) }.must_raise \
      Sequel::Plugins::ClosureTree::ClosureTreeCycleError
    child.parent_id.must_equal parent.id
  end

  it "restores parent association caches when creating a child rolls back" do
    root = node(:root)
    root.children.to_a

    child = @node_class.new(name: "child", parent: root)
    def child.after_create
      super
      raise Sequel::DatabaseError, "boom"
    end

    proc { child.save }.must_raise Sequel::DatabaseError

    child.must_be :new?
    root.children.to_a.must_equal []
    closure_rows.must_equal [[root.id, root.id, 0]]
  end

  it "serializes intersecting moves on two connections without cycles or lost paths" do
    root = node(:root)
    first = node(:first, root)
    second = node(:second, root)
    first_child = node(:first_child, first)
    second_child = node(:second_child, second)

    db1 = Sequel.sqlite(@tempfile.path, timeout: 30000)
    db2 = Sequel.sqlite(@tempfile.path, timeout: 30000)
    model1 = Class.new(Sequel::Model(db1[:nodes])) do
      plugin :closure_tree
    end
    model2 = Class.new(Sequel::Model(db2[:nodes])) do
      plugin :closure_tree
    end
    model1.closure_tree_table.must_equal :nodes_closures
    model2.closure_tree_table.must_equal :nodes_closures

    started = Queue.new
    second_started = Queue.new
    release_first = Queue.new
    release_second = Queue.new
    first_finished = Queue.new
    errors = []

    first_thread = Thread.new do
      db1.transaction(mode: :immediate) do
        started << true
        release_first.pop
        model1.with_pk(first.id).move_to(model1.with_pk(second_child.id))
      end
    rescue => error
      errors << error
    end
    first_finished << true

    second_thread = Thread.new do
      started.pop
      second_started << true
      release_second.pop

      begin
        db2.transaction(mode: :immediate) do
          model2.with_pk(second.id).move_to(model2.with_pk(first_child.id))
        end
      rescue => error
        errors << error
      end
    end

    second_started.pop
    release_first << true
    first_finished.pop
    release_second << true

    first_thread.join
    second_thread.join
    db1.disconnect
    db2.disconnect

    errors.each do |error|
      error.must_be_kind_of Sequel::Plugins::ClosureTree::ClosureTreeCycleError
    end
    errors.length.must_equal 1
    assert_closure_matches_adjacency
  end
end
