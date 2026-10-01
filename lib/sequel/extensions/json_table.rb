# frozen-string-literal: true
#
# The json_table extension provides a portable restricted JSON_TABLE DSL for
# PostgreSQL and SQLite.  SQLite expansion is performed entirely in SQL using
# JSON1 table-valued functions; values are not fetched into Ruby for expansion.

require 'strscan'

module Sequel
  class JSONTable < SQL::Expression
    include SQL::AliasMethods

    SCALAR_TYPES = [String, Integer, Float, Numeric, BigDecimal,
                    Date, DateTime, Time, TrueClass, FalseClass].freeze
    SCALAR_TYPES << Bignum if defined?(Bignum)
    SCALAR_TYPES.freeze
    INTEGER_TYPES = defined?(Bignum) ? [Integer, Bignum].freeze : [Integer].freeze

    class ColumnDSL
      attr_reader :columns

      def self.columns(&block)
        new(&block).columns.freeze
      end

      def initialize(&block)
        @columns = []
        instance_exec(&block)
      end

      def ordinality(name)
        @columns << [:ordinality, name].freeze
      end

      def column(name, type, opts=OPTS)
        @columns << [:column, name, type, opts].freeze
      end

      def nested(path, &block)
        @columns << [:nested, path, ColumnDSL.columns(&block)].freeze
      end

      SCALAR_TYPES.each do |type|
        define_method(type.name) do |name, opts=OPTS|
          column(name, type, opts)
        end
      end
    end

    Node = Struct.new(:index, :path, :columns, :parent_index, :branch)

    def self.new(expr, path, opts=OPTS, &block)
      columns = opts[:_columns] || ColumnDSL.columns(&block)
      super(expr, path, opts[:passing], opts[:on_error], columns)
    end

    def initialize(expr, path, passing, on_error, columns)
      raise Error, "json_table requires a column block" if columns.nil?
      @expr = expr
      @path = path
      @passing = passing
      @on_error = on_error
      @columns = columns
      @nodes = []
      @outputs = []
      build_nodes(columns, @path, nil, nil)
      collect_outputs(columns, 0)
      validate
      freeze
    end

    def to_s_append(ds, sql)
      case ds.db.database_type
      when :sqlite
        SQLiteBuilder.new(self, ds).build(sql)
      when :postgres
        PostgresBuilder.new(self, ds).build(sql)
      else
        raise Error, "json_table is only supported on PostgreSQL and SQLite"
      end
    end

    def sequel_ast_transform(transformer)
      opts = {:passing=>@passing, :on_error=>@on_error, :_columns=>@columns}
      self.class.new(transformer.call(@expr), @path, opts)
    end

    private

    def build_nodes(columns, path, parent, branch)
      index = @nodes.length
      @nodes << Node.new(index, path, columns, parent, branch)
      child_branch = 0
      columns.each do |column|
        next unless column[0] == :nested
        build_nodes(column[2], column[1], index, child_branch)
        child_branch += 1
      end
      index
    end

    def collect_outputs(columns, node_index)
      child_branch = 0
      columns.each do |column|
        case column[0]
        when :ordinality, :column
          @outputs << ([node_index] + column).freeze
        when :nested
          child = @nodes.index{|node| node.parent_index == node_index && node.branch == child_branch}
          collect_outputs(column[2], child)
          child_branch += 1
        end
      end
    end

    def validate
      unless [nil, :error, :empty_array].include?(@on_error)
        raise Error, "unsupported json_table on_error option: #{@on_error.inspect}"
      end
      validate_columns(@columns)
    end

    def validate_columns(columns)
      columns.each do |column|
        next unless column[0] == :column
        _, _, type, opts = column
        unless SCALAR_TYPES.include?(type)
          raise Error, "unsupported portable json_table column type: #{type.inspect}"
        end
        [opts[:on_empty], opts[:on_error]].each do |value|
          next if value.nil? || !value.is_a?(Symbol)
          unless [:null, :error, :empty_array, :empty_object].include?(value)
            raise Error, "unsupported json_table on empty/error option: #{value.inspect}"
          end
        end
      end
      columns.each{|column| validate_columns(column[2]) if column[0] == :nested}
    end

    class PostgresBuilder
      def initialize(table, ds)
        @table = table
        @ds = ds
      end

      def build(sql)
        sql << 'json_table('
        @ds.literal_append(sql, @table.instance_variable_get(:@expr))
        sql << ', '
        append_literal(sql, @table.instance_variable_get(:@path))
        passing = @table.instance_variable_get(:@passing)
        if passing && !passing.empty?
          sql << ' PASSING '
          passing.each_with_index do |(name, value), index|
            sql << ', ' if index > 0
            @ds.literal_append(sql, value)
            sql << ' AS '
            @ds.send(:identifier_append, sql, name)
          end
        end
        append_columns(sql, @table.instance_variable_get(:@columns))
        case @table.instance_variable_get(:@on_error)
        when :error then sql << ' ERROR ON ERROR'
        when :empty_array then sql << ' EMPTY ARRAY ON ERROR'
        end
        sql << ')'
      end

      private

      def append_columns(sql, columns)
        sql << ' COLUMNS('
        columns.each_with_index do |column, index|
          sql << ', ' if index > 0
          case column[0]
          when :ordinality
            @ds.literal_append(sql, column[1])
            sql << ' FOR ORDINALITY'
          when :column
            _, name, type, opts = column
            @ds.literal_append(sql, name)
            sql << ' ' << @ds.db.send(:type_literal, :type=>type).to_s
            sql << ' PATH '
            append_literal(sql, opts[:path] || "$.#{name}")
            append_on(sql, opts[:on_empty] || :null, ' ON EMPTY')
            append_on(sql, opts[:on_error] || :null, ' ON ERROR')
          when :nested
            sql << 'NESTED '
            append_literal(sql, column[1])
            append_columns(sql, column[2])
          end
        end
        sql << ')'
      end

      def append_on(sql, value, suffix)
        case value
        when nil, :null then sql << ' NULL'
        when :error then sql << ' ERROR'
        when :empty_array then sql << ' EMPTY ARRAY'
        when :empty_object then sql << ' EMPTY OBJECT'
        else
          sql << ' DEFAULT '
          append_literal(sql, value)
        end
        sql << suffix
      end

      def append_literal(sql, value)
        if sql.respond_to?(:skip_auto_param)
          sql.skip_auto_param{@ds.literal_append(sql, value)}
        else
          @ds.literal_append(sql, value)
        end
      end
    end

    class SQLiteBuilder
      def initialize(table, ds)
        @table = table
        @ds = ds
        @nodes = table.instance_variable_get(:@nodes)
        @outputs = table.instance_variable_get(:@outputs)
        @chains = {}
      end

      def build(sql)
        validate!
        queries = @nodes.map { |node| build_branch(node) }
        sql << '(SELECT '
        @outputs.each_with_index do |output, index|
          sql << ', ' if index > 0
          @ds.send(:identifier_append, sql, output[2])
        end
        sql << ' FROM ('
        queries.each_with_index do |query, index|
          sql << ' UNION ALL ' if index > 0
          sql << query
        end
        sql << ') ORDER BY _sort)'
      end

      private

      def validate!
        @outputs.each do |_,_,_,type,opts|
          next unless type
          if [:empty_array, :empty_object].include?(opts[:on_empty]) ||
             [:empty_array, :empty_object].include?(opts[:on_error])
            raise Error, "empty array/object json_table behavior requires a JSON column and is not supported on SQLite"
          end
        end
      end

      def build_branch(node)
        chain = chain_for(node)
        select = ["#{sort_expression(node)} AS _sort"]
        @outputs.each do |output|
          select << "#{output_expression(output, node.index)} AS #{@ds.literal(output[2])}"
        end
        sql = "SELECT #{select.join(', ')} FROM #{chain_sql(chain)}"
        children = direct_children(node)
        unless children.empty?
          guards = children.map { |child| "NOT EXISTS (#{child_exists_subquery(node, child)})" }
          sql << " WHERE #{guards.join(' AND ')}"
        end
        sql
      end

      def direct_children(node)
        @nodes.select { |child| child.parent_index == node.index }
      end

      def child_exists_subquery(parent, child)
        parent_alias = "j#{chain_for(parent).last[2]}"
        parts = []
        tokens = parse_path(child.path)
        tokens.each_with_index do |segment, index|
          source_alias = index.zero? ? parent_alias : "e#{index - 1}"
          terminal = index == tokens.length - 1
          source = if segment[0] == :wildcard
            wildcard_source(source_alias)
          elsif terminal
            singleton_source(source_alias, segment)
          else
            navigation_source(source_alias, segment)
          end
          parts << "json_each(#{source}) e#{index}"
        end
        "SELECT 1 FROM #{parts.join(' JOIN ')}"
      end

      def chain_for(node)
        @chains[node.index] ||= begin
          if node.parent_index.nil?
            root_chain(node.path)
          else
            chain = chain_for(@nodes[node.parent_index]).map(&:dup)
            start_alias = chain.last[2] + 1
            parse_path(node.path).each_with_index do |segment, index|
              chain << [segment[0], segment[1], start_alias + index]
            end
            chain
          end
        end
      end

      def root_chain(path)
        tokens = parse_path(path)
        if tokens.first && tokens.first[0] == :wildcard
          [[:root, nil, 0], [:root_wildcard, nil, 1]] + tokens[1..-1].each_with_index.map { |segment, index| [segment[0], segment[1], index + 2] }
        else
          [[:root, nil, 0]] + tokens.each_with_index.map { |segment, index| [segment[0], segment[1], index + 1] }
        end
      end

      def parse_path(path)
        scanner = StringScanner.new(path.to_s)
        raise Error, "invalid JSON path: #{path}" unless scanner.scan(/\$/)
        segments = []
        until scanner.eos?
          if scanner.scan(/\[\*\]/)
            segments << [:wildcard]
          elsif scanner.scan(/\[(\d+)\]/)
            segments << [:index, scanner[1].to_i]
          elsif scanner.scan(/\.([A-Za-z_][A-Za-z0-9_]*)/)
            segments << [:member, scanner[1]]
          else
            raise Error, "unsupported portable JSON path on SQLite: #{path}"
          end
        end
        segments
      end

      def chain_sql(chain)
        parts = []
        chain.each_with_index do |segment, index|
          name = "j#{segment[2]}"
          source = if index.zero? && segment[0] == :root
            root_singleton_source
          elsif segment[0] == :root_wildcard
            wildcard_source("j#{chain[index - 1][2]}")
          elsif segment[0] == :wildcard
            wildcard_source("j#{chain[index - 1][2]}")
          else
            navigation_source("j#{chain[index - 1][2]}", segment)
          end
          parts << ((index.zero? ? "json_each(#{source})" : "JOIN json_each(#{source})") + " #{name}")
        end
        parts.join(' ')
      end

      def root_singleton_source
        expr = expression_sql
        "json_array(CASE WHEN json_valid(#{expr}) THEN json(#{expr}) ELSE #{root_invalid_expression} END)"
      end

      def singleton_source(previous, segment)
        kind, key = segment
        path = @ds.literal(kind == :index ? "$[#{key}]" : "$.#{key}")
        present = "#{previous}.type IN ('object', 'array') AND json_type(#{previous}.value, #{path}) IS NOT NULL"
        value = "CASE WHEN json_type(#{previous}.value, #{path}) IN ('array', 'object') THEN json(json_extract(#{previous}.value, #{path})) WHEN json_type(#{previous}.value, #{path}) = 'null' THEN json('null') ELSE json_extract(#{previous}.value, #{path}) END"
        "CASE WHEN #{present} THEN json_array(#{value}) ELSE json_array() END"
      end

      def navigation_source(previous, segment)
        kind, key = segment
        path = @ds.literal(kind == :index ? "$[#{key}]" : "$.#{key}")
        present = "#{previous}.type IN ('object', 'array') AND json_type(#{previous}.value, #{path}) IS NOT NULL"
        value = "CASE WHEN json_type(#{previous}.value, #{path}) IN ('array', 'object') THEN json(json_extract(#{previous}.value, #{path})) WHEN json_type(#{previous}.value, #{path}) = 'null' THEN json('null') ELSE json_extract(#{previous}.value, #{path}) END"
        "CASE WHEN #{present} THEN json_array(#{value}) ELSE json_array(NULL) END"
      end

      def wildcard_source(previous)
        "CASE WHEN #{previous}.type = 'array' THEN #{previous}.value ELSE json_array() END"
      end

      def expression_sql
        @ds.literal(@table.instance_variable_get(:@expr))
      end

      def root_invalid_expression
        @table.instance_variable_get(:@on_error) == :error ? "json('{' || '')" : 'NULL'
      end

      def sort_expression(node)
        wildcard_aliases = wildcard_positions(node)
        ordinal = wildcard_aliases.any? ? "printf('%012d', j#{wildcard_aliases.last}.key + 1)" : "'1'"
        own = "printf('%012d', #{node.branch || 0}) || ':' || #{ordinal}"
        node.parent_index ? "(#{sort_expression(@nodes[node.parent_index])}) || '/' || #{own}" : own
      end

      def wildcard_positions(node)
        chain_for(node).each_with_index.map do |segment, index|
          chain_for(node)[index][2] if [:wildcard, :root_wildcard].include?(segment[0])
        end.compact
      end

      def output_expression(output, current_node_index)
        output_node_index = output[0]
        return 'NULL' unless descendant?(current_node_index, output_node_index)
        node = @nodes[output_node_index]
        alias_name = "j#{chain_for(node).last[2]}"
        output[1] == :ordinality ? ordinality_expression(node, alias_name) : scalar_expression(output, alias_name)
      end

      def descendant?(node_index, ancestor_index)
        while node_index
          return true if node_index == ancestor_index
          node_index = @nodes[node_index].parent_index
        end
        false
      end

      def ordinality_expression(node, alias_name)
        positions = wildcard_positions(node)
        positions.empty? ? '1' : "#{alias_name}.key + 1"
      end

      def scalar_expression(output, alias_name)
        _, _, name, type, opts = output
        path = @ds.literal(opts[:path] || "$.#{name}")
        type_expr = "json_type(#{alias_name}.value, #{path})"
        value_expr = "json_extract(#{alias_name}.value, #{path})"
        "CASE WHEN #{type_expr} = 'null' OR (#{type_expr} IS NULL AND #{alias_name}.type = 'null') THEN NULL " \
        "WHEN #{type_expr} IS NULL AND #{alias_name}.type IN ('object', 'array') THEN #{on_value(opts[:on_empty] || :null)} " \
        "WHEN #{type_test(type, type_expr)} THEN #{value_expr} " \
        "ELSE #{on_value(opts[:on_error] || :null)} END"
      end

      def type_test(type, type_expr)
        if [String, Date, DateTime, Time].include?(type)
          "#{type_expr} = 'text'"
        elsif INTEGER_TYPES.include?(type)
          "#{type_expr} = 'integer'"
        elsif [Float, Numeric, BigDecimal].include?(type)
          "#{type_expr} IN ('integer', 'real')"
        elsif [TrueClass, FalseClass].include?(type)
          "#{type_expr} IN ('true', 'false')"
        else
          raise Error, "unsupported portable json_table column type: #{type.inspect}"
        end
      end

      def on_value(value)
        case value
        when nil, :null then 'NULL'
        when :error then "json('{' || '')"
        when Symbol then @ds.literal(value.to_s)
        else @ds.literal(value)
        end
      end
    end
  end

  module SQL::Builders
    def json_table(expr, path, opts=OPTS, &block)
      Sequel::JSONTable.new(expr, path, opts, &block)
    end
  end
end
