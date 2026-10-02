# frozen-string-literal: true
#
# The conjunctive_query_containment extension adds a static analysis
# that determines whether one conjunctive query is contained in another,
# without executing either query against the current database contents:
#
#   DB.extension :conjunctive_query_containment
#   result = q1.cq_containment(q2, schema)
#   result.contained?      # q1 returns a subset of q2's rows on every database
#   result.not_contained?  # some database exists where q1 returns a row q2 does not
#   result.unsupported?    # either query uses features outside the supported fragment
#
# The supported query fragment is conjunctive queries under set
# (DISTINCT) semantics:
#
# * explicit column projections (no +SELECT *+, expressions, or aggregates)
# * inner joins (INNER JOIN, CROSS JOIN, and USING joins) and cross products
# * filters and join conditions built by ANDing column = column and
#   column = constant equalities
#
# Queries using any other feature (outer joins, OR, inequalities,
# grouping, aggregates, subqueries, set operations, LIMIT/OFFSET, ...)
# make the check return an unsupported result.
#
# The +schema+ argument is a hash mapping table name symbols to an array
# of column name symbols.  All listed columns are assumed to be NOT NULL;
# the analysis is only valid for databases where that holds.
#
# When the queries are comparable, the result is decided using the
# classic Chandra-Merlin homomorphism criterion, so table aliasing,
# self joins, and duplicate predicates do not affect the outcome:
#
# * If q1 is contained in q2, <tt>result.mapping</tt> is a checkable
#   variable mapping (a homomorphism from q2 to q1) of the form
#   <tt>{aliases: {q2_alias => q1_alias}, variables: {[q2_alias, column] => [q1_alias, column]}}</tt>.
# * If q1 is not contained in q2, <tt>result.counterexample</tt> is a
#   finite counterexample database of the form
#   <tt>{tables: {table => [row, ...]}, missing_row: [...]}</tt>.
#   Loading the rows into an empty database makes q1 return
#   +missing_row+ while q2 does not.
#
# Example:
#
#   schema = {users: [:id, :name], orders: [:id, :user_id]}
#   q1 = DB[:users].join(:orders, :user_id=>:id).
#     where(Sequel[:users][:id]=>1).select(Sequel[:orders][:id])
#   q2 = DB[:users].join(:orders, :user_id=>:id).select(Sequel[:orders][:id])
#   result = q1.cq_containment(q2, schema)
#   result.contained? # => true
#   result.mapping[:aliases] # => {users: :users, orders: :orders}
#
# Related module: Sequel::ConjunctiveQueryContainment

module Sequel
  module ConjunctiveQueryContainment
    # Raised internally when a query uses features outside the supported
    # conjunctive query fragment.
    class Unsupported < Error; end

    # The result of a containment check.  The +status+ is one of
    # :contained, :not_contained, or :unsupported.
    class Result
      # For contained results, a hash with :aliases and :variables entries
      # describing the variable mapping witnessing containment.  nil when
      # containment holds vacuously (the first query is always empty).
      attr_reader :mapping

      # For not_contained results, a hash with :tables and :missing_row
      # entries describing a finite counterexample database.
      attr_reader :counterexample

      # For unsupported results, a string describing the unsupported
      # feature.  Also set when containment holds vacuously.
      attr_reader :reason

      def initialize(status, mapping=nil, counterexample=nil, reason=nil)
        @status = status
        @mapping = mapping
        @counterexample = counterexample
        @reason = reason
        freeze
      end

      # One of :contained, :not_contained, or :unsupported.
      attr_reader :status

      # Whether the first query is contained in the second query.
      def contained?
        @status == :contained
      end

      # Whether the first query is not contained in the second query.
      def not_contained?
        @status == :not_contained
      end

      # Whether either query uses features outside the supported fragment.
      def unsupported?
        @status == :unsupported
      end
    end

    # A normalized conjunctive query: a list of table atoms, a projection
    # of column variables, and equality classes over column variables
    # (with optional constants), built from a dataset.
    class Query
      Atom = Struct.new(:alias_name, :table)

      # Dataset options that take the query outside the supported fragment.
      UNSUPPORTED_OPTS = {
        :compounds=>"compound queries (UNION/EXCEPT/INTERSECT)",
        :group=>"GROUP BY",
        :having=>"HAVING",
        :limit=>"LIMIT",
        :offset=>"OFFSET",
        :qualify=>"QUALIFY",
        :window=>"WINDOW",
        :with=>"WITH",
        :lock_style=>"locking clauses",
        :sql=>"literal SQL"
      }.freeze

      # The table atoms of the query, as Atom structs with alias_name and
      # table members.
      attr_reader :atoms

      # The projected column variables, as frozen [alias_name, column] arrays.
      attr_reader :projection

      def initialize(dataset, schema)
        @schema = schema
        opts = dataset.opts
        check_supported_opts!(opts)
        @atoms = []
        @atom_by_alias = {}
        @parent = {}
        @constants = {}
        @unsatisfiable = false
        extract_sources(opts[:from])
        extract_joins(opts[:join]) if opts[:join]
        extract_condition(opts[:where]) if opts[:where]
        @projection = extract_projection(opts[:select])
      end

      # Whether the query is empty on every database, because its equality
      # constraints require a column to equal two distinct constants.
      def unsatisfiable?
        @unsatisfiable
      end

      # The union-find representative of the equality class for the given
      # [alias_name, column] variable.
      def find(var)
        unless @parent.key?(var)
          @parent[var] = var
          return var
        end
        root = var
        root = @parent[root] while @parent[root] != root
        while @parent[var] != root
          @parent[var], var = root, @parent[var]
        end
        root
      end

      # Whether the equality class of the given variable is bound to a
      # constant.
      def constant?(var)
        @constants.key?(find(var))
      end

      # The constant bound to the equality class of the given variable,
      # or nil if the class is unbound.
      def constant_of(var)
        @constants[find(var)]
      end

      # All constants bound to equality classes of the query.
      def constant_values
        @constants.values
      end

      private

      def check_supported_opts!(opts)
        UNSUPPORTED_OPTS.each do |key, description|
          if opts[key]
            raise Unsupported, "queries using #{description} are not supported"
          end
        end
        if (distinct = opts[:distinct]) && !(distinct.respond_to?(:empty?) && distinct.empty?)
          raise Unsupported, "queries using DISTINCT ON are not supported"
        end
      end

      def extract_sources(sources)
        if sources.nil? || sources.empty?
          raise Unsupported, "queries without a FROM clause are not supported"
        end
        sources.each{|source| add_atom(source)}
      end

      def add_atom(expr)
        case expr
        when ::Symbol
          table = aliaz = expr
        when SQL::Identifier
          table = aliaz = symbol_value(expr.value)
        when SQL::AliasedExpression
          if expr.columns
            raise Unsupported, "derived column lists are not supported"
          end
          table = case (inner = expr.expression)
          when ::Symbol
            inner
          when SQL::Identifier
            symbol_value(inner.value)
          else
            raise Unsupported, "only plain tables are supported as query sources"
          end
          aliaz = symbol_value(expr.alias)
        else
          raise Unsupported, "only plain tables are supported as query sources"
        end
        if @atom_by_alias.key?(aliaz)
          raise Unsupported, "duplicate table alias: #{aliaz}"
        end
        unless @schema.key?(table)
          raise Unsupported, "no schema information for table: #{table}"
        end
        atom = Atom.new(aliaz, table)
        @atoms << atom
        @atom_by_alias[aliaz] = atom
        atom
      end

      def extract_joins(joins)
        joins.each do |join|
          case join
          when SQL::JoinOnClause
            check_inner_join!(join)
            add_atom(join.table_expr)
            extract_condition(join.on)
          when SQL::JoinUsingClause
            check_inner_join!(join)
            extract_using(add_atom(join.table_expr), join.using)
          when SQL::JoinClause
            unless join.join_type == :cross
              raise Unsupported, "only INNER and CROSS joins are supported"
            end
            add_atom(join.table_expr)
          else
            raise Unsupported, "unsupported join clause"
          end
        end
      end

      def check_inner_join!(join)
        unless join.join_type == :inner
          raise Unsupported, "only INNER joins are supported"
        end
      end

      def extract_using(atom, columns)
        columns.each do |column|
          column = symbol_value(column)
          unless @schema[atom.table].include?(column)
            raise Unsupported, "USING column not present in joined table: #{column}"
          end
          var = [atom.alias_name, column].freeze
          matched = false
          @atoms.each do |previous|
            next if previous.equal?(atom)
            if @schema[previous.table].include?(column)
              union(var, [previous.alias_name, column].freeze)
              matched = true
            end
          end
          unless matched
            raise Unsupported, "USING column not present in any preceding table: #{column}"
          end
        end
      end

      def extract_condition(expr)
        unless expr.is_a?(SQL::BooleanExpression)
          raise Unsupported, "unsupported filter expression: #{expr.inspect}"
        end
        case expr.op
        when :AND
          expr.args.each{|arg| extract_condition(arg)}
        when :NOOP
          if expr.args.length == 1
            extract_condition(expr.args[0])
          else
            raise Unsupported, "unsupported boolean expression"
          end
        when :'='
          left, right = expr.args
          lvar = column_variable(left)
          rvar = column_variable(right)
          if lvar && rvar
            union(lvar, rvar)
          elsif lvar
            add_constant(lvar, constant_value(right))
          elsif rvar
            add_constant(rvar, constant_value(left))
          else
            @unsatisfiable = true unless constant_value(left) == constant_value(right)
          end
        else
          raise Unsupported, "unsupported operator in condition: #{expr.op}"
        end
      end

      def extract_projection(select)
        if select.nil? || select.empty?
          raise Unsupported, "queries without an explicit column projection are not supported"
        end
        select.map do |expr|
          if expr.is_a?(SQL::AliasedExpression)
            if expr.columns
              raise Unsupported, "derived column lists are not supported"
            end
            expr = expr.expression
          end
          unless (var = column_variable(expr))
            raise Unsupported, "projection entries must be plain columns"
          end
          var
        end
      end

      # Return the [alias_name, column] variable for the expression, or nil
      # if the expression is not a column reference.
      def column_variable(expr)
        case expr
        when SQL::QualifiedIdentifier
          aliaz = symbol_value(expr.table)
          column = symbol_value(expr.column)
          unless @atom_by_alias.key?(aliaz)
            raise Unsupported, "unknown table alias: #{aliaz}"
          end
          [aliaz, column].freeze
        when SQL::Identifier
          resolve_unqualified(symbol_value(expr.value))
        when ::Symbol
          resolve_unqualified(expr)
        end
      end

      def resolve_unqualified(column)
        matches = @atoms.select{|atom| @schema[atom.table].include?(column)}
        if matches.empty?
          raise Unsupported, "cannot resolve unqualified column: #{column}"
        elsif matches.length > 1
          raise Unsupported, "ambiguous unqualified column: #{column}"
        end
        [matches[0].alias_name, column].freeze
      end

      def constant_value(expr)
        case expr
        when ::String, ::Integer, ::Float, ::BigDecimal, ::Date, ::Time, ::DateTime, true, false
          expr
        else
          raise Unsupported, "unsupported constant: #{expr.inspect}"
        end
      end

      def symbol_value(value)
        unless value.is_a?(::Symbol) || value.is_a?(::String)
          raise Unsupported, "unsupported identifier: #{value.inspect}"
        end
        value.to_sym
      end

      def union(var1, var2)
        rep1 = find(var1)
        rep2 = find(var2)
        return if rep1 == rep2
        @parent[rep2] = rep1
        if @constants.key?(rep2)
          if @constants.key?(rep1)
            @unsatisfiable = true unless @constants[rep1] == @constants[rep2]
          else
            @constants[rep1] = @constants[rep2]
          end
          @constants.delete(rep2)
        end
      end

      def add_constant(var, value)
        rep = find(var)
        if @constants.key?(rep)
          @unsatisfiable = true unless @constants[rep] == value
        else
          @constants[rep] = value
        end
      end
    end

    # Check whether +dataset+ is contained in +other+ on every database
    # satisfying +schema+ (a hash mapping table name symbols to arrays of
    # NOT NULL column name symbols).  Returns a Result.
    def self.check(dataset, other, schema)
      unless schema.is_a?(Hash)
        raise Error, "schema must be a hash mapping table names to arrays of column names"
      end
      schema = normalize_schema(schema)
      begin
        query = Query.new(dataset, schema)
        other_query = Query.new(other, schema)
      rescue Unsupported => error
        return Result.new(:unsupported, nil, nil, error.message)
      end

      if query.unsatisfiable?
        return Result.new(:contained, nil, nil,
          "the first query is empty on every database, so it is contained in every query")
      end

      if other_query.unsatisfiable? || query.projection.length != other_query.projection.length
        return Result.new(:not_contained, nil, counterexample(query, other_query, schema))
      end

      if (mapping = find_homomorphism(other_query, query, schema))
        Result.new(:contained, mapping)
      else
        Result.new(:not_contained, nil, counterexample(query, other_query, schema))
      end
    end

    # Normalize a schema hash so table and column names are symbols.
    def self.normalize_schema(schema)
      normalized = {}
      schema.each do |table, columns|
        normalized[table.to_sym] = columns.map{|column| column.to_sym}.freeze
      end
      normalized.freeze
    end

    # Search for a homomorphism from +from_query+ to the canonical
    # database of +to_query+ that maps the projection of +from_query+ to
    # the projection of +to_query+.  Returns the variable mapping hash, or
    # nil if no such homomorphism exists.
    def self.find_homomorphism(from_query, to_query, schema)
      atoms = from_query.atoms.sort_by{|atom| to_query.atoms.count{|a| a.table == atom.table}}
      candidates = atoms.map{|atom| to_query.atoms.select{|a| a.table == atom.table}}
      return nil if candidates.any?(&:empty?)

      constraints = homomorphism_constraints(from_query, schema)
      assignment = {}
      backtrack = lambda do |index|
        if index == atoms.length
          true
        else
          atom = atoms[index]
          candidates[index].any? do |target|
            assignment[atom.alias_name] = target
            if homomorphism_consistent?(constraints, to_query, assignment) && backtrack.call(index + 1)
              true
            else
              assignment.delete(atom.alias_name)
              false
            end
          end
        end
      end
      return nil unless backtrack.call(0)

      aliases = {}
      variables = {}
      from_query.atoms.each do |atom|
        target = assignment[atom.alias_name]
        aliases[atom.alias_name] = target.alias_name
        schema[atom.table].each do |column|
          variables[[atom.alias_name, column].freeze] = [target.alias_name, column].freeze
        end
      end
      {:aliases=>aliases, :variables=>variables}
    end

    # Precompute the constraints a homomorphism from +query+ must satisfy:
    # constant bindings, equality class members, and projection positions.
    def self.homomorphism_constraints(query, schema)
      constants = []
      classes = {}
      query.atoms.each do |atom|
        schema[atom.table].each do |column|
          var = [atom.alias_name, column].freeze
          (classes[query.find(var)] ||= []) << var
          constants << [var, query.constant_of(var)] if query.constant?(var)
        end
      end
      equalities = []
      classes.each_value do |vars|
        first = vars[0]
        vars[1..-1].each{|var| equalities << [first, var]}
      end
      projection = query.projection.each_with_index.map{|var, i| [var, i]}
      {:constants=>constants, :equalities=>equalities, :projection=>projection}
    end

    # Check the constraints that only involve already-assigned atoms of
    # the source query against the target query's equality classes.
    def self.homomorphism_consistent?(constraints, to_query, assignment)
      image = lambda do |var|
        if (target = assignment[var[0]])
          [target.alias_name, var[1]].freeze
        end
      end
      constraints[:constants].each do |var, constant|
        next unless (img = image.call(var))
        return false unless to_query.constant?(img) && to_query.constant_of(img) == constant
      end
      constraints[:equalities].each do |var1, var2|
        next unless (img1 = image.call(var1)) && (img2 = image.call(var2))
        return false unless to_query.find(img1) == to_query.find(img2)
      end
      constraints[:projection].each do |var, index|
        next unless (img = image.call(var))
        return false unless to_query.find(img) == to_query.find(to_query.projection[index])
      end
      true
    end

    # Build the canonical database of +query+: one row per table atom,
    # where equality classes bound to constants use the constant and all
    # other classes use fresh symbolic values.  +query+ returns
    # :missing_row on this database, while any query it is not contained
    # in does not.
    def self.counterexample(query, other_query, schema)
      prefix = symbolic_prefix(query, other_query)
      values = {}
      counter = 0
      value_for = lambda do |var|
        if query.constant?(var)
          query.constant_of(var)
        else
          rep = query.find(var)
          unless values.key?(rep)
            counter += 1
            values[rep] = "#{prefix}#{counter}"
          end
          values[rep]
        end
      end
      tables = {}
      query.atoms.each do |atom|
        row = {}
        schema[atom.table].each do |column|
          row[column] = value_for.call([atom.alias_name, column])
        end
        (tables[atom.table] ||= []) << row
      end
      missing_row = query.projection.map{|var| value_for.call(var)}
      {:tables=>tables, :missing_row=>missing_row}
    end

    # Choose a prefix for symbolic counterexample values that cannot
    # collide with string constants used in either query.
    def self.symbolic_prefix(*queries)
      prefix = "cq_var_"
      loop do
        clash = queries.any? do |query|
          query.constant_values.any?{|c| c.is_a?(String) && c.start_with?(prefix)}
        end
        return prefix unless clash
        prefix = "_#{prefix}"
      end
    end

    module DatasetMethods
      # Statically check whether this dataset's query is contained in
      # +other+'s query on every database satisfying +schema+ (a hash
      # mapping table name symbols to arrays of NOT NULL column name
      # symbols).  Returns a Sequel::ConjunctiveQueryContainment::Result.
      def cq_containment(other, schema)
        ConjunctiveQueryContainment.check(self, other, schema)
      end
    end

  end

  Dataset.register_extension(:conjunctive_query_containment, ConjunctiveQueryContainment::DatasetMethods)
end
