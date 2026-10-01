# frozen-string-literal: true
#
# The json_table extension provides a portable, restricted table definition
# interface for expanding JSON documents into relational rows.  It supports
# both PostgreSQL 17+ (using the native SQL/JSON +json_table+ function) and
# the SQLite JSON1 extension (using +json_each+ and +json_extract+), with the
# same row-expansion contract on both databases.
#
# To load the extension:
#
#   Sequel.extension :json_table
#
# To use the extension, call #json_table on a dataset, or create a
# Sequel::JSONTable object with Sequel.json_table:
#
#   DB[:docs].json_table(:data, '$.items') do
#     ordinality :ordinal
#     String :name, path: '$.name', on_empty: nil, on_error: nil
#     Integer :count
#     nested '$.tags' do
#       String :tag
#     end
#   end
#
# This is a restricted subset of the PostgreSQL +json_table+ DSL provided by
# the pg_json_ops extension.  The following constructs are supported portably:
#
# ordinality(name) :: Include a FOR ORDINALITY column.  Ordinality starts at
#                     1 for the items expanded at each level, and resets for
#                     every parent row.
# column(name, type, opts={}) :: Include a scalar column of the given type.
# String(name, opts={}), Integer(name, opts={}), ... :: Shortcuts for the
#   common scalar types (String, Integer, Float, Numeric, TrueClass,
#   FalseClass, Date, DateTime, and Time).
# nested(path, &block) :: Expand rows from the items at the given path.
#   Multiple sibling +nested+ blocks are combined using the SQL/JSON union
#   semantics: each row produced by one sibling has NULL values for the
#   columns of the other siblings.  Siblings are never combined using a
#   cross product.
#
# Scalar columns support these options:
#
# :path :: JSON path to the value (the default is <tt>$.NAME</tt>, where
#          +NAME+ is the column name).
# :on_empty :: Value to use when the path does not yield a value.  By default
#              this is +nil+ (NULL).  Use +:error+ to raise an error instead,
#              or provide any other literal value as the default.
# :on_error :: Value to use when the yielded value cannot be converted to the
#              column type.  By default this is +nil+ (NULL).  Use +:error+
#              to raise an error instead, or provide any other literal value
#              as the default.
#
# A missing value (path yields nothing), an explicit JSON +null+, and a type
# conversion failure are always handled distinctly:
#
# * A missing value applies the +:on_empty+ behavior.  An explicit JSON
#   +null+ does not, it always produces Ruby +nil+.
# * A value of the wrong JSON type applies the +:on_error+ behavior.
# * The JSON +null+ value always produces Ruby +nil+, regardless of the
#   configured +:on_empty+ behavior.
#
# When a +nested+ path does not yield any items (the path is missing,
# contains an empty array, or the parent value does not contain the path),
# a single row is emitted with NULL values for all columns introduced by that
# nested block (outer-join style parent row preservation).
#
# On SQLite, all expansion is performed inside the database using the JSON1
# functions; JSON data is not fetched into Ruby and expanded there.
#
# Because SQLite does not allow a subquery in FROM to reference sibling
# tables laterally, the SQLite emulation cannot correlate a root JSON
# expression to a column of another FROM table.  Use a JSON literal, a bound
# parameter, a CTE in scope, or evaluate the expansion per document instead.
#
# Related class: Sequel::JSONTable

module Sequel
  # A portable table definition for expanding JSON documents into rows.
  # JSONTable instances are typically created using Sequel.json_table.
class JSONTable < SQL::Expression
    # Scalar types supported portably by the restricted DSL, mapped to the
    # SQL type emitted for PostgreSQL's json_table.
    SCALAR_TYPES = {
      String => 'text'.freeze,
      Integer => 'integer'.freeze,
      Float => 'double precision'.freeze,
      Numeric => 'numeric'.freeze,
      TrueClass => 'boolean'.freeze,
      FalseClass => 'boolean'.freeze,
      Date => 'date'.freeze,
      DateTime => 'timestamp'.freeze,
      Time => 'timestamp'.freeze,
    }.freeze

    # Ruby classes exposed as DSL methods inside json_table blocks.
    DSL_TYPES = %w'String Integer Float Numeric Date DateTime Time TrueClass FalseClass'.map(&:to_sym).freeze

    # Class used to evaluate json_table blocks and nested blocks.
    class ColumnDSL
      # Return the frozen column definition tree recorded for the block.
      attr_reader :columns

      def self.columns(&block)
        new(&block).columns.freeze
      end

      def initialize(&block)
        @columns = []
        instance_exec(&block)
      end

      # Include a FOR ORDINALITY column.
      def ordinality(name)
        @columns << [:ordinality, name].freeze
      end

      # Include a scalar column of the given type.
      def column(name, type, opts=OPTS)
        unless JSONTable::SCALAR_TYPES.key?(type)
          raise Error, "unsupported json_table column type: #{type.inspect}"
        end

        opts = opts.dup
        opts[:path] ||= JSONTable.default_path(name)
        @columns << [:column, name, type, opts.freeze].freeze
      end

      # Include a nested set of columns expanded from the items at the path.
      def nested(path, &block)
        @columns << [:nested, path, ColumnDSL.columns(&block)].freeze
      end

      # Define the generic Ruby class type shortcuts.
      DSL_TYPES.each do |meth|
        klass = Object.const_get(meth)
        define_method(meth) do |name, opts=OPTS|
          column(name, klass, opts)
        end
      end
    end
    private_constant :ColumnDSL

    # Return the default JSON path for a column with the given name.
    def self.default_path(name)
      # Quote the name as a JSON path key, escaping backslashes and double
      # quotes.  Both PostgreSQL and SQLite accept double quoted member names.
      name = name.to_s
      '$.' + '"' + name.gsub(/["\\]/) { |c| "\\#{c}" } + '"'
    end

    # The JSON expression providing the documents to expand.
    attr_reader :expr

    # The JSON path expression to the row set to expand.
    attr_reader :path

    # The frozen column definition tree for the table.
    attr_reader :columns

    # The parsed per-depth level structure used by the SQLite emulation.
    attr_reader :levels

    # Table level options (currently only :on_error).
    attr_reader :opts

    def initialize(expr, path, opts=OPTS, &block)
      @expr = expr
      @path = path
      @opts = opts.freeze
      @columns = opts[:_columns] || ColumnDSL.columns(&block)
      @on_error = opts[:on_error]
      unless [nil, :error, :empty_array].include?(@on_error)
        raise Error, "unsupported json_table :on_error option: #{@on_error.inspect}"
      end

      @levels = build_levels

      freeze
    end

    # Return a dataset that expands the JSON table rows, selecting all
    # declared columns.  The returned dataset can be used in place of a normal
    # dataset or joined/comma-sourced with other tables.
    def to_dataset(db)
      db.json_table(self)
    end

    # All output column names, in declaration order, including nested columns.
    def visible_columns
      visible_columns_for(@columns)
    end

    # Support transforming of the JSON expression.
    def sequel_ast_transform(transformer)
      opts = @opts.merge(:_columns => @columns)
      self.class.new(transformer.call(@expr), @path, opts)
    end

    # Dispatch to the database specific SQL representation.
    def to_s_append(ds, sql)
      case ds.db.database_type
      when :postgres
        postgres_sql_append(ds, sql)
      when :sqlite
        sql << '('
        SQLiteJSONTable.new(self, ds).to_s_append(ds, sql)
        sql << ')'
      else
        raise Error, "json_table is not implemented on #{ds.db.database_type}"
      end
    end


    private

    def visible_columns_for(columns)
      columns.flat_map do |column|
        case column[0]
        when :column, :ordinality
          [column[1]]
        when :nested
          visible_columns_for(column[2])
        end
      end
    end

    # Build the internal level structure as a flat array, one entry per
    # nesting depth.  Every NESTED PATH block producing rows at a depth gets a
    # unique branch index within that depth.  Each level has:
    # :scalars :: [column, branch_index] pairs (nil branch for root columns)
    # :blocks :: Hash mapping the parent block's branch index (0 for the root
    #            block) to that block's child [path, columns] NESTED PATH
    #            branches.  The SQLite combiner selects the child list of the
    #            block that produced each parent row.
    def build_levels
      root_scalars = []
      root_children = []
      @columns.each do |column|
        case column[0]
        when :column, :ordinality
          root_scalars << [column, nil].freeze
        when :nested
          root_children << [column[1], column[2]].freeze
        end
      end

      root_level = {:scalars => root_scalars.freeze, :blocks => {0 => root_children.freeze}.freeze}
      levels = [root_level]

      # parents is a list of [parent_branch_index, columns] pairs for the
      # blocks whose NESTED children produce rows at the next depth.  The root
      # block is parent branch 0.
      parents = [[0, @columns]]
      until parents.empty?
        scalars = []
        blocks = []
        next_parents = []

        # Assign global branch indices in parent block order, declaration order.
        global_index = 0
        parents.each do |parent_branch, columns|
          children = []
          columns.each do |column|
            next unless column[0] == :nested

            _, nested_path, nested_columns = column
            branch_index = global_index
            global_index += 1
            children << [nested_path, nested_columns].freeze
            nested_columns.each do |entry|
              scalars << [entry, branch_index].freeze if entry[0] == :column || entry[0] == :ordinality
            end
            next_parents << [branch_index, nested_columns]
          end
          blocks << [parent_branch, children.freeze].freeze
        end

        break if global_index.zero?
        blocks_hash = blocks.reject { |_, children| children.empty? }.to_h
        levels << {:scalars => scalars.freeze, :blocks => blocks_hash.freeze}
        parents = next_parents
      end

      levels.freeze
    end

    # Append the PostgreSQL native json_table expression.  The per-column
    # ON EMPTY/ON ERROR clauses are always emitted explicitly so that the
    # behavior matches the SQLite emulation regardless of database defaults.
    def postgres_sql_append(ds, sql)
      sql << 'json_table('
      ds.literal_append(sql, @expr)
      sql << ', '
      postgres_default_literal_append(ds, sql, @path)
      postgres_columns_append(ds, sql, @columns)
      if @on_error == :empty_array
        sql << ' EMPTY ARRAY ON ERROR'
      elsif @on_error == :error
        sql << ' ERROR ON ERROR'
      end
      sql << ')'
    end

    def postgres_columns_append(ds, sql, columns)
      sql << ' COLUMNS('
      columns.each_with_index do |column, idx|
        sql << ', ' if idx > 0
        postgres_column_append(ds, sql, column)
      end
      sql << ')'
    end

    def postgres_column_append(ds, sql, column)
      case column[0]
      when :column
        _, name, type, opts = column
        ds.literal_append(sql, name)
        sql << ' ' << SCALAR_TYPES.fetch(type)
        sql << ' PATH '
        postgres_default_literal_append(ds, sql, opts[:path])
        postgres_on_value_append(ds, sql, opts[:on_empty], ' ON EMPTY')
        postgres_on_value_append(ds, sql, opts[:on_error], ' ON ERROR')
      when :ordinality
        ds.literal_append(sql, column[1])
        sql << ' FOR ORDINALITY'
      else # :nested
        _, path, nested_columns = column
        sql << 'NESTED '
        postgres_default_literal_append(ds, sql, path)
        postgres_columns_append(ds, sql, nested_columns)
      end
    end

    # Emit the ON EMPTY/ON ERROR behavior for a scalar column.  Unspecified
    # and +:null+ both emit NULL ON EMPTY/ON ERROR explicitly.
    def postgres_on_value_append(ds, sql, value, cond)
      if value.nil?
        sql << ' NULL'
      elsif value == :error
        sql << ' ERROR'
      else
        sql << ' DEFAULT '
        postgres_default_literal_append(ds, sql, value)
      end
      sql << cond
    end

    # Do not auto parameterize default values or paths, as PostgreSQL does
    # not allow parameters in these clauses.
    def postgres_default_literal_append(ds, sql, value)
      if sql.respond_to?(:skip_auto_param)
        sql.skip_auto_param { ds.literal_append(sql, value) }
      else
        ds.literal_append(sql, value)
      end
    end
  end


  # Builds the raw SELECT query that emulates json_table on SQLite using the
  # JSON1 functions.  The query is a comma join of one json_each table-valued
  # function per nesting depth.  The root json_each expands the root path
  # items.  Each nested json_each expands a combiner array whose entries tag
  # the owning parent row and sibling branch:
  #
  #   [{"pk": <parent json_each key>, "b": 0, "v": <item>}, ...]
  #
  # The combiner is built from the UNION ALL of all sibling NESTED PATH
  # branches declared within the parent blocks of the previous depth, so
  # siblings contribute distinct rows (union) and never a cross product.  A
  # single marker entry tagged {"pk": "", "b": -1} is emitted for a parent
  # row whose branches all yield no items, preserving the parent row (outer
  # join semantics); the marker propagates through deeper depths.  The
  # json_each key provides the FOR ORDINALITY value, which resets for every
  # parent row.
  class SQLiteJSONTable < SQL::Expression
    MARKER = '{"b":-1}'.freeze

    def initialize(table, ds)
      @table = table
      @ds = ds
      @factors = []
      @selects = []
      build
    end

    def to_s_append(_ds, sql)
      sql << "SELECT #{@selects.join(', ')} FROM #{@factors.join(', ')}"
    end

    private

    def build
      levels = @table.levels
      levels.each_with_index { |level, depth| emit_level(level, depth) }
    end

    def emit_level(level, depth)
      calias = "c#{depth}"
      if depth.zero?
        @factors << "json_each(#{root_sequence_sql}) #{calias}"
      else
        @factors << "json_each(#{combiner_sql(level, depth)}) #{calias}"
      end

      frag = depth.zero? ? "#{calias}.value" : "(#{calias}.value -> '$.v')"
      level[:scalars].each do |entry, branch_index|
        @selects << scalar_select_sql(entry, depth, branch_index, calias, frag)
      end
    end

    # Raw SQL for the combiner array of a nested depth.  The level's :blocks
    # map each parent block (by its global branch index at the previous
    # depth) to its child NESTED PATH branches.  A parent row selects its
    # block's child list; the children are concatenated from independent
    # correlated scalar subqueries (no derived-table correlation).  Items are
    # tagged with their global branch index; a marker row is produced when the
    # block yields no items.
    def combiner_sql(level, depth)
      parent_alias = "c#{depth - 1}"
      parent_item = depth == 1 ? "#{parent_alias}.value" : "(#{parent_alias}.value -> '$.v')"
      parent_b = depth == 1 ? '0' : "json_extract(#{parent_alias}.value, '$.b')"

      cases = level[:blocks].sort.map do |parent_branch, child_branches|
        pieces = child_branches.each_with_index.map do |(path, _), idx|
          branch_index = global_branch_index(level, parent_branch, idx)
          # A present non-array value is wrapped into one item by the branch
          # sequence; an empty array or a missing value yields no items.
          path_lit = literal(path)
          cond = "json_type(#{parent_item}, #{path_lit}) IS NOT NULL " \
                 "AND (json_type(#{parent_item}, #{path_lit}) != 'array' " \
                 "OR json_array_length(#{parent_item}, #{path_lit}) > 0)"
          "CASE WHEN #{cond} THEN (SELECT #{idx.zero? ? "'' || " : "',' || "}group_concat(" \
          "json_insert(json_object('b', #{branch_index}), '$.v', je.value)) " \
          "FROM json_each(#{branch_sequence_sql(parent_item, path)}) je) ELSE '' END"
        end
        body = pieces.join(' || ')
        "WHEN #{parent_b} = #{parent_branch} THEN " \
        "COALESCE(NULLIF('[' || #{body} || ']', '[]'), '[#{MARKER}]')"
      end
      "CASE #{cases.join(' ')} ELSE '[#{MARKER}]' END"
    end

    # Global branch index of the idx-th child of a parent block at a level.
    def global_branch_index(level, parent_branch, idx)
      flat = level[:blocks].sort.flat_map { |_, children| children }
      children = level[:blocks][parent_branch]
      flat.index(children[idx])
    end

    # Sequence of items for the root path.
    def root_sequence_sql
      expr = literal(@table.expr)
      path = literal(@table.path)
      guard = @table.opts[:on_error] == :empty_array ? "WHEN json_valid(#{expr}) = 0 THEN '[]' " : ''
      "CASE #{guard}" \
      "WHEN json_type(#{expr}, #{path}) = 'array' THEN (#{expr} -> #{path}) " \
      "WHEN json_type(#{expr}, #{path}) IS NULL THEN '[]' " \
      "ELSE json_insert('[]', '$[#]', (#{expr} -> #{path})) END"
    end

    # Sequence of items for one sibling branch.
    def branch_sequence_sql(parent_frag, path)
      path = literal(path)
      "CASE WHEN json_type(#{parent_frag}, #{path}) = 'array' THEN (#{parent_frag} -> #{path}) " \
      "WHEN json_type(#{parent_frag}, #{path}) IS NULL THEN NULL " \
      "ELSE json_insert('[]', '$[#]', (#{parent_frag} -> #{path})) END"
    end

    def scalar_select_sql(entry, depth, branch_index, calias, frag)
      case entry[0]
      when :ordinality
        ordinal = "CAST(#{calias}.key AS INTEGER) + 1"
        expr = depth.zero? ? ordinal : "CASE WHEN #{tag_expr(calias, 'b')} >= 0 THEN #{ordinal} ELSE NULL END"
        "#{expr} AS #{quote_identifier(entry[1])}"
      when :column
        _, name, type, opts = entry
        scalar = scalar_value_sql(frag, calias, type, opts)
        expr = if depth.zero?
          scalar
        else
          "CASE WHEN #{tag_expr(calias, 'b')} = #{branch_index} THEN (#{scalar}) ELSE NULL END"
        end
        "#{expr} AS #{quote_identifier(name)}"
      end
    end

    # CASE expression distinguishing a missing value, an explicit JSON null,
    # and a value that cannot be converted to the column type.
    def scalar_value_sql(frag, calias, type, opts)
      path = literal(opts[:path])
      type_expr = "json_type(#{frag}, #{path})"
      predicate, conversion = type_conversion_sql(frag, path, type_expr, type)
      "CASE WHEN #{type_expr} IS NULL THEN #{on_value_sql(opts[:on_empty], calias)} " \
      "WHEN #{type_expr} = 'null' THEN NULL " \
      "WHEN #{predicate} THEN #{conversion} " \
      "ELSE #{on_value_sql(opts[:on_error], calias)} END"
    end

    def type_conversion_sql(frag, path, type_expr, type)
      value = "json_extract(#{frag}, #{path})"
      if type == Integer
        ["#{type_expr} = 'integer'", "CAST(#{value} AS INTEGER)"]
      elsif type == Float
        ["#{type_expr} IN ('integer', 'real')", "CAST(#{value} AS REAL)"]
      elsif type == Numeric
        ["#{type_expr} IN ('integer', 'real')", "CAST(#{value} AS NUMERIC)"]
      elsif type == TrueClass || type == FalseClass
        ["#{type_expr} IN ('true', 'false')", "CAST(#{value} AS INTEGER)"]
      elsif [Date, DateTime, Time].include?(type)
        ["#{type_expr} = 'text'", "CAST(#{value} AS TEXT)"]
      else # String
        conversion =
          "CASE #{type_expr} WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' " \
          "ELSE CAST(#{value} AS TEXT) END"
        ["#{type_expr} IN ('text', 'integer', 'real', 'true', 'false')", conversion]
      end
    end

    # SQL for an ON EMPTY/ON ERROR behavior.
    def on_value_sql(value, calias)
      case value
      when nil, :null
        'NULL'
      when :error
        "json('{' || substr(#{calias}.value, 1, 0))"
      else
        literal(value)
      end
    end

    def tag_expr(calias, key)
      "json_extract(#{calias}.value, '$.#{key}')"
    end

    def quote_identifier(name)
      @ds.send(:quote_identifier, name)
    end

    def literal(value)
      @ds.literal(value)
    end
  end

  module SQL::Builders
    # Return a portable JSONTable expression expanding the JSON document at
    # +expr+ using the JSON path +path+, with the table definition given by
    # the block (see Sequel::JSONTable for the block DSL).
    #
    #   Sequel.json_table(:data, '$.items') do
    #     ordinality :ordinal
    #     String :name
    #   end
    def json_table(expr, path='$', opts=OPTS, &block)
      JSONTable.new(expr, path, opts, &block)
    end
  end

  class Dataset
    # Expand JSON documents into rows using the portable restricted table
    # definition block.  Accepts either a Sequel::JSONTable instance or the
    # same arguments as Sequel.json_table, and returns a dataset selecting all
    # declared columns:
    #
    #   DB.json_table(:data, '$.items'){ String :name }
    def json_table(expr, path='$', opts=OPTS, &block)
      table = expr.is_a?(JSONTable) ? expr : JSONTable.new(expr, path, opts, &block)
      from(table).select(*table.visible_columns)
    end
  end

  class Database
    # Return a dataset expanding JSON documents into rows (see Dataset#json_table).
    def json_table(expr, path='$', opts=OPTS, &block)
      from.json_table(expr, path, opts, &block)
    end
  end
end
