# frozen-string-literal: true
#
# The mutual_recursive extension supports a restricted form of mutual
# recursion between two named relations. It compiles the declarations into
# one recursive CTE with one label column and one slot for every column in
# either relation, then projects each relation back to its original columns.
#
# Restrictions enforced before SQL generation:
# * exactly two relations are declared;
# * every recursive branch directly references exactly one declared relation;
# * recursive relations cannot be used through subqueries;
# * aggregate functions, grouping, compound datasets, outer/natural/USING
#   joins, raw literal SQL, and negation are not allowed in recursive
#   branches;
# * each branch must explicitly select exactly the number of columns
#   declared for its relation.
#
# Load it into a database and declare both base and recursive branches:
#
#   DB.extension(:mutual_recursive)
#   relations = DB.mutual_recursive(
#     odd: {
#       columns: [:n],
#       base: DB[:edges].where(b: 1).select { b.as(:n) },
#       recursive: lambda do |r|
#         DB[:edges].join(r[:even], r[:even][:n] => :a).select { b.as(:n) }
#       end
#     },
#     even: {
#       columns: [:n],
#       recursive: lambda do |r|
#         DB[:edges].join(r[:odd], r[:odd][:n] => :a).select { b.as(:n) }
#       end
#     }
#   )
#
#   relations[:odd] # dataset with only the original :n column visible
#
# Only UNION (not UNION ALL) is used, so rows are deduplicated. Each relation
# gets disjoint column slots; all other slots are filled with untyped NULL,
# which cannot change either NULL comparison or UNION deduplication semantics.
#
# Related module: Sequel::MutualRecursive

module Sequel
  module MutualRecursive
    UNION_NAME = :_sequel_mutual_recursive_relations
    LABEL_COLUMN = :_sequel_mutual_recursive_label

    AGGREGATE_FUNCTIONS = %i[
      array_agg avg bool_and bool_or bit_and bit_or count every group_concat
      json_group_array json_group_object max min stddev stddev_pop stddev_samp
      string_agg sum total var_pop var_samp variance
    ].freeze

    FORBIDDEN_OPTIONS = %i[
      with sql append_sql group group_options having limit offset order lock
      returning insert_conflict
    ].freeze

    # Placeholder identifier passed to a recursive branch. It marks references
    # that should be rewritten to the single internal recursive CTE.
    class RelationRef < SQL::Identifier
    end

    class Compiler
      def initialize(db, specs)
        @db = db
        @input_names = specs.is_a?(Hash) ? specs.keys.map(&:to_sym) : []
        @specs = normalize_specs(specs)
        @slots = []
        @slot_by_relation = {}

        @specs.each do |name, spec|
          @slot_by_relation[name] = {}
          spec[:columns].each do |column|
            slot = slot_name(name, column)
            @slot_by_relation[name][column] = slot
            @slots << slot
          end
        end
      end

      def compile
        validate!

        base_branches = @specs.flat_map { |name, spec| spec[:base].map { |ds| pad_branch(ds, name) } }
        base_branches << empty_branch if base_branches.empty?
        base = unioned(base_branches)

        recursive_branches = @specs.flat_map do |name, spec|
          spec[:recursive].map { |ds| prepare_recursive_branch(ds, name) }
        end
        recursive_branches << stop_branch if recursive_branches.empty?
        recursive = unioned(recursive_branches)

        unified = @db[UNION_NAME].with_recursive(
          UNION_NAME, base, recursive,
          :args => (@slots + [LABEL_COLUMN]), :union_all => false
        )

        result = {}
        @specs.each do |name, spec|
          selected = spec[:columns].map do |column|
            Sequel.as(@slot_by_relation[name][column], column)
          end
          ds = unified.
            where(LABEL_COLUMN => name.to_s).
            select(*selected).
            from_self(:alias => name)
          ds.send(:columns=, spec[:columns].dup)
          result[name] = ds
        end
        result
      end

      private

      def normalize_specs(specs)
        unless specs.is_a?(Hash) && specs.length == 2
          raise Error, "mutual_recursive expects exactly two named relations"
        end

        specs.each_with_object({}) do |(name, spec), normalized|
          name = name.to_sym
          unless spec.is_a?(Hash)
            raise Error, "mutual_recursive relation #{name.inspect} must be a hash"
          end
          if normalized.key?(name)
            raise Error, "mutual_recursive relation names must be unique"
          end
          normalized[name] = normalize_relation(name, spec)
        end
      end

      def normalize_relation(name, spec)
        declared = spec[:columns] && Array(spec[:columns]).map(&:to_sym)
        if declared
          if declared.empty?
            raise Error, "mutual_recursive relation #{name.inspect} must declare at least one column"
          end
          if declared.uniq.length != declared.length
            raise Error, "mutual_recursive relation #{name.inspect} has duplicate columns"
          end
        end

        base = spec.key?(:base) && !spec[:base].nil? ? branches(name, spec[:base], :base) : []
        recursive = spec.key?(:recursive) && !spec[:recursive].nil? ? branches(name, spec[:recursive], :recursive) : []
        columns = declared || infer_columns(name, base + recursive)

        (base + recursive).each do |ds|
          selected = ds.opts[:select] || []
          if selected.empty? ||
             selected.any? { |column| column.is_a?(SQL::ColumnAll) } ||
             selected.length != columns.length
            raise Error,
              "mutual_recursive relation #{name.inspect} branches must explicitly select #{columns.length} columns"
          end
        end

        {:columns => columns.freeze, :base => base, :recursive => recursive}
      end

      def branches(name, value, kind)
        list = value.is_a?(Array) ? value : [value]
        list.map do |branch|
          branch = call_branch(branch) if branch.is_a?(Proc)
          unless branch.is_a?(Dataset)
            raise Error, "mutual_recursive #{kind} branch for #{name.inspect} must be a dataset"
          end
          branch
        end
      end

      def call_branch(branch)
        branch.call(relation_refs)
      end

      def relation_refs
        @relation_refs ||= @input_names.each_with_object({}) do |name, refs|
          refs[name] = RelationRef.new(name)
        end
      end

      def infer_columns(name, branches)
        names = branches.map { |ds| select_names(name, ds) }.inject([], :+)
        if names.empty?
          raise Error,
            "mutual_recursive relation #{name.inspect} must declare :columns or explicitly select named columns"
        end
        names
      end

      def select_names(name, ds)
        (ds.opts[:select] || []).map do |column|
          case column
          when SQL::AliasedExpression
            column.alias.to_sym
          when Symbol
            column
          when SQL::Identifier
            column.value.to_sym
          when SQL::QualifiedIdentifier
            column.column.to_sym
          else
            raise Error,
              "mutual_recursive relation #{name.inspect} needs :columns unless every selected expression has an alias"
          end
        end
      end

      def validate!
        unless @db.dataset.supports_cte?(:select)
          raise InvalidOperation, "database does not support recursive common table expressions"
        end

        @specs.each do |name, spec|
          spec[:base].each { |ds| validate_base_branch(name, ds) }
          spec[:recursive].each { |ds| validate_recursive_branch(name, ds) }
        end
      end

      def validate_base_branch(name, ds)
        validate_dataset(name, ds, :base)
        if direct_refs(ds).any?
          raise Error, "mutual_recursive base branch for #{name.inspect} must not reference recursive relations"
        end
        walk_options(ds.opts, name, []) do |expression|
          if relation_ref?(expression)
            raise Error, "mutual_recursive base branch for #{name.inspect} must not reference recursive relations"
          end
        end
      end

      def validate_recursive_branch(name, ds)
        validate_dataset(name, ds, :recursive)
        FORBIDDEN_OPTIONS.each do |option|
          if ds.opts.key?(option) && !ds.opts[option].nil?
            raise Error, "mutual_recursive recursive branch for #{name.inspect} uses unsupported #{option.inspect}"
          end
        end
        refs = direct_refs(ds)
        unless refs.length == 1
          raise Error,
            "mutual_recursive recursive branch for #{name.inspect} must reference exactly one recursive relation"
        end

        info = direct_info(ds, name)
        allowed_relations = [info[:relation]]

        Array(ds.opts[:join]).each do |join|
          next unless join_relation(join)
          if join.is_a?(SQL::JoinUsingClause) || ![:inner, :cross].include?(join.join_type)
            raise Error,
              "mutual_recursive recursive branch for #{name.inspect} only supports INNER " \
              "and CROSS joins to a recursive relation"
          end
        end

        walk_options(ds.opts, name, allowed_relations) do |expression|
          if relation_ref?(expression)
            raise Error,
              "mutual_recursive recursive relation for #{name.inspect} can only be referenced directly in FROM/JOIN"
          elsif aggregate?(expression)
            raise Error,
              "mutual_recursive recursive branch for #{name.inspect} uses aggregate function #{expression.name.inspect}"
          elsif negation?(expression)
            raise Error, "mutual_recursive recursive branch for #{name.inspect} uses negation"
          elsif expression.is_a?(LiteralString) || expression.is_a?(SQL::PlaceholderLiteralString)
            raise Error, "mutual_recursive recursive branch for #{name.inspect} uses raw literal SQL"
          elsif expression.is_a?(Proc) || expression.is_a?(SQL::DelayedEvaluation)
            raise Error, "mutual_recursive recursive branch for #{name.inspect} uses delayed SQL evaluation"
          end
        end
      end

      def validate_dataset(name, ds, kind)
        unless ds.is_a?(Dataset)
          raise Error, "mutual_recursive #{kind} branch for #{name.inspect} must be a dataset"
        end
        if ds.opts[:select].nil? || ds.opts[:select].empty?
          raise Error, "mutual_recursive #{kind} branch for #{name.inspect} must explicitly select columns"
        end
        if ds.opts[:compounds]
          raise Error, "mutual_recursive #{kind} branch for #{name.inspect} uses a compound dataset"
        end
      end

      def direct_refs(ds)
        refs = Array(ds.opts[:from]).flat_map { |source| extract_ref(source) }
        refs + Array(ds.opts[:join]).flat_map { |join| extract_ref(join.table_expr) }
      end

      def extract_ref(expression)
        if expression.is_a?(RelationRef)
          [expression]
        elsif expression.is_a?(SQL::AliasedExpression) && expression.expression.is_a?(RelationRef)
          [expression.expression]
        else
          []
        end
      end

      def join_relation(join)
        extract_ref(join.table_expr).first
      end

      def relation_ref?(expression)
        expression.is_a?(RelationRef)
      end

      def declared_relation?(name)
        @specs.key?(name.to_sym)
      end

      def identifier_value(value)
        value.is_a?(SQL::Identifier) ? value.value : value
      end

      def walk_options(options, relation_name, allowed_refs, &block)
        options.each do |key, value|
          next if [:cache, :row_proc, :servers, :defaults].include?(key)

          if key == :from
            value.each do |source|
              walk(source, relation_name, [], &block) if extract_ref(source).empty?
            end
          elsif key == :join
            value.each do |join|
              unless join_relation(join)
                walk(join.table_expr, relation_name, allowed_refs, &block)
              end
              walk(join.on, relation_name, allowed_refs, &block) if join.is_a?(SQL::JoinOnClause)
              walk(join.using, relation_name, allowed_refs, &block) if join.is_a?(SQL::JoinUsingClause)
            end
          else
            walk(value, relation_name, allowed_refs, &block)
          end
        end
      end

      def walk(value, relation_name, allowed_refs, &block)
        case value
        when RelationRef
          yield value unless allowed_refs.include?(value.value)
        when Dataset
          if direct_refs(value).any?
            raise Error,
              "mutual_recursive recursive branch for #{relation_name.inspect} references a " \
              "recursive relation through a subquery"
          end
          if value.opts[:compounds]
            raise Error,
              "mutual_recursive recursive branch for #{relation_name.inspect} uses a compound dataset"
          end
          walk_options(value.opts, relation_name, [], &block)
        when Hash
          value.each do |key, item|
            walk(key, relation_name, allowed_refs, &block)
            walk(item, relation_name, allowed_refs, &block)
          end
        when Array, Set
          value.each { |item| walk(item, relation_name, allowed_refs, &block) }
        when SQL::QualifiedIdentifier
          table = identifier_value(value.table).to_s
          if declared_relation?(table) && !allowed_refs.map(&:to_s).include?(table)
            raise Error,
              "mutual_recursive recursive branch for #{relation_name.inspect} references a " \
              "recursive relation outside its direct FROM/JOIN"
          end
          yield value
          walk(value.table, relation_name, allowed_refs, &block) unless declared_relation?(table)
          walk(value.column, relation_name, allowed_refs, &block)
        when SQL::AliasedExpression
          walk(value.expression, relation_name, allowed_refs, &block)
          walk(value.columns, relation_name, allowed_refs, &block) if value.columns
        when SQL::ComplexExpression
          yield value
          value.args.each { |arg| walk(arg, relation_name, allowed_refs, &block) }
        when SQL::Function
          yield value
          walk(value.args, relation_name, allowed_refs, &block)
          walk(value.opts, relation_name, allowed_refs, &block)
        when SQL::JoinOnClause
          walk(value.on, relation_name, allowed_refs, &block)
        when SQL::JoinUsingClause
          walk(value.using, relation_name, allowed_refs, &block)
        when SQL::JoinClause
        when SQL::ColumnAll
          yield value
          walk(value.table, relation_name, allowed_refs, &block)
        when SQL::Cast
          yield value
          walk(value.expr, relation_name, allowed_refs, &block)
        when SQL::CaseExpression
          yield value
          walk(value.conditions, relation_name, allowed_refs, &block)
          walk(value.default, relation_name, allowed_refs, &block)
          if value.respond_to?(:expression?) && value.expression?
            walk(value.expression, relation_name, allowed_refs, &block)
          end
        when SQL::Wrapper, SQL::Subscript
          yield value
          walk(value.is_a?(SQL::Wrapper) ? value.value : value.expression, relation_name, allowed_refs, &block)
          walk(value.sub, relation_name, allowed_refs, &block) if value.is_a?(SQL::Subscript)
        when SQL::NegativeBooleanConstant
          yield value
        when SQL::Expression
          yield value
          value.instance_variables.each do |ivar|
            walk(value.instance_variable_get(ivar), relation_name, allowed_refs, &block)
          end
        when LiteralString, SQL::PlaceholderLiteralString, Proc, SQL::DelayedEvaluation
          yield value
        end
      end

      def aggregate?(expression)
        return true if expression.is_a?(SQL::Function) && !expression.opts[:over].nil?
        expression.is_a?(SQL::Function) && AGGREGATE_FUNCTIONS.include?(expression.name.to_s.downcase.to_sym)
      end

      def negation?(expression)
        return true if expression.is_a?(SQL::NegativeBooleanConstant)
        return false unless expression.is_a?(SQL::BooleanExpression)
        op = expression.op
        op == :NOT || op == :!= || op == :'NOT IN' || op == :'IS NOT' || op.to_s.start_with?("NOT ")
      end

      def unioned(branches)
        branches.inject do |left, right|
          left.union(right, :all => false, :from_self => false)
        end
      end

      def pad_branch(ds, relation)
        selected = ds.opts[:select].map { |column| unwrap_alias(column) }
        ds.select(*global_select(relation, selected))
      end

      def prepare_recursive_branch(ds, relation)
        info = direct_info(ds, relation)
        target = info[:relation]
        ds = add_label_predicate(ds, info)
        opts = ds.opts.dup
        opts[:from] = Array(opts[:from]).map.with_index do |source, index|
          info[:location] == :from && info[:index] == index ?
            replace_table(source, info[:qualifier]) : source
        end
        opts[:join] = Array(opts[:join]).map.with_index do |join, index|
          if info[:location] == :join && info[:index] == index
            replace_join_table(join, info[:qualifier])
          else
            join
          end
        end

        transformed = RelationRewriter.new(info[:relation], info[:qualifier], @slot_by_relation[target]).transform(opts)
        selected = transformed[:select].map { |column| unwrap_alias(column) }
        ds.clone(transformed).select(*global_select(relation, selected))
      end

      def direct_info(ds, relation)
        Array(ds.opts[:from]).each_with_index do |source, index|
          if (target = extract_ref(source).first)
            return info(target.value, :from, index, source, table_alias(source), :where)
          end
        end

        Array(ds.opts[:join]).each_with_index do |join, index|
          if (target = join_relation(join))
            location = join.is_a?(SQL::JoinOnClause) ? :join_on : :join
            return info(target.value, :join, index, join.table_expr, join.table_alias || UNION_NAME, location)
          end
        end

        raise Error,
          "mutual_recursive recursive branch for #{relation.inspect} must reference exactly one recursive relation"
      end

      def info(target, location, index, expression, qualifier, join_location)
        qualifier ||= UNION_NAME
        {:relation => target, :location => location, :index => index,
         :expression => expression, :qualifier => qualifier,
         :join_location => join_location}
      end

      def add_label_predicate(ds, info)
        predicate = {Sequel.qualify(info[:qualifier], LABEL_COLUMN) => info[:relation].to_s}
        if info[:location] == :from || info[:join_location] != :join_on
          ds.where(predicate)
        else
          joins = ds.opts[:join].map.with_index do |join, index|
            next join unless index == info[:index]
            on = join.on ? SQL::BooleanExpression.new(:AND, join.on,
              SQL::BooleanExpression.from_value_pairs(predicate)) :
              SQL::BooleanExpression.from_value_pairs(predicate)
            SQL::JoinOnClause.new(on, join.join_type, join.table_expr)
          end
          ds.clone(:join => joins)
        end
      end

      def replace_table(source, qualifier)
        if source.is_a?(SQL::AliasedExpression)
          SQL::AliasedExpression.new(SQL::Identifier.new(UNION_NAME), source.alias)
        elsif qualifier == UNION_NAME
          SQL::Identifier.new(UNION_NAME)
        else
          SQL::AliasedExpression.new(SQL::Identifier.new(UNION_NAME), qualifier)
        end
      end

      def replace_join_table(join, qualifier)
        table_expr = replace_table(join.table_expr, qualifier)
        if join.is_a?(SQL::JoinOnClause)
          SQL::JoinOnClause.new(join.on, join.join_type, table_expr)
        elsif join.is_a?(SQL::JoinUsingClause)
          SQL::JoinUsingClause.new(join.using, join.join_type, table_expr)
        else
          SQL::JoinClause.new(join.join_type, table_expr)
        end
      end

      def table_alias(expression)
        expression.is_a?(SQL::AliasedExpression) ? expression.alias : nil
      end

      def unwrap_alias(expression)
        expression.is_a?(SQL::AliasedExpression) ? expression.expression : expression
      end

      def global_select(relation, selected)
        own_slots = @slot_by_relation[relation].values
        @slots.map do |slot|
          index = own_slots.index(slot)
          index ? Sequel.as(selected[index], slot) : Sequel.as(SQL::Constants::NULL, slot)
        end + [Sequel.as(relation.to_s, LABEL_COLUMN)]
      end

      def empty_select
        @slots.map { |slot| Sequel.as(SQL::Constants::NULL, slot) } +
          [Sequel.as(SQL::Constants::NULL, LABEL_COLUMN)]
      end

      def empty_branch
        @db.select(*empty_select).where(false)
      end

      def stop_branch
        @db[UNION_NAME].where(false).select(*empty_select)
      end

      def slot_name(relation, column)
        :"_sequel_mutual_recursive_#{relation}_#{column}"
      end
    end

    class RelationRewriter < ASTTransformer
      def initialize(relation, qualifier, columns)
        @relation = relation.to_s
        @qualifier = qualifier.to_s
        @columns = columns.merge(LABEL_COLUMN => LABEL_COLUMN)
      end

      private

      def v(object)
        case object
        when SQL::QualifiedIdentifier
          table = identifier_name(object.table)
          if table == @relation || table == @qualifier
            column = identifier_name(object.column).to_sym
            unless (slot = @columns[column])
              raise Error, "mutual_recursive relation #{@relation.inspect} does not have column #{column.inspect}"
            end
            SQL::QualifiedIdentifier.new(@qualifier, slot)
          else
            super
          end
        when SQL::Identifier
          if object.value.to_s == @relation
            SQL::Identifier.new(@qualifier)
          else
            super
          end
        when SQL::ColumnAll
          if identifier_name(object.table).to_s == @relation || identifier_name(object.table).to_s == @qualifier
            raise Error, "mutual_recursive does not support selecting all columns from a recursive relation"
          else
            super
          end
        when RelationRef
          raise Error, "mutual_recursive recursive relations can only be used as direct FROM/JOIN tables"
        else
          super
        end
      end

      def identifier_name(value)
        case value
        when SQL::Identifier then value.value
        when SQL::QualifiedIdentifier then value.column
        else value
        end.to_s
      end
    end

    module DatabaseMethods
      def mutual_recursive(specs)
        Compiler.new(self, specs).compile
      end
      alias with_mutual_recursive mutual_recursive
    end
  end

  Database.register_extension(:mutual_recursive, MutualRecursive::DatabaseMethods)
end
