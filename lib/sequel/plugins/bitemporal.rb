# frozen_string_literal: true

module Sequel
  module Plugins
    # The bitemporal plugin stores records on two half-open time axes:
    #
    # * the business interval describes when values are effective
    # * the system interval describes when the database knew about the values
    #
    # Closed historical versions are retained. When an interval is revised,
    # affected current versions are closed on the system axis, unaffected
    # portions of their business intervals are retained, and new versions are
    # inserted. The split, close, and insert statements run in one transaction.
    #
    # The required columns are:
    #
    # * entity column (default: +:entity_id+)
    # * +valid_from+ and +valid_to+
    # * +system_from+ and +system_to+, with +nil+ representing an open end
    #
    # Usage:
    #
    #   Price.plugin :bitemporal, entity: :product_id
    #
    #   # On January 25, enter the $10 price that becomes effective February 1.
    #   Price.record(product_id: 1, amount: 10,
    #     valid_from: Date.new(2026, 2, 1), record_at: Date.new(2026, 1, 25))
    #
    #   # On February 20, record what actually happened in February. The January
    #   # expectation remains queryable with an as-of time before February 20.
    #   Price.record(product_id: 1, amount: 12,
    #     valid_from: Date.new(2026, 2, 1), valid_to: nil,
    #     record_at: Date.new(2026, 2, 20))
    #
    #   Price.known_at(jan31).valid_at(feb1).first # expected then: $10
    #   Price.current.visible_at(feb1).first       # actual now: $12
    #
    # The plugin checks for overlap inside the write transaction. For writes
    # under concurrency, back that invariant with a database exclusion
    # constraint for non-overlapping business intervals partitioned by entity
    # and system_from (on PostgreSQL, this needs the btree_gist extension).
    module Bitemporal
      # Error raised by the bitemporal plugin.
      class Error < Sequel::Error; end

      # Error raised when recording a value would create overlapping business
      # intervals for one entity at the same point on the system time axis.
      class OverlapError < Error; end

      # Configure the plugin. Options:
      #
      # :entity :: Name of the column identifying the entity (default: :entity_id)
      # :valid_from :: Start of the business interval (default: :valid_from)
      # :valid_to :: End of the business interval, nil means forever (default: :valid_to)
      # :system_from :: Start of the system interval (default: :system_from)
      # :system_to :: End of the system interval, nil means current (default: :system_to)
      def self.configure(model, opts=OPTS)
        model.instance_exec do
          @bitemporal_entity_column = opts[:entity] || :entity_id
          @bitemporal_valid_from_column = opts[:valid_from] || :valid_from
          @bitemporal_valid_to_column = opts[:valid_to] || :valid_to
          @bitemporal_system_from_column = opts[:system_from] || :system_from
          @bitemporal_system_to_column = opts[:system_to] || :system_to
        end
      end

      module ClassMethods
        attr_reader :bitemporal_entity_column
        attr_reader :bitemporal_valid_from_column
        attr_reader :bitemporal_valid_to_column
        attr_reader :bitemporal_system_from_column
        attr_reader :bitemporal_system_to_column

        Plugins.inherited_instance_variables(self,
          :@bitemporal_entity_column=>nil,
          :@bitemporal_valid_from_column=>nil,
          :@bitemporal_valid_to_column=>nil,
          :@bitemporal_system_from_column=>nil,
          :@bitemporal_system_to_column=>nil)

        Plugins.def_dataset_methods(self, [:current, :known_at, :as_of, :valid_at, :visible_at])

        # Record +attributes+ on the bitemporal timeline. If a model instance is
        # passed, its value attributes are used and its system interval columns
        # are ignored.
        #
        # +valid_from+ is required and +valid_to+ may be nil for an open-ended
        # business interval. +record_at+ supplies +system_from+ and defaults to
        # the database's current time.
        def record(attributes=OPTS)
          values = attributes.is_a?(Sequel::Model) ? attributes.values.dup : attributes.dup
          record_at = values.delete(:record_at) || values.delete(:as_of) || dataset.current_datetime
          record_attributes = values.reject do |column, _|
            column == bitemporal_system_from_column ||
              column == bitemporal_system_to_column
          end
          new(record_attributes).record_bitemporal(record_at)
        end

        # Alias of #record, useful when the operation is a correction.
        def revise(attributes=OPTS)
          record(attributes)
        end

        # Return the columns removed when copying an existing version.
        def bitemporal_copy_excluded_columns
          [*primary_key,
           bitemporal_valid_from_column,
           bitemporal_valid_to_column,
           bitemporal_system_from_column,
           bitemporal_system_to_column]
        end

        # Return the columns that define the two intervals.
        def bitemporal_interval_columns
          [bitemporal_valid_from_column,
           bitemporal_valid_to_column,
           bitemporal_system_from_column,
           bitemporal_system_to_column]
        end
      end

      module DatasetMethods
        # Limit rows to business intervals containing +time+, using half-open
        # [valid_from, valid_to) semantics. A nil end means forever.
        def valid_at(time)
          where do |r|
            ends = (r.__send__(model.bitemporal_valid_to_column) > time) |
                   (r.__send__(model.bitemporal_valid_to_column) =~ nil)
            (r.__send__(model.bitemporal_valid_from_column) <= time) & ends
          end
        end

        # Limit rows to system intervals containing +time+, using half-open
        # [system_from, system_to) semantics.
        def known_at(time)
          where do |r|
            ends = (r.__send__(model.bitemporal_system_to_column) > time) |
                   (r.__send__(model.bitemporal_system_to_column) =~ nil)
            (r.__send__(model.bitemporal_system_from_column) <= time) & ends
          end
        end
        alias as_of known_at

        # Limit rows to versions currently known by the database.
        def current
          where(model.bitemporal_system_to_column=>nil)
        end

        # Apply #valid_at and, optionally, #known_at (also available as +as_of+).
        # With no known-at time,
        # this queries the current database view.
        def visible_at(time, known_at: nil)
          (known_at ? self.known_at(known_at) : self).valid_at(time)
        end
      end

      module InstanceMethods
        # Record this instance's value on the bitemporal timeline and return the
        # inserted versions. The new instance is validated before writing.
        def record_bitemporal(record_at)
          unless record_at
            raise Sequel::Plugins::Bitemporal::Error, "must provide a record time"
          end

          valid_start = values.fetch(model.bitemporal_valid_from_column) do
            raise Sequel::Plugins::Bitemporal::Error,
              "must provide #{model.bitemporal_valid_from_column.inspect}"
          end
          valid_end = values[model.bitemporal_valid_to_column]
          values.fetch(model.bitemporal_entity_column) do
            raise Sequel::Plugins::Bitemporal::Error,
              "must provide #{model.bitemporal_entity_column.inspect}"
          end

          if valid_end && valid_start >= valid_end
            raise Sequel::Plugins::Bitemporal::Error,
              "business interval must use half-open [from, to) semantics"
          end

          valid?
          raise_hook_failure(:validation) if errors.any?

          @bitemporal_inserted = []
          db.transaction do
            perform_bitemporal_record(valid_start, valid_end, record_at)
          end
          @bitemporal_inserted
        end

        private

        def perform_bitemporal_record(valid_start, valid_end, record_at)
          vf = model.bitemporal_valid_from_column
          vt = model.bitemporal_valid_to_column
          sf = model.bitemporal_system_from_column
          st = model.bitemporal_system_to_column
          entity = values[model.bitemporal_entity_column]
          base = model.naked.where(model.bitemporal_entity_column=>entity)

          base.for_update.all

          overlap = base.where(sf=>record_at).where do |r|
            bitemporal_overlap_expr(r, vf, vt, valid_start, valid_end)
          end.first
          if overlap
            raise Sequel::Plugins::Bitemporal::OverlapError,
              "bitemporal business intervals overlap at system time #{record_at.inspect}"
          end

          active = base.current.where do |r|
            ((r.__send__(sf) <= record_at) &
              bitemporal_overlap_expr(r, vf, vt, valid_start, valid_end))
          end.all

          future = base.where do |r|
            ((r.__send__(sf) > record_at) &
              bitemporal_overlap_expr(r, vf, vt, valid_start, valid_end))
          end.all

          active.each do |row|
            close_bitemporal_row(row, record_at)
            retain_unaffected_business_parts(row, valid_start, valid_end)
          end

          bitemporal_segments(valid_start, valid_end, active, future).each do |segment_start, segment_end|
            future_intervals = future.select do |row|
              bitemporal_interval_contains?(row[vf], row[vt], segment_start)
            end.map{|row| [row[sf], row[st]]}.sort_by(&:first)

            insert_new_in_system_gaps(segment_start, segment_end, record_at, future_intervals)
          end
        end

        def bitemporal_overlap_expr(row, from_column, to_column, starts, ending)
          overlap = (row.__send__(to_column) > starts) | (row.__send__(to_column) =~ nil)
          if ending
            overlap &= (row.__send__(from_column) < ending)
          end
          overlap
        end

        def bitemporal_segments(valid_start, valid_end, active, future)
          boundaries = [valid_start]
          boundaries << valid_end if valid_end

          (active + future).each do |row|
            row_start = row[model.bitemporal_valid_from_column]
            row_end = row[model.bitemporal_valid_to_column]
            start = [valid_start, row_start].max
            finish = valid_end
            finish = row_end if finish.nil? || (row_end && row_end < finish)
            boundaries << start
            boundaries << finish if finish
          end

          boundaries = boundaries.compact.uniq.sort
          segments = boundaries.each_cons(2).to_a
          segments << [boundaries.last, nil] if valid_end.nil? && boundaries.any?
          segments
        end

        def retain_unaffected_business_parts(row, valid_start, valid_end)
          vf = model.bitemporal_valid_from_column
          vt = model.bitemporal_valid_to_column
          sf = model.bitemporal_system_from_column
          st = model.bitemporal_system_to_column
          start = [valid_start, row[vf]].max
          finish = bitemporal_min_end(valid_end, row[vt])

          insert_bitemporal_copy(row, row[vf], start, row[sf], row[st]) if start > row[vf]
          if finish && (row[vt].nil? || finish < row[vt])
            insert_bitemporal_copy(row, finish, row[vt], row[sf], row[st])
          end
        end

        def insert_new_in_system_gaps(valid_start, valid_end, record_at, future_intervals)
          cursor = record_at
          future_intervals.each do |system_start, system_end|
            insert_new_bitemporal(valid_start, valid_end, cursor, system_start)
            return if system_end.nil?
            cursor = [cursor, system_end].max
          end
          insert_new_bitemporal(valid_start, valid_end, cursor, nil)
        end

        def insert_new_bitemporal(valid_start, valid_end, system_start, system_end)
          return if system_end && system_start >= system_end

          row = bitemporal_value_attributes.merge(
            model.bitemporal_valid_from_column=>valid_start,
            model.bitemporal_valid_to_column=>valid_end,
            model.bitemporal_system_from_column=>system_start,
            model.bitemporal_system_to_column=>system_end)
          insert_bitemporal_row(row)
        end

        def insert_bitemporal_copy(row, valid_start, valid_end, system_start, system_end)
          return if valid_end && valid_start >= valid_end
          return if system_end && system_start >= system_end

          copy = bitemporal_copy_attributes(row).merge(
            model.bitemporal_valid_from_column=>valid_start,
            model.bitemporal_valid_to_column=>valid_end,
            model.bitemporal_system_from_column=>system_start,
            model.bitemporal_system_to_column=>system_end)
          insert_bitemporal_row(copy)
        end

        def insert_bitemporal_row(row)
          model.naked.insert(row)
          @bitemporal_inserted ||= []
          @bitemporal_inserted << model.load(row)
        end

        def close_bitemporal_row(row, record_at)
          pks = Array(model.primary_key)
          raise Sequel::Plugins::Bitemporal::Error, "bitemporal models require a primary key" if pks.empty?
          filter = pks.to_h{|pk| [pk, row[pk]]}

          if row[model.bitemporal_system_from_column] == record_at
            model.where(filter).delete
          else
            model.where(filter).update(model.bitemporal_system_to_column=>record_at)
          end
        end

        def bitemporal_value_attributes
          values.reject do |column, _|
            Array(model.primary_key).include?(column) ||
              model.bitemporal_interval_columns.include?(column)
          end
        end

        def bitemporal_copy_attributes(row)
          row.reject do |column, _|
            model.bitemporal_copy_excluded_columns.include?(column)
          end
        end

        def bitemporal_interval_contains?(starts, ending, time)
          starts <= time && (ending.nil? || ending > time)
        end

        def bitemporal_min_end(first, second)
          return second if first.nil?
          return first if second.nil?
          [first, second].min
        end
      end
    end
  end
end
