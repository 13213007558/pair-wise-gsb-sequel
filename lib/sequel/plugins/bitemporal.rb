# frozen_string_literal: true

module Sequel
  module Plugins
    # The bitemporal plugin stores both the business-valid interval and the
    # database knowledge (system) interval for each row.  Both intervals are
    # half-open: [from, to).  A +nil+ end means the value is currently open.
    #
    # Rows are append-only in system time.  Recording a new version closes all
    # currently visible versions that overlap the supplied business interval,
    # preserves the unaffected left and right parts of those intervals, and
    # inserts the new version.  All operations are performed in a transaction
    # (or a savepoint when called inside one).
    #
    # Example:
    #
    #   DB.create_table(:product_prices) do
    #     primary_key :id
    #     Integer :product_id, null: false
    #     BigDecimal :amount, size: [10, 2], null: false
    #     Date :valid_from, null: false
    #     Date :valid_to
    #     DateTime :system_from, null: false
    #     DateTime :system_to
    #   end
    #
    #   class ProductPrice < Sequel::Model(:product_prices)
    #     plugin :bitemporal, key: :product_id
    #   end
    #
    #   feb1 = Date.new(2026, 2, 1)
    #   feb15 = Date.new(2026, 2, 15)
    #   mar1 = Date.new(2026, 3, 1)
    #
    #   ProductPrice.record(product_id: 1, amount: 100, valid_from: feb1,
    #     recorded_at: feb1)
    #
    #   # At Feb 20, a correction for Feb 15...Mar 1 becomes known.  The old
    #   # Feb 1...open price is split into Feb 1...Feb 15 and Mar 1...open.
    #   ProductPrice.record(product_id: 1, amount: 120,
    #     valid_from: feb15, valid_to: mar1, recorded_at: Date.new(2026, 2, 20))
    #
    #   ProductPrice.visible_at(feb15, Date.new(2026, 2, 20)).get(:amount)
    #   # What actually took effect once the correction was known: 120
    #   ProductPrice.known_at(feb1).valid_at(feb15).get(:amount)
    #   # What the system believed on Feb 1 would take effect: 100
    #
    # In a concurrent production database, also add a database constraint to
    # enforce the invariant.  For PostgreSQL, enable btree_gist and add a
    # partial exclusion constraint on (entity key, valid range) where
    # +system_to+ is NULL.
    module Bitemporal
      class Error < Sequel::Error
      end

      DEFAULTS = {
        :key => :entity_id,
        :valid_from => :valid_from,
        :valid_to => :valid_to,
        :system_from => :system_from,
        :system_to => :system_to,
      }.freeze

      # Configure the plugin.
      # Options:
      # :key :: column or array of columns identifying the same entity
      # :valid_from :: business interval start column (default: :valid_from)
      # :valid_to :: business interval end column (default: :valid_to)
      # :system_from :: system interval start column (default: :system_from)
      # :system_to :: open system interval column (default: :system_to)
      def self.configure(model, opts=OPTS)
        options = DEFAULTS.merge(opts)
        model.instance_exec do
          key_columns = Array(options[:key]).freeze
          if key_columns.empty?
            raise Error, "bitemporal plugin requires at least one :key column"
          end
          @bitemporal_entity_key_columns = key_columns
          @bitemporal_valid_from_column = options[:valid_from]
          @bitemporal_valid_to_column = options[:valid_to]
          @bitemporal_system_from_column = options[:system_from]
          @bitemporal_system_to_column = options[:system_to]
        end
      end

      module ClassMethods
        attr_reader :bitemporal_entity_key_columns
        attr_reader :bitemporal_valid_from_column
        attr_reader :bitemporal_valid_to_column
        attr_reader :bitemporal_system_from_column
        attr_reader :bitemporal_system_to_column

        Plugins.inherited_instance_variables(self,
          :@bitemporal_entity_key_columns=>nil,
          :@bitemporal_valid_from_column=>nil,
          :@bitemporal_valid_to_column=>nil,
          :@bitemporal_system_from_column=>nil,
          :@bitemporal_system_to_column=>nil)

        Plugins.def_dataset_methods(self,
          [:bitemporal_record, :known_at, :as_of, :valid_at, :during,
           :visible_at])

        # Record a new version of an entity for the half-open business
        # interval [valid_from, valid_to).  +valid_to+ defaults to nil,
        # meaning open-ended.  +recorded_at+ defaults to the current time.
        def record(values=OPTS, valid_from: nil, valid_to: nil,
                   recorded_at: nil, **attrs)
          values = values.equal?(OPTS) ? attrs : values.merge(attrs)
          dataset.bitemporal_record(values, valid_from: valid_from,
            valid_to: valid_to, recorded_at: recorded_at)
        end
      end

      module DatasetMethods
        # Filter to rows the database knew at +time+, using half-open system
        # intervals: system_from <= time < system_to.  Open system intervals
        # (system_to IS NULL) remain visible.
        def known_at(time)
          time = bitemporal_typecast(model.bitemporal_system_from_column, time)
          where(bitemporal_column(model.bitemporal_system_from_column) <= time).
            where(bitemporal_open_or_after(model.bitemporal_system_to_column, time))
        end

        alias as_of known_at

        # Filter to rows whose half-open business interval contains +time+:
        # valid_from <= time < valid_to.  Open business intervals remain
        # visible.
        def valid_at(time)
          time = bitemporal_typecast(model.bitemporal_valid_from_column, time)
          where(bitemporal_column(model.bitemporal_valid_from_column) <= time).
            where(bitemporal_open_or_after(model.bitemporal_valid_to_column, time))
        end

        alias during valid_at

        # Filter to values that were known to the database at +known_time+ and
        # business-valid at +valid_time+.
        def visible_at(valid_time, known_time=model.dataset.current_datetime)
          known_at(known_time).valid_at(valid_time)
        end

        # Close and split all currently visible overlapping versions, then
        # insert the supplied version.  Returns the inserted model instance.
        def bitemporal_record(values=OPTS, valid_from: nil, valid_to: nil,
                              recorded_at: nil, **attrs)
          transaction_options = model.db.supports_savepoints? ? {savepoint: true} : OPTS
          model.db.transaction(transaction_options) do
            values = values.equal?(OPTS) ? attrs.dup : values.dup.merge!(attrs)
            valid_from = values.delete(model.bitemporal_valid_from_column) if valid_from.nil?
            if values.key?(model.bitemporal_valid_to_column)
              valid_to = values.delete(model.bitemporal_valid_to_column) if valid_to.nil?
            end
            if values.key?(model.bitemporal_system_from_column)
              if recorded_at.nil?
                recorded_at = values.delete(model.bitemporal_system_from_column)
              end
            end
            values.delete(model.bitemporal_system_to_column)
            recorded_at ||= current_datetime
            valid_from = bitemporal_typecast(model.bitemporal_valid_from_column, valid_from)
            valid_to = bitemporal_typecast(model.bitemporal_valid_to_column, valid_to)
            recorded_at = bitemporal_typecast(model.bitemporal_system_from_column, recorded_at)

            validate_bitemporal_interval(valid_from, valid_to)
            validate_bitemporal_values(values, recorded_at)

            candidates = bitemporal_entity_versions(values).for_update.all
            current_candidates = candidates.select do |row|
              row[model.bitemporal_system_to_column].nil?
            end
            validate_recorded_at(candidates, recorded_at)
            validate_existing_system_intervals(candidates)
            validate_existing_bitemporal_intervals(current_candidates)

            overlapping = current_candidates.select do |row|
              bitemporal_intervals_overlap?(
                row[model.bitemporal_valid_from_column],
                row[model.bitemporal_valid_to_column],
                valid_from,
                valid_to)
            end

            close_bitemporal_versions(overlapping, recorded_at)
            split_bitemporal_versions(overlapping, valid_from, valid_to, recorded_at)
            insert_bitemporal_version(values, valid_from, valid_to, recorded_at)
          end
        end

        private

        def bitemporal_column(column)
          Sequel[first_source_alias][column]
        end

        def bitemporal_table
          db.from(first_source_table)
        end

        def bitemporal_typecast(column, value)
          schema = model.db_schema[column]
          return value unless schema && schema[:type]
          db.typecast_value(schema[:type], value)
        end

        def bitemporal_open_or_after(column, time)
          expression = bitemporal_column(column)
          (expression > time) | {expression => nil}
        end

        def bitemporal_entity_versions(values)
          condition = OPTS.dup
          model.bitemporal_entity_key_columns.each do |column|
            condition[column] = values.fetch(column) do
              raise Bitemporal::Error, "missing entity key value for #{column.inspect}"
            end
          end

          bitemporal_table.where(condition)
        end

        def validate_bitemporal_interval(from, to)
          if from.nil?
            raise Bitemporal::Error, "#{model.bitemporal_valid_from_column.inspect} is required"
          end
          if to && from >= to
            raise Bitemporal::Error,
              "bitemporal interval must use half-open semantics with from < to"
          end
        end

        def validate_bitemporal_values(values, recorded_at)
          if recorded_at.nil?
            raise Bitemporal::Error, "#{model.bitemporal_system_from_column.inspect} is required"
          end

          reserved = [
            model.bitemporal_valid_from_column,
            model.bitemporal_valid_to_column,
            model.bitemporal_system_from_column,
            model.bitemporal_system_to_column,
          ]
          if (values.keys.map(&:to_sym) & reserved).any?
            raise Bitemporal::Error,
              "system and interval columns cannot be supplied as value columns"
          end
        end

        def validate_recorded_at(rows, recorded_at)
          latest_system_time = rows.map do |row|
            row[model.bitemporal_system_from_column]
          end.compact.max
          if latest_system_time && recorded_at < latest_system_time
            raise Bitemporal::Error, "system time cannot be earlier than an existing version"
          end
        end

        def validate_existing_system_intervals(rows)
          rows.each do |row|
            from = row[model.bitemporal_system_from_column]
            to = row[model.bitemporal_system_to_column]
            if from.nil? || (to && from > to)
              raise Bitemporal::Error, "existing system intervals must be half-open"
            end
          end
        end

        def validate_existing_bitemporal_intervals(rows)
          rows = rows.sort_by { |row| row[model.bitemporal_valid_from_column] }
          rows.each_cons(2) do |first, second|
            if bitemporal_intervals_overlap?(
              first[model.bitemporal_valid_from_column],
              first[model.bitemporal_valid_to_column],
              second[model.bitemporal_valid_from_column],
              second[model.bitemporal_valid_to_column])
              raise Bitemporal::Error,
                "existing bitemporal intervals overlap for the same entity and system time"
            end
          end
          rows.each do |row|
            from = row[model.bitemporal_valid_from_column]
            to = row[model.bitemporal_valid_to_column]
            if from.nil? || (to && from >= to)
              raise Bitemporal::Error, "existing business intervals must be half-open"
            end
          end
        end

        def bitemporal_intervals_overlap?(first_from, first_to, second_from, second_to)
          (second_to.nil? || first_from < second_to) &&
            (first_to.nil? || second_from < first_to)
        end

        def close_bitemporal_versions(rows, recorded_at)
          rows.each do |row|
            bitemporal_table.where(bitemporal_pk_hash(row)).
              update(model.bitemporal_system_to_column => recorded_at)
          end
        end

        def split_bitemporal_versions(rows, valid_from, valid_to, recorded_at)
          rows.each do |row|
            old_from = row[model.bitemporal_valid_from_column]
            old_to = row[model.bitemporal_valid_to_column]

            if old_from < valid_from
              insert_bitemporal_copy(row, old_from, valid_from, recorded_at)
            end

            if valid_to && (old_to.nil? || valid_to < old_to)
              insert_bitemporal_copy(row, valid_to, old_to, recorded_at)
            end
          end
        end

        def insert_bitemporal_copy(row, valid_from, valid_to, recorded_at)
          values = bitemporal_copy_values(row)
          values[model.bitemporal_valid_from_column] = valid_from
          values[model.bitemporal_valid_to_column] = valid_to
          values[model.bitemporal_system_from_column] = recorded_at
          values[model.bitemporal_system_to_column] = nil
          bitemporal_table.insert(values)
        end

        def bitemporal_copy_values(row)
          key_columns = model.bitemporal_entity_key_columns
          interval_columns = [
            model.bitemporal_valid_from_column,
            model.bitemporal_valid_to_column,
            model.bitemporal_system_from_column,
            model.bitemporal_system_to_column,
          ]
          excluded = (Array(model.primary_key) - key_columns) | interval_columns
          row.to_hash.dup.delete_if { |column, _| excluded.include?(column) }
        end

        def insert_bitemporal_version(values, valid_from, valid_to, recorded_at)
          insert_values = values.merge(
            model.bitemporal_valid_from_column => valid_from,
            model.bitemporal_valid_to_column => valid_to,
            model.bitemporal_system_from_column => recorded_at,
            model.bitemporal_system_to_column => nil)
          object = model.new
          insert_values.each do |column, value|
            object[column] = value
          end
          object.save(transaction: false)
          object
        end

        def bitemporal_pk_hash(row)
          primary_key = model.primary_key
          keys = Array(primary_key)

          if primary_key.nil?
            raise Bitemporal::Error, "model must have a primary key to revise bitemporal rows"
          end

          Hash[keys.map { |column| [column, row[column]] }]
        end

      end

      module InstanceMethods
        def before_update
          super
          raise Bitemporal::Error, "bitemporal rows are append-only; record a new version"
        end

        def before_destroy
          super
          raise Bitemporal::Error, "bitemporal rows are append-only and cannot be destroyed"
        end
      end
    end
  end
end
