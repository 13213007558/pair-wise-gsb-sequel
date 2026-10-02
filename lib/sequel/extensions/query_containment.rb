# frozen-string-literal: true
#
# The query_containment extension adds Dataset#contained_in?, which
# statically checks whether one conjunctive query is contained in another
# (i.e. whether the first query is guaranteed to return a subset of the
# rows returned by the second query on every database), without running
# the queries against the current database contents.  This is useful when
# migrating a query to a new version and you want to know whether the new
# query always returns all rows the old query returned:
#
#   DB.extension(:query_containment)
#   result = old_ds.contained_in?(new_ds, :schema=>{:orders=>[:id, :status]})
#   result.status # => :contained, :not_contained, or :unsupported
#
# The supported query fragment is conjunctive queries under set semantics:
#
# * SELECT DISTINCT with an explicit projection of column references
#   (output aliases are allowed and ignored)
# * FROM and INNER JOIN of tables (self joins and table aliases are
#   supported, as are cross joins)
# * WHERE and JOIN ON conditions that are conjunctions of equality
#   predicates between two columns or between a column and a string or
#   numeric constant
#
# The +:schema+ option must map table names to their columns, and all
# columns are assumed to be NOT NULL.  Queries using any other feature
# (outer joins, grouping, limiting, set operations, non-equality
# predicates, NULL or boolean constants, subqueries, etc.) return a
# result with a +:unsupported+ status.
#
# The returned Sequel::QueryContainment::Result reflects one of three
# outcomes:
#
# [+:contained+] The first query is contained in the second on every
#                database.  Result#mapping holds a checkable homomorphism
#                witness: a hash mapping each table alias used in the
#                second query to the table alias of the first query it
#                corresponds to.  You can verify the mapping independently
#                with Sequel::QueryContainment.valid_mapping?.
# [+:not_contained+] The first query is not contained in the second.
#                Result#counterexample holds a
#                Sequel::QueryContainment::Counterexample describing a
#                finite database (the canonical database of the first
#                query) on which the first query returns a row the second
#                query does not.  The counterexample is verified by
#                running both queries against an in-memory SQLite
#                database; Counterexample#missing_rows holds the rows
#                returned only by the first query.
# [+:unsupported+] One of the queries uses features outside the supported
#                fragment; Result#reason explains why.
#
# Table aliases, self joins, and duplicate predicates do not affect the
# outcome, since the analysis works on equality classes of column
# references rather than on the syntactic form of the query.
#
# Related module: Sequel::QueryContainment

module Sequel
  module QueryContainment
    # Raised internally when a dataset uses SQL features outside the
    # supported conjunctive query fragment.
    class Unsupported < Sequel::Error; end

    # Dataset options that are either part of the supported fragment
    # (:select, :from, :join, :where, :distinct), do not affect the set
    # of rows returned by the query (:order, :server, :sql), or are
    # internal Sequel bookkeeping (:last_joined_table).
    OPTS_ALLOWED = [:select, :from, :join, :where, :distinct, :order, :server, :sql, :last_joined_table].freeze

    # Union-find over query elements.  Elements are either column
    # references ([:col, table_alias, column]) or constants
    # ([:const, value]).
    class UnionFind
      def initialize
        @parent = {}
      end

      def find(x)
        return x unless @parent.key?(x)
        root = x
        root = @parent[root] while @parent.key?(root)
        until x == root
          nxt = @parent[x]
          @parent[x] = root
          x = nxt
        end
        root
      end

      def union(a, b)
        a = find(a)
        b = find(b)
        @parent[b] = a unless a == b
      end
    end

    # A conjunctive query parsed into a set of table references (atoms),
    # equality classes over column references and constants, and a
    # projection (head) of column references.
    class Query
      # Hash mapping table alias strings to table name strings.
      attr_reader :atoms

      # Array of resolved projection elements, each
      # [:col, table_alias, column].
      attr_reader :head

      # All constant values used in equality predicates.
      attr_reader :constants

      def initialize
        @atoms = {}
        @raw_equalities = []
        @raw_head = []
        @constants = []
        @uf = UnionFind.new
        @class_consts = {}
        @satisfiable = true
      end

      def add_atom(key, table)
        if @atoms.key?(key)
          raise Unsupported, "table reference #{key.inspect} is used more than once; give each occurrence a unique alias"
        end
        @atoms[key] = table
      end

      def add_equality(left, right)
        @raw_equalities << [left, right]
        @constants << left[1] if left[0] == :const
        @constants << right[1] if right[0] == :const
      end

      def add_head(node)
        @raw_head << node
      end

      # Whether the query can return rows on some database.  False if the
      # equality predicates force two distinct constants to be equal.
      def satisfiable?
        @satisfiable
      end

      # Resolve column references using the schema and build the equality
      # classes.  +schema+ maps table name strings to arrays of column
      # name strings.
      def finalize(schema)
        @schema = schema
        @atoms.each_value do |table|
          unless schema.key?(table)
            raise ArgumentError, "schema does not include table referenced by query: #{table}"
          end
        end
        @raw_equalities.each do |left, right|
          l = resolve_term(left)
          r = resolve_term(right)
          if l[0] == :const && r[0] == :const
            @satisfiable = false if l[1] != r[1]
          else
            @uf.union(l, r)
          end
        end
        @constants.each do |value|
          element = [:const, value]
          root = @uf.find(element)
          if @class_consts.key?(root)
            @satisfiable = false if @class_consts[root] != value
          else
            @class_consts[root] = value
          end
        end
        @head = @raw_head.map{|node| resolve_column(node)}
        self
      end

      # The representative of the equality class containing the element.
      def rep(element)
        @uf.find(element)
      end

      # The constant in the equality class with the given representative,
      # or nil if the class contains no constant.
      def class_const(root)
        @class_consts[root]
      end

      # Yield each equality class as ([column_elements], constant_or_nil).
      def each_class
        groups = Hash.new{|h, k| h[k] = []}
        @atoms.each do |key, table|
          @schema[table].each do |column|
            element = [:col, key, column]
            groups[@uf.find(element)] << element
          end
        end
        @constants.each do |value|
          element = [:const, value]
          groups[@uf.find(element)] << element
        end
        groups.each_value do |members|
          columns = members.select{|m| m[0] == :col}
          const = nil
          members.each do |m|
            if m[0] == :const
              const = m[1]
              break
            end
          end
          yield columns, const
        end
      end

      private

      def resolve_term(node)
        node[0] == :const ? node : resolve_column(node)
      end

      def resolve_column(node)
        _, table, column = node
        if table
          unless @atoms.key?(table)
            raise Unsupported, "unknown table or alias referenced: #{table}"
          end
          unless @schema[@atoms[table]].include?(column)
            raise Unsupported, "column #{column} is not in the schema for table #{@atoms[table]}"
          end
          [:col, table, column]
        else
          matches = @atoms.keys.select{|key| @schema[@atoms[key]].include?(column)}
          unless matches.length == 1
            raise Unsupported, "unqualified column #{column} is unknown or ambiguous"
          end
          [:col, matches[0], column]
        end
      end
    end

    # The result of a containment check.  See the module documentation for
    # the meaning of the three possible statuses.
    class Result
      # One of :contained, :not_contained, or :unsupported.
      attr_reader :status

      # For :contained results, a hash mapping each table alias (Symbol)
      # of the second query to the table alias of the first query it is
      # mapped to by the containment witness homomorphism.  Column
      # references map by column name.  nil when containment holds
      # vacuously because the first query is unsatisfiable.
      attr_reader :mapping

      # For :not_contained results, a Counterexample.
      attr_reader :counterexample

      # A human readable explanation, set for :unsupported results and
      # for vacuous containment.
      attr_reader :reason

      def initialize(status, opts=OPTS)
        @status = status
        @mapping = opts[:mapping]
        @counterexample = opts[:counterexample]
        @reason = opts[:reason]
        freeze
      end

      def contained?
        @status == :contained
      end

      def not_contained?
        @status == :not_contained
      end

      def unsupported?
        @status == :unsupported
      end
    end

    # A finite database witnessing that one query is not contained in
    # another: the canonical (frozen) database of the first query, on
    # which the first query returns a row the second query does not.
    class Counterexample
      # Hash mapping table name strings to arrays of row hashes.  Each
      # table reference in the first query contributes one row; equality
      # classes are frozen to distinct values (constants keep their
      # value, other classes get fresh integers).
      attr_reader :rows

      # The projection tuple of the first query on this database.  This
      # tuple is returned by the first query but not by the second.
      attr_reader :witness

      # Rows returned by the first query but not the second when both
      # queries run against the counterexample database (an array of
      # value arrays).  Only set after verification.
      attr_reader :missing_rows

      # The in-memory SQLite Sequel::Database holding the counterexample,
      # if verification was performed.
      attr_reader :database

      # The error raised when verification could not be attempted (for
      # example, when the sqlite3 gem is not available).
      attr_reader :verification_error

      def initialize(old_query, new_query, old_ds, new_ds, schema)
        @schema = schema
        @old_sql = old_ds.unordered.select_sql
        @new_sql = new_ds.unordered.select_sql
        @arity_match = old_query.head.length == new_query.head.length

        numeric = (old_query.constants + new_query.constants).select{|c| c.is_a?(Numeric)}
        fresh = numeric.empty? ? 1 : numeric.map{|c| c.floor}.max + 1

        frozen = {}
        value_for = lambda do |element|
          root = old_query.rep(element)
          if (c = old_query.class_const(root))
            c
          else
            frozen[root] ||= (value = fresh; fresh += 1; value)
          end
        end

        @rows = {}
        old_query.atoms.each do |key, table|
          row = {}
          schema[table].each do |column|
            row[column.to_sym] = value_for.call([:col, key, column])
          end
          (@rows[table] ||= []) << row
        end
        @witness = old_query.head.map{|element| value_for.call(element)}
        @verified = false
      end

      # Whether the counterexample was verified by running both queries
      # against an in-memory SQLite database.
      def verified?
        @verified
      end

      # Build the counterexample database in an in-memory SQLite database,
      # run both queries against it, and populate missing_rows with the
      # rows returned by the first query but not the second.  Raises
      # Sequel::Error if the verification is inconsistent with the
      # containment analysis.  If the sqlite3 gem is not available, the
      # verification is skipped and verification_error is set.
      def verify!
        db = Sequel.sqlite
        @schema.each do |table, columns|
          defs = columns.map{|c| db.literal(SQL::Identifier.new(c))}.join(", ")
          db.run("CREATE TABLE #{db.literal(SQL::Identifier.new(table))} (#{defs})")
        end
        @rows.each do |table, table_rows|
          ds = db.from(SQL::Identifier.new(table))
          table_rows.each{|row| ds.insert(row)}
        end
        @missing_rows =
          if @arity_match
            fetch_rows(db, "#{@old_sql} EXCEPT #{@new_sql}")
          else
            fetch_rows(db, @old_sql)
          end
        @database = db
        @verified = true
        if @missing_rows.empty?
          raise Sequel::Error, "query containment counterexample could not be verified"
        end
        self
      rescue LoadError => e
        @verification_error = e
        self
      end

      private

      def fetch_rows(db, sql)
        db.synchronize(:default){|conn| conn.execute(sql)}
      end
    end

    # Check whether the first dataset is contained in the second (i.e.
    # returns a subset of the second dataset's rows on every database).
    # Both datasets must be conjunctive queries (see the module
    # documentation).  The :schema option is required and must map table
    # names to arrays of column names (or hashes with column name keys);
    # all columns are assumed to be NOT NULL.  Returns a Result.
    def self.check(old_ds, new_ds, opts=OPTS)
      schema = normalize_schema(opts[:schema])
      old_query = parse_dataset(old_ds, schema)
      new_query = parse_dataset(new_ds, schema)
      check_queries(old_query, new_query, old_ds, new_ds, schema)
    rescue Unsupported => e
      Result.new(:unsupported, :reason=>e.message)
    end

    # Independently verify a containment witness mapping, as returned in
    # Result#mapping.  +mapping+ must map each table alias of the second
    # (containing) query to a table alias of the first query, such that
    # every atom, equality predicate, and projected column of the second
    # query maps onto the first query.  Returns true or false.  Raises
    # QueryContainment::Unsupported if either query is outside the
    # supported fragment.
    def self.valid_mapping?(old_ds, new_ds, mapping, opts=OPTS)
      schema = normalize_schema(opts[:schema])
      old_query = parse_dataset(old_ds, schema)
      new_query = parse_dataset(new_ds, schema)
      return false unless old_query.satisfiable? && new_query.satisfiable?
      return false unless old_query.head.length == new_query.head.length
      normalized = {}
      mapping.each{|k, v| normalized[k.to_s] = v.to_s}
      return false unless normalized.keys.sort == new_query.atoms.keys.sort
      normalized.each do |new_key, old_key|
        return false unless old_query.atoms[old_key] == new_query.atoms[new_key]
      end
      old_head_reps = old_query.head.map{|el| old_query.rep(el)}
      mapping_consistent?(normalized, new_query, old_query, old_head_reps)
    end

    def self.normalize_schema(schema) # :nodoc:
      unless schema.is_a?(Hash)
        raise ArgumentError, "the :schema option must map table names to columns"
      end
      normalized = {}
      schema.each do |table, columns|
        columns = columns.keys if columns.is_a?(Hash)
        columns = columns.map{|c| c.to_s}
        if columns.empty?
          raise ArgumentError, "schema table #{table} has no columns"
        end
        normalized[table.to_s] = columns
      end
      normalized
    end

    def self.check_queries(old_query, new_query, old_ds, new_ds, schema) # :nodoc:
      unless old_query.satisfiable?
        return Result.new(:contained, :reason=>"the first query is unsatisfiable because it contains contradictory constant equalities, so it is contained in every query")
      end
      mapping = nil
      if new_query.satisfiable? && old_query.head.length == new_query.head.length
        mapping = find_mapping(new_query, old_query)
      end
      if mapping
        Result.new(:contained, :mapping=>mapping.each_with_object({}){|(k, v), h| h[k.to_sym] = v.to_sym})
      else
        counterexample = Counterexample.new(old_query, new_query, old_ds, new_ds, schema)
        counterexample.verify!
        Result.new(:not_contained, :counterexample=>counterexample)
      end
    end

    # Search for a homomorphism from from_query's atoms to to_query's
    # atoms witnessing containment.  Returns a hash mapping from_query's
    # table aliases to to_query's, or nil if no homomorphism exists.
    def self.find_mapping(from_query, to_query) # :nodoc:
      candidates = {}
      from_query.atoms.each do |key, table|
        c = to_query.atoms.keys.select{|ok| to_query.atoms[ok] == table}
        return nil if c.empty?
        candidates[key] = c
      end
      order = from_query.atoms.keys.sort_by{|k| [candidates[k].length, k]}
      head_reps = to_query.head.map{|el| to_query.rep(el)}
      assignment = {}
      backtrack = lambda do |i|
        if i == order.length
          true
        else
          key = order[i]
          candidates[key].any? do |to_key|
            assignment[key] = to_key
            ok = mapping_consistent?(assignment, from_query, to_query, head_reps) && backtrack.call(i + 1)
            assignment.delete(key) unless ok
            ok
          end
        end
      end
      backtrack.call(0) ? assignment : nil
    end

    # Whether the given partial or complete atom mapping is consistent
    # with the equality classes and projection of both queries.
    def self.mapping_consistent?(assignment, from_query, to_query, head_reps) # :nodoc:
      from_query.each_class do |columns, const|
        root = nil
        columns.each do |element|
          next unless assignment.key?(element[1])
          r = to_query.rep([:col, assignment[element[1]], element[2]])
          if root.nil?
            root = r
          elsif root != r
            return false
          end
        end
        if const && root && to_query.class_const(root) != const
          return false
        end
      end
      from_query.head.each_with_index do |element, i|
        next unless assignment.key?(element[1])
        return false unless to_query.rep([:col, assignment[element[1]], element[2]]) == head_reps[i]
      end
      true
    end

    def self.parse_dataset(ds, schema) # :nodoc:
      opts = ds.opts
      opts.each do |key, value|
        next if value.nil? || OPTS_ALLOWED.include?(key)
        raise Unsupported, "dataset option #{key.inspect} is not supported"
      end
      distinct = opts[:distinct]
      raise Unsupported, "query must use DISTINCT (containment uses set semantics)" if distinct.nil?
      raise Unsupported, "DISTINCT ON is not supported" unless distinct.empty?
      select = opts[:select]
      if select.nil? || select.empty?
        raise Unsupported, "query must have an explicit column projection"
      end
      from = opts[:from]
      if from.nil? || from.empty?
        raise Unsupported, "query has no FROM clause"
      end

      query = Query.new
      from.each do |f|
        key, table = parse_table_ref(f)
        query.add_atom(key, table)
      end
      Array(opts[:join]).each{|j| parse_join(query, j)}
      parse_conditions(query, opts[:where]) if opts[:where]
      select.each{|s| parse_select_item(query, s)}
      query.finalize(schema)
    end

    def self.parse_table_ref(expr) # :nodoc:
      case expr
      when Symbol
        [expr.to_s, expr.to_s]
      when SQL::Identifier
        [expr.value.to_s, expr.value.to_s]
      when SQL::AliasedExpression
        raise Unsupported, "derived column lists are not supported" if expr.columns
        aliaz = expr.alias
        unless aliaz.is_a?(Symbol) || aliaz.is_a?(SQL::Identifier)
          raise Unsupported, "unsupported table alias: #{aliaz.inspect}"
        end
        [aliaz.to_s, table_name(expr.expression)]
      else
        raise Unsupported, "unsupported table reference: #{expr.inspect}"
      end
    end

    def self.table_name(expr) # :nodoc:
      case expr
      when Symbol
        expr.to_s
      when SQL::Identifier
        expr.value.to_s
      else
        raise Unsupported, "unsupported table reference: #{expr.inspect}"
      end
    end

    def self.parse_join(query, join) # :nodoc:
      unless join.is_a?(SQL::JoinClause)
        raise Unsupported, "unsupported join: #{join.inspect}"
      end
      unless join.join_type == :inner || join.join_type == :cross
        raise Unsupported, "only inner joins are supported, not #{join.join_type} joins"
      end
      if join.is_a?(SQL::JoinUsingClause)
        raise Unsupported, "JOIN USING is not supported"
      end
      key, table = parse_table_ref(join.table_expr)
      query.add_atom(key, table)
      parse_conditions(query, join.on) if join.is_a?(SQL::JoinOnClause)
    end

    def self.parse_conditions(query, expr) # :nodoc:
      unless expr.is_a?(SQL::BooleanExpression)
        raise Unsupported, "unsupported filter condition: #{expr.inspect}"
      end
      case expr.op
      when :AND
        expr.args.each{|arg| parse_conditions(query, arg)}
      when :'='
        unless expr.args.length == 2
          raise Unsupported, "unsupported equality predicate: #{expr.inspect}"
        end
        query.add_equality(classify_term(expr.args[0]), classify_term(expr.args[1]))
      else
        raise Unsupported, "unsupported predicate: #{expr.op}"
      end
    end

    def self.parse_select_item(query, item) # :nodoc:
      if item.is_a?(SQL::AliasedExpression)
        raise Unsupported, "derived column lists are not supported" if item.columns
        term = classify_term(item.expression)
      else
        term = classify_term(item)
      end
      unless term[0] == :column
        raise Unsupported, "only column references can be projected, not: #{item.inspect}"
      end
      query.add_head(term)
    end

    def self.classify_term(term) # :nodoc:
      case term
      when Symbol
        [:column, nil, term.to_s]
      when SQL::Identifier
        [:column, nil, term.value.to_s]
      when SQL::QualifiedIdentifier
        [:column, term.table.to_s, term.column.to_s]
      when SQL::Blob
        raise Unsupported, "blob constants are not supported"
      when Integer
        [:const, term]
      when Float
        [:const, normalize_constant(term)]
      when String
        [:const, term]
      when nil, true, false
        raise Unsupported, "NULL and boolean constants are not supported"
      else
        raise Unsupported, "unsupported term in equality predicate: #{term.inspect}"
      end
    end

    # SQLite compares integers and floats by numeric value, so normalize
    # integral floats to integers for equality class purposes.
    def self.normalize_constant(value) # :nodoc:
      if value.is_a?(Float) && value.finite? && value == value.truncate
        value.to_i
      else
        value
      end
    end

    private_class_method :normalize_schema, :check_queries, :find_mapping,
      :mapping_consistent?, :parse_dataset, :parse_table_ref, :table_name,
      :parse_join, :parse_conditions, :parse_select_item, :classify_term,
      :normalize_constant

    module DatasetMethods
      # Statically check whether this dataset is contained in +other+
      # (i.e. returns a subset of +other+'s rows on every database).
      # Both datasets must be conjunctive queries; see the
      # Sequel::QueryContainment module documentation.  The :schema
      # option is required and must map table names to their columns,
      # which are assumed to be NOT NULL.  Returns a
      # Sequel::QueryContainment::Result.
      def contained_in?(other, opts=OPTS)
        QueryContainment.check(self, other, opts)
      end
    end

    Dataset.register_extension(:query_containment, QueryContainment::DatasetMethods)
  end
end
