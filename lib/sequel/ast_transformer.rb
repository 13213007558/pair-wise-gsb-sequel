# frozen-string-literal: true

module Sequel
  # The +ASTTransformer+ class is designed to handle the abstract syntax trees
  # that Sequel uses internally and produce modified copies of them.  By itself
  # it only produces a straight copy.  It's designed to be subclassed and have
  # subclasses returned modified copies of the specific nodes that need to
  # be modified.
  class ASTTransformer
    # Return +obj+ or a potentially transformed version of it.
    def transform(obj)
      v(obj)
    end

    private

    # Recursive version that handles all of Sequel's internal object types
    # and produces copies of them.
    def v(o)
      case o
      when Symbol, Numeric, String, Class, TrueClass, FalseClass, NilClass
        o
      when Array
        o.map{|x| v(x)}
      when Hash
        h = {}
        o.each{|k, val| h[v(k)] = v(val)}
        h
      when Set
        Set.new(o.map{|x| v(x)})
      when SQL::NumericExpression
        if o.op == :extract
          o.class.new(o.op, o.args[0], v(o.args[1]))
        else
          o.class.new(o.op, *v(o.args))
        end
      when SQL::ComplexExpression
        o.class.new(o.op, *v(o.args))
      when SQL::Identifier
        SQL::Identifier.new(v(o.value))
      when SQL::QualifiedIdentifier
        SQL::QualifiedIdentifier.new(v(o.table), v(o.column))
      when SQL::OrderedExpression
        SQL::OrderedExpression.new(v(o.expression), o.descending, :nulls=>o.nulls)
      when SQL::AliasedExpression
        SQL::AliasedExpression.new(v(o.expression), o.alias, o.columns)
      when SQL::CaseExpression
        args = [v(o.conditions), v(o.default)]
        args << v(o.expression) if o.expression?
        SQL::CaseExpression.new(*args)
      when SQL::Cast
        SQL::Cast.new(v(o.expr), o.type)
      when SQL::Function
        h = {}
        o.opts.each do |k, val|
          h[k] = v(val)
        end
        SQL::Function.new!(o.name, v(o.args), h)
      when SQL::Subscript
        SQL::Subscript.new(v(o.expression), v(o.sub))
      when SQL::Window
        opts = o.opts.dup
        opts[:partition] = v(opts[:partition]) if opts[:partition]
        opts[:order] = v(opts[:order]) if opts[:order]
        SQL::Window.new(opts)
      when SQL::PlaceholderLiteralString
        args = if o.args.is_a?(Hash)
          h = {}
          o.args.each{|k,val| h[k] = v(val)}
          h
        else
          v(o.args)
        end
        SQL::PlaceholderLiteralString.new(o.str, args, o.parens)
      when SQL::JoinOnClause
        SQL::JoinOnClause.new(v(o.on), o.join_type, v(o.table_expr))
      when SQL::JoinUsingClause
        SQL::JoinUsingClause.new(v(o.using), o.join_type, v(o.table_expr))
      when SQL::JoinClause
        SQL::JoinClause.new(o.join_type, v(o.table_expr))
      when SQL::DelayedEvaluation
        SQL::DelayedEvaluation.new(lambda{|ds| v(o.call(ds))})
      when SQL::Wrapper
        SQL::Wrapper.new(v(o.value))
      when SQL::Expression
        if o.respond_to?(:sequel_ast_transform)
          o.sequel_ast_transform(method(:v))
        else
          o
        end
      else
        o
      end
    end
  end

  # Handles qualifying existing datasets, so that unqualified columns
  # in the dataset are qualified with a given table name.
  class Qualifier < ASTTransformer
    # Set the table used to qualify unqualified columns
    def initialize(table)
      @table = table
    end

    private

    # Turn <tt>SQL::Identifier</tt>s and symbols that aren't implicitly
    # qualified into <tt>SQL::QualifiedIdentifier</tt>s.  For symbols that
    # are not implicitly qualified by are implicitly aliased, return an
    # <tt>SQL::AliasedExpression</tt>s with a qualified version of the symbol.
    def v(o)
      case o
      when Symbol
        t, column, aliaz = Sequel.split_symbol(o)
        if t
          o
        elsif aliaz
          SQL::AliasedExpression.new(SQL::QualifiedIdentifier.new(@table, SQL::Identifier.new(column)), aliaz)
        else
          SQL::QualifiedIdentifier.new(@table, o)
        end
      when SQL::Identifier
        SQL::QualifiedIdentifier.new(@table, o)
      when SQL::QualifiedIdentifier, SQL::JoinClause
        # Return these directly, so we don't accidentally qualify symbols in them.
        o
      else
        super
      end
    end
  end

  # Handles extracting window functions from expressions, replacing them
  # with identifiers that reference generated aliases.  Used to implement
  # filtering on the results of window functions on databases that do not
  # support such filtering natively, by moving the window functions into
  # a subquery and referencing the aliases in an outer query.
  class WindowFunctionExtractor < ASTTransformer
    # An array of pairs, each pair containing the generated alias symbol
    # and the related window function (SQL::Function), for all window
    # functions extracted from the transformed expression.
    attr_reader :window_functions

    def initialize
      @window_functions = []
      @function_aliases = {}
      super()
    end

    private

    # Replace window functions with identifiers referencing the generated
    # alias for the window function, recording the window function so it
    # can be added to a subquery.  Duplicate window functions use the same
    # alias.
    def v(o)
      if o.is_a?(SQL::Function) && o.opts[:over]
        unless aliaz = @function_aliases[o]
          aliaz = :"__window_filter_#{@window_functions.length + 1}"
          @function_aliases[o] = aliaz
          @window_functions << [aliaz, o]
        end
        SQL::Identifier.new(aliaz)
      else
        super
      end
    end
  end
end
