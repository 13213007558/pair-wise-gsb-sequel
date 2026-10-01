# frozen_string_literal: true

# The tuple_provenance extension annotates result rows with provenance
# polynomials over stable base-table row identifiers.  Base rows are
# variables, inner joins multiply variables, and UNION ALL combines
# alternate derivations additively.  The extension is intentionally
# limited to bag relational queries it can translate safely.
#
# Load it on an individual dataset and provide the stable identifier
# columns for each base table or table alias:
#
#   ds = DB[:items].
#     inner_join(:tags, item_id: :id).
#     extension(:tuple_provenance).
#     with_tuple_provenance(items: :id, tags: :id)
#
# Each row includes a monomial under +:_tuple_provenance+.  Calling
# +tuple_provenance+ groups duplicate output values and returns the
# corresponding polynomial.

require 'json'

module Sequel
  class Dataset
    module TupleProvenance
      TUPLE_PROVENANCE_COLUMN = :_tuple_provenance

      Variable = Struct.new(:relation, :key) do
        def to_s
          parts = key.map { |name, value| [name, value].join('=') }
          "#{relation}[#{parts.join(', ')}]"
        end
        alias_method :inspect, :to_s
      end

      class Monomial
        include Enumerable

        attr_reader :variables

        def initialize(variables)
          @variables = variables.freeze
          freeze
        end

        def each(&block)
          variables.each(&block)
        end

        def *(other)
          Monomial.new(variables + other.variables)
        end

        def ==(other)
          other.is_a?(Monomial) && variables == other.variables
        end
        alias_method :eql?, :==

        def hash
          variables.hash
        end

        def to_s
          variables.map(&:to_s).join(' * ')
        end
        alias_method :inspect, :to_s
      end

      class Polynomial
        include Enumerable

        attr_reader :terms

        def initialize(terms = {})
          @terms = terms.reject { |_, coefficient| coefficient.zero? }.freeze
          freeze
        end

        def each(&block)
          terms.each(&block)
        end

        def +(other)
          Polynomial.new(terms.merge(other.terms) { |_, left, right| left + right })
        end

        def ==(other)
          other.is_a?(Polynomial) && terms == other.terms
        end
        alias_method :eql?, :==

        def hash
          terms.hash
        end

        def to_s
          terms.map do |monomial, coefficient|
            coefficient == 1 ? monomial.to_s : "#{coefficient} * #{monomial}"
          end.join(' + ')
        end
        alias_method :inspect, :to_s
      end

      def with_tuple_provenance(keys)
        clone(:tuple_provenance_keys => keys.freeze, :tuple_provenance => true)
      end

      def tuple_provenance
        groups = Hash.new { |hash, row| hash[row] = Hash.new(0) }

        naked.with_row_proc(nil).each do |row|
          expression = row.delete(TUPLE_PROVENANCE_COLUMN)
          groups[row.to_h][expression] += 1
        end

        groups.transform_values { |terms| Polynomial.new(terms) }
      end

      def select_sql(*args)
        return super unless @opts[:tuple_provenance]
        build_tuple_provenance_dataset.select_sql(*args)
      end

      def each(*args, &block)
        return super unless @opts[:tuple_provenance]
        build_tuple_provenance_dataset.each(*args, &block)
      end

      private

      def build_tuple_provenance_dataset
        if tuple_provenance_wrapped_compound?
          validate_tuple_provenance_wrapped_query!
          inner = opts[:from].first.expression
          inner = inner.extension(:tuple_provenance).
            with_tuple_provenance(opts[:tuple_provenance_keys])
          return inner.send(:build_tuple_provenance_dataset)
        end

        validate_tuple_provenance_query!

        dataset = if Array(opts[:compounds]).any?
          relations = [rewrite_tuple_provenance_branch(self.clone(:compounds => nil))]
          opts[:compounds].each do |type, branch, all|
            unless type == :union && all
              raise InvalidOperation, 'tuple provenance only supports UNION ALL compounds'
            end
            relations << rewrite_tuple_provenance_branch(branch)
          end
          relations[1..].reduce(relations.first.dataset) do |union, relation|
            union.union(relation.dataset, all: true, from_self: false)
          end
        else
          rewrite_tuple_provenance_branch(self).dataset
        end

        dataset = dataset.with_row_proc(tuple_provenance_row_proc(row_proc))
        dataset
      end

      def tuple_provenance_row_proc(original_row_proc)
        proc do |row|
          token = row.delete(TUPLE_PROVENANCE_COLUMN)
          row = original_row_proc.call(row) if original_row_proc
          provenance = parse_tuple_provenance_token(token)

          if row.is_a?(Hash)
            row[TUPLE_PROVENANCE_COLUMN] = provenance
          else
            row.singleton_class.attr_accessor(TUPLE_PROVENANCE_COLUMN)
            row.public_send("#{TUPLE_PROVENANCE_COLUMN}=", provenance)
          end
          row
        end
      end

      def parse_tuple_provenance_token(token)
        variables = JSON.parse(token.to_s).map do |part|
          relation = part.fetch('relation').to_sym
          key = part.fetch('key').transform_keys(&:to_sym)
          Variable.new(relation, key)
        end
        Monomial.new(variables)
      end

      def validate_tuple_provenance_query!
        unless db.database_type == :sqlite
          raise InvalidOperation, 'tuple provenance is only supported with SQLite'
        end

        validate_tuple_provenance_dataset!(self)
        Array(opts[:compounds]).each do |type, dataset, all|
          unless type == :union && all
            raise InvalidOperation, 'tuple provenance only supports UNION ALL compounds'
          end
          validate_tuple_provenance_dataset!(dataset)
          if dataset.opts[:compounds]
            raise InvalidOperation, 'tuple provenance does not support nested compound queries'
          end
        end
      end

      def validate_tuple_provenance_dataset!(dataset)
        unsupported = [:sql, :with, :distinct, :group, :having, :lock,
          :lateral, :returning, :graph, :eager_graph, :window, :limit, :offset, :order]
        unsupported.each do |option|
          next unless dataset.opts[option]
          raise InvalidOperation, "tuple provenance does not support #{option} queries"
        end

        raise InvalidOperation, 'tuple provenance requires a FROM clause' unless dataset.opts[:from]

        source_aliases = []
        dataset.opts[:from].each do |source|
          validate_tuple_provenance_source!(source)
          source_aliases << tuple_provenance_source_name(source).last
        end

        Array(dataset.opts[:join]).each do |join|
          validate_tuple_provenance_source!(join.table_expr)
          source_aliases << tuple_provenance_source_name(join.table_expr).last
          unless join.join_type == :inner
            raise InvalidOperation, 'tuple provenance only supports inner joins'
          end
          if join.is_a?(SQL::JoinUsingClause)
            raise InvalidOperation, 'tuple provenance does not support JOIN USING'
          end
          unless join.is_a?(SQL::JoinOnClause)
            raise InvalidOperation, 'tuple provenance requires an ON clause for inner joins'
          end
          validate_tuple_provenance_expression!(join.on, true)
        end

        duplicate_alias = source_aliases.find { |source_alias| source_aliases.count(source_alias) > 1 }
        if duplicate_alias
          raise InvalidOperation, "duplicate tuple provenance source alias: #{duplicate_alias}"
        end

        validate_tuple_provenance_expression!(dataset.opts[:where], true)
        Array(dataset.opts[:select]).each do |expression|
          validate_tuple_provenance_expression!(expression, :select)
        end

        if dataset.opts[:select].nil? &&
            (Array(dataset.opts[:join]).any? || Array(dataset.opts[:from]).length > 1)
          raise InvalidOperation, 'tuple provenance requires an explicit projection for joins'
        end
      end

      def validate_tuple_provenance_source!(source)
        expression = source.is_a?(SQL::AliasedExpression) ? source.expression : source
        return if [Symbol, SQL::Identifier, SQL::QualifiedIdentifier].any? { |klass| expression.is_a?(klass) }
        raise InvalidOperation, "tuple provenance only supports base table sources: #{expression.class}"
      end

      def validate_tuple_provenance_expression!(expression, context)
        case expression
        when nil
          nil
        when LiteralString
          raise InvalidOperation, 'tuple provenance does not support literal SQL expressions'
        when SQL::AliasedExpression
          validate_tuple_provenance_expression!(expression.expression, context)
        when Symbol, SQL::Identifier, SQL::QualifiedIdentifier, SQL::ColumnAll
          nil
        when Numeric, true, false
          nil
        when String
          if context == :select
            raise InvalidOperation, 'tuple provenance does not support string SQL projections'
          end
        when SQL::BooleanExpression
          if context == :select && ![:AND, :OR].include?(expression.op)
            raise InvalidOperation, 'tuple provenance does not support boolean projections'
          end
          expression.args.each { |arg| validate_tuple_provenance_expression!(arg, true) }
        when SQL::NumericExpression, SQL::StringExpression, SQL::ComplexExpression
          expression.args.each { |arg| validate_tuple_provenance_expression!(arg, context) }
        when Array
          expression.each { |value| validate_tuple_provenance_expression!(value, true) }
        when Hash
          expression.each do |left, right|
            validate_tuple_provenance_expression!(left, true)
            validate_tuple_provenance_expression!(right, true)
          end
        else
          raise InvalidOperation, "tuple provenance does not support #{expression.class} expressions"
        end
      end

      def tuple_provenance_wrapped_compound?
        return false if opts[:compounds]
        source = Array(opts[:from]).first
        source.is_a?(SQL::AliasedExpression) &&
          source.expression.is_a?(Dataset) &&
          source.expression.opts[:compounds]
      end

      def validate_tuple_provenance_wrapped_query!
        allowed = [:from, :num_dataset_sources, :tuple_provenance,
          :tuple_provenance_keys, :row_proc, :compounds]
        unexpected = opts.select { |_, value| !value.nil? }.keys - allowed
        unless unexpected.empty?
          raise InvalidOperation, "tuple provenance does not support #{unexpected.first} queries"
        end
      end

      def rewrite_tuple_provenance_branch(dataset)
        primary, *additional_sources = dataset.opts[:from].map do |source|
          rewrite_tuple_provenance_source(source)
        end

        relation = additional_sources.reduce(primary) do |left, right|
          combine_tuple_provenance_relations(left, right, :cross, nil)
        end

        relation = Array(dataset.opts[:join]).reduce(relation) do |left, join|
          right = rewrite_tuple_provenance_source(join.table_expr)
          condition = join.is_a?(SQL::JoinOnClause) ? join.on : nil
          combine_tuple_provenance_relations(left, right, join.join_type, condition)
        end

        columns = tuple_provenance_select_columns(dataset, relation)
        query = relation.dataset
        query = query.where(dataset.opts[:where]) if dataset.opts[:where]
        query = query.select(*columns, relation.token.as(TUPLE_PROVENANCE_COLUMN))
        TupleProvenanceRelation.new(query, relation.token, relation.alias_columns)
      end

      def rewrite_tuple_provenance_source(source)
        table, aliaz = tuple_provenance_source_name(source)
        keys = tuple_provenance_keys_for(table, aliaz)
        internal_columns = tuple_provenance_table_columns(table).map do |column|
          Sequel.qualify(table, column)
        end
        token = tuple_provenance_base_token(aliaz, table, keys)
        base_source = tuple_provenance_base_source(source, table)
        subquery = db.from(base_source).select(*internal_columns, token.as(TUPLE_PROVENANCE_COLUMN))
        dataset = db.from(subquery.as(aliaz))
        visible_columns = internal_columns.map { |column| Sequel.qualify(aliaz, column.column) }
        TupleProvenanceRelation.new(dataset, Sequel.qualify(aliaz, TUPLE_PROVENANCE_COLUMN), visible_columns)
      end

      def tuple_provenance_base_source(source, table)
        case source
        when SQL::AliasedExpression
          source.expression
        when Symbol
          _, original_table, original_alias = split_symbol(source)
          original_alias ? original_table.to_sym : table
        else
          source
        end
      end

      def combine_tuple_provenance_relations(left, right, type, condition)
        right_source = right.dataset.opts[:from].first
        joined = left.dataset.join_table(type, right_source, condition)
        token = multiply_tuple_provenance_tokens(left.token, right.token)
        TupleProvenanceRelation.new(joined, token, left.alias_columns + right.alias_columns)
      end

      def tuple_provenance_source_name(source)
        case source
        when SQL::AliasedExpression
          [tuple_provenance_table_name(source.expression), source.alias]
        when Symbol
          _, table, aliaz = split_symbol(source)
          table = (table || source).to_sym
          aliaz = (aliaz || table).to_sym
          [table, aliaz]
        when SQL::Identifier
          [source.value.to_sym, source.value.to_sym]
        when SQL::QualifiedIdentifier
          column = tuple_provenance_identifier_value(source.column)
          [column, column]
        else
          raise InvalidOperation, "tuple provenance only supports base table sources: #{source.class}"
        end
      end

      def tuple_provenance_table_name(source)
        case source
        when Symbol
          (split_symbol(source)[1] || source).to_sym
        when SQL::Identifier
          source.value
        when SQL::QualifiedIdentifier
          tuple_provenance_identifier_value(source.column)
        else
          raise InvalidOperation, "tuple provenance only supports base table sources: #{source.class}"
        end
      end

      def tuple_provenance_identifier_value(identifier)
        identifier.is_a?(SQL::Identifier) ? identifier.value : identifier
      end

      def tuple_provenance_keys_for(table, aliaz)
        configured = opts[:tuple_provenance_keys]
        value = configured[aliaz] || configured[aliaz.to_s] ||
          configured[table] || configured[table.to_s]
        unless value
          raise InvalidOperation, "missing tuple provenance key for #{aliaz}"
        end
        Array(value).map(&:to_sym)
      end

      def tuple_provenance_table_columns(table)
        db.schema(table).map { |column,| column.to_sym }
      end

      def tuple_provenance_base_token(label, table, keys)
        arguments = [label.to_s]
        arguments.concat(keys.flat_map { |key| [key.to_s, Sequel.qualify(table, key)] })
        key_placeholders = (['?, ?'] * keys.length).join(', ')
        sql = "json_array(json_object('relation', ?, 'key', json_object(#{key_placeholders})))"
        Sequel.lit(sql, *arguments)
      end

      def multiply_tuple_provenance_tokens(left, right)
        Sequel.lit("('[' || substr(?, 2, length(?) - 2) || ',' || substr(?, 2, length(?) - 2) || ']')",
          left, left, right, right)
      end

      def tuple_provenance_select_columns(dataset, relation)
        selects = Array(dataset.opts[:select])
        return relation.alias_columns if selects.empty?

        selects.flat_map do |select|
          case select
          when SQL::ColumnAll
            source_alias = tuple_provenance_column_all_alias(select.table)
            relation.alias_columns.select { |column| column.table == source_alias }
          else
            [select]
          end
        end
      end

      def tuple_provenance_column_all_alias(table)
        case table
        when SQL::QualifiedIdentifier
          table.column
        when SQL::Identifier
          table.value
        else
          table
        end
      end

      TupleProvenanceRelation = Struct.new(:dataset, :token, :alias_columns)
    end

    register_extension(:tuple_provenance, TupleProvenance)
  end
end
