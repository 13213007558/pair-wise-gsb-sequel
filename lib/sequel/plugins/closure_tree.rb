# frozen_string_literal: true

module Sequel
  module Plugins
    # The closure_tree plugin maintains a closure table alongside the
    # adjacency list used by the tree plugin. Each pair of ancestor and
    # descendant nodes is stored in the closure table with its distance,
    # including a depth 0 row for every node itself.
    #
    # The node table must have the parent foreign key (default: +parent_id+),
    # and the closure table defaults to +\#\{table_name\}_closures+ with
    # +ancestor_id+, +descendant_id+, and +depth+ columns. Use
    # Model.create_closure_table to create the default indexes and foreign
    # keys.
    #
    # Creating and moving nodes updates the parent pointer and closure rows
    # in the same database transaction. Use #move_to to move a subtree,
    # #destroy_subtree to delete a subtree, and #ancestors/#descendants to
    # read a node's related nodes without recursive queries.
    module ClosureTree
      def self.apply(model, opts=OPTS)
        opts = opts.dup
        closure_keys = [
          :closure_table,
          :ancestor_column,
          :descendant_column,
          :depth_column
        ]
        closure_options, tree_options = opts.partition do |key, _|
          closure_keys.include?(key)
        end.map(&:to_h)
        closure_options[:primary_key] = opts[:primary_key]
        model.plugin :tree, tree_options

        primary_key = closure_options[:primary_key] || model.primary_key
        if Array(primary_key).length != 1
          raise Error, "closure_tree plugin requires a simple primary key"
        end

        model.instance_exec do
          @closure_tree_table = closure_options[:closure_table] || :"#{table_name}_closures"
          @closure_tree_ancestor_column = closure_options[:ancestor_column] || :ancestor_id
          @closure_tree_descendant_column = closure_options[:descendant_column] || :descendant_id
          @closure_tree_depth_column = closure_options[:depth_column] || :depth
          @closure_tree_primary_key = primary_key
        end
      end

      module ClassMethods
        attr_accessor :closure_tree_table,
          :closure_tree_ancestor_column,
          :closure_tree_descendant_column,
          :closure_tree_depth_column,
          :closure_tree_primary_key

        Plugins.inherited_instance_variables(self,
          :@closure_tree_table=>nil,
          :@closure_tree_ancestor_column=>nil,
          :@closure_tree_descendant_column=>nil,
          :@closure_tree_depth_column=>nil,
          :@closure_tree_primary_key=>nil)

        # Create the closure table with indexes and foreign keys pointing back
        # to the model table. Does nothing if the table already exists.
        def create_closure_table
          node_table = table_name
          node_key = closure_tree_primary_key
          ancestor_column = closure_tree_ancestor_column
          descendant_column = closure_tree_descendant_column
          depth_column = closure_tree_depth_column

          db.create_table?(closure_tree_table) do
            Integer ancestor_column, null: false, table: node_table, key: node_key
            Integer descendant_column, null: false, table: node_table, key: node_key
            Integer depth_column, null: false
            primary_key [ancestor_column, descendant_column]
            index descendant_column
            index ancestor_column
          end
        end

        # Dataset containing all closure relationships for this tree.
        def closure_tree_dataset
          db[closure_tree_table]
        end
      end

      module InstanceMethods
        # Return the ancestors of this node, ordered from the immediate parent
        # to the root. The node itself is not included.
        def ancestors
          ancestors_dataset.all
        end

        # Dataset for the ancestors of this node.
        def ancestors_dataset
          closure_tree_related_dataset(:ancestor).
            exclude(
              Sequel.qualify(model.closure_tree_table, model.closure_tree_depth_column) => 0
            )
        end

        # Return this node and its ancestors, ordered from this node to the
        # root.
        def self_and_ancestors
          self_and_ancestors_dataset.all
        end

        # Dataset for this node and its ancestors.
        def self_and_ancestors_dataset
          closure_tree_related_dataset(:ancestor)
        end

        # Return the descendants of this node in breadth-first depth order.
        # The node itself is not included.
        def descendants
          descendants_dataset.all
        end

        # Dataset for the descendants of this node.
        def descendants_dataset
          self_and_descendants_dataset.
            exclude(
              Sequel.qualify(model.closure_tree_table, model.closure_tree_depth_column) => 0
            )
        end

        # Return this node and its descendants, ordered from this node to
        # deeper descendants.
        def self_and_descendants
          closure_tree_related_dataset(:descendant).all
        end

        # Dataset for this node and its descendants.
        def self_and_descendants_dataset
          closure_tree_related_dataset(:descendant)
        end

        # Move this node and its entire subtree under +new_parent+. Pass nil
        # to make the subtree a new root. Moving a node under itself or one of
        # its descendants raises ClosureTreeCycleError.
        def move_to(new_parent)
          raise Error, "cannot move an unsaved #{model.name} node" if new?

          old_parent = associations[model.parent_association_name]
          old_children = old_parent && old_parent.associations[model.children_association_name]
          old_children = old_children && old_children.dup
          new_children = if new_parent.is_a?(model)
            new_parent.associations[model.children_association_name]
          end
          new_children = new_children && new_children.dup

          case new_parent
          when nil
            self[model.parent_column] = nil
            associations.delete(model.parent_association_name)
          when model
            raise Error, "cannot move a node under an unsaved parent" if new_parent.new?
            public_send(model.parent_association_name.to_s + "=", new_parent)
          else
            self[model.parent_column] = new_parent
            associations.delete(model.parent_association_name)
          end

          result = save
          if result
            old_parent.associations.delete(model.children_association_name) if old_parent
            result
          else
            restore_cached_children(old_parent, old_children)
            restore_cached_children(new_parent, new_children) if new_parent.is_a?(model)
            result
          end
        rescue StandardError
          restore_cached_children(old_parent, old_children)
          restore_cached_children(new_parent, new_children) if new_parent.is_a?(model)
          raise
        end

        alias move move_to

        # Delete this node and all of its descendants, running each object's
        # destroy hooks. The node rows and closure relationships are deleted
        # in one transaction.
        def destroy_subtree
          raise Error, "cannot destroy an unsaved node" if new?

          closure_tree_transaction do
            nodes = subtree_nodes_by_depth
            ids = nodes.map(&:pk)
            closure_tree_dataset.where(model.closure_tree_descendant_column => ids).delete
            nodes.each do |node|
              node.instance_variable_set(:@closure_tree_destroying_subtree, true)
            end
            nodes.reverse_each(&:destroy)
          end

          self
        end

        # Return the root of this tree using the closure table.
        def root
          ancestors.last || self
        end

        private

        def after_create
          super
          insert_closure_self_row
          insert_closure_parent_rows unless self[model.parent_column].nil?
          @closure_tree_new_parent = nil
          @closure_tree_new_parent_children = nil
        end

        def change_column_value(column, value)
          if column == model.parent_column
            unless new? || @closure_tree_rollback_state
              capture_closure_tree_rollback_state(value != self[column])
            end
          end
          super
        end

        def before_update
          if @closure_tree_parent_changed
            new_parent_id = self[model.parent_column]
            ensure_not_moving_under_self_or_descendant(new_parent_id)
          end
          super
        end

        def before_save
          if (new? || @closure_tree_parent_changed) &&
              (parent_id = self[model.parent_column]) &&
              model.where(qualified_primary_key => parent_id).empty?
            raise Error, "#{model.name} parent #{parent_id.inspect} does not exist"
          end
          super
        end

        def after_update
          super

          if @closure_tree_parent_changed
            rebuild_closure_for_move
            invalidate_closure_tree_associations
          end
        end

        def before_destroy
          unless @closure_tree_destroying_subtree
            closure_tree_dataset.
              where(model.closure_tree_ancestor_column => pk).
              or(model.closure_tree_descendant_column => pk).
              delete
          end
          super
        end

        def after_destroy
          super
          if parent = associations[model.parent_association_name]
            parent.associations.delete(model.children_association_name)
          end
          associations.delete(model.parent_association_name)
          associations.delete(model.children_association_name)
        end

        def save(opts=OPTS)
          unless closure_tree_save_requires_transaction?
            return super
          end

          rollback_state = @closure_tree_rollback_state ||
            capture_closure_tree_rollback_state(new?)

          result = closure_tree_transaction do
            super
          end
          @closure_tree_rollback_state = nil if result

          unless result
            restore_closure_tree_rollback_state(rollback_state)
          end
          result
        rescue StandardError
          @closure_tree_rollback_state = nil
          restore_closure_tree_rollback_state(rollback_state)
          raise
        end

        def destroy(opts=OPTS)
          closure_tree_transaction { super }
        end

        public :save, :destroy

        def closure_tree_dataset
          model.closure_tree_dataset
        end

        def qualified_primary_key
          Sequel.qualify(model.table_name, model.closure_tree_primary_key)
        end

        def closure_tree_related_dataset(direction)
          join_column = direction == :ancestor ?
            model.closure_tree_ancestor_column :
            model.closure_tree_descendant_column
          filter_column = direction == :ancestor ?
            model.closure_tree_descendant_column :
            model.closure_tree_ancestor_column

          model.dataset.
            join(model.closure_tree_table, join_column => qualified_primary_key).
            where(Sequel.qualify(model.closure_tree_table, filter_column) => pk).
            order(
              Sequel.qualify(model.closure_tree_table, model.closure_tree_depth_column),
              qualified_primary_key
            ).
            select_all(model.table_name)
        end

        def subtree_nodes_by_depth
          model.dataset.
            join(model.closure_tree_table,
              model.closure_tree_descendant_column => qualified_primary_key).
            where(model.closure_tree_ancestor_column => pk).
            order(Sequel.qualify(model.closure_tree_table, model.closure_tree_depth_column).desc).
            select_all(model.table_name).
            all
        end

        def ensure_not_moving_under_self_or_descendant(new_parent_id)
          return if new_parent_id.nil?

          if new_parent_id == pk || closure_tree_dataset.where(
            Sequel.qualify(model.closure_tree_table,
              model.closure_tree_ancestor_column) => pk,
            Sequel.qualify(model.closure_tree_table,
              model.closure_tree_descendant_column) => new_parent_id
          ).count > 0
            raise ClosureTreeCycleError, "cannot move a node under itself or one of its descendants"
          end
        end

        def rebuild_closure_for_move
          delete_old_closure_ancestor_rows if @closure_tree_old_parent_id
          insert_closure_parent_rows if self[model.parent_column]
        end

        def delete_old_closure_ancestor_rows
          descendants = closure_tree_dataset.
            where(model.closure_tree_ancestor_column => pk).
            select(model.closure_tree_descendant_column)
          ancestors = closure_tree_dataset.
            where(model.closure_tree_descendant_column => pk).
            exclude(model.closure_tree_depth_column => 0).
            select(model.closure_tree_ancestor_column)

          closure_tree_dataset.where(
            model.closure_tree_descendant_column => descendants,
            model.closure_tree_ancestor_column => ancestors
          ).delete
        end

        def insert_closure_self_row
          closure_tree_dataset.insert(
            model.closure_tree_ancestor_column => pk,
            model.closure_tree_descendant_column => pk,
            model.closure_tree_depth_column => 0
          )
        end

        def insert_closure_parent_rows
          ancestor_column = model.closure_tree_ancestor_column
          descendant_column = model.closure_tree_descendant_column
          depth_column = model.closure_tree_depth_column
          parent_alias = :parent_closures
          subtree_alias = :subtree_closures
          select_dataset = db[model.closure_tree_table].
            unordered.
            from(
              Sequel.as(model.closure_tree_table, parent_alias),
              Sequel.as(model.closure_tree_table, subtree_alias)
            ).
            where(
              Sequel[parent_alias][descendant_column] => self[model.parent_column],
              Sequel[subtree_alias][ancestor_column] => pk
            ).
            select(
              Sequel[parent_alias][ancestor_column],
              Sequel[subtree_alias][descendant_column],
              Sequel.as(
                Sequel[parent_alias][depth_column] +
                  Sequel[subtree_alias][depth_column] + 1,
                depth_column
              )
            )

          closure_tree_dataset.insert([
              ancestor_column,
              descendant_column,
              depth_column
            ],
            select_dataset)
        end

        def invalidate_closure_tree_associations
          old_parent = @closure_tree_rollback_state && @closure_tree_rollback_state[:old_parent]
          new_parent = associations[model.parent_association_name]
          children_name = model.children_association_name

          old_parent.associations.delete(children_name) if old_parent && old_parent.associations
          if new_parent && new_parent.associations
            new_parent.associations.delete(children_name)
          end

          associations.delete(model.parent_association_name)
          associations.delete(children_name)
          @closure_tree_rollback_state = nil
          @closure_tree_parent_changed = nil
          @closure_tree_old_parent_id = nil
          @closure_tree_old_parent = nil
        end

        def remove_reciprocal_object(opts, associated_object)
          if !new? && opts[:name] == model.parent_association_name
            capture_closure_tree_rollback_state(false) unless @closure_tree_rollback_state
          end
          super
        end

        def add_reciprocal_object(opts, associated_object)
          if opts[:name] == model.parent_association_name
            if new?
              @closure_tree_new_parent = associated_object
              @closure_tree_new_parent_children =
                associated_object.associations[model.children_association_name]
              @closure_tree_new_parent_children =
                @closure_tree_new_parent_children && @closure_tree_new_parent_children.dup
            else
              capture_closure_tree_rollback_state(true) unless @closure_tree_rollback_state
              @closure_tree_new_parent = associated_object
              @closure_tree_new_parent_children =
                associated_object.associations[model.children_association_name]
              @closure_tree_new_parent_children =
                @closure_tree_new_parent_children && @closure_tree_new_parent_children.dup
            end
          end
          super
        end

        def set_associated_object(opts, associated_object)
          previous_parent_id = @closure_tree_old_parent_id || self[model.parent_column]
          if !new? && opts[:name] == model.parent_association_name &&
              associated_object&.pk != previous_parent_id
            capture_closure_tree_rollback_state(true) unless @closure_tree_rollback_state
            @closure_tree_parent_changed = true
            @closure_tree_new_parent = associated_object
            @closure_tree_new_parent_children =
              associated_object.associations[model.children_association_name]
            @closure_tree_new_parent_children =
              @closure_tree_new_parent_children && @closure_tree_new_parent_children.dup
          end
          super
        end

        def capture_closure_tree_rollback_state(parent_changed=false)
          parent_column = model.parent_column
          @closure_tree_old_parent_id = self[parent_column]
          @closure_tree_old_parent = associations[model.parent_association_name]
          @closure_tree_parent_changed = parent_changed
          @closure_tree_rollback_state = {
            :values => values.dup,
            :changed_columns => changed_columns.dup,
            :associations => associations.dup,
            :new => new?,
            :modified => modified?,
            :this => @this,
            :old_parent => @closure_tree_old_parent,
            :old_parent_children => begin
              old_parent_children = @closure_tree_old_parent &&
                @closure_tree_old_parent.associations[model.children_association_name]
              old_parent_children && old_parent_children.dup
            end
          }
        end

        def restore_closure_tree_rollback_state(state)
          return unless state

          @values.replace(state[:values])
          changed_columns.replace(state[:changed_columns])
          @new = state[:new]
          @modified = state[:modified]
          @this = state[:this]
          @associations = state[:associations] && Hash[state[:associations]]

          restore_cached_children(state[:old_parent], state[:old_parent_children])
          restore_cached_children(@closure_tree_new_parent,
            @closure_tree_new_parent_children)
          if parent = associations[model.parent_association_name]
            parent.associations.delete(model.children_association_name)
          end

          @closure_tree_parent_changed = nil
          @closure_tree_old_parent_id = nil
          @closure_tree_old_parent = nil
          @closure_tree_new_parent = nil
          @closure_tree_new_parent_children = nil
        end

        def restore_cached_children(parent, children)
          return unless parent && parent.associations
          parent.associations[model.children_association_name] = children
        end

        def closure_tree_transaction(&block)
          opts = closure_tree_transaction_options
          db.transaction(opts.merge(:server=>this_server), &block)
        end

        def closure_tree_save_requires_transaction?
          new? || @closure_tree_parent_changed
        end

        def closure_tree_transaction_options
          return OPTS if db.in_transaction?(:server=>this_server)

          opts = {}
          opts[:mode] = :immediate if db.database_type == :sqlite
          opts[:isolation] = :serializable if db.supports_transaction_isolation_levels?
          opts
        end
      end

      class ClosureTreeCycleError < Error; end
    end
  end
end
