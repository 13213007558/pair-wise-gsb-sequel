# frozen-string-literal: true
#
# The exists_to_join extension can rewrite supported correlated EXISTS and
# NOT EXISTS filters into deduplicated inner joins and marked left joins,
# respectively. It is opt-in: loading the extension only adds the rewriting
# methods, and a query is not changed until one of them is called.
#
#   DB.extension(:exists_to_join)
#   DB[:orders].where(DB[:items].where(items__order_id: orders__id).exists).
#     rewrite_exists_to_joins
#
# The supported shape is a top-level EXISTS or NOT EXISTS whose subquery:
#
# * has one simple FROM table,
# * has no join, GROUP, HAVING, aggregate, LIMIT/OFFSET, compound, or lock,
# * correlates through top-level equality conditions, and
# * otherwise uses only local filters.
#
# Unsupported queries are returned unchanged. Use the non-bang form and array
# destructuring to receive the dataset and the reasons why rewriting was not
# possible:
#
#   dataset, reasons = ds.rewrite_exists_to_joins
#
# Related module: Sequel::Dataset::ExistsToJoin

module Sequel
  class Dataset
    module ExistsToJoin
      EXISTS_STR = ["EXISTS ".freeze].freeze
      AGGREGATE_FUNCTIONS = [:avg, :count, :every, :group_concat, :max, :min,
                             :some, :stddev, :stddev_pop, :stddev_samp,
                             :string_agg, :sum, :var_pop, :var_samp, :variance].freeze

      # Rewrite supported top-level EXISTS and NOT EXISTS filters. Always
      # returns the rewritten dataset and an array of skip reasons. When no
      # rewrite is possible, the returned dataset is the receiver.
      def rewrite_exists_to_joins
        analyzer = ExistsToJoinAnalyzer.new(self)
        [analyzer.rewrite, analyzer.reasons]
      end
      alias_method :rewrite_correlated_exists_to_joins, :rewrite_exists_to_joins

      # Rewrite the dataset, returning the dataset instead of the skip reasons.
      def rewrite_exists_to_joins!
        rewrite_exists_to_joins.first
      end
      alias_method :rewrite_correlated_exists_to_joins!, :rewrite_exists_to_joins!

      private

      # Internal analyzer. The public API is on Dataset#rewrite_exists_to_joins.
      class ExistsToJoinAnalyzer
        attr_reader :reasons

        def initialize(dataset)
          @dataset = dataset
          @reasons = []
          @outer_aliases = source_aliases(dataset, true)
        end

        def rewrite
          return @dataset unless supported_outer?

          predicates = top_level_and_arguments(@dataset.opts[:where])
          return skip("no top-level EXISTS or NOT EXISTS filter") if predicates.nil?

          exists_predicates = predicates.select { |predicate| exists_expression?(predicate) }
          return skip("no top-level EXISTS or NOT EXISTS filter") if exists_predicates.empty?

          residual = predicates.reject { |predicate| exists_expression?(predicate) }
          rewrites = exists_predicates.map { |predicate| rewrite_predicate(predicate) }
          return @dataset if rewrites.any?(&:nil?)

          build_dataset(residual, rewrites)
        end

        private

        def supported_outer?
          if @dataset.opts[:sql]
            skip("dataset uses raw SQL")
          elsif @dataset.opts[:from].nil? || @dataset.opts[:from].empty?
            skip("dataset has no FROM clause")
          elsif @dataset.opts[:compounds]
            skip("dataset uses a compound query")
          else
            true
          end
        end

        def rewrite_predicate(predicate)
          negated = predicate.is_a?(SQL::BooleanExpression) && predicate.op == :NOT
          exists = negated ? predicate.args.first : predicate
          subquery = exists.args.first

          unless subquery.is_a?(Dataset)
            return skip("EXISTS argument is not a dataset")
          end

          analysis = analyze_subquery(subquery)
          return nil unless analysis

          {:negated=>negated, :subquery=>subquery}.merge!(analysis)
        end

        def analyze_subquery(subquery)
          unless supported_subquery_shape?(subquery)
            return nil
          end

          inner_aliases = source_aliases(subquery, false)
          if inner_aliases.empty?
            return skip("EXISTS subquery has no simple table source")
          end
          if inner_aliases.length > 1 || subquery.opts[:join]
            return skip("EXISTS subquery joins multiple sources")
          end

          predicates = top_level_and_arguments(subquery.opts[:where])

          correlations = []
          local = []

          predicates.each do |predicate|
            return skip("EXISTS subquery uses OR in its WHERE clause") if uses_or?(predicate)
            equality = equality_correlation(predicate, inner_aliases)
            if equality
              correlations << equality
            elsif nested_outer_reference?(predicate)
              return skip("EXISTS subquery uses a cross-level reference")
            elsif references_alias?(predicate, @outer_aliases)
              return skip("correlated predicate is not an equality condition")
            else
              local << predicate
            end
          end

          if correlations.empty?
            return skip("EXISTS subquery is not correlated by an equality condition")
          end

          {:inner_aliases=>inner_aliases, :correlations=>correlations,
           :local=>local}
        end

        def supported_subquery_shape?(subquery)
          options = subquery.opts
          if options[:with]
            skip("EXISTS subquery uses a CTE")
          elsif options[:limit] || options[:offset]
            skip("EXISTS subquery uses LIMIT or OFFSET")
          elsif options[:group] || options[:having]
            skip("EXISTS subquery uses aggregation")
          elsif options[:compounds]
            skip("EXISTS subquery uses a compound query")
          elsif options[:lock]
            skip("EXISTS subquery uses a locking clause")
          elsif contains_aggregate?(options[:select]) ||
                contains_aggregate?(options[:where]) ||
                contains_aggregate?(options[:group])
            skip("EXISTS subquery uses an aggregate expression")
          elsif subquery_from_subquery?(subquery)
            skip("EXISTS subquery uses a subquery source")
          elsif !simple_source?(Array(options[:from]).first)
            skip("EXISTS subquery has no simple table source")
          elsif Array(options[:from]).length > 1
            skip("EXISTS subquery joins multiple sources")
          else
            true
          end
        end

        def build_dataset(residual, rewrites)
          dataset = @dataset.clone(:where=>combine_and(residual))
          selected = @dataset.opts[:select]

          rewrites.each_with_index do |rewrite, index|
            join_alias = @dataset.unused_table_alias(:"_sequel_exists_#{index}", used_join_aliases(dataset))
            key_aliases = rewrite[:correlations].each_with_index.map do |_, key_index|
              :"_sequel_exists_key_#{index}_#{key_index}"
            end
            marker_alias = :"_sequel_exists_match_#{index}" if rewrite[:negated]

            selections = rewrite[:correlations].each_with_index.map do |correlation, key_index|
              correlation[:inner].as(key_aliases[key_index])
            end
            selections << SQL::AliasedExpression.new(1, marker_alias) if marker_alias

            joined_subquery = rewrite[:subquery].
              clone(:select=>nil, :where=>combine_and(rewrite[:local]), :order=>nil)
            joined_subquery = joined_subquery.select(*selections).distinct

            condition = rewrite[:correlations].each_with_index.map do |correlation, key_index|
              SQL::QualifiedIdentifier.new(join_alias, key_aliases[key_index]) =~ correlation[:outer]
            end.inject(&:&)

            if rewrite[:negated]
              dataset = dataset.left_join(joined_subquery.as(join_alias), condition, :qualify=>false).
                where(SQL::QualifiedIdentifier.new(join_alias, marker_alias)=>nil)
            else
              dataset = dataset.inner_join(joined_subquery.as(join_alias), condition, :qualify=>false)
            end
          end

          if selected && !selected.empty?
            dataset = dataset.select(*selected)
          else
            dataset = dataset.select(*original_wildcards)
          end

          dataset
        end

        def used_join_aliases(dataset)
          Array(dataset.opts[:join]).map { |join| join.table_alias }.compact
        end

        def original_wildcards
          source_expressions(@dataset, true).map do |source|
            SQL::ColumnAll.new(source_alias(source))
          end
        end

        def equality_correlation(predicate, inner_aliases)
          return nil unless predicate.is_a?(SQL::BooleanExpression) && predicate.op == :'='
          left, right = predicate.args
          left_inner = references_alias?(left, inner_aliases) && !references_alias?(left, @outer_aliases)
          right_inner = references_alias?(right, inner_aliases) && !references_alias?(right, @outer_aliases)
          left_outer = references_alias?(left, @outer_aliases) && !references_alias?(left, inner_aliases)
          right_outer = references_alias?(right, @outer_aliases) && !references_alias?(right, inner_aliases)

          if left_inner && right_outer
            {:inner=>left, :outer=>right}
          elsif right_inner && left_outer
            {:inner=>right, :outer=>left}
          end
        end

        def top_level_and_arguments(expression)
          case expression
          when nil
            []
          when SQL::BooleanExpression
            if expression.op == :AND
              expression.args.flat_map { |argument| top_level_and_arguments(argument) || return }
            else
              [expression]
            end
          else
            [expression]
          end
        end

        def exists_expression?(expression)
          if expression.is_a?(SQL::PlaceholderLiteralString)
            expression.str == EXISTS_STR && expression.args.is_a?(Array) && expression.args.length == 1
          elsif expression.is_a?(SQL::BooleanExpression) && expression.op == :NOT && expression.args.length == 1
            expression.args.first.is_a?(SQL::PlaceholderLiteralString) && exists_expression?(expression.args.first)
          else
            false
          end
        end

        def uses_or?(expression)
          case expression
          when SQL::BooleanExpression
            expression.op == :OR || expression.args.any? { |argument| uses_or?(argument) }
          when SQL::CaseExpression
            uses_or?(expression.conditions) || uses_or?(expression.default) || uses_or?(expression.expression)
          when SQL::Function
            uses_or?(expression.args) || uses_or?(expression.opts)
          when Array
            expression.any? { |item| uses_or?(item) }
          when Hash
            expression.values.any? { |item| uses_or?(item) }
          else
            false
          end
        end

        def combine_and(predicates)
          return nil if predicates.empty?
          return predicates.first if predicates.length == 1
          SQL::BooleanExpression.new(:AND, *predicates)
        end

        def contains_aggregate?(expression)
          each_expression_node(expression) do |node|
            if node.is_a?(SQL::Function) && AGGREGATE_FUNCTIONS.include?(node.name.to_s.downcase.to_sym)
              return true
            end
          end
          false
        end

        def subquery_from_subquery?(subquery)
          Array(subquery.opts[:from]).any? do |source|
            source.is_a?(Dataset) ||
              (source.is_a?(SQL::AliasedExpression) && source.expression.is_a?(Dataset))
          end
        end

        def simple_source?(source)
          source.is_a?(Symbol) || source.is_a?(SQL::Identifier) || source.is_a?(SQL::QualifiedIdentifier) ||
            (source.is_a?(SQL::AliasedExpression) && simple_source?(source.expression))
        end

        def nested_outer_reference?(expression)
          datasets = []
          collect_nested_datasets(expression, 0, datasets)
          datasets.any? do |depth, dataset|
            depth >= 1 &&
              (references_alias?(dataset.opts[:where], @outer_aliases, true) ||
               references_alias?(dataset.opts[:having], @outer_aliases, true))
          end
        end

        def collect_nested_datasets(expression, depth, datasets)
          each_expression_node_with_dataset_depth(expression, depth) do |node, node_depth|
            datasets << [node_depth, node] if node.is_a?(Dataset)
          end
        end

        def references_alias?(expression, aliases, skip_nested_datasets = false)
          return false if expression.nil? || aliases.empty?
          each_expression_node(expression) do |node|
            next if skip_nested_datasets && node.is_a?(Dataset)
            case node
            when SQL::QualifiedIdentifier
              return true if aliases.any? { |table_alias| same_identifier?(table_alias, node.table) }
            when Symbol
              table = symbol_table(node)
              return true if table && aliases.any? { |table_alias| same_identifier?(table_alias, table) }
            end
          end
          false
        end

        def same_identifier?(left, right)
          if left.is_a?(Symbol) || left.is_a?(::String) || right.is_a?(Symbol) || right.is_a?(::String)
            left.to_s == right.to_s
          else
            left == right
          end
        end

        def each_expression_node(node, &block)
          yield(node)
          return if node.is_a?(Dataset)

          case node
          when Array
            node.each { |item| each_expression_node(item, &block) }
          when Hash
            node.each_value { |item| each_expression_node(item, &block) }
          when SQL::ComplexExpression, SQL::CaseExpression, SQL::Function, SQL::Subscript
            enumerable_node_values(node).each { |item| each_expression_node(item, &block) }
          when SQL::QualifiedIdentifier
            yield(node.table)
            yield(node.column)
          when SQL::Identifier
            yield(node.value)
          when SQL::AliasedExpression
            each_expression_node(node.expression, &block)
          when SQL::PlaceholderLiteralString
            each_expression_node(node.args, &block)
          when SQL::JoinClause
            each_expression_node(node.table_expr, &block)
            each_expression_node(node.on, &block) if node.is_a?(SQL::JoinOnClause)
          end
        end

        def each_expression_node_with_dataset_depth(node, depth = 0, &block)
          yield(node, depth)

          case node
          when Array
            node.each { |item| each_expression_node_with_dataset_depth(item, depth, &block) }
          when Hash
            node.each_value { |item| each_expression_node_with_dataset_depth(item, depth, &block) }
          when SQL::ComplexExpression, SQL::CaseExpression, SQL::Function, SQL::Subscript
            enumerable_node_values(node).each { |item| each_expression_node_with_dataset_depth(item, depth, &block) }
          when SQL::QualifiedIdentifier
            yield(node.table, depth)
            yield(node.column, depth)
          when SQL::Identifier
            yield(node.value, depth)
          when SQL::AliasedExpression
            each_expression_node_with_dataset_depth(node.expression, depth + 1, &block)
          when SQL::PlaceholderLiteralString
            each_expression_node_with_dataset_depth(node.args, depth + 1, &block)
          when SQL::JoinClause
            each_expression_node_with_dataset_depth(node.table_expr, depth, &block)
            each_expression_node_with_dataset_depth(node.on, depth, &block) if node.is_a?(SQL::JoinOnClause)
          when Dataset
            node.opts.each_value { |item| each_expression_node_with_dataset_depth(item, depth, &block) }
          end
        end

        def enumerable_node_values(node)
          values = case node
          when SQL::ComplexExpression, SQL::Subscript
            node.args
          when SQL::Function
            [node.name, node.args, node.opts]
          when SQL::CaseExpression
            [node.conditions, node.default, node.expression]
          end
          Array(values)
        end

        def source_aliases(dataset, include_joins)
          source_expressions(dataset, include_joins).map { |source| source_alias(source) }.select do |alias_name|
            alias_name.is_a?(Symbol) || alias_name.is_a?(::String) ||
              alias_name.is_a?(SQL::QualifiedIdentifier) || alias_name.is_a?(SQL::Identifier)
          end.uniq
        end

        def source_expressions(dataset, include_joins)
          sources = Array(dataset.opts[:from])
          sources += Array(dataset.opts[:join]) if include_joins
          sources
        end

        def source_alias(source)
          case source
          when SQL::AliasedExpression
            source.alias
          when SQL::JoinClause
            source.table_alias || source.table
          when Symbol
            _, table, aliaz = @dataset.send(:split_symbol, source)
            aliaz ? aliaz.to_sym : (table ? table.to_sym : source)
          when SQL::QualifiedIdentifier
            source.column
          when SQL::Identifier
            source.value
          else
            source
          end
        end

        def symbol_table(symbol)
          table, = @dataset.send(:split_symbol, symbol)
          table ? table.to_sym : nil
        end

        def skip(reason)
          @reasons << reason
          nil
        end
      end

      private_constant :ExistsToJoinAnalyzer
    end

    register_extension(:exists_to_join, ExistsToJoin)
  end
end
