# frozen-string-literal: true
#
# The tuple_provenance dataset extension answers the question "which
# combinations of base table rows produced this result row?" (also known
# as how-provenance or semiring provenance).  While the provenance
# extension records where a query was constructed, tuple provenance
# records which input data produced each output row.
#
# For base tables with a stable row identity (a primary key, or +rowid+
# on SQLite), the extension rewrites the query so that every distinct
# output tuple carries a provenance expression:
#
# * Base table rows are identified by tokens such as <tt>orders[3]</tt>
#   (table name plus the row's stable identifier).
# * An inner join multiplies provenance: a result row produced by
#   combining <tt>items[1]</tt> and <tt>orders[2]</tt> has provenance
#   <tt>items[1]*orders[2]</tt>.
# * Alternative derivations of the same output tuple (duplicate
#   projections or UNION ALL branches) add provenance:
#   <tt>orders[1]+orders[2]</tt>.  Duplicate occurrences are preserved,
#   so the number of times a token appears in the expression is the
#   number of result rows that depend on that base row.
#
# Example:
#
#   DB.extension :tuple_provenance
#   DB[:items].join(:orders, item_id: :id).where{qty > 5}.select(:name).with_tuple_provenance
#   # SELECT name, group_concat(__tuple_provenance__, '+') AS tuple_provenance
#   # FROM (SELECT name, (...) AS __tuple_provenance__
#   #       FROM items INNER JOIN orders ON (orders.item_id = items.id)
#   #       WHERE (qty > 5)) AS t1
#   # GROUP BY name
#
# Only positive relational queries are supported: selection, projection,
# inner joins, and UNION ALL over physical base tables (or over subqueries
# that are themselves supported).  Aggregation, DISTINCT, EXCEPT/INTERSECT,
# plain UNION, outer joins, subqueries in predicates, LIMIT/OFFSET, and
# other constructs raise Sequel::InvalidOperation when
# with_tuple_provenance is called, instead of silently returning
# incomplete provenance.
#
# The summation of derivations uses group_concat (or string_agg on
# PostgreSQL), and row identifiers are cast to the database's string
# type.
#
# Related module: Sequel::Dataset::TupleProvenance

#
module Sequel
  class Dataset
    module TupleProvenance
      # The column in the returned dataset holding the provenance expression.
      PROVENANCE_COLUMN = :tuple_provenance

      # The column used to carry per-row provenance terms before summation.
      INTERNAL_COLUMN = :__tuple_provenance__

      # Dataset options that make a query unsupported, mapped to the
      # feature name used in error messages.
      UNSUPPORTED_OPTIONS = {
        distinct: "DISTINCT",
        group: "GROUP BY",
        having: "HAVING",
        limit: "LIMIT",
        offset: "OFFSET",
        order: "ORDER BY",
        with: "WITH",
        sql: "static SQL",
        lock: "locking clauses"
      }.freeze

      # Join types with positive relational semantics.
      SUPPORTED_JOIN_TYPES = [:inner, :cross].freeze

      # Return a dataset grouping the receiver's output by distinct tuple,
      # with a +tuple_provenance+ column holding the provenance expression
      # for the tuple.  Each term in the expression is a product of base
      # row tokens such as <tt>items[1]*orders[2]</tt>, and terms are
      # summed with <tt>+</tt>, one term per derivation of the tuple.
      #
      # Raises Sequel::InvalidOperation if any part of the query is not
      # supported.
      def with_tuple_provenance
        expanded = tuple_provenance_expand
        columns = tuple_provenance_output_columns
        agg = if db.database_type == :postgres
          Sequel.function(:string_agg, INTERNAL_COLUMN, "+")
        else
          Sequel.function(:group_concat, INTERNAL_COLUMN, "+")
        end
        db.from(expanded).select(*columns, Sequel.as(agg, PROVENANCE_COLUMN)).group(*columns)
      end

      private

      # Expand the dataset into an equivalent query with an additional
      # __tuple_provenance__ column giving the provenance term for each
      # output row.
      def tuple_provenance_expand
        if @opts[:compounds]
          tuple_provenance_expand_compounds
        else
          tuple_provenance_expand_simple
        end
      end

      # Expand a UNION ALL compound query, validating that only UNION ALL
      # is used.
      def tuple_provenance_expand_compounds
        ds = tuple_provenance_expand_dataset(clone(compounds: nil))
        @opts[:compounds].each do |type, compound_ds, all|
          unless type == :union && all
            raise InvalidOperation, "tuple provenance only supports UNION ALL compound queries, not #{type.to_s.upcase.tr('_', ' ')}"
          end
          ds = ds.union(tuple_provenance_expand_dataset(compound_ds), all: true, from_self: false)
        end
        ds
      end

      # Expand a related dataset (a subquery source or compound branch),
      # raising a clear error if the extension is not loaded for it.
      def tuple_provenance_expand_dataset(dataset)
        unless dataset.respond_to?(:tuple_provenance_expand, true)
          raise InvalidOperation, "tuple provenance requires the tuple_provenance extension to be loaded for all datasets in the query (use DB.extension :tuple_provenance)"
        end
        dataset.send(:tuple_provenance_expand)
      end

      # Expand a non-compound query, replacing any subquery sources with
      # their expansions and appending the provenance term column.
      def tuple_provenance_expand_simple
        tuple_provenance_validate!

        provenance_terms = []

        new_from = Array(@opts[:from]).map do |entry|
          new_entry, term = tuple_provenance_expand_source(entry)
          provenance_terms << term
          new_entry
        end

        new_joins = Array(@opts[:join]).map do |join|
          unless SUPPORTED_JOIN_TYPES.include?(join.join_type)
            raise InvalidOperation, "tuple provenance only supports inner joins, not #{join.join_type} joins"
          end
          tuple_provenance_check_filter(join.on) if join.is_a?(SQL::JoinOnClause)
          new_table_expr, term = tuple_provenance_expand_source(join.table_expr)
          provenance_terms << term
          tuple_provenance_rebuild_join(join, new_table_expr)
        end

        if provenance_terms.empty?
          raise InvalidOperation, "tuple provenance requires at least one base table in FROM"
        end

        ds = self
        ds = ds.clone(from: new_from.freeze) unless new_from.empty?
        ds = ds.clone(join: new_joins.freeze) unless new_joins.empty?
        ds.select_append(Sequel.as(Sequel.join(provenance_terms, "*"), INTERNAL_COLUMN))
      end

      # Return [new from entry, provenance term] for a FROM or JOIN entry.
      # Base tables get a token based on their stable row identifier;
      # supported subqueries are expanded recursively and pass their
      # provenance column through.
      def tuple_provenance_expand_source(entry)
        case entry
        when Symbol
          [entry, tuple_provenance_token(entry, entry)]
        when SQL::Identifier
          [entry, tuple_provenance_token(entry.value, entry.value)]
        when SQL::AliasedExpression
          case (expression = entry.expression)
          when Symbol
            [entry, tuple_provenance_token(expression, entry.alias)]
          when SQL::Identifier
            [entry, tuple_provenance_token(expression.value, entry.alias)]
          when Sequel::Dataset
            expanded = tuple_provenance_expand_dataset(expression)
            [expanded.as(entry.alias), Sequel.qualify(entry.alias, INTERNAL_COLUMN)]
          else
            raise InvalidOperation, "tuple provenance does not support #{expression.inspect} as a FROM entry"
          end
        when Sequel::Dataset
          raise InvalidOperation, "tuple provenance requires subqueries in FROM to be aliased"
        else
          raise InvalidOperation, "tuple provenance does not support #{entry.inspect} as a FROM entry"
        end
      end

      # Rebuild a join clause with a replaced table expression.
      def tuple_provenance_rebuild_join(join, table_expr)
        case join
        when SQL::JoinOnClause
          SQL::JoinOnClause.new(join.on, join.join_type, table_expr)
        when SQL::JoinUsingClause
          SQL::JoinUsingClause.new(join.using, join.join_type, table_expr)
        else
          SQL::JoinClause.new(join.join_type, table_expr)
        end
      end

      # The provenance token expression for a base table row, such as
      # <tt>'orders[' || CAST(orders.id AS varchar) || ']'</tt>.
      def tuple_provenance_token(table, table_alias)
        parts = ["#{table}["]
        tuple_provenance_key_columns(table).each_with_index do |column, i|
          parts << "," if i > 0
          parts << Sequel.cast(Sequel.qualify(table_alias, column), String)
        end
        parts << "]"
        Sequel.join(parts)
      end

      # The stable row identifier columns for a base table: its primary
      # key, or +rowid+ on SQLite.  Raises if the table has no stable
      # row identifier.
      def tuple_provenance_key_columns(table)
        primary_key = db.schema(table).select{|_, info| info[:primary_key]}.map{|name, _| name}
        if primary_key.empty?
          if db.database_type == :sqlite
            [:rowid]
          else
            raise InvalidOperation, "tuple provenance requires a stable row identifier for table #{table}, but it has no primary key"
          end
        else
          primary_key
        end
      end

      # The output column names of the dataset, used to group derivations
      # of the same tuple.
      def tuple_provenance_output_columns
        select = @opts[:select]
        if select && !select.any?{|s| s.is_a?(SQL::ColumnAll)}
          hash_key_symbols(select)
        else
          columns
        end
      end

      # Raise Sequel::InvalidOperation for any unsupported construct in a
      # non-compound query.
      def tuple_provenance_validate!
        UNSUPPORTED_OPTIONS.each do |option, feature|
          if @opts[option]
            raise InvalidOperation, "tuple provenance does not support #{feature}"
          end
        end

        if (select = @opts[:select])
          select.each do |entry|
            entry = entry.expression if entry.is_a?(SQL::AliasedExpression)
            unless entry.is_a?(Symbol) || entry.is_a?(SQL::Identifier) ||
                entry.is_a?(SQL::QualifiedIdentifier) || entry.is_a?(SQL::ColumnAll)
              raise InvalidOperation, "tuple provenance only supports plain column projections, not #{entry.inspect}"
            end
          end
        end

        tuple_provenance_check_filter(@opts[:where])
        nil
      end

      # Recursively check a filter expression for subqueries and literal
      # SQL fragments, which could hide table references that provenance
      # cannot track.
      def tuple_provenance_check_filter(expression)
        case expression
        when nil
          nil
        when Sequel::Dataset
          raise InvalidOperation, "tuple provenance does not support subqueries in predicates"
        when SQL::PlaceholderLiteralString, LiteralString, String
          raise InvalidOperation, "tuple provenance does not support literal SQL fragments in predicates"
        when SQL::Expression
          expression.class.comparison_attrs.each do |attr|
            tuple_provenance_check_expression_value(expression.public_send(attr))
          end
        when Array
          expression.each{|e| tuple_provenance_check_filter(e)}
        when Hash
          expression.each{|k, v| tuple_provenance_check_filter(k); tuple_provenance_check_filter(v)}
        end
        nil
      end

      # Check a value nested inside a filter expression.  Plain strings
      # are allowed here, since they are literal values and not SQL
      # fragments.
      def tuple_provenance_check_expression_value(value)
        case value
        when Sequel::Dataset
          raise InvalidOperation, "tuple provenance does not support subqueries in predicates"
        when SQL::PlaceholderLiteralString, LiteralString
          raise InvalidOperation, "tuple provenance does not support literal SQL fragments in predicates"
        when SQL::Expression
          value.class.comparison_attrs.each do |attr|
            tuple_provenance_check_expression_value(value.public_send(attr))
          end
        when Array
          value.each{|e| tuple_provenance_check_expression_value(e)}
        when Hash
          value.each{|k, v| tuple_provenance_check_expression_value(k); tuple_provenance_check_expression_value(v)}
        end
        nil
      end
    end

    register_extension(:tuple_provenance, TupleProvenance)
  end
end
