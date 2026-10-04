# frozen_string_literal: true
require_relative 'spec_helper'

describe "Dataset#match_recognize" do
  before do
    @db = Sequel.connect('mock://oracle')
    @db.server_version = 12020000
  end

  it "compiles nested Oracle row patterns and binds DEFINE expressions" do
    pattern = Sequel.row_pattern do |p|
      p.start_event + (p.middle_event.one_to_three | p.noise_event.any_number).group + p.end_event
    end

    sql = @db[:events].
      match_recognize(
        partition_by: [:account_id, Sequel[:region]],
        order_by: [Sequel.asc(:event_at), Sequel.desc(:id)],
        measures: {
          first_at: Sequel.function(:first, :event_at),
          b_count: Sequel.function(:count, :middle_event)
        },
        after_match_skip: {to: :end_event},
        pattern: pattern,
        define: {
          start_event: Sequel.lit('event_type = ?', 'A'),
          middle_event: Sequel[:event_type] =~ :B,
          noise_event: {event_type: 'N'},
          end_event: Sequel[:event_at] > Sequel.lit('?', Date.new(2020, 1, 2))
        }
      ).sql

    sql.force_encoding(Encoding::UTF_8).must_equal(
      'SELECT * FROM "EVENTS" MATCH_RECOGNIZE(' \
      'PARTITION BY "ACCOUNT_ID", "REGION" ' \
      'ORDER BY "EVENT_AT" ASC, "ID" DESC ' \
      'MEASURES first("EVENT_AT") AS "FIRST_AT", count("MIDDLE_EVENT") AS "B_COUNT" ' \
      'AFTER MATCH SKIP TO "END_EVENT" ' \
      'PATTERN ("START_EVENT" ("MIDDLE_EVENT"{1,3} | "NOISE_EVENT"*) "END_EVENT") ' \
      'DEFINE "START_EVENT" AS event_type = \'A\', ' \
      '"MIDDLE_EVENT" AS ("EVENT_TYPE" = "B"), ' \
      '"NOISE_EVENT" AS ("EVENT_TYPE" = \'N\'), ' \
      '"END_EVENT" AS ("EVENT_AT" > DATE \'2020-01-02\'))'
    )
  end

  it "supports pattern concatenation, alternation, grouping, and quantifiers" do
    pattern = Sequel.row_pattern do
      (a + b).group.one_or_more | (c.maybe + d.any_number + e.times(2..4))
    end

    sql = @db[:t].match_recognize(
      pattern: pattern,
      define: {a: Sequel[:x] > 1, b: Sequel[:x] < 2, c: Sequel[:x] > 3, d: Sequel[:x] < 4, e: Sequel[:x] > 5},
      after_match_skip: :show_all_rows
    ).sql

    sql.force_encoding(Encoding::UTF_8).must_equal(
      'SELECT * FROM "T" MATCH_RECOGNIZE(' \
      'AFTER MATCH SHOW ALL ROWS ' \
      'PATTERN (("A" "B")+ | "C"? "D"* "E"{2,4}) ' \
      'DEFINE "A" AS ("X" > 1), "B" AS ("X" < 2), ' \
      '"C" AS ("X" > 3), "D" AS ("X" < 4), "E" AS ("X" > 5))'
    )
  end

  it "raises for an undeclared pattern variable" do
    pattern = Sequel.row_pattern { a + b }
    proc do
      @db[:t].match_recognize(pattern: pattern, define: {a: Sequel[:x] > 1})
    end.must_raise Sequel::Error
  end

  it "raises for duplicate DEFINE variables" do
    proc do
      @db[:t].match_recognize(
        pattern: Sequel.row_pattern(:a),
        define: [[:a, Sequel[:x] > 1], [:a, Sequel[:x] > 2]]
      )
    end.must_raise Sequel::Error
  end

  it "raises on unsupported adapters and Oracle versions" do
    db = Sequel.mock
    proc do
      db[:t].match_recognize(pattern: Sequel.row_pattern(:a), define: {a: Sequel[:x] > 1})
    end.must_raise Sequel::InvalidOperation

    @db.server_version = 11020000
    proc do
      @db[:t].match_recognize(pattern: Sequel.row_pattern(:a), define: {a: Sequel[:x] > 1})
    end.must_raise Sequel::InvalidOperation
  end

  it "validates identifiers and skip targets" do
    proc { Sequel::SQL::RowPattern::Variable.new(:'1a') }.must_raise Sequel::Error
    proc do
      @db[:t].match_recognize(
        pattern: Sequel.row_pattern(:a),
        define: {a: Sequel[:x] > 1},
        after_match_skip: {to: :b}
      )
    end.must_raise Sequel::Error
  end
end
