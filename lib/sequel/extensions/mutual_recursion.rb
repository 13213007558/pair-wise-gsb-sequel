# frozen-string-literal: true
#
# The mutual_recursion extension adds Database#mutual_recursive, which
# compiles a restricted mutual recursion declaration into a single
# recursive common table expression.  This is useful on databases that
# only support a single recursive CTE per query, because the mutually
# recursive relations are stored in one shared recursive table, with a
# relation tag column separating the tuples of each declared relation.
#
# A mutual recursion is declared as a hash mapping relation names to
# relation definitions.  Each definition provides a +columns+ array
# (the columns the relation produces) and a dataset for the nonrecursive
# (base) branch and/or the recursive branch:
#
#   DB.extension(:mutual_recursion)
#
#   rels = DB.mutual_recursive(
#     even: {
#       columns: [:node],
#       nonrecursive: DB[:starts].select(:node),
#       recursive: DB[:edges].
#         join(:odd, Sequel[:odd][:node]=>Sequel[:edges][:src]).
#         select(Sequel[:edges][:dst])
#     },
#     odd: {
#       columns: [:node],
#       recursive: DB[:edges].
#         join(:even, Sequel[:even][:node]=>Sequel[:edges][:src]).
#         select(Sequel[:edges][:dst])
#     }
#   )
#
# The recursive branches reference the recursive relations as if they
# were tables.  References to recursive relation columns must use
# explicitly qualified identifiers (e.g. Sequel[:odd][:node]), since
# they are rewritten to the columns of the shared recursive table.
#
# The declaration is compiled to a single recursive CTE whose rows are
# tagged with the relation name and padded with NULLs up to the widest
# relation, so the UNION used for recursion only eliminates duplicate
# rows within the same relation:
#
#   WITH RECURSIVE mutual_recursive(relation, c1) AS (
#     SELECT 'even' AS relation, t1.node AS c1 FROM (SELECT node FROM starts) AS t1
#     UNION
#     SELECT 'odd' AS relation, edges.dst AS c1 FROM edges
#       JOIN mutual_recursive AS even ON (even.c1 = edges.src) WHERE (even.relation = 'even')
#     UNION
#     SELECT 'even' AS relation, edges.dst AS c1 FROM edges
#       JOIN mutual_recursive AS odd ON (odd.c1 = edges.src) WHERE (odd.relation = 'odd')
#   )
#   SELECT mutual_recursive.c1 AS node FROM mutual_recursive
#   WHERE (mutual_recursive.relation = 'even')
#
# mutual_recursive returns a hash mapping relation names to datasets
# that produce the rows of each relation.  The unified recursive table
# is only an internal representation; the returned datasets present the
# declared columns of each relation.
#
# The supported fragment is deliberately restricted so that the
# recursion is monotone and always terminates:
#
# * Only duplicate-eliminating UNION semantics are used (no UNION ALL).
# * Each recursive branch may reference recursive relations at most
#   once (linear recursion), and only in its top-level FROM/JOIN.
# * Aggregates (GROUP BY, HAVING, aggregate functions) are not allowed.
# * Negation is not allowed (NOT, EXCEPT, INTERSECT).
#
# A Sequel::MutualRecursion::Error is raised when the declaration is
# made (before any SQL is generated) if these restrictions are violated.
#
# Related module: Sequel::MutualRecursion

module Sequel
  module MutualRecursion
    # Error raised for mutual recursion declarations that violate the
    # supported restrictions.
    class Error < Sequel::Error; end

    # Aggregate function names that are not allowed in the declaration.
    AGGREGATE_FUNCTIONS = %w[array_agg avg bool_and bool_or count every group_concat max min string_agg sum total].freeze

    # Compile the given mutual recursion declaration, returning a hash
    # mapping relation names to datasets producing the rows of each
    # relation.  See the module documentation for the declaration format.
    #
    # Options:
    # :name :: The name of the shared recursive table (default: mutual_recursive).
    # :tag_column :: The name of the relation tag column (default: relation).
    def mutual_recursive(relations, opts=OPTS)
      Compiler.new(self, relations, opts).datasets
    end

    # Compiles a restricted mutual recursion declaration into a single
    # recursive CTE shared by all declared relations.
    class Compiler
      # Rewrites qualified references to recursive relation columns to
      # the value columns of the shared recursive table.
      class ColumnMapper < ASTTransformer
        def initialize(alias_map, value_columns)
          @alias_map = alias_map
          @value_columns = value_columns
        end

        private

        def v(o)
          case o
          when SQL::QualifiedIdentifier
            map_qualified(o) || super
          when Symbol
            map_symbol(o) || super
          else
            super
          end
        end

        def map_qualified(q)
          table = q.table
          table = table.value if table.is_a?(SQL::Identifier)
          return unless (table.is_a?(Symbol) || table.is_a?(String)) && (rel = @alias_map[table.to_sym])
          SQL::QualifiedIdentifier.new(q.table, value_column(rel, q.column))
        end

        def map_symbol(s)
          table, column, aliaz = Sequel.split_symbol(s)
          return unless table && (rel = @alias_map[table.to_sym])
          qi = SQL::QualifiedIdentifier.new(table.to_sym, value_column(rel, column))
          aliaz ? SQL::AliasedExpression.new(qi, aliaz.to_sym) : qi
        end

        def value_column(rel, column)
          column = column.value if column.is_a?(SQL::Identifier)
          i = rel[:columns].index(column.to_sym)
          unless i
            raise Error, "recursive relation #{rel[:name]} has no column #{column} " \
              "(declared columns: #{rel[:columns].join(', ')})"
          end
          @value_columns[i]
        end
      end

      def initialize(db, relations, opts)
        @db = db
        @cte_name = (opts[:name] || :mutual_recursive).to_sym
        @tag_column = (opts[:tag_column] || :relation).to_sym
        @relations = normalize(relations)
        @by_name = {}
        @relations.each{|r| @by_name[r[:name]] = r}
        arity = @relations.map{|r| r[:columns].length}.max
        @value_columns = (1..arity).map{|i| :"c#{i}"}
        validate!
      end

      # Compile the declaration.  Returns a hash mapping relation names to
      # datasets that produce the rows of each relation.
      def datasets
        ds = @db[@cte_name].
          with_recursive(@cte_name, nonrecursive_union, recursive_union,
            :args=>cte_columns, :union_all=>false)
        result = {}
        @relations.each do |rel|
          result[rel[:name]] = ds.
            where(Sequel[@cte_name][@tag_column]=>rel[:name].to_s).
            select(*rel[:columns].each_with_index.map do |c, i|
              Sequel.as(Sequel[@cte_name][@value_columns[i]], c)
            end)
        end
        result
      end

      private

      def cte_columns
        [@tag_column] + @value_columns
      end

      def nonrecursive_union
        union_branches(@relations.map{|r| compile_base_branch(r) if r[:nonrecursive]}.compact)
      end

      def recursive_union
        union_branches(@relations.map{|r| compile_recursive_branch(r) if r[:recursive]}.compact)
      end

      def union_branches(branches)
        branches.reduce{|a, b| a.union(b, :from_self=>false)}
      end

      # The select list for a branch of the relation: the relation tag,
      # the relation columns renamed to the shared value columns, and
      # NULL padding up to the arity of the shared recursive table.  The
      # block maps each declared column to the expression selecting it.
      def padded_select(rel)
        selects = [Sequel.as(rel[:name].to_s, @tag_column)]
        rel[:columns].each_with_index do |c, i|
          selects << Sequel.as(yield(c, i), @value_columns[i])
        end
        (@value_columns.length - rel[:columns].length).times do |i|
          selects << Sequel.as(nil, @value_columns[rel[:columns].length + i])
        end
        selects
      end

      # Base branches cannot reference recursive relations, so they can
      # safely be wrapped in a subquery to rename their columns.
      def compile_base_branch(rel)
        aliaz = :"#{@cte_name}_#{rel[:name]}"
        rel[:nonrecursive].
          from_self(:alias=>aliaz).
          select(*padded_select(rel){|c, _| Sequel[aliaz][c]})
      end

      # Recursive branches must reference the shared recursive table
      # directly (databases such as SQLite forbid the recursive table
      # inside a subquery), so references to the declared relations are
      # rewritten in place to aliased references to the shared recursive
      # table, qualified references to relation columns are rewritten to
      # the shared value columns, and a tag predicate is added.
      def compile_recursive_branch(rel)
        ds = rel[:recursive]
        o = ds.opts
        alias_map = {}
        new_from = (o[:from] || []).map{|s| replace_source(s, alias_map) || s}
        joins = o[:join] || []
        replacements = joins.map{|j| replace_source(j.table_expr, alias_map)}
        mapper = ColumnMapper.new(alias_map, @value_columns)
        new_joins = joins.each_with_index.map do |j, i|
          rebuild_join(j, replacements[i] || j.table_expr, mapper, rel, !replacements[i].nil?)
        end
        select = mapper.transform(o[:select])
        ds = ds.clone(:from=>new_from) if o[:from]
        ds = ds.clone(:join=>new_joins) unless joins.empty?
        if (where = o[:where])
          ds = ds.clone(:where=>mapper.transform(where))
        end
        alias_map.each do |aliaz, r|
          ds = ds.where(Sequel[aliaz][@tag_column]=>r[:name].to_s)
        end
        ds.clone(:select=>padded_select(rel) do |_, i|
          e = select[i]
          e.is_a?(SQL::AliasedExpression) ? e.expression : e
        end)
      end

      def rebuild_join(join, table_expr, mapper, rel, replaced)
        case join
        when SQL::JoinOnClause
          SQL::JoinOnClause.new(mapper.transform(join.on), join.join_type, table_expr)
        when SQL::JoinUsingClause
          if replaced
            raise Error, "recursive branch of relation #{rel[:name]} joins a recursive relation " \
              "with a USING join; use an ON join with explicitly qualified columns instead"
          end
          SQL::JoinUsingClause.new(mapper.transform(join.using), join.join_type, table_expr)
        else
          SQL::JoinClause.new(join.join_type, table_expr)
        end
      end

      # If the given FROM/JOIN source references a declared relation,
      # record the alias in alias_map and return an aliased reference to
      # the shared recursive table.  Otherwise return nil.
      def replace_source(source, alias_map)
        return unless info = source_relation(source)
        name, aliaz = info
        alias_map[aliaz] = @by_name[name]
        Sequel.as(Sequel[@cte_name], aliaz)
      end

      # [relation name, alias] if the source references a declared
      # relation, nil otherwise.
      def source_relation(source)
        case source
        when Symbol
          schema, table, aliaz = Sequel.split_symbol(source)
          relation_info(table, aliaz) unless schema
        when SQL::Identifier
          relation_info(source.value, nil)
        when SQL::AliasedExpression
          case e = source.expression
          when Symbol
            schema, table, = Sequel.split_symbol(e)
            relation_info(table, source.alias) unless schema
          when SQL::Identifier
            relation_info(e.value, source.alias)
          end
        end
      end

      def relation_info(name, aliaz)
        name = name.to_sym
        [name, (aliaz || name).to_sym] if @by_name.key?(name)
      end

      # Normalize and check the structure of the declaration itself.
      def normalize(relations)
        unless relations.is_a?(Hash) && relations.length >= 2
          raise Error, "mutual_recursive requires a hash of at least two relation definitions"
        end
        relations.map do |name, defn|
          name = name.to_sym
          if name == @cte_name
            raise Error, "relation name #{name} conflicts with the shared recursive table name"
          end
          unless defn.is_a?(Hash)
            raise Error, "definition for relation #{name} must be a hash"
          end
          columns = defn[:columns]
          unless columns.is_a?(Array) && !columns.empty? && columns.all?{|c| c.is_a?(Symbol)}
            raise Error, "relation #{name} must declare :columns as a non-empty array of symbols"
          end
          unless columns.uniq.length == columns.length
            raise Error, "relation #{name} declares duplicate columns"
          end
          nonrecursive = defn[:nonrecursive]
          recursive = defn[:recursive]
          [nonrecursive, recursive].each do |ds|
            if ds && !ds.is_a?(Dataset)
              raise Error, "relation #{name} branches must be Sequel datasets"
            end
          end
          unless nonrecursive || recursive
            raise Error, "relation #{name} must declare a :nonrecursive and/or :recursive branch"
          end
          {:name=>name, :columns=>columns, :nonrecursive=>nonrecursive, :recursive=>recursive}
        end
      end

      # Check the declaration against the supported restrictions, before
      # any SQL is generated.
      def validate!
        unless @relations.any?{|r| r[:nonrecursive]}
          raise Error, "at least one relation must declare a :nonrecursive branch (a base case is required)"
        end
        unless @relations.any?{|r| r[:recursive]}
          raise Error, "at least one relation must declare a :recursive branch"
        end
        @relations.each do |rel|
          check_branch!(rel, rel[:nonrecursive], false) if rel[:nonrecursive]
          check_branch!(rel, rel[:recursive], true) if rel[:recursive]
        end
      end

      def check_branch!(rel, ds, recursive)
        o = ds.opts
        check_group!(rel, o)
        check_compounds!(rel, o[:compounds], recursive)
        inspect_expressions!(rel, o)
        (o[:from] || []).each{|s| inspect_branch_source!(rel, s)}
        (o[:join] || []).each{|j| inspect_branch_source!(rel, j.table_expr)}
        (o[:compounds] || []).each{|_, cds, _| inspect_dataset_subquery!(rel, cds)}
        refs = top_level_references(ds)
        if recursive
          if refs.length > 1
            raise Error, "recursive branch of relation #{rel[:name]} references recursive relations " \
              "#{refs.length} times (#{refs.join(', ')}); each recursive branch may reference " \
              "recursive relations at most once"
          end
          select = o[:select]
          unless select && select.length == rel[:columns].length
            raise Error, "recursive branch of relation #{rel[:name]} must explicitly select the " \
              "#{rel[:columns].length} declared column(s) (#{rel[:columns].join(', ')}) in order"
          end
        elsif !refs.empty?
          raise Error, "nonrecursive branch of relation #{rel[:name]} references recursive relation #{refs.first}"
        end
      end

      def check_group!(rel, o)
        if o[:group] || o[:having]
          raise Error, "relation #{rel[:name]} uses GROUP BY/HAVING (aggregation is not supported)"
        end
      end

      def check_compounds!(rel, compounds, recursive)
        return unless compounds && !compounds.empty?
        if recursive
          raise Error, "recursive branch of relation #{rel[:name]} cannot use UNION/EXCEPT/INTERSECT compounds"
        elsif compounds.any?{|type, _, all| type != :union || all}
          raise Error, "relation #{rel[:name]} cannot use EXCEPT/INTERSECT or UNION ALL " \
            "(negation and bag semantics are not supported)"
        end
      end

      def inspect_expressions!(rel, o)
        inspect_expression!(rel, o[:select]) if o[:select]
        inspect_expression!(rel, o[:where]) if o[:where]
        inspect_expression!(rel, o[:having]) if o[:having]
        inspect_expression!(rel, o[:join]) if o[:join]
      end

      def top_level_references(ds)
        refs = []
        (ds.opts[:from] || []).each do |s|
          if (info = source_relation(s))
            refs << info[0]
          end
        end
        (ds.opts[:join] || []).each do |j|
          if (info = source_relation(j.table_expr))
            refs << info[0]
          end
        end
        refs
      end

      # Raise for aggregates and negation in the given expression,
      # recursing into subexpressions and subqueries.
      def inspect_expression!(rel, expr)
        case expr
        when SQL::Function
          if AGGREGATE_FUNCTIONS.include?(expr.name.to_s.downcase)
            raise Error, "relation #{rel[:name]} uses aggregate function #{expr.name} " \
              "(aggregation is not supported)"
          end
          inspect_expression!(rel, expr.args)
        when SQL::BooleanExpression
          if expr.op == :NOT
            raise Error, "relation #{rel[:name]} uses NOT (negation is not supported)"
          end
          inspect_expression!(rel, expr.args)
        when SQL::ComplexExpression
          inspect_expression!(rel, expr.args)
        when SQL::AliasedExpression
          inspect_expression!(rel, expr.expression)
        when SQL::Cast
          inspect_expression!(rel, expr.expr)
        when SQL::CaseExpression
          inspect_expression!(rel, expr.conditions)
          inspect_expression!(rel, expr.default) if expr.default
          inspect_expression!(rel, expr.expression) if expr.expression?
        when SQL::Subscript
          inspect_expression!(rel, expr.expression)
          inspect_expression!(rel, expr.sub)
        when SQL::JoinOnClause
          inspect_expression!(rel, expr.on)
        when Dataset
          inspect_dataset_subquery!(rel, expr)
        when Array
          expr.each{|e| inspect_expression!(rel, e)}
        when Hash
          expr.each{|k, v| inspect_expression!(rel, k); inspect_expression!(rel, v)}
        end
      end

      # Check a dataset used as a source in a branch for nested
      # subqueries referencing recursive relations.
      def inspect_branch_source!(rel, source)
        case source
        when Dataset
          inspect_dataset_subquery!(rel, source)
        when SQL::AliasedExpression
          inspect_dataset_subquery!(rel, source.expression) if source.expression.is_a?(Dataset)
        end
      end

      # Check a subquery for references to recursive relations, which
      # are only allowed in the top-level FROM/JOIN of a recursive branch.
      def inspect_dataset_subquery!(rel, ds)
        o = ds.opts
        check_group!(rel, o)
        check_compounds!(rel, o[:compounds], false)
        inspect_expressions!(rel, o)
        (o[:from] || []).each{|s| check_nested_source!(rel, s)}
        (o[:join] || []).each{|j| check_nested_source!(rel, j.table_expr)}
        (o[:compounds] || []).each{|_, cds, _| inspect_dataset_subquery!(rel, cds)}
      end

      def check_nested_source!(rel, source)
        case source
        when Dataset
          inspect_dataset_subquery!(rel, source)
        when SQL::AliasedExpression
          if source.expression.is_a?(Dataset)
            inspect_dataset_subquery!(rel, source.expression)
          else
            check_nested_relation!(rel, source)
          end
        else
          check_nested_relation!(rel, source)
        end
      end

      def check_nested_relation!(rel, source)
        if (info = source_relation(source))
          raise Error, "relation #{rel[:name]} references recursive relation #{info[0]} inside a " \
            "subquery; recursive relations may only be referenced in the top-level FROM/JOIN " \
            "of a recursive branch"
        end
      end
    end
  end

  Database.register_extension(:mutual_recursion, MutualRecursion)
end
