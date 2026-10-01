# frozen-string-literal: true
#
# The keyset_pagination extension adds Dataset#keyset_paginate, which
# returns pages using key-set (seek) predicates instead of OFFSET.  Each
# cursor is an opaque, HMAC-signed string that stores typed values for the
# complete ORDER BY definition.  The final ordered expression must be a
# stable unique key, and every ordered expression must specify whether NULL
# values sort first or last.
#
# Example:
#
#   DB.extension(:keyset_pagination)
#
#   ds = DB[:items].order(
#     Sequel.desc(:priority, :nulls=>:last),
#     Sequel.asc(:created_at, :nulls=>:last),
#     Sequel.asc(:id, :nulls=>:last)
#   )
#
#   page = ds.keyset_paginate(25, :cursor_secret=>secret)
#   page.records
#   page.after_cursor
#
#   next_page = ds.keyset_paginate(25, :after=>page.after_cursor, :cursor_secret=>secret)
#
# Unlike the pagination extension, this extension never executes a COUNT
# query.  It requests one additional row to determine whether another page
# exists in the requested direction.

require 'bigdecimal'
require 'date'
require 'json'
require 'openssl'

module Sequel
  module KeysetPagination
    # Represents one ordered page of records.
    class Page
      include Enumerable

      def initialize(records, page_size, direction, cursor_present, more_in_requested_direction, cursor_codec, orders) # :nodoc:
        @records = records.freeze
        @page_size = page_size
        @direction = direction
        @cursor_present = cursor_present
        @more_in_requested_direction = more_in_requested_direction
        @cursor_codec = cursor_codec
        @orders = orders.freeze
        freeze
      end

      # The records for the page, always in the dataset's original order.
      attr_reader :records

      # Iterate over the records in the page.
      def each(&block)
        records.each(&block)
      end

      # The requested maximum number of records for the page.
      def page_size
        @page_size
      end

      # Whether a page exists before the current page.
      def has_previous_page?
        if @direction == :before
          @more_in_requested_direction
        else
          @cursor_present
        end
      end
      alias prev_page? has_previous_page?

      # Whether a page exists after the current page.
      def has_next_page?
        if @direction == :after
          @more_in_requested_direction
        else
          @cursor_present
        end
      end
      alias next_page? has_next_page?

      # Cursor immediately before the first record on the page.
      def before_cursor
        return if records.empty?
        cursor_for(records.first)
      end

      # Cursor immediately after the last record on the page.
      def after_cursor
        return if records.empty?
        cursor_for(records.last)
      end

      # A hash suitable for sending to an API client.
      def to_h
        {
          :records=>records,
          :page_size=>page_size,
          :has_previous_page=>has_previous_page?,
          :has_next_page=>has_next_page?,
          :before_cursor=>before_cursor,
          :after_cursor=>after_cursor
        }
      end

      private

      def cursor_for(record)
        values = @orders.map do |order|
          @cursor_codec.typed_value(record[CursorCodec.row_key(order.expression)])
        end
        @cursor_codec.encode(values)
      end
    end

    # Encodes and validates keyset page cursors.
    class CursorCodec
      CURSOR_VERSION = 1
      NULL_TYPE = "null".freeze
      ENCODED_TYPES = {
        TrueClass=>"boolean".freeze,
        FalseClass=>"boolean".freeze,
        Integer=>"integer".freeze,
        Float=>"float".freeze,
        BigDecimal=>"decimal".freeze,
        String=>"string".freeze,
        DateTime=>"datetime".freeze,
        Date=>"date".freeze,
        Time=>"time".freeze
      }.freeze
      DECODED_TYPES = ENCODED_TYPES.invert.freeze

      def initialize(dataset, orders, unique_key, secret)
        raise(Error, "keyset pagination requires a non-empty :cursor_secret") unless secret.is_a?(String) && !secret.empty?

        @columns = orders.map do |order|
          {
            "e"=>dataset.literal(order.expression),
            "d"=>order.descending,
            "n"=>order.nulls.to_s
          }
        end
        @column_count = @columns.length
        @columns << {"u"=>dataset.literal(unique_key)}
        @fingerprint = digest("#{CURSOR_VERSION}\0#{encode_json(@columns)}")
        @secret = secret
      end

      # Return the cursor key to use for the given ordered expression when
      # reading a value from a result row.
      def self.row_key(expression)
        case expression
        when Symbol
          expression
        when SQL::Identifier
          expression.value
        when SQL::QualifiedIdentifier
          expression.column
        when SQL::AliasedExpression
          expression.alias
        else
          raise(Error, "keyset pagination requires ordered columns or identifiers, got #{expression.inspect}")
        end
      end

      def encode(values)
        payload = {
          "v"=>CURSOR_VERSION,
          "f"=>@fingerprint,
          "d"=>values
        }
        encoded_payload = encode_json(payload)
        signature = sign(encoded_payload)
        encode64("#{signature}.#{encoded_payload}")
      end

      def decode(cursor)
        message = cursor.is_a?(String) ? decode64(cursor) : nil
        signature, encoded_payload = message.is_a?(String) ? message.split(".", 2) : nil
        unless signature.is_a?(String) && /\A[0-9a-f]{64}\z/.match(signature) && encoded_payload.is_a?(String) && !encoded_payload.empty?
          raise(InvalidValue, "invalid keyset cursor")
        end
        verify_signature(signature, encoded_payload)

        payload = parse_json(encoded_payload)
        unless payload.is_a?(Hash) && payload["v"] == CURSOR_VERSION && payload["f"] == @fingerprint && payload["d"].is_a?(Array) && payload["d"].length == @column_count
          raise(InvalidValue, "keyset cursor does not match the dataset order")
        end

        payload["d"].map do |value|
          decode_typed_value(value)
        end
      end

      def typed_value(value)
        return {"t"=>NULL_TYPE} if value.nil?

        type = ENCODED_TYPES.find do |ruby_class, type_name|
          value.is_a?(ruby_class)
        end
        raise(InvalidValue, "unsupported keyset cursor value type: #{value.class}") unless type

        {"t"=>type.last, "v"=>encode_value(type.last, value)}
      end

      private

      def decode_typed_value(value)
        unless value.is_a?(Hash) && value.key?("t")
          raise(InvalidValue, "invalid keyset cursor value")
        end

        type = value["t"]
        return nil if type == NULL_TYPE
        unless DECODED_TYPES.key?(type) && value.key?("v") && value["v"].is_a?(String)
          raise(InvalidValue, "invalid keyset cursor value")
        end

        decode_value(type, value["v"])
      end

      def encode_value(type, value)
        case type
        when "integer", "float", "decimal", "string"
          value.to_s
        when "date"
          value.iso8601
        when "datetime", "time"
          value.iso8601(9)
        when "boolean"
          value ? "true" : "false"
        end
      end

      def decode_value(type, value)
        case type
        when "integer"
          Integer(value, 10)
        when "float"
          Float(value)
        when "decimal"
          BigDecimal(value)
        when "string"
          value
        when "boolean"
          return true if value == "true"
          return false if value == "false"
          raise(InvalidValue, "invalid keyset cursor value")
        when "date"
          Date.iso8601(value)
        when "datetime"
          DateTime.iso8601(value)
        when "time"
          Time.iso8601(value)
        end
      rescue ArgumentError, TypeError
        raise(InvalidValue, "invalid keyset cursor value")
      end

      def sign(data)
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, @secret, data)
      end

      def verify_signature(signature, data)
        expected = sign(data)
        unless signature && signature.bytesize == expected.bytesize && secure_equal?(signature, expected)
          raise(InvalidValue, "invalid keyset cursor signature")
        end
      rescue ArgumentError
        raise(InvalidValue, "invalid keyset cursor")
      end

      def digest(data)
        OpenSSL::Digest::SHA256.hexdigest(data)
      end

      def secure_equal?(actual, expected)
        result = 0
        actual.bytes.zip(expected.bytes).each{|a, b| result |= a ^ b}
        result == 0
      end

      def encode_json(data)
        JSON.generate(data)
      end

      def parse_json(data)
        JSON.parse(data)
      rescue JSON::ParserError
        raise(InvalidValue, "invalid keyset cursor")
      end

      def encode64(data)
        [data].pack("m").delete("\n=").tr("+/", "-_")
      end

      def decode64(data)
        raise(InvalidValue, "invalid keyset cursor") unless data.is_a?(String) && !data.empty?
        decoded = data.tr("-_", "+/").unpack("m").first
        raise(InvalidValue, "invalid keyset cursor") unless decoded.is_a?(String)
        decoded
      rescue ArgumentError
        raise(InvalidValue, "invalid keyset cursor")
      end
    end

    module DatasetMethods
      # Return one page of an ordered dataset using key-set pagination.  The
      # dataset must have a final stable unique ordered key and every ordered
      # expression must specify NULLS FIRST or NULLS LAST.
      def keyset_paginate(page_size, opts=OPTS)
        raise(Error, "cannot keyset paginate a dataset with a limit") if @opts[:limit]
        raise(Error, "cannot keyset paginate a dataset with an offset") if @opts[:offset]
        raise(Error, "page size must be greater than 0") unless page_size.is_a?(Integer) && page_size > 0
        raise(Error, "cannot provide both :before and :after cursors") if opts[:before] && opts[:after]

        unique_key = opts.fetch(:unique_key, :id)
        orders = keyset_orders(unique_key)
        codec = CursorCodec.new(self, orders, unique_key, opts[:cursor_secret])
        direction = opts[:before] ? :before : :after
        cursor = opts[direction]
        values = cursor ? codec.decode(cursor) : nil

        effective_orders = direction == :before ? orders.map(&:invert) : orders
        page_dataset = direction == :before ? order(*effective_orders) : self
        page_dataset = seek(page_dataset, orders, effective_orders, values, direction)
        page_dataset = page_dataset.limit(page_size + 1)
        rows = page_dataset.all
        more = rows.length > page_size
        records = rows.first(page_size)
        records = records.reverse if direction == :before

        Page.new(records, page_size, direction, !cursor.nil?, more, codec, orders)
      end

      private

      def keyset_orders(unique_key)
        orders = @opts[:order]
        orders = orders.is_a?(Array) ? orders : [orders] if orders
        unless complete_keyset_orders?(orders, unique_key)
          raise(Error, "keyset pagination requires explicit ordered expressions with NULLS FIRST or NULLS LAST and a final stable unique key")
        end
        orders
      end

      def complete_keyset_orders?(orders, unique_key)
        orders &&
          !orders.empty? &&
          orders.all?{|order| order.is_a?(SQL::OrderedExpression) && [:first, :last].include?(order.nulls) && keyset_order_expression?(order.expression)} &&
          !orders.last.expression.is_a?(SQL::AliasedExpression) &&
          keyset_expression_matches?(orders.last.expression, unique_key)
      end

      def keyset_order_expression?(expression)
        case expression
        when Symbol, SQL::Identifier, SQL::QualifiedIdentifier
          true
        when SQL::AliasedExpression
          true
        else
          false
        end
      end

      def keyset_expression_matches?(expression, unique_key)
        return keyset_expression_matches?(expression.expression, unique_key.expression) if unique_key.is_a?(SQL::AliasedExpression)
        return expression.alias == unique_key if expression.is_a?(SQL::AliasedExpression) && unique_key.is_a?(Symbol)

        case unique_key
        when Symbol
          expression == unique_key ||
            (expression.is_a?(SQL::Identifier) && expression.value == unique_key) ||
            (expression.is_a?(SQL::QualifiedIdentifier) && expression.column == unique_key)
        when SQL::Identifier
          expression.is_a?(SQL::Identifier) && expression.value == unique_key.value
        when SQL::QualifiedIdentifier
          expression.is_a?(SQL::QualifiedIdentifier) && expression.table == unique_key.table && expression.column == unique_key.column
        when SQL::AliasedExpression
          keyset_expression_matches?(expression.expression, unique_key.expression)
        else
          expression == unique_key
        end
      end

      def seek(dataset, orders, effective_orders, values, direction)
        return dataset if values.nil?

        unless values.length == orders.length
          raise(InvalidValue, "keyset cursor does not match the dataset order")
        end

        dataset.unordered.where(keyset_filter(orders, values, direction == :before ? :less : :greater)).order(*effective_orders)
      end

      def keyset_filter(orders, values, comparison)
        conditions = []
        orders.length.times do |index|
          allow_null = index < orders.length - 1
          expression = filter_expression(orders[index].expression)
          prefix = []
          index.times do |prefix_index|
            prefix << keyset_equality(filter_expression(orders[prefix_index].expression), values[prefix_index])
          end
          strict_condition = keyset_strict(expression, orders[index].nulls, orders[index].descending, values[index], comparison, allow_null)
          conditions << SQL::BooleanExpression.new(:AND, *prefix, strict_condition) if strict_condition
        end
        SQL::BooleanExpression.new(:OR, *conditions)
      end

      def filter_expression(expression)
        expression.is_a?(SQL::AliasedExpression) ? expression.expression : expression
      end

      def keyset_equality(expression, value)
        if value.nil?
          Sequel.expr(expression => nil)
        else
          Sequel.expr(expression => value)
        end
      end

      def keyset_strict(expression, nulls, descending, value, comparison, allow_null)
        if value.nil?
          nulls_before = nulls == :first
          nonnull_matches = comparison == :greater ? nulls_before : !nulls_before
          return nonnull_matches ? ~Sequel.expr(expression => nil) : nil
        else
          if descending == (comparison == :greater)
            condition = Sequel.expr(expression) < value
          else
            condition = Sequel.expr(expression) > value
          end
          null_matches = comparison == :greater ? nulls == :last : nulls == :first
          condition |= Sequel.expr(expression => nil) if null_matches && allow_null

          condition
        end
      end
    end
  end

  Dataset.register_extension(:keyset_pagination, KeysetPagination::DatasetMethods)
end
