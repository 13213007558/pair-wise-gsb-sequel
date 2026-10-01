# frozen-string-literal: true
#
# The correlated_exists_to_join extension can rewrite supported correlated
# EXISTS and NOT EXISTS filters into equivalent semi-joins and anti-joins.
# The rewrite is opt-in and only rewrites cases that can be proven equivalent.
# Unsupported filters are left unchanged.
#
#   ds = ds.extension(:correlated_exists_to_join).correlated_exists_to_join
#
# You can collect the reason for each unsupported predicate:
#
#   skipped = []
#   ds.extension(:correlated_exists_to_join).correlated_exists_to_join(skipped)
#
# Related module: Sequel::CorrelatedExistsToJoin

module Sequel
  module CorrelatedExistsToJoin
    # Rewrite supported correlated EXISTS predicates in the WHERE clause into
    # semi-joins or anti-joins. Unsupported predicates are retained.
    #
    # If +skipped+ is given, it receives a [reason, expression] pair for every
    # predicate that cannot be rewritten. The method can also yield the pair.
    def correlated_exists_to_join(skipped=nil)
      where = opts[:where]
      return self if where.nil?

      analyzer = Analyzer.new(self)
      result = analyzer.rewrite_boolean(where, self) do |reason, expression|
        skipped << [reason, expression] if skipped
        yield(reason, expression) if block_given?
      end

      return self unless result.changed
      result.dataset
    end

    class Analyzer
      EXISTS_STR = ["EXISTS ".freeze].freeze
      private_constant :EXISTS_STR

      AGGREGATE_FUNCTIONS = %i[
        array_agg avg bit_and bit_or bool_and bool_or count every
        group_concat json_agg jsonb_agg max min stddev stddev_pop stddev_samp
        string_agg sum variance var_pop var_samp xml_agg
      ].freeze
      private_constant :AGGREGATE_FUNCTIONS

      def initialize(dataset)
        @dataset = dataset
      end

      def rewrite_boolean(expression, dataset, &skip)
        terms = and_terms(expression)
        base_aliases = source_aliases(dataset)
        base = preserve_original_projection(dataset.clone(:where=>nil), base_aliases)
        rewritten_terms = []
        changed = false

        terms.each do |term|
          rewritten = rewrite_term(term, base, &skip)
          if rewritten.changed
            changed = true
            rewritten_terms.concat(and_terms(rewritten.where_expr) || [rewritten.where_expr])
            base = rewritten.dataset
          else
            rewritten_terms << term
          end
        end

        return Result.unchanged(dataset, expression) unless changed

        where_expr = combine_terms(rewritten_terms)
        base = base.where(where_expr) if where_expr
        Result.new(base, where_expr || true)
      end

      private

      def preserve_original_projection(dataset, aliases)
        select = dataset.opts[:select]
        wildcard_selected = select && select.length == 1 &&
          (select.first == :* || select.first == SQL::Function::WILDCARD)
        if select.nil? || wildcard_selected
          dataset.select(*aliases.map { |aliaz| SQL::ColumnAll.new(aliaz) })
        else
          dataset
        end
      end

      def rewrite_term(term, dataset, &skip)
        exists = extract_exists(term)
        return skip_unsupported(:unsupported_boolean, term, dataset, &skip) unless exists

        negated, inner_dataset = exists
        rewrite_exists(negated, inner_dataset, term, dataset, &skip)
      end

      def rewrite_exists(negated, inner_dataset, term, dataset, &skip)
        unless negated || !dataset.opts[:join]
          skip.call(:mixed_with_anti_join, term) if skip
          return Result.unchanged(dataset, term)
        end

        reason = unsupported_reason(inner_dataset)
        if reason
          skip.call(reason, term) if skip
          return Result.unchanged(dataset, term)
        end

        inner_alias = inner_dataset.first_source_alias
        correlation = analyze_where(inner_dataset.opts[:where], inner_alias, source_aliases(dataset))
        if correlation.is_a?(Symbol)
          skip.call(correlation, term) if skip
          return Result.unchanged(dataset, term)
        end

        equalities = correlation[:equalities]
        if equalities.empty?
          skip.call(:not_correlated, term) if skip
          return Result.unchanged(dataset, term)
        end

        key_pairs = equalities.map.with_index do |equality, index|
          inner_side, outer_side = equality
          key_alias = :"sequel_exists_key_#{index + 1}"
          [inner_side.as(key_alias), outer_side, key_alias]
        end
        filters = correlation[:local]
        if negated
          filters += equalities.map do |inner_side, _|
            SQL::BooleanExpression.new(:"IS NOT", inner_side, nil)
          end
        end
        filtered_inner = inner_dataset.clone(:where=>combine_terms(filters))

        join_dataset = filtered_inner.unordered.unlimited.select(*key_pairs.map(&:first)).distinct
        join_alias = dataset.unused_table_alias(:"#{inner_alias}_exists")
        join_on = key_pairs.map do |_, outer_side, key_alias|
          SQL::BooleanExpression.new(:"=", SQL::QualifiedIdentifier.new(join_alias, key_alias), outer_side)
        end
        join_on = combine_terms(join_on)
        joined = dataset.join_table(negated ? :left_outer : :inner, join_dataset.as(join_alias), join_on)
        if negated
          anti_condition = combine_terms(key_pairs.map do |_, _, key_alias|
            SQL::BooleanExpression.from_value_pairs([[SQL::QualifiedIdentifier.new(join_alias, key_alias), nil]])
          end)
        else
          anti_condition = nil
        end

        Result.new(joined, anti_condition)
      end

      def analyze_where(expression, inner_alias, outer_aliases)
        local = []
        equalities = []
        terms = expression ? and_terms(expression) : []
        return :not_conjunctive unless terms

        terms.each do |term|
          equality = inner_outer_equality(term, inner_alias, outer_aliases)
          if equality == false
            local << term
          elsif equality.nil?
            reason = unsupported_correlation_reason(term, inner_alias, outer_aliases)
            return reason unless reason == :unsupported_predicate
            local << term
          else
            equalities << equality
          end
        end

        {:local=>local, :equalities=>equalities}
      end

      def inner_outer_equality(expression, inner_alias, outer_aliases)
        return nil unless equality_expression?(expression)

        left, right = expression.args
        left_side = correlation_side(left, inner_alias, outer_aliases)
        right_side = correlation_side(right, inner_alias, outer_aliases)
        return nil unless left_side && right_side
        return nil if left_side.first == right_side.first
        return nil unless column_reference?(left) && column_reference?(right)

        if left_side.first == :inner
          [left, right]
        else
          [right, left]
        end
      end

      def correlation_side(expression, inner_alias, outer_aliases)
        reference = single_table_reference(expression)
        return nil unless reference

        table, = reference
        return nil if table.nil?
        if table == inner_alias.to_s
          [:inner, table]
        elsif outer_aliases.map(&:to_s).include?(table)
          [:outer, table]
        else
          [:other, table]
        end
      end

      def unsupported_correlation_reason(expression, inner_alias, outer_aliases)
        if contains_unsupported_reference_in_datasets?(expression, inner_alias, outer_aliases)
          return :cross_level_reference
        end
        tables = table_references(expression).map(&:first).uniq
        if tables.any? { |table| table && table != inner_alias.to_s && !outer_aliases.map(&:to_s).include?(table) }
          return :cross_level_reference
        end
        return :unsupported_correlation if tables.any? { |table| outer_aliases.map(&:to_s).include?(table) }
        :unsupported_predicate
      end

      def unsupported_reason(dataset)
        unless dataset.is_a?(Dataset)
          return :unsupported_exists
        end
        return :static_sql if dataset.opts[:sql]
        return :compound_query if dataset.opts[:compounds]
        return :with_clause if dataset.opts[:with]
        return :subquery if dataset.opts[:from]&.first&.is_a?(Dataset)
        return :join if dataset.opts[:join]
        return :multiple_sources unless Array(dataset.opts[:from]).length == 1
        return :distinct if dataset.opts[:distinct]
        return :aggregate if dataset.opts[:group] || dataset.opts[:having]
        return :limit if dataset.opts[:limit] || dataset.opts[:offset]

        outer_aliases = source_aliases(dataset)
        [*dataset.opts[:select], dataset.opts[:where]].each do |expression|
          reason = expression_unsupported_reason(expression, outer_aliases)
          return reason if reason
        end
        nil
      end

      def expression_unsupported_reason(expression, outer_aliases=nil)
        case expression
        when nil, Symbol, Numeric, String, SQL::QualifiedIdentifier, SQL::Identifier,
             SQL::ColumnAll, true, false
          nil
        when SQL::Function
          return :aggregate if AGGREGATE_FUNCTIONS.include?(function_name(expression))
          return :window_function if expression.opts[:over]
          expression.args.each do |argument|
            reason = expression_unsupported_reason(argument, outer_aliases)
            return reason if reason
          end
          nil
        when SQL::ComplexExpression, SQL::CaseExpression, SQL::Cast, SQL::Subscript,
             SQL::OrderedExpression, SQL::Wrapper, SQL::Window
          ast_children(expression).each do |child|
            reason = expression_unsupported_reason(child, outer_aliases)
            return reason if reason
          end
          nil
        when SQL::AliasedExpression
          expression_unsupported_reason(expression.expression, outer_aliases)
        when SQL::PlaceholderLiteralString
          Array(expression.args).each do |argument|
            reason = expression_unsupported_reason(argument, outer_aliases)
            return reason if reason
          end
          nil
        when Dataset
          nil
        else
          if expression.respond_to?(:args)
            expression.args.each do |argument|
              reason = expression_unsupported_reason(argument, outer_aliases)
              return reason if reason
            end
          end
          nil
        end
      end

      def ast_children(expression)
        case expression
        when SQL::ComplexExpression
          expression.args
        when SQL::CaseExpression
          [expression.default, expression.expression, expression.conditions].compact
        when SQL::Cast
          [expression.expr, expression.type]
        when SQL::Subscript
          [expression.expression, expression.sub]
        when SQL::AliasedExpression
          [expression.expression]
        when SQL::PlaceholderLiteralString
          Array(expression.args)
        when SQL::OrderedExpression
          [expression.expression]
        when SQL::Wrapper
          [expression.value]
        when SQL::Window
          expression.opts.values
        else
          []
        end
      end

      def contains_unsupported_reference_in_datasets?(expression, inner_alias, outer_aliases)
        expression_contains_unsupported_reference_in_dataset?(
          expression, [inner_alias.to_s, *outer_aliases.map(&:to_s)], false
        )
      end

      def expression_contains_unsupported_reference_in_dataset?(
        expression, correlation_aliases, nested
      )
        case expression
        when Dataset
          permitted_aliases = nested ? correlation_aliases : correlation_aliases[0..-2]
          dataset_contains_unsupported_reference?(expression, permitted_aliases, true)
        when Array
          expression.any? do |child|
            expression_contains_unsupported_reference_in_dataset?(
              child, correlation_aliases, nested
            )
          end
        when SQL::ComplexExpression, SQL::CaseExpression, SQL::Cast, SQL::Subscript,
             SQL::OrderedExpression, SQL::Wrapper, SQL::AliasedExpression,
             SQL::PlaceholderLiteralString, SQL::Function
          ast_children(expression).any? do |child|
            expression_contains_unsupported_reference_in_dataset?(
              child, correlation_aliases, nested
            )
          end
        else
          false
        end
      end

      def dataset_contains_unsupported_reference?(dataset, correlation_aliases, nested)
        local_aliases = source_aliases(dataset)
        expressions = [
          *dataset.opts[:select], dataset.opts[:where], dataset.opts[:having],
          *Array(dataset.opts[:group]), *Array(dataset.opts[:order])
        ]
        expressions.concat(Array(dataset.opts[:from]).select { |source| source.is_a?(Dataset) })
        expressions += Array(dataset.opts[:join]).map(&:on)
        expressions.compact.any? do |expression|
          tables = table_references(expression).map(&:first).uniq
          tables.any? do |table|
            !local_aliases.map(&:to_s).include?(table) &&
              !correlation_aliases.include?(table)
          end || expression_contains_unsupported_reference_in_dataset?(
            expression,
            nested ? [] : [local_aliases.first.to_s],
            true
          )
        end
      end

      def extract_exists(expression)
        if exists_expression?(expression)
          [false, exists_dataset(expression)]
        elsif negated_exists_expression?(expression)
          [true, exists_dataset(expression.args.first)]
        end
      end

      def exists_expression?(expression)
        expression.is_a?(SQL::PlaceholderLiteralString) &&
          expression.str == EXISTS_STR &&
          expression.parens &&
          expression.args.is_a?(Array) &&
          expression.args.length == 1
      end

      def negated_exists_expression?(expression)
        expression.is_a?(SQL::BooleanExpression) &&
          expression.op == :NOT &&
          expression.args.length == 1 &&
          exists_expression?(expression.args.first)
      end

      def exists_dataset(expression)
        expression.args.first
      end

      def equality_expression?(expression)
        expression.is_a?(SQL::BooleanExpression) &&
          expression.op == :'=' &&
          expression.args.length == 2
      end

      def column_reference?(expression)
        expression.is_a?(Symbol) || expression.is_a?(SQL::QualifiedIdentifier) || expression.is_a?(SQL::Identifier)
      end

      def single_table_reference(expression)
        references = table_references(expression)
        references.first if references.length == 1
      end

      def table_references(expression)
        case expression
        when Symbol
          table = nil
          column = expression.to_s
          if Sequel.split_symbols?
            table, column = @dataset.send(:split_symbol, expression)
          end
          [[table, column]]
        when SQL::QualifiedIdentifier
          [[expression.table.to_s, expression.column.to_s]]
        when SQL::Identifier
          [[nil, expression.value.to_s]]
        when SQL::ComplexExpression, SQL::CaseExpression, SQL::Cast, SQL::Subscript,
             SQL::OrderedExpression, SQL::Wrapper, SQL::AliasedExpression,
             SQL::PlaceholderLiteralString, SQL::Function
          ast_children(expression).flat_map { |child| table_references(child) }
        else
          []
        end
      end

      def and_terms(expression)
        if expression.is_a?(SQL::BooleanExpression) && expression.op == :AND
          expression.args.flat_map { |argument| and_terms(argument) || [argument] }
        else
          [expression]
        end
      end

      def combine_terms(terms)
        terms = terms.compact
        return nil if terms.empty?
        return terms.first if terms.length == 1
        SQL::BooleanExpression.new(:AND, *terms)
      end

      def source_aliases(dataset)
        sources = Array(dataset.opts[:from]).map { |source| alias_from_source(source) }
        joins = Array(dataset.opts[:join]).map { |join| join.table_alias || alias_from_source(join.table) }
        (sources + joins).compact
      end

      def alias_from_source(source)
        case source
        when Symbol
          @dataset.send(:alias_symbol, source)
        when SQL::AliasedExpression
          source.alias
        when SQL::QualifiedIdentifier
          source.column
        when SQL::Identifier
          source.value
        when String
          source.to_sym
        when Dataset
          source.first_source_alias
        end
      end

      def function_name(expression)
        expression.name.to_s.downcase.to_sym
      end

      def skip_unsupported(reason, expression, dataset)
        yield(reason, expression) if block_given?
        Result.unchanged(dataset, expression)
      end

      class Result
        attr_reader :dataset, :where_expr
        attr_reader :changed

        def initialize(dataset, where_expr)
          @dataset = dataset
          @where_expr = where_expr
          @changed = true
          freeze
        end

        def self.unchanged(dataset, where_expr)
          result = allocate
          result.instance_variable_set(:@dataset, dataset)
          result.instance_variable_set(:@where_expr, where_expr)
          result.instance_variable_set(:@changed, false)
          result.freeze
        end
      end
    end
  end

  Dataset.register_extension(:correlated_exists_to_join, CorrelatedExistsToJoin)
end
