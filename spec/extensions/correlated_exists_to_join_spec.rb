# frozen_string_literal: true
require_relative "spec_helper"

describe "correlated_exists_to_join extension" do
  before do
    @db = Sequel.sqlite
    @db.create_table(:parents) do
      Integer :id
      String :tag
    end
    @db.create_table(:children) do
      Integer :id
      Integer :parent_id
      TrueClass :active
      String :status
    end

    @db[:parents].multi_insert([
      {:id=>1, :tag=>"a"},
      {:id=>1, :tag=>"b"},
      {:id=>2, :tag=>"c"},
      {:id=>3, :tag=>"d"},
      {:id=>4, :tag=>"e"},
      {:id=>nil, :tag=>"f"}
    ])
    @db[:children].multi_insert([
      {:id=>10, :parent_id=>1, :active=>true, :status=>"x"},
      {:id=>11, :parent_id=>1, :active=>true, :status=>"y"},
      {:id=>12, :parent_id=>1, :active=>false, :status=>"z"},
      {:id=>13, :parent_id=>2, :active=>true, :status=>"x"},
      {:id=>14, :parent_id=>nil, :active=>true, :status=>"x"},
      {:id=>15, :parent_id=>3, :active=>true, :status=>"x"},
      {:id=>16, :parent_id=>4, :active=>true, :status=>nil}
    ])
  end

  after do
    @db.disconnect
  end

  def multiset(dataset)
    dataset.all.map(&:values).sort_by(&:inspect)
  end

  def rewrite(dataset, skipped=nil)
    dataset.extension(:correlated_exists_to_join).correlated_exists_to_join(skipped)
  end

  def active_exists
    @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      Sequel[:children][:active]=>true
    ).exists
  end

  it "does not apply the rewrite unless explicitly requested" do
    dataset = @db[:parents].where(active_exists)
    dataset.sql.must_include "EXISTS"
  end

  it "rewrites EXISTS to a semi-join without duplicating outer rows" do
    original = @db[:parents].where(active_exists)
    rewritten = rewrite(original)

    rewritten.sql.must_include "INNER JOIN"
    rewritten.sql.wont_include "EXISTS"
    multiset(rewritten).must_equal multiset(original)
    multiset(rewritten).must_equal [
      [1, "a"],
      [1, "b"],
      [2, "c"],
      [3, "d"],
      [4, "e"]
    ]
  end

  it "rewrites NOT EXISTS to an anti-join with NULL-safe semantics" do
    original = @db[:parents].where(~active_exists)
    rewritten = rewrite(original)

    rewritten.sql.must_include "LEFT OUTER JOIN"
    rewritten.sql.must_include "IS NULL"
    rewritten.sql.wont_include "NOT IN"
    multiset(rewritten).must_equal multiset(original)
    multiset(rewritten).must_equal [[nil, "f"]]
  end

  it "does not treat NULL key rows in a matching source as unmatched for anti-joins" do
    @db[:parents].insert(:id=>7, :tag=>"i")
    @db[:children].multi_insert([
      {:id=>19, :parent_id=>7, :active=>true, :status=>"x"},
      {:id=>20, :parent_id=>nil, :active=>true, :status=>"x"}
    ])
    original = @db[:parents].where(~active_exists)
    rewritten = rewrite(original)

    multiset(rewritten).must_equal multiset(original)
    multiset(rewritten).wont_include [7, "i"]
  end

  it "keeps an anti-join null test on its own join when followed by another join" do
    null_exists = @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      Sequel[:children][:status]=>nil
    ).exists
    dataset = @db[:parents].where((~null_exists) & active_exists)
    skipped = []
    rewritten = rewrite(dataset, skipped)

    skipped.map(&:first).must_equal [:mixed_with_anti_join]
    multiset(rewritten).must_equal multiset(dataset)
    rewritten.sql.must_include "LEFT OUTER JOIN"
    rewritten.sql.must_include "EXISTS"
  end

  it "handles NULL components in composite anti-join keys" do
    @db[:parents].multi_insert([
      {:id=>5, :tag=>"g"},
      {:id=>6, :tag=>"h"}
    ])
    @db[:children].multi_insert([
      {:id=>17, :parent_id=>5, :active=>true, :status=>"x"},
      {:id=>18, :parent_id=>6, :active=>true, :status=>"x"}
    ])
    exists = @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      Sequel[:children][:status]=>Sequel[:parents][:tag]
    ).exists
    original = @db[:parents].where(~exists)
    rewritten = rewrite(original)

    multiset(rewritten).must_equal multiset(original)
    rewritten.sql.must_include "IS NULL"
  end

  it "keeps local NULL filters inside the correlated subquery" do
    exists = @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      Sequel[:children][:status]=>nil
    ).exists
    original = @db[:parents].where(exists)
    rewritten = rewrite(original)

    multiset(rewritten).must_equal multiset(original)
    multiset(rewritten).must_equal [[4, "e"]]
  end

  it "supports local NULL filters in anti-joins" do
    exists = @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      Sequel[:children][:status]=>nil
    ).exists
    original = @db[:parents].where(~exists)
    rewritten = rewrite(original)

    multiset(rewritten).must_equal multiset(original)
    multiset(rewritten).must_equal [
      [1, "a"],
      [1, "b"],
      [2, "c"],
      [3, "d"],
      [nil, "f"]
    ]
  end

  it "preserves placeholder literalizer arguments in the rewritten AST" do
    original_loader = Sequel::Dataset::PlaceholderLiteralizer.loader(@db[:parents]) do |pl, dataset|
      active = pl.arg
      exists = @db[:children].where(
        Sequel[:children][:parent_id]=>Sequel[:parents][:id],
        Sequel[:children][:active]=>active
      ).exists
      dataset.where(exists)
    end
    rewritten_loader = Sequel::Dataset::PlaceholderLiteralizer.loader(@db[:parents]) do |pl, dataset|
      active = pl.arg
      exists = @db[:children].where(
        Sequel[:children][:parent_id]=>Sequel[:parents][:id],
        Sequel[:children][:active]=>active
      ).exists
      dataset.where(exists).extension(:correlated_exists_to_join).correlated_exists_to_join
    end

    [true, false].each do |active|
      rewritten_loader.all(active).map(&:values).sort_by(&:inspect).must_equal(
        original_loader.all(active).map(&:values).sort_by(&:inspect)
      )
    end
    rewritten_loader.sql(true).must_include "INNER JOIN"
    rewritten_loader.sql(true).wont_include "EXISTS"
  end

  it "preserves local scalar subqueries in the EXISTS source" do
    @db.create_table(:lookup) do
      Integer :child_id
      Integer :parent_id
    end
    @db[:lookup].insert(:child_id=>13, :parent_id=>2)
    exists = @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      Sequel[:children][:id]=>@db[:lookup].where(
        Sequel[:lookup][:child_id]=>Sequel[:children][:id]
      ).select(:child_id)
    ).exists
    original = @db[:parents].where(exists)
    rewritten = rewrite(original)

    multiset(rewritten).must_equal multiset(original)
    multiset(rewritten).must_equal [[2, "c"]]
  end

  it "supports unqualified columns in local filters without schema inspection" do
    exists = @db[:children].where({
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      :active=>true
    }).where(Sequel.like(:status, "x")).exists
    original = @db[:parents].where(exists)
    rewritten = rewrite(original)

    multiset(rewritten).must_equal multiset(original)
  end

  it "leaves unsupported predicates unchanged and reports skip reasons" do
    db = Sequel.mock
    correlation = {
      Sequel[:children][:parent_id]=>Sequel[:parents][:id]
    }

    aggregate = db[:children].group(:parent_id).having { count(parent_id) > 0 }.where(correlation)
    limited = db[:children].limit(1).where(correlation)
    inequality = db[:children].where {
      Sequel[:children][:id] > Sequel[:parents][:id]
    }
    nested = db[:children].where(
      Sequel[:children][:id]=>db[:others].where(
        Sequel[:others][:id]=>Sequel[:parents][:id]
      ).select(1)
    )

    {
      aggregate.exists => :aggregate,
      limited.exists => :limit,
      inequality.exists => :unsupported_correlation,
      nested.exists => :cross_level_reference
    }.each do |predicate, reason|
      dataset = db[:parents].where(predicate)
      skipped = []
      rewritten = rewrite(dataset, skipped)
      skipped.map(&:first).must_equal [reason]
      rewritten.must_equal dataset
      rewritten.sql.must_include "EXISTS"
    end
  end

  it "skips an EXISTS that references a scope above its immediate parent query" do
    nested_exists = @db[:others].where(Sequel[:others][:id]=>Sequel[:parents][:id]).exists
    middle = @db[:children].where(
      Sequel[:children][:parent_id]=>Sequel[:parents][:id],
      nested_exists=>true
    ).exists
    dataset = @db[:parents].where(middle)
    skipped = []

    rewrite(dataset, skipped).must_equal dataset
    skipped.map(&:first).must_equal [:cross_level_reference]
  end
end
