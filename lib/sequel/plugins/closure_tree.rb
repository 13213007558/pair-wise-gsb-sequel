# frozen-string-literal: true

module Sequel
  module Plugins
    # = Overview
    #
    # The closure_tree plugin allows you to work with tree structured data
    # stored using an adjacency list (each node has a foreign key pointing to
    # its parent) combined with a closure table that stores every
    # ancestor/descendant pair with its depth.  While the tree plugin has to
    # issue one query per level to find ancestors or descendants, the closure
    # table allows loading all ancestors or all descendants of a node with a
    # single query, which is useful for directory-service style workloads that
    # query ancestors and descendants frequently.
    #
    # The closure table contains one row for every ancestor/descendant pair,
    # including a zero-depth row from every node to itself:
    #
    #   ancestor_id   | descendant_id | depth
    #   1             | 1             | 0
    #   1             | 2             | 1
    #   1             | 3             | 2
    #   2             | 2             | 0
    #   2             | 3             | 1
    #   3             | 3             | 0
    #
    # The plugin keeps the closure table in sync when nodes are created,
    # moved, or destroyed, and commits the parent pointer and closure table
    # changes in the same transaction.  If a move fails, the in-memory
    # association caches of the instances involved are invalidated so they do
    # not reflect the rolled back move.
    #
    # = Usage
    #
    #   class Node < Sequel::Model(:nodes)
    #     plugin :closure_tree
    #   end
    #
    #   root = Node.create(name: 'root')
    #   child = root.add_child(name: 'child')
    #   grandchild = child.add_child(name: 'grandchild')
    #
    #   grandchild.ancestors   # => [child, root]
    #   root.descendants       # => [child, grandchild]
    #
    #   child.move_to(other_node)  # move the whole subtree to another parent
    #   child.move_to_root         # move the whole subtree to a new root
    #   child.delete_subtree       # delete the node and all of its descendants
    #
    # Moving a node to itself or to one of its own descendants is rejected by
    # raising a Sequel::Plugins::ClosureTree::Error.  Moves are validated
    # inside the transaction after the write lock has been acquired (the
    # plugin uses immediate transactions on databases that support them, such
    # as SQLite), so concurrent intersecting moves on the same database are
    # serialized before validation and cannot create cycles or lose paths.
    #
    # = Options
    #
    # All options supported by the tree plugin are supported and passed
    # through.  Additionally, the following options are supported:
    #
    # :ancestor_column :: The column in the closure table holding the ancestor
    #                     id (default: :ancestor_id)
    # :closure_table :: The name of the closure table
    #                   (default: table_name + '_hierarchy')
    # :depth_column :: The column in the closure table holding the depth
    #                  (default: :depth)
    # :descendant_column :: The column in the closure table holding the
    #                       descendant id (default: :descendant_id)
    module ClosureTree
      # Exception raised when an invalid move is attempted, such as moving a
      # node to itself or to one of its own descendants.
      class Error < Sequel::Error; end

      # Apply the tree plugin with the given options, and set the closure
      # table specific attributes.
      def self.apply(model, opts=OPTS)
        opts = opts.dup
        closure_table = opts.delete(:closure_table)
        ancestor_column = opts.delete(:ancestor_column)
        descendant_column = opts.delete(:descendant_column)
        depth_column = opts.delete(:depth_column)

        model.plugin :tree, opts

        model.instance_eval do
          @closure_table = closure_table || :"#{table_name}_hierarchy"
          @ancestor_column = ancestor_column || :ancestor_id
          @descendant_column = descendant_column || :descendant_id
          @depth_column = depth_column || :depth
          # The closure table must be updated in the same transaction as the
          # node table, so force transactional saves.
          self.use_transactions = true
        end
      end

      module ClassMethods
        # The column in the closure table holding the ancestor id.
        attr_reader :ancestor_column

        # The name of the table storing the ancestor/descendant pairs.
        attr_reader :closure_table

        # The column in the closure table holding the depth.
        attr_reader :depth_column

        # The column in the closure table holding the descendant id.
        attr_reader :descendant_column

        Plugins.inherited_instance_variables(self, :@ancestor_column=>nil, :@closure_table=>nil, :@depth_column=>nil, :@descendant_column=>nil)

        # The dataset for the closure table.
        def closure_table_dataset
          db[closure_table]
        end
      end

      module InstanceMethods
        # Returns list of ancestors, starting from parent until root, using a
        # single query against the closure table.
        #
        #   subchild1.ancestors # => [child1, root]
        def ancestors
          ancestors_dataset.all
        end

        # Returns a dataset for all ancestors of the node, ordered from
        # parent to root.
        def ancestors_dataset
          m = model
          ct = m.closure_table
          m.select_all(m.table_name).
            join(ct, m.ancestor_column=>m.primary_key).
            where(Sequel[ct][m.descendant_column]=>pk).
            exclude(Sequel[ct][m.depth_column]=>0).
            order(Sequel[ct][m.depth_column])
        end

        # Returns list of descendants, ordered from the closest to the
        # furthest, using a single query against the closure table.
        #
        #   node.descendants # => [child1, child2, subchild1_1]
        def descendants
          descendants_dataset.all
        end

        # Returns a dataset for all descendants of the node, ordered from
        # the closest to the furthest.
        def descendants_dataset
          m = model
          ct = m.closure_table
          m.select_all(m.table_name).
            join(ct, m.descendant_column=>m.primary_key).
            where(Sequel[ct][m.ancestor_column]=>pk).
            exclude(Sequel[ct][m.depth_column]=>0).
            order(Sequel[ct][m.depth_column])
        end

        # The level of the node in the tree, 0 for root nodes.
        def level
          model.closure_table_dataset.where(model.descendant_column=>pk).max(model.depth_column) || 0
        end

        # Create a new child node of the current node, inserting the node
        # and its closure table rows in the same transaction.
        #
        #   child = node.add_child(name: 'child')
        def add_child(values=OPTS)
          m = model
          raise Error, 'cannot add a child to an unsaved node' if new?
          m.db.transaction(mode: :immediate) do
            child = m.create(values.merge(m.parent_column=>pk))
            child.associations[m.parent_association_name] = self
            child
          end
        end

        # Move the node and its entire subtree to a new parent, updating the
        # parent pointer and the closure table in the same transaction.  Use
        # move_to_root with no argument to move the subtree to a new root.
        # Raises Sequel::Plugins::ClosureTree::Error if the new parent is the
        # node itself or one of its descendants.
        def move_to(new_parent)
          m = model
          raise Error, 'cannot move an unsaved node' if new?
          new_parent_id = new_parent && new_parent.pk
          if new_parent_id == pk
            raise Error, 'cannot move a node to be a child of itself'
          end
          parent_column = m.parent_column
          return self if new_parent_id == get_column_value(parent_column)

          ct = m.closure_table_dataset
          ac = m.ancestor_column
          dc = m.descendant_column
          de = m.depth_column
          id = pk

          begin
            m.db.transaction(mode: :immediate) do
              # Update the parent pointer before validating.  Combined with
              # the immediate transaction, this makes sure the transaction
              # holds the database write lock before validating, so
              # concurrent moves on the same database are serialized before
              # validation and cannot create cycles or lose paths.
              this.update(parent_column=>new_parent_id)

              if new_parent_id && !ct.where(ac=>id, dc=>new_parent_id).empty?
                raise Error, 'cannot move a node to one of its own descendants'
              end

              # Remove all links from ancestors outside the subtree to nodes
              # inside the subtree.
              subtree = ct.where(ac=>id).select(dc)
              ct.where(dc=>subtree).exclude(ac=>subtree).delete

              if new_parent_id
                # Link every ancestor of the new parent (including the new
                # parent itself) to every node in the moved subtree
                # (including the moved node itself).
                a = :closure_tree_ancestors
                d = :closure_tree_descendants
                ct.insert([ac, dc, de],
                  m.db[Sequel[m.closure_table].as(a)].
                    cross_join(Sequel[m.closure_table].as(d)).
                    where(Sequel[a][dc]=>new_parent_id, Sequel[d][ac]=>id).
                    select(Sequel[a][ac], Sequel[d][dc], Sequel[a][de] + Sequel[d][de] + 1))
              end
            end
          rescue Exception
            # The parent pointer and closure table changes were rolled back,
            # so invalidate the cached associations of the instances involved
            # to keep them from reflecting the rolled back move.
            associations.delete(m.parent_association_name)
            associations.delete(m.children_association_name)
            new_parent.associations.delete(m.children_association_name) if new_parent
            raise
          end

          @values[parent_column] = new_parent_id
          associations.delete(m.parent_association_name)
          associations.delete(m.children_association_name)
          new_parent.associations.delete(m.children_association_name) if new_parent
          self
        end

        # Move the node and its entire subtree to a new root.
        def move_to_root
          move_to(nil)
        end

        # Delete the node and all of its descendants, removing the related
        # closure table rows in the same transaction.
        def delete_subtree
          m = model
          raise Error, 'cannot delete the subtree of an unsaved node' if new?
          ct = m.closure_table_dataset
          m.db.transaction(mode: :immediate) do
            ids = ct.where(m.ancestor_column=>pk).select_map(m.descendant_column)
            ct.where(m.descendant_column=>ids).delete
            m.where(m.primary_key=>ids).delete
          end
          associations.clear
          self
        end

        private

        # Insert the closure table rows for the node: a zero-depth row from
        # the node to itself, and a copy of the parent's ancestor rows with
        # the depth incremented by one.
        def after_create
          super
          m = model
          ct = m.closure_table_dataset
          id = pk
          rows = [[id, id, 0]]
          if parent_id = get_column_value(m.parent_column)
            ct.where(m.descendant_column=>parent_id).each do |row|
              rows << [row[m.ancestor_column], id, row[m.depth_column] + 1]
            end
          end
          ct.import([m.ancestor_column, m.descendant_column, m.depth_column], rows)
        end

        # Remove all closure table rows referencing the node.
        def after_destroy
          super
          m = model
          m.closure_table_dataset.where(m.ancestor_column=>pk).or(m.descendant_column=>pk).delete
        end
      end
    end
  end
end
