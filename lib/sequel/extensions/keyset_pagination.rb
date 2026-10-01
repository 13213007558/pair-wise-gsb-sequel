# frozen-string-literal: true
#
# The keyset_pagination extension adds the Sequel::Dataset#keyset_paginate
# method, which implements keyset (cursor based) pagination as an
# alternative to offset/limit pagination.  Instead of page numbers, the
# client is given opaque +after+/+before+ cursors that encode the typed
# sort values of the rows at the page boundaries, and passes a cursor back
# to retrieve the next or previous page:
#
#   ds = DB[:items].
#     order(Sequel.desc(:priority, nulls: :last),
#           Sequel.asc(:created_at, nulls: :last),
#           Sequel.asc(:id, nulls: :last)).
#     extension(:keyset_pagination)
#
#   page = ds.keyset_paginate(25)
#   rows = page.all
#   page.keyset_after_cursor  # cursor for the next page (nil if none)
#   page.keyset_before_cursor # cursor for the previous page (nil if none)
#
#   next_page = ds.keyset_paginate(25, after: page.keyset_after_cursor)
#   prev_page = ds.keyset_paginate(25, before: next_page.keyset_before_cursor)
#
# Previous pages are returned in the original list order (the dataset
# transparently reverses the ordering and reverses the results back).
#
# Because the cursor stores the position in the sort order instead of an
# offset, records inserted or deleted at page boundaries between requests
# do not cause rows to be skipped or returned twice, and no total record
# count query is issued (an extra record is retrieved to detect whether
# another page exists).
#
# Requirements for the dataset being paginated:
#
# * It must be ordered, and every ORDER BY entry must use
#   Sequel.asc/Sequel.desc with an explicit :nulls (:first/:last) option,
#   so the position of NULL values in the sort order is unambiguous.
# * Every ORDER BY entry must be a simple column reference.
# * The final ORDER BY entry must be a stable unique key (such as the
#   table's primary key), so the sort order is total and deterministic.
#   When the primary key can be determined from the dataset, this is
#   verified and a Sequel::KeysetPaginationError is raised if the final
#   sort column is not the primary key.
#
# Cursors are bound to the dataset's ORDER BY definition.  A cursor that
# is malformed or was created for a different ordering raises
# Sequel::KeysetPaginationError instead of silently returning wrong rows.
#
# You can load this extension into specific datasets:
#
#   ds = DB[:table]
#   ds = ds.extension(:keyset_pagination)
#
# Or you can load it into all of a database's datasets, which
# is probably the desired behavior if you are using this extension:
#
#   DB.extension(:keyset_pagination)
#
# Related modules: Sequel::DatasetKeysetPagination, Sequel::Dataset::KeysetPagination

require 'json'
require 'time'
require 'bigdecimal'

module Sequel
  # Error raised when a keyset pagination cursor is invalid, does not match
  # the dataset's ordering, or the dataset cannot be keyset paginated.
  class KeysetPaginationError < Error; end

  module DatasetKeysetPagination
    # Return a keyset paginated dataset, limited to +page_size+ records per
    # page.  Pass an +after+ cursor to retrieve the page following the
    # cursor position, or a +before+ cursor to retrieve the page preceding
    # it (returned in the original list order).  Without a cursor, returns
    # the first page.  Cursors are obtained from a previously paginated
    # dataset via #keyset_after_cursor/#keyset_before_cursor.
    def keyset_paginate(page_size, after: nil, before: nil)
      unless page_size.is_a?(Integer) && page_size > 0
        raise KeysetPaginationError, "keyset pagination page size must be a positive Integer, got: #{page_size.inspect}"
      end
      if @opts[:limit] || @opts[:offset]
        raise KeysetPaginationError, "cannot keyset paginate a dataset that already has a limit or offset"
      end
      if after && before
        raise KeysetPaginationError, "cannot keyset paginate with both :after and :before cursors"
      end

      spec = keyset_pagination_order_spec
      keyset_pagination_check_unique_key(spec)

      ds = self
      direction = nil
      if after
        ds = ds.where(keyset_pagination_condition(spec, keyset_pagination_decode_cursor(after, spec)))
        direction = :after
      elsif before
        values = keyset_pagination_decode_cursor(before, spec)
        reverse_spec = spec.map(&:invert)
        ds = ds.where(keyset_pagination_condition(reverse_spec, values)).order(*reverse_spec)
        direction = :before
      end

      ds.limit(page_size + 1).
        with_extend(Dataset::KeysetPagination).
        clone(:keyset_page_size=>page_size, :keyset_direction=>direction, :keyset_order=>spec, :keyset_state=>{})
    end

    private

    # The dataset's ORDER BY entries as an array of
    # Sequel::SQL::OrderedExpression, validating that the ordering is
    # suitable for keyset pagination.
    def keyset_pagination_order_spec
      order = @opts[:order]
      if !order || order.empty?
        raise KeysetPaginationError, "keyset pagination requires the dataset to have an ORDER BY clause"
      end
      order.map do |o|
        unless o.is_a?(SQL::OrderedExpression)
          raise KeysetPaginationError, "keyset pagination requires every ORDER BY entry to use Sequel.asc/Sequel.desc with an explicit :nulls option, got: #{o.inspect}"
        end
        unless o.nulls
          raise KeysetPaginationError, "keyset pagination requires an explicit NULLS FIRST or NULLS LAST for every ORDER BY entry (use the :nulls option), missing for: #{o.expression.inspect}"
        end
        keyset_pagination_column(o.expression)
        o
      end.freeze
    end

    # The result row key for a simple ORDER BY column expression.
    def keyset_pagination_column(expression)
      case expression
      when Symbol
        parts = expression.to_s.split('__')
        case parts.length
        when 1 then expression
        when 2 then parts[1].to_sym
        else
          raise KeysetPaginationError, "keyset pagination only supports simple column references in ORDER BY, got: #{expression.inspect}"
        end
      when SQL::Identifier
        expression.value
      when SQL::QualifiedIdentifier
        expression.column
      else
        raise KeysetPaginationError, "keyset pagination only supports simple column references in ORDER BY, got: #{expression.inspect}"
      end
    end

    # Verify that the final sort key is the table's primary key, when the
    # primary key can be determined for a simple single-table dataset.
    def keyset_pagination_check_unique_key(spec)
      from = @opts[:from]
      return unless from && from.length == 1 && from.first.is_a?(Symbol)

      schema = begin
        db.schema(from.first)
      rescue StandardError
        return
      end
      pk_columns = schema.select{|_, info| info[:primary_key]}.map{|name, _| name}
      return if pk_columns.empty?

      last_column = keyset_pagination_column(spec.last.expression)
      unless pk_columns.length == 1 && pk_columns.first == last_column
        raise KeysetPaginationError, "keyset pagination requires the final ORDER BY column to be a stable unique key (the primary key #{pk_columns.map(&:inspect).join(', ')} for #{from.first}), got: #{last_column.inspect}"
      end
    end

    # The condition matching rows strictly after the given sort values in
    # the ordering defined by +spec+ (an array of OrderedExpression).
    def keyset_pagination_condition(spec, values)
      terms = []
      spec.each_with_index do |o, i|
        next unless (term = keyset_pagination_term(o, values[i]))
        if i == 0
          terms << term
        else
          prefix = spec[0...i].each_with_index.map{|po, j| {po.expression => values[j]}}
          terms << Sequel.&(*prefix, term)
        end
      end
      # No rows sort after the cursor position (e.g. a cursor on the final
      # row where all values are NULL with NULLS LAST).
      return SQL::Constants::SQLFALSE if terms.empty?
      Sequel.|(*terms)
    end

    # The condition matching rows strictly after +value+ for a single
    # ORDER BY entry, or nil if no rows can sort after the value.
    def keyset_pagination_term(o, value)
      expression = o.expression
      if value.nil?
        # With NULLS FIRST, every non-NULL value sorts after NULL.
        # With NULLS LAST, nothing sorts after NULL.
        o.nulls == :first ? Sequel.~(expression=>nil) : nil
      else
        condition = SQL::BooleanExpression.new(o.descending ? :< : :>, expression, value)
        # With NULLS LAST, NULL values sort after every non-NULL value.
        condition = Sequel.|(condition, expression=>nil) if o.nulls == :last
        condition
      end
    end

    # Decode and validate a cursor string against the dataset's ordering,
    # returning the array of typed sort values it holds.
    def keyset_pagination_decode_cursor(cursor, spec)
      payload = begin
        JSON.parse(keyset_pagination_base64_decode(cursor.to_s))
      rescue StandardError => e
        raise KeysetPaginationError, "invalid keyset pagination cursor: #{e.message}"
      end
      unless payload.is_a?(Hash) && payload['v'] == 1 && payload['order'].is_a?(Array) && payload['values'].is_a?(Array)
        raise KeysetPaginationError, "invalid keyset pagination cursor format"
      end

      expected_order = spec.map{|o| [keyset_pagination_column(o.expression).to_s, o.descending ? 'desc' : 'asc', o.nulls.to_s]}
      unless payload['order'] == expected_order
        raise KeysetPaginationError, "keyset pagination cursor ordering #{payload['order'].inspect} does not match the dataset ordering #{expected_order.inspect}"
      end
      unless payload['values'].length == spec.length
        raise KeysetPaginationError, "keyset pagination cursor holds #{payload['values'].length} sort values, expected #{spec.length}"
      end

      payload['values'].map{|typed_value| keyset_pagination_decode_value(typed_value)}
    end

    # Encode the sort values of a row as an opaque cursor string bound to
    # the dataset's ordering.
    def keyset_pagination_encode_cursor(values)
      order = @opts[:keyset_order].map do |o|
        [keyset_pagination_column(o.expression).to_s, o.descending ? 'desc' : 'asc', o.nulls.to_s]
      end
      keyset_pagination_base64_encode(JSON.generate('v'=>1, 'order'=>order, 'values'=>values.map{|v| keyset_pagination_encode_value(v)}))
    end

    # URL-safe base64 encoding without padding (implemented via
    # Array#pack to avoid a dependency on the base64 library).
    def keyset_pagination_base64_encode(string)
      [string].pack('m0').tr('+/', '-_').sub(/=+\z/, '')
    end

    def keyset_pagination_base64_decode(string)
      string = string.tr('-_', '+/')
      "#{string}#{'=' * ((4 - string.length % 4) % 4)}".unpack1('m0')
    end

    def keyset_pagination_encode_value(value)
      case value
      when nil then ['null', nil]
      when Integer then ['i', value]
      when Float then ['f', value]
      when String then ['s', value]
      when true, false then ['b', value]
      when Time then ['t', value.iso8601(9)]
      when DateTime then ['dt', value.iso8601(9)]
      when Date then ['d', value.iso8601]
      when BigDecimal then ['bd', value.to_s('F')]
      else
        raise KeysetPaginationError, "keyset pagination cannot serialize #{value.class} values in cursors"
      end
    end

    def keyset_pagination_decode_value(typed_value)
      unless typed_value.is_a?(Array) && typed_value.length == 2 && typed_value[0].is_a?(String)
        raise KeysetPaginationError, "invalid typed value in keyset pagination cursor: #{typed_value.inspect}"
      end
      type, raw = typed_value
      begin
        case type
        when 'null'
          nil
        when 'i'
          raise TypeError unless raw.is_a?(Integer)
          raw
        when 'f'
          raise TypeError unless raw.is_a?(Numeric)
          raw.to_f
        when 's'
          raise TypeError unless raw.is_a?(String)
          raw
        when 'b'
          raise TypeError unless raw == true || raw == false
          raw
        when 't'
          raise TypeError unless raw.is_a?(String)
          Time.iso8601(raw)
        when 'dt'
          raise TypeError unless raw.is_a?(String)
          DateTime.iso8601(raw)
        when 'd'
          raise TypeError unless raw.is_a?(String)
          Date.iso8601(raw)
        when 'bd'
          raise TypeError unless raw.is_a?(String)
          BigDecimal(raw)
        else
          raise KeysetPaginationError, "unknown type #{type.inspect} in keyset pagination cursor"
        end
      rescue ArgumentError, TypeError
        raise KeysetPaginationError, "invalid typed value in keyset pagination cursor: #{typed_value.inspect}"
      end
    end
  end

  class Dataset
    # Holds methods that only relate to keyset paginated datasets.
    module KeysetPagination
      # The number of records per page.
      def keyset_page_size
        @opts[:keyset_page_size]
      end

      # The records of the current page, in the dataset's original list
      # order (also when paginating backwards).  Only available after the
      # page's records have been retrieved (e.g. via #all or #each).
      def keyset_records
        @opts[:keyset_state][:records] || raise(KeysetPaginationError, "keyset pagination cursors are only available after the page records have been retrieved")
      end

      # Whether another page exists after the current page.  Only accurate
      # after the page's records have been retrieved.
      def keyset_next_page?
        @opts[:keyset_direction] == :before || !!@opts[:keyset_state][:has_more]
      end

      # Whether another page exists before the current page.  Only
      # accurate after the page's records have been retrieved.
      def keyset_prev_page?
        case @opts[:keyset_direction]
        when :after then true
        when :before then !!@opts[:keyset_state][:has_more]
        else false
        end
      end

      # An opaque cursor for retrieving the page after the current page
      # (via keyset_paginate(:after)), or nil if there is no next page.
      def keyset_after_cursor
        keyset_pagination_row_cursor(keyset_records.last) if keyset_next_page? && keyset_records.any?
      end

      # An opaque cursor for retrieving the page before the current page
      # (via keyset_paginate(:before)), or nil if there is no previous
      # page.
      def keyset_before_cursor
        keyset_pagination_row_cursor(keyset_records.first) if keyset_prev_page? && keyset_records.any?
      end

      # Retrieve one extra record to detect whether another page exists,
      # trim the page to the page size, and reverse records back to the
      # original list order when paginating backwards.
      def fetch_rows(sql)
        records = []
        ret = super(sql){|row| records << row}
        state = @opts[:keyset_state]
        state[:has_more] = records.length > keyset_page_size
        records = records.first(keyset_page_size)
        records.reverse! if @opts[:keyset_direction] == :before
        state[:records] = records
        records.each{|row| yield row}
        ret
      end

      private

      # Build a cursor from the sort values of the given result row.
      def keyset_pagination_row_cursor(row)
        values = @opts[:keyset_order].map do |o|
          column = keyset_pagination_column(o.expression)
          unless row.key?(column)
            raise KeysetPaginationError, "keyset pagination requires the dataset to select the ORDER BY column #{column.inspect}, but it is missing from the result row"
          end
          row[column]
        end
        keyset_pagination_encode_cursor(values)
      end
    end
  end

  Dataset.register_extension(:keyset_pagination, DatasetKeysetPagination)
end
