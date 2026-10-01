# frozen-string-literal: true
#
# The pg_range extension adds support for the PostgreSQL 9.2+ range
# types to Sequel.  PostgreSQL range types are similar to ruby's
# Range class, representing an array of values.  However, they
# are more flexible than ruby's ranges, allowing exclusive beginnings
# and endings (ruby's range only allows exclusive endings).
#
# When PostgreSQL range values are retrieved, they are parsed and returned
# as instances of Sequel::Postgres::PGRange.  PGRange mostly acts
# like a Range, but it's not a Range as not all PostgreSQL range
# type values would be valid ruby ranges.  If the range type value
# you are using is a valid ruby range, you can call PGRange#to_range
# to get a Range.  However, if you call PGRange#to_range on a range
# type value uses features that ruby's Range does not support, an
# exception will be raised.
#
# In addition to the parser, this extension comes with literalizers
# for PGRange and Range, so they can be used in queries and as bound variables.
#
# To turn an existing Range into a PGRange, use Sequel.pg_range:
#
#   Sequel.pg_range(range)
#
# If you have loaded the {core_extensions extension}[rdoc-ref:doc/core_extensions.rdoc],
# or you have loaded the core_refinements extension
# and have activated refinements for the file, you can also use Range#pg_range:
#
#   range.pg_range 
#
# You may want to specify a specific range type:
#
#   Sequel.pg_range(range, :daterange)
#   range.pg_range(:daterange)
#
# If you specify the range database type, Sequel will automatically cast
# the value to that type when literalizing.
#
# PGRange also supports set operations in Ruby, without needing a
# database connection:
#
#   r1 = Sequel.pg_range(1..5)
#   r2 = Sequel.pg_range(4..10)
#   r1 | r2             # union (also r1 + r2, r1.union(r2))
#   r1 & r2             # intersection (also r1.intersection(r2))
#   r1 - r2             # difference (also r1.difference(r2))
#   r1.complement(0..20) # complement within the given bounding range
#
# Union, difference, and complement can result in multiple ranges, so
# they return Sequel::Postgres::PGMultiRange instances (the
# pg_multirange extension is loaded automatically by this extension).
# Intersection returns a PGRange when both operands are single ranges.
# All set operation results are normalized: the ranges are sorted,
# non-overlapping, and cannot be merged further.  Ranges with integer
# or date bounds use discrete semantics (adjacent ranges such as
# [1,5] and [6,10] are merged), while ranges with continuous bounds
# (such as numerics and timestamps) are only merged when they overlap
# or share an endpoint included by at least one of the ranges.
# Set operations never modify their operands, and raise
# Sequel::InvalidValue if the operands have incompatible database
# types or bounds that cannot be ordered.
#
# To use this extension, load it into the Database instance:
#
#   DB.extension :pg_range
#
# See the {schema modification guide}[rdoc-ref:doc/schema_modification.rdoc]
# for details on using range type columns in CREATE/ALTER TABLE statements.
#
# This extension makes it easy to add support for other range types.  In
# general, you just need to make sure that the subtype is handled and has the
# appropriate converter installed.  For user defined
# types, you can do this via:
#
#   DB.add_conversion_proc(subtype_oid){|string| }
#
# Then you can call
# Sequel::Postgres::PGRange::DatabaseMethods#register_range_type
# to automatically set up a handler for the range type.  So if you
# want to support the timerange type (assuming the time type is already
# supported):
#
#   DB.register_range_type('timerange')
#
# This extension integrates with the pg_array extension.  If you plan
# to use arrays of range types, load the pg_array extension before the
# pg_range extension:
#
#   DB.extension :pg_array, :pg_range
#
# Related module: Sequel::Postgres::PGRange

require 'sequel/extensions/pg_multirange'

module Sequel
  module Postgres
    class PGRange
      include Sequel::SQL::AliasMethods

      # Creates callable objects that convert strings into PGRange instances.
      class Parser
        # The database range type for this parser (e.g. 'int4range'),
        # automatically setting the db_type for the returned PGRange instances.
        attr_reader :db_type

        # A callable object to convert the beginning and ending of the range into
        # the appropriate ruby type.
        attr_reader :converter

        # Set the db_type and converter on initialization.
        def initialize(db_type, converter=nil)
          @db_type = db_type.to_s.dup.freeze if db_type
          @converter = converter
        end

        # Parse the range type input string into a PGRange value.
        def call(string)
          if string == 'empty'
            return PGRange.empty(db_type)
          end

          raise(InvalidValue, "invalid or unhandled range format: #{string.inspect}") unless matches = /\A(\[|\()("((?:\\"|[^"])*)"|[^"]*),("((?:\\"|[^"])*)"|[^"]*)(\]|\))\z/.match(string)

          exclude_begin = matches[1] == '('
          exclude_end = matches[6] == ')'

          # If the input is quoted, it needs to be unescaped.  Also, quoted input isn't
          # checked for emptiness, since the empty quoted string is considered an 
          # element that happens to be the empty string, while an unquoted empty string
          # is considered unbounded.
          #
          # While PostgreSQL allows pure escaping for input (without quoting), it appears
          # to always use the quoted output form when characters need to be escaped, so
          # there isn't a need to unescape unquoted output.
          if beg = matches[3]
            beg.gsub!(/\\(.)/, '\1')
          else
            beg = matches[2] unless matches[2].empty?
          end
          if en = matches[5]
            en.gsub!(/\\(.)/, '\1')
          else
            en = matches[4] unless matches[4].empty?
          end

          if c = converter
            beg = c.call(beg) if beg
            en = c.call(en) if en
          end

          PGRange.new(beg, en, :exclude_begin=>exclude_begin, :exclude_end=>exclude_end, :db_type=>db_type)
        end
      end

      module DatabaseMethods
        # Add the conversion procs to the database
        # and extend the datasets to correctly literalize ruby Range values.
        def self.extended(db)
          db.instance_exec do
            @pg_range_schema_types ||= {}
            extend_datasets(DatasetMethods)
            register_range_type('int4range', :oid=>3904, :subtype_oid=>23)
            register_range_type('numrange', :oid=>3906, :subtype_oid=>1700)
            register_range_type('tsrange', :oid=>3908, :subtype_oid=>1114)
            register_range_type('tstzrange', :oid=>3910, :subtype_oid=>1184)
            register_range_type('daterange', :oid=>3912, :subtype_oid=>1082)
            register_range_type('int8range', :oid=>3926, :subtype_oid=>20)
            if respond_to?(:register_array_type)
              register_array_type('int4range', :oid=>3905, :scalar_oid=>3904, :scalar_typecast=>:int4range)
              register_array_type('numrange', :oid=>3907, :scalar_oid=>3906, :scalar_typecast=>:numrange)
              register_array_type('tsrange', :oid=>3909, :scalar_oid=>3908, :scalar_typecast=>:tsrange)
              register_array_type('tstzrange', :oid=>3911, :scalar_oid=>3910, :scalar_typecast=>:tstzrange)
              register_array_type('daterange', :oid=>3913, :scalar_oid=>3912, :scalar_typecast=>:daterange)
              register_array_type('int8range', :oid=>3927, :scalar_oid=>3926, :scalar_typecast=>:int8range)
            end
            [:int4range, :numrange, :tsrange, :tstzrange, :daterange, :int8range].each do |v|
              @schema_type_classes[v] = PGRange
            end

            procs = conversion_procs
            add_conversion_proc(3908, Parser.new("tsrange", procs[1114]))
            add_conversion_proc(3910, Parser.new("tstzrange", procs[1184]))
            if respond_to?(:register_array_type) && defined?(PGArray::Creator)
              add_conversion_proc(3909, PGArray::Creator.new("tsrange", procs[3908]))
              add_conversion_proc(3911, PGArray::Creator.new("tstzrange", procs[3910]))
            end
          end
        end

        # Handle Range and PGRange values in bound variables
        def bound_variable_arg(arg, conn)
          case arg
          when PGRange 
            arg.unquoted_literal(schema_utility_dataset)
          when Range
            PGRange.from_range(arg).unquoted_literal(schema_utility_dataset)
          else
            super
          end
        end

        # Freeze the pg range schema types to prevent adding new ones.
        def freeze
          @pg_range_schema_types.freeze
          super
        end

        # Register a database specific range type.  This can be used to support
        # different range types per Database.  Options:
        #
        # :converter :: A callable object (e.g. Proc), that is called with the start or end of the range
        #               (usually a string), and should return the appropriate typecasted object.
        # :oid :: The PostgreSQL OID for the range type.  This is used by the Sequel postgres adapter
        #         to set up automatic type conversion on retrieval from the database.
        # :subtype_oid :: Should be the PostgreSQL OID for the range's subtype. If given,
        #                 automatically sets the :converter option by looking for scalar conversion
        #                 proc.
        #
        # If a block is given, it is treated as the :converter option.
        def register_range_type(db_type, opts=OPTS, &block)
          oid = opts[:oid]
          soid = opts[:subtype_oid]

          if has_converter = opts.has_key?(:converter)
            raise Error, "can't provide both a block and :converter option to register_range_type" if block
            converter = opts[:converter]
          else
            has_converter = true if block
            converter = block
          end

          unless (soid || has_converter) && oid
            range_oid, subtype_oid = from(:pg_range).join(:pg_type, :oid=>:rngtypid).where(:typname=>db_type.to_s).get([:rngtypid, :rngsubtype])
            soid ||= subtype_oid unless has_converter
            oid ||= range_oid
          end

          db_type = db_type.to_s.dup.freeze

          if soid
            raise Error, "can't provide both a converter and :subtype_oid option to register" if has_converter 
            raise Error, "no conversion proc for :subtype_oid=>#{soid.inspect} in conversion_procs" unless converter = conversion_procs[soid]
          end

          parser = Parser.new(db_type, converter)
          add_conversion_proc(oid, parser)

          @pg_range_schema_types[db_type] = db_type.to_sym

          singleton_class.class_eval do
            meth = :"typecast_value_#{db_type}"
            define_method(meth){|v| typecast_value_pg_range(v, parser)}
            private meth
          end

          @schema_type_classes[:"#{opts[:type_symbol] || db_type}"] = PGRange
          nil
        end

        private

        # Recognize the registered database range types.
        def schema_range_type(db_type)
          @pg_range_schema_types[db_type] || super
        end

        # Set the :ruby_default value if the default value is recognized as a range.
        def schema_post_process(_)
          super.each do |a|
            h = a[1]
            db_type = h[:db_type]
            if @pg_range_schema_types[db_type] && h[:default] =~ /\A'([^']+)'::#{db_type}\z/
              default = $1
              if convertor = conversion_procs[h[:oid]]
                h[:ruby_default] = convertor.call(default)
              end
            end
          end
        end

        # Typecast value correctly to a PGRange.  If already an
        # PGRange instance with the same db_type, return as is.
        # If a PGRange with a different subtype, return a new
        # PGRange with the same values and the expected subtype.
        # If a Range object, create a PGRange with the given
        # db_type.  If a string, assume it is in PostgreSQL
        # output format and parse it using the parser.
        def typecast_value_pg_range(value, parser)
          case value
          when PGRange
            if value.db_type.to_s == parser.db_type
              value
            elsif value.empty?
              PGRange.empty(parser.db_type)
            else
              PGRange.new(value.begin, value.end, :exclude_begin=>value.exclude_begin?, :exclude_end=>value.exclude_end?, :db_type=>parser.db_type)
            end
          when Range
            PGRange.from_range(value, parser.db_type)
          when String
            parser.call(typecast_check_string_length(value, 100))
          else
            raise Sequel::InvalidValue, "invalid value for range type: #{value.inspect}"
          end
        end
      end

      module DatasetMethods
        private

        # Handle literalization of ruby Range objects, treating them as
        # PostgreSQL ranges.
        def literal_other_append(sql, v)
          case v
          when Range
            super(sql, Sequel::Postgres::PGRange.from_range(v))
          else
            super
          end
        end
      end

      include Enumerable

      # The beginning of the range.  If nil, the range has an unbounded beginning.
      attr_reader :begin

      # The end of the range.  If nil, the range has an unbounded ending.
      attr_reader :end

      # The PostgreSQL database type for the range (e.g. 'int4range').
      attr_reader :db_type

      # Create a new PGRange instance using the beginning and ending of the ruby Range,
      # with the given db_type.
      def self.from_range(range, db_type=nil)
        new(range.begin, range.end, :exclude_end=>range.exclude_end?, :db_type=>db_type)
      end

      # Create an empty PGRange with the given database type.
      def self.empty(db_type=nil)
        new(nil, nil, :empty=>true, :db_type=>db_type)
      end

      # Initialize a new PGRange instance.  Accepts the following options:
      #
      # :db_type :: The PostgreSQL database type for the range.
      # :empty :: Whether the range is empty (has no points)
      # :exclude_begin :: Whether the beginning element is excluded from the range.
      # :exclude_end :: Whether the ending element is excluded from the range.
      def initialize(beg, en, opts=OPTS)
        @begin = beg
        @end = en
        @empty = !!opts[:empty]
        @exclude_begin = !!opts[:exclude_begin]
        @exclude_end = !!opts[:exclude_end]
        @db_type = opts[:db_type]
        if @empty
          raise(Error, 'cannot have an empty range with either a beginning or ending') unless @begin.nil? && @end.nil? && opts[:exclude_begin].nil? && opts[:exclude_end].nil?
        end
      end

      # Delegate to the ruby range object so that the object mostly acts like a range.
      range_methods = %w'each last first step'
      range_methods.each do |m|
        class_eval("def #{m}(*a, &block) to_range.#{m}(*a, &block) end", __FILE__, __LINE__)
      end

      # Return whether the value is inside the range.
      def cover?(value)
        return false if empty?
        b = self.begin
        return false if b && b.public_send(exclude_begin? ? :>= : :>, value)
        e = self.end
        return false if e && e.public_send(exclude_end? ? :<= : :<, value)
        true
      end

      # Consider the receiver equal to other PGRange instances with the
      # same beginning, ending, exclusions, and database type.  Also consider
      # it equal to Range instances if this PGRange can be converted to a
      # a Range and those ranges are equal.
      def eql?(other)
        case other
        when PGRange
          if db_type == other.db_type
            if empty?
              other.empty?
            elsif other.empty?
              false
            else
              [:@begin, :@end, :@exclude_begin, :@exclude_end].all?{|v| instance_variable_get(v) == other.instance_variable_get(v)}
            end
          else
            false
          end
        when Range
          if valid_ruby_range?
            to_range.eql?(other)
          else
            false
          end
        else
          false
        end
      end
      alias == eql?

      # Make sure equal ranges have the same hash.
      def hash
        if @empty
          @db_type.hash
        else
          [@begin, @end, @exclude_begin, @exclude_end, @db_type].hash
        end
      end

      # Allow PGRange values in case statements, where they return true if they
      # are equal to each other using eql?, or if this PGRange can be converted
      # to a Range, delegating to that range.
      def ===(other)
        if eql?(other)
          true
        else
          if valid_ruby_range?
            to_range === other 
          else
            false
          end
        end
      end

      # Whether this range is empty (has no points).  Note that for manually created ranges
      # (ones not retrieved from the database), this will only be true if the range
      # was created using the :empty option.
      def empty?
        @empty
      end

      # Whether the beginning element is excluded from the range.
      def exclude_begin?
        @exclude_begin
      end

      # Whether the ending element is excluded from the range.
      def exclude_end?
        @exclude_end
      end

      # Support a friendly output
      def inspect
        range = if empty?
          "empty"
        else
          "#{@exclude_begin ? "(" : "["}#{@begin},#{@end}#{@exclude_end ? ")" : "]"}"
        end

        "#<#{self.class.name} #{range}#{"::#{@db_type}" if @db_type}>"
      end
      alias to_s inspect

      # Append a literalize version of the receiver to the sql.
      def sql_literal_append(ds, sql)
        if (s = @db_type) && !empty?
          sql << s.to_s << "("
          ds.literal_append(sql, self.begin)
          sql << ','
          ds.literal_append(sql, self.end)
          sql << ','
          ds.literal_append(sql, "#{exclude_begin? ? "(" : "["}#{exclude_end? ? ")" : "]"}")
          sql << ")"
        else
          ds.literal_append(sql, unquoted_literal(ds))
          if s
            sql << '::' << s.to_s
          end
        end
      end

      ENDLESS_RANGE_NOT_SUPPORTED = RUBY_VERSION < '2.6'
      STARTLESS_RANGE_NOT_SUPPORTED = RUBY_VERSION < '2.7'

      # Return a ruby Range object for this instance, if one can be created.
      def to_range
        return @range if @range
        raise(Error, "cannot create ruby range for an empty PostgreSQL range") if empty?
        raise(Error, "cannot create ruby range when PostgreSQL range excludes beginning element") if exclude_begin?
        # simplecov:disable
        raise(Error, "cannot create ruby range when PostgreSQL range has unbounded beginning") if STARTLESS_RANGE_NOT_SUPPORTED && !self.begin
        raise(Error, "cannot create ruby range when PostgreSQL range has unbounded ending") if ENDLESS_RANGE_NOT_SUPPORTED && !self.end
        # simplecov:enable
        @range = Range.new(self.begin, self.end, exclude_end?)
      end

      # Whether or not this PGRange is a valid ruby range.  In order to be a valid ruby range,
      # it must have a beginning and an ending (no unbounded ranges), and it cannot exclude
      # the beginning element.
      def valid_ruby_range?
        !(empty? || exclude_begin? || (STARTLESS_RANGE_NOT_SUPPORTED && !self.begin) || (ENDLESS_RANGE_NOT_SUPPORTED && !self.end))
      end

      # Whether the beginning of the range is unbounded.
      def unbounded_begin?
        self.begin.nil? && !empty?
      end

      # Whether the end of the range is unbounded.
      def unbounded_end?
        self.end.nil? && !empty?
      end

      # Return a string containing the unescaped version of the range.
      # Separated out for use by the bound argument code.
      def unquoted_literal(ds)
        if empty?
          'empty'
        else
          "#{exclude_begin? ? "(" : "["}#{escape_value(self.begin, ds)},#{escape_value(self.end, ds)}#{exclude_end? ? ")" : "]"}"
        end
      end

      # Allow automatic parameterization for ranges with types, if both start .
      def sequel_auto_param_type(ds)
        "::#{db_type}" if db_type && (!@begin || ds.send(:auto_param_type, @begin)) && (!@end || ds.send(:auto_param_type, @end))
      end

      # Database range types with discrete subtypes.  Set operations on
      # ranges of these types use discrete semantics, where one range's end
      # and another range's start are adjacent if they are successors.
      DISCRETE_DB_TYPES = %w'int4range int8range daterange'.freeze

      # Database range types with continuous subtypes.  Set operations on
      # ranges of these types use continuous semantics.
      CONTINUOUS_DB_TYPES = %w'numrange tsrange tstzrange'.freeze

      # Return a PGMultiRange containing the union of this range and the
      # given range, multirange, or array of ranges.  The result is
      # normalized, with ranges sorted, non-overlapping, and not mergeable.
      def union(other)
        left, right, db_type, discrete = PGRange.set_operation_context(self, other)
        PGRange.multirange_result(PGRange.normalize_ranges(left + right, db_type, discrete), db_type)
      end
      alias | union
      alias + union

      # Return the intersection of this range and the given range,
      # multirange, or array of ranges.  Returns a PGRange (possibly empty)
      # if the other operand is a single range, and a PGMultiRange otherwise.
      def intersection(other)
        left, right, db_type, discrete = PGRange.set_operation_context(self, other)
        ranges = PGRange.intersect_ranges(left, right, db_type, discrete)
        if other.is_a?(PGMultiRange) || other.is_a?(Array)
          PGRange.multirange_result(ranges, db_type)
        else
          ranges.empty? ? PGRange.empty(db_type) : ranges.first
        end
      end
      alias & intersection

      # Return a PGMultiRange containing the parts of this range that are
      # not covered by the given range, multirange, or array of ranges.
      # The result is normalized, with ranges sorted, non-overlapping, and
      # not mergeable.
      def difference(other)
        left, right, db_type, discrete = PGRange.set_operation_context(self, other)
        PGRange.multirange_result(PGRange.subtract_ranges(left, right, db_type, discrete), db_type)
      end
      alias - difference

      # Return a PGMultiRange containing the parts of the given bounding
      # range (or multirange) that are not covered by this range.  If no
      # bounding range is given, an unbounded range is used, so the result
      # contains all points not covered by this range.
      def complement(frame=nil)
        frame ||= PGRange.new(nil, nil)
        left, right, db_type, discrete = PGRange.set_operation_context(frame, self)
        PGRange.multirange_result(PGRange.subtract_ranges(left, right, db_type, discrete), db_type)
      end

      # Normalize an array of PGRanges, returning a new array of PGRanges
      # that is sorted, with empty ranges removed, and overlapping or
      # adjacent ranges merged.  If a database range type is given, the
      # returned ranges use that type, and it is used to determine whether
      # the ranges use discrete or continuous semantics.  If the discrete
      # flag is not given, it is inferred from the database type or the
      # range bounds.
      def self.normalize_ranges(ranges, db_type=nil, discrete=nil)
        discrete = resolve_discrete(db_type, ranges) if discrete.nil?
        kept = ranges.reject{|range| empty_range?(range, discrete)}
        return [] if kept.empty?
        sorted = sort_ranges(kept)
        result = [sorted.first]
        sorted[1..-1].each do |range|
          last = result[-1]
          if mergeable_ranges?(last, range, discrete)
            result[-1] = merge_ranges(last, range)
          else
            result << range
          end
        end
        if db_type
          db_type = db_type.to_s
          result = result.map do |range|
            if range.db_type == db_type
              range
            else
              new(range.begin, range.end, :exclude_begin=>range.exclude_begin?, :exclude_end=>range.exclude_end?, :db_type=>db_type)
            end
          end
        end
        result
      end

      # Return an array of PGRanges covering the parts of the ranges in
      # a_ranges that are also covered by the ranges in b_ranges.  Both
      # arrays are normalized before intersecting, and the result is
      # sorted and non-overlapping.
      def self.intersect_ranges(a_ranges, b_ranges, db_type=nil, discrete=nil)
        discrete = resolve_discrete(db_type, a_ranges + b_ranges) if discrete.nil?
        a_ranges = normalize_ranges(a_ranges, db_type, discrete)
        b_ranges = normalize_ranges(b_ranges, db_type, discrete)
        ranges = []
        a_ranges.each do |a|
          b_ranges.each do |b|
            range = intersect_pair(a, b)
            ranges << range unless empty_range?(range, discrete)
          end
        end
        ranges
      end

      # Return an array of PGRanges covering the parts of the ranges in
      # a_ranges that are not covered by the ranges in b_ranges.  Both
      # arrays are normalized before subtracting, and the result is
      # sorted and non-overlapping.
      def self.subtract_ranges(a_ranges, b_ranges, db_type=nil, discrete=nil)
        discrete = resolve_discrete(db_type, a_ranges + b_ranges) if discrete.nil?
        a_ranges = normalize_ranges(a_ranges, db_type, discrete)
        b_ranges = normalize_ranges(b_ranges, db_type, discrete)
        a_ranges.flat_map do |a|
          pieces = [a]
          b_ranges.each do |b|
            pieces = pieces.flat_map{|piece| subtract_pair(piece, b, discrete)}
            break if pieces.empty?
          end
          pieces
        end
      end

      # Prepare two operands for a set operation, returning an array with
      # the left ranges, the right ranges, the shared database range type
      # (nil if untyped), and whether the ranges use discrete semantics.
      # Operands can be PGRanges, PGMultiRanges, ruby Ranges, or arrays of
      # ranges.  Raises Sequel::InvalidValue if the operands use
      # incompatible database types or bounds.
      def self.set_operation_context(left, right)
        types = []
        left = set_operation_ranges(left, types)
        right = set_operation_ranges(right, types)
        db_type = set_operation_db_type(types)
        discrete = resolve_discrete(db_type, left + right)
        [left, right, db_type, discrete]
      end

      # Return a PGMultiRange for the given normalized ranges, mapping the
      # given database range type to the related multirange type.
      def self.multirange_result(ranges, db_type)
        PGMultiRange.new(ranges, multirange_type(db_type))
      end

      # Compare two range bound values, raising Sequel::InvalidValue if
      # the values cannot be ordered.
      def self.compare_bounds(a, b)
        begin
          result = a <=> b
        rescue NoMethodError
          result = nil
        end
        unless result
          raise InvalidValue, "cannot order range bounds #{a.inspect} and #{b.inspect}"
        end
        result
      end

      # Whether the given range is empty, treating ranges such as (1,2)
      # for discrete types as empty even if they were not created with the
      # :empty option.
      def self.empty_range?(range, discrete)
        return true if range.empty?
        beg = range.begin
        en = range.end
        return false if beg.nil? || en.nil?
        if discrete
          beg = beg.succ if range.exclude_begin?
          en = en.succ unless range.exclude_end?
          compare_bounds(beg, en) >= 0
        else
          cmp = compare_bounds(beg, en)
          cmp > 0 || (cmp == 0 && (range.exclude_begin? || range.exclude_end?))
        end
      end

      # Whether two sorted ranges (a starting no later than b) overlap or
      # are adjacent, so that they can be merged into a single range.
      def self.mergeable_ranges?(a, b, discrete)
        return true if a.end.nil? || b.begin.nil?
        cmp = compare_bounds(a.end, b.begin)
        return true if cmp > 0
        if cmp.zero?
          # Mergeable if at least one of the ranges includes the shared
          # endpoint.  If both exclude it, the endpoint itself is a gap.
          return !(a.exclude_end? && b.exclude_begin?)
        end
        if discrete
          a_reach = a.exclude_end? ? a.end : a.end.succ
          b_start = b.exclude_begin? ? b.begin.succ : b.begin
          compare_bounds(a_reach, b_start) >= 0
        else
          false
        end
      end

      # The base range type for the given range or multirange database
      # type (e.g. 'int4range' for 'int4multirange').
      def self.base_range_type(db_type)
        if db_type
          db_type.to_s.sub('multi', '')
        end
      end

      # The multirange database type for the given database range type
      # (e.g. 'int4multirange' for 'int4range'), or nil if the type does
      # not follow the standard naming convention.
      def self.multirange_type(db_type)
        if db_type
          db_type = db_type.to_s
          if db_type.end_with?('range')
            db_type.sub(/range\z/, 'multirange')
          end
        end
      end

      # Whether the value uses discrete semantics as a range bound.
      # Integers and dates are discrete; other types (including
      # DateTime) are continuous.
      def self.discrete_bound?(value)
        case value
        when Integer
          true
        when DateTime
          false
        when Date
          true
        else
          false
        end
      end

      # Whether ranges with the given database type and bounds use
      # discrete semantics.  Returns nil if it cannot be determined.
      # Raises Sequel::InvalidValue when mixing discrete and continuous
      # bounds.
      def self.discrete_ranges?(db_type, ranges)
        if db_type
          db_type = base_range_type(db_type)
          return true if DISCRETE_DB_TYPES.include?(db_type)
          return false if CONTINUOUS_DB_TYPES.include?(db_type)
        end
        discrete = nil
        ranges.each do |range|
          [range.begin, range.end].each do |value|
            next if value.nil?
            d = discrete_bound?(value)
            if discrete.nil?
              discrete = d
            elsif discrete != d
              raise InvalidValue, "cannot mix discrete and continuous bounds in a range set operation"
            end
          end
        end
        discrete
      end

      # Whether ranges with the given database type and bounds use
      # discrete semantics, defaulting to false when it cannot be
      # determined.  Raises Sequel::InvalidValue if the ranges are
      # discrete but have bounds that do not support a successor.
      def self.resolve_discrete(db_type, ranges)
        discrete = discrete_ranges?(db_type, ranges)
        discrete = false if discrete.nil?
        if discrete
          ranges.each do |range|
            [range.begin, range.end].each do |value|
              if !value.nil? && !value.respond_to?(:succ)
                raise InvalidValue, "discrete range bound does not support succ: #{value.inspect}"
              end
            end
          end
        end
        discrete
      end

      # Sort the ranges by their beginnings, with unbounded beginnings
      # first, and inclusive beginnings before exclusive ones.
      def self.sort_ranges(ranges)
        ranges.sort do |a, b|
          ab = a.begin
          bb = b.begin
          if ab.nil?
            bb.nil? ? (a.exclude_begin? ? 1 : 0) <=> (b.exclude_begin? ? 1 : 0) : -1
          elsif bb.nil?
            1
          else
            cmp = compare_bounds(ab, bb)
            cmp.zero? ? (a.exclude_begin? ? 1 : 0) <=> (b.exclude_begin? ? 1 : 0) : cmp
          end
        end
      end

      # Merge two overlapping or adjacent ranges into a new PGRange.
      def self.merge_ranges(a, b)
        if a.end.nil? || b.end.nil?
          en = nil
          en_ex = false
        else
          cmp = compare_bounds(a.end, b.end)
          if cmp > 0
            en = a.end
            en_ex = a.exclude_end?
          elsif cmp < 0
            en = b.end
            en_ex = b.exclude_end?
          else
            en = a.end
            en_ex = a.exclude_end? && b.exclude_end?
          end
        end
        new(a.begin, en, :exclude_begin=>a.begin.nil? ? false : a.exclude_begin?, :exclude_end=>en_ex, :db_type=>a.db_type || b.db_type)
      end

      # Return a new PGRange covering the intersection of two ranges.
      # The result may be empty; use empty_range? to check.
      def self.intersect_pair(a, b)
        if a.begin.nil?
          lo = b.begin
          lo_ex = b.exclude_begin?
        elsif b.begin.nil?
          lo = a.begin
          lo_ex = a.exclude_begin?
        else
          cmp = compare_bounds(a.begin, b.begin)
          if cmp < 0
            lo = b.begin
            lo_ex = b.exclude_begin?
          elsif cmp > 0
            lo = a.begin
            lo_ex = a.exclude_begin?
          else
            lo = a.begin
            lo_ex = a.exclude_begin? || b.exclude_begin?
          end
        end
        if a.end.nil?
          hi = b.end
          hi_ex = b.exclude_end?
        elsif b.end.nil?
          hi = a.end
          hi_ex = a.exclude_end?
        else
          cmp = compare_bounds(a.end, b.end)
          if cmp < 0
            hi = a.end
            hi_ex = a.exclude_end?
          elsif cmp > 0
            hi = b.end
            hi_ex = b.exclude_end?
          else
            hi = a.end
            hi_ex = a.exclude_end? || b.exclude_end?
          end
        end
        lo_ex = false if lo.nil?
        hi_ex = false if hi.nil?
        new(lo, hi, :exclude_begin=>lo_ex, :exclude_end=>hi_ex, :db_type=>a.db_type || b.db_type)
      end

      # Return an array of PGRanges covering the parts of range a that
      # are not covered by range b.
      def self.subtract_pair(a, b, discrete)
        return [a] if empty_range?(b, discrete)
        return [a] if empty_range?(intersect_pair(a, b), discrete)
        db_type = a.db_type || b.db_type
        pieces = []
        unless b.begin.nil?
          left = new(a.begin, b.begin, :exclude_begin=>a.begin.nil? ? false : a.exclude_begin?, :exclude_end=>!b.exclude_begin?, :db_type=>db_type)
          pieces << left unless empty_range?(left, discrete)
        end
        unless b.end.nil?
          right = new(b.end, a.end, :exclude_begin=>!b.exclude_end?, :exclude_end=>a.end.nil? ? false : a.exclude_end?, :db_type=>db_type)
          pieces << right unless empty_range?(right, discrete)
        end
        pieces
      end

      # Convert a set operation operand into an array of PGRanges,
      # adding the operand's database type to the types array.
      def self.set_operation_ranges(operand, types)
        case operand
        when PGRange
          types << operand.db_type
          [operand]
        when PGMultiRange
          types << operand.db_type
          operand.map{|range| set_operation_range(range)}
        when Range
          [from_range(operand)]
        when Array
          operand.map{|range| set_operation_range(range)}
        else
          raise InvalidValue, "cannot perform range set operation with #{operand.inspect}"
        end
      end

      # Convert the object to a PGRange for use in a set operation.
      def self.set_operation_range(obj)
        case obj
        when PGRange
          obj
        when Range
          from_range(obj)
        else
          raise InvalidValue, "cannot perform range set operation with #{obj.inspect}"
        end
      end

      # Given the database types of the operands of a set operation,
      # return the shared base range type, or nil if all operands are
      # untyped.  Raises Sequel::InvalidValue if the operands use
      # incompatible database types.
      def self.set_operation_db_type(types)
        types = types.map{|t| base_range_type(t)}.compact.reject{|t| t.empty?}.uniq
        if types.length > 1
          raise InvalidValue, "cannot perform range set operation on ranges with different database types: #{types.join(', ')}"
        end
        types.first
      end

      private

      # Escape common range types.  Instead of quoting, just backslash escape all
      # special characters.
      def escape_value(k, ds)
        case k
        when nil
          ''
        when Time, Date
          ds.literal_date_or_time(k, true)
        when Integer, Float
          k.to_s
        when BigDecimal
          k.to_s('F')
        when LiteralString
          k
        when String
          if k.empty?
            '""'
          else
            k.gsub(/("|,|\\|\[|\]|\(|\))/, '\\\\\1')
          end
        else
          ds.literal(k).gsub(/("|,|\\|\[|\]|\(|\))/, '\\\\\1')
        end
      end
    end
  end

  module SQL::Builders
    # Convert the object to a Postgres::PGRange.
    def pg_range(v, db_type=nil)
      case v
      when Postgres::PGRange
        if db_type.nil? || v.db_type == db_type
          v
        else
          Postgres::PGRange.new(v.begin, v.end, :exclude_begin=>v.exclude_begin?, :exclude_end=>v.exclude_end?, :db_type=>db_type)
        end
      when Range
        Postgres::PGRange.from_range(v, db_type)
      else
        # May not be defined unless the pg_range_ops extension is used
        pg_range_op(v)
      end
    end
  end

  Database.register_extension(:pg_range, Postgres::PGRange::DatabaseMethods)
end

# simplecov:disable
if Sequel.core_extensions?
  class Range 
    # Create a new PGRange using the receiver as the input range,
    # with the given database type.
    def pg_range(db_type=nil)
      Sequel::Postgres::PGRange.from_range(self, db_type)
    end
  end
end

if defined?(Sequel::CoreRefinements)
  module Sequel::CoreRefinements
    refine Range do
      def pg_range(db_type=nil)
        Sequel::Postgres::PGRange.from_range(self, db_type)
      end
    end
  end
end
# simplecov:enable
