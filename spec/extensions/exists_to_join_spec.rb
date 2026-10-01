# frozen_string_literal: true
require_relative "spec_helper"

describe "exists_to_join extension" do
  before do
    @db = Sequel.sqlite
    @db.create_table(:parents) do
      Integer :id
      String :kind
      TrueClass :keep, default: true
    end
    @db.create_table(:events) do
      Integer :id
      Integer :parent_id
      String :kind
      FalseClass :active
    end
    @db.create_table(:grandchildren) do
      Integer :event_id
      TrueClass :ok
    end

    @parents = @db[:parents]
    @events = @db[:events]
    @grandchildren = @db[:grandchildren]

    @parents.import([:id, :kind, :keep], [
      [1, "a", true], [1, "a", true], [2, "a", true],
      [3, "a", true], [4, "b", true], [5, "a", true],
      [nil, "a", true], [6, "a", false]
    ])
    @events.import([:id, :parent_id, :kind, :active], [
      [1, 1, "a", true], [2, 1, "a", true], [3, 2, "a", false],
      [4, 3, "a", true], [5, nil, "a", true], [6, 5, "b", true]
    ])
    @grandchildren.import([:event_id, :ok], [[1, true], [2, true], [4, true]])
  end

  after do
    @db.disconnect
  end

  def correlated_events(active = true)
    @events.
      where(Sequel[:events][:parent_id] => Sequel[:parents][:id]).
      where(Sequel[:events][:kind] => Sequel[:parents][:kind]).
      where(Sequel[:events][:active] => active)
  end

  def multiset(original, rewritten)
    original_rows = original.select_map([Sequel[:parents][:id], Sequel[:parents][:kind]])
    rewritten_rows = rewritten.select_map([Sequel[:parents][:id], Sequel[:parents][:kind]])
    sorted_original_rows = original_rows.sort_by do |row|
      row.map { |value| [value.nil? ? 1 : 0, value.to_s] }
    end
    sorted_rewritten_rows = rewritten_rows.sort_by do |row|
      row.map { |value| [value.nil? ? 1 : 0, value.to_s] }
    end
    [sorted_original_rows, sorted_rewritten_rows]
  end

  it "rewrites correlated EXISTS to a deduplicated semi-join" do
    original = @parents.where(Sequel[:parents][:keep] => true).where(correlated_events.exists)
    rewritten, reasons = original.extension(:exists_to_join).rewrite_exists_to_joins

    reasons.must_equal []
    rewritten.sql.must_match(/INNER JOIN/i)
    rewritten.sql.must_match(/SELECT DISTINCT/i)
    rewritten.sql.wont_match(/(?:^|[^_A-Za-z])EXISTS(?:$|[^_A-Za-z])/i)

    expected, actual = multiset(original, rewritten)
    actual.must_equal expected
    actual.must_equal [[1, "a"], [1, "a"], [3, "a"]]
  end

  it "rewrites correlated NOT EXISTS to an anti-join without NOT IN" do
    original = @parents.where(~correlated_events.exists)
    rewritten, reasons = original.extension(:exists_to_join).rewrite_exists_to_joins

    reasons.must_equal []
    rewritten.sql.must_match(/LEFT JOIN/i)
    rewritten.sql.must_match(/_sequel_exists_match_0[^\n]* IS NULL/i)
    rewritten.sql.wont_match(/NOT IN/i)
    rewritten.sql.wont_match(/(?:^|[^_A-Za-z])EXISTS(?:$|[^_A-Za-z])/i)

    expected, actual = multiset(original, rewritten)
    actual.must_equal expected
    actual.must_equal [
      [2, "a"], [4, "b"], [5, "a"], [6, "a"], [nil, "a"]
    ]
  end

  it "keeps outer filters and local filters while preserving duplicate outer rows" do
    events = correlated_events.where(Sequel.lit("? = 1", Sequel[:events][:active]))
    original = @parents.where(Sequel[:parents][:kind] => "a").where(events.exists)
    rewritten, reasons = original.extension(:exists_to_join).rewrite_exists_to_joins

    reasons.must_equal []
    expected, actual = multiset(original, rewritten)
    actual.must_equal expected
    actual.must_equal [[1, "a"], [1, "a"], [3, "a"]]
    rewritten.sql.must_match(/`parents`\.`kind` = 'a'/)
    rewritten.sql.must_match(/\(`events`\.`active` = 1\)/)
  end

  it "supports local nested EXISTS while rejecting cross-level references" do
    local_nested = correlated_events.where(
      @grandchildren.where(
        Sequel[:grandchildren][:event_id] => Sequel[:events][:id]
      ).where(Sequel[:grandchildren][:ok] => true).exists
    )
    original = @parents.where(local_nested.exists)
    rewritten, reasons = original.extension(:exists_to_join).rewrite_exists_to_joins

    reasons.must_equal []
    expected, actual = multiset(original, rewritten)
    actual.must_equal expected
    actual.must_equal [[1, "a"], [1, "a"], [3, "a"]]

    cross_level_nested = correlated_events.where(
      @grandchildren.where(
        Sequel[:grandchildren][:event_id] => Sequel[:parents][:id]
      ).exists
    )
    skipped = @parents.where(cross_level_nested.exists).extension(:exists_to_join)
    rewritten, reasons = skipped.rewrite_exists_to_joins

    rewritten.sql.must_equal skipped.sql
    reasons.must_include "EXISTS subquery uses a cross-level reference"
    rewritten.sql.must_match(/(?:^|[^_A-Za-z])EXISTS(?:$|[^_A-Za-z])/i)

    deeper_cross_level_nested = correlated_events.where(
      @grandchildren.where(
        Sequel[:grandchildren][:event_id] => @db.from(
          @db[:grandchildren].where(Sequel[:grandchildren][:event_id] => Sequel[:parents][:id])
        ).select(1)
      ).exists
    )
    check_skip(@parents.where(deeper_cross_level_nested.exists),
               "EXISTS subquery uses a cross-level reference")
  end

  it "does not apply unless the rewrite method is called" do
    original = @parents.where(correlated_events.exists)
    @db.extension(:exists_to_join)

    @parents.where(correlated_events.exists).sql.must_equal original.sql
    @parents.where(correlated_events.exists).extension(:exists_to_join).sql.must_match(/EXISTS/i)
  end

  it "skips unsupported aggregate expressions, limits, non-equality correlation, and OR" do
    aggregate = @events.
      where(Sequel[:events][:parent_id] => Sequel[:parents][:id]).
      select_append(Sequel.function(:count, :id))
    check_skip(@parents.where(aggregate.exists), "EXISTS subquery uses an aggregate expression")

    limited = @events.
      where(Sequel[:events][:parent_id] => Sequel[:parents][:id]).
      limit(1)
    check_skip(@parents.where(limited.exists), "EXISTS subquery uses LIMIT or OFFSET")

    non_equality = @events.where {
      Sequel[:events][:parent_id] > Sequel[:parents][:id]
    }
    check_skip(@parents.where(non_equality.exists),
               "correlated predicate is not an equality condition")

    disjunction = @events.where {
      (Sequel[:events][:parent_id] =~ Sequel[:parents][:id]) |
      Sequel.expr(Sequel[:events][:active] => true)
    }
    check_skip(@parents.where(disjunction.exists),
               "EXISTS subquery uses OR in its WHERE clause")
  end

  it "leaves uncorrelated EXISTS unchanged" do
    uncorrelated = @events.where(Sequel[:events][:active] => true)
    check_skip(@parents.where(uncorrelated.exists),
               "EXISTS subquery is not correlated by an equality condition")
  end

  it "does not partially rewrite a conjunction containing an unsupported EXISTS" do
    supported = @events.
      where(Sequel[:events][:parent_id] => Sequel[:parents][:id]).
      where(Sequel[:events][:kind] => Sequel[:parents][:kind])
    unsupported = @events.
      where(Sequel[:events][:parent_id] => Sequel[:parents][:id]).
      limit(1)
    original = @parents.where(supported.exists).where(unsupported.exists)
    rewritten, reasons = original.extension(:exists_to_join).rewrite_exists_to_joins

    rewritten.sql.must_equal original.sql
    reasons.must_include "EXISTS subquery uses LIMIT or OFFSET"
    rewritten.sql.must_match(/(?:^|[^_A-Za-z])EXISTS(?:$|[^_A-Za-z])/i)
  end

  it "returns only the rewritten dataset through the bang method" do
    original = @parents.where(correlated_events.exists)
    rewritten = original.extension(:exists_to_join).rewrite_exists_to_joins!

    rewritten.sql.must_match(/INNER JOIN/i)
    expected, actual = multiset(original, rewritten)
    actual.must_equal expected
  end

  def check_skip(dataset, reason)
    rewritten, reasons = dataset.extension(:exists_to_join).rewrite_exists_to_joins
    rewritten.sql.must_equal dataset.sql
    reasons.must_include reason
    rewritten.sql.must_match(/(?:^|[^_A-Za-z])EXISTS(?:$|[^_A-Za-z])/i)
  end
end
