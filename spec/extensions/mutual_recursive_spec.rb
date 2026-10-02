# frozen_string_literal: true
require_relative "spec_helper"

describe "mutual_recursive extension" do
  before do
    @db = Sequel.sqlite
    @db.extension(:mutual_recursive)
  end

  def parity_relations(db)
    db.mutual_recursive(
      :odd => {
        :columns => [:n],
        :base => db[:edges].where(:b => 1).select(Sequel[:b].as(:n)),
        :recursive => lambda do |r|
          db[:edges].
            join(r[:even], r[:even][:n] => :a).
            select(Sequel[:b].as(:n))
        end
      },
      :even => {
        :columns => [:n],
        :recursive => lambda do |r|
          db[:edges].
            join(r[:odd], r[:odd][:n] => :a).
            select(Sequel[:b].as(:n))
        end
      }
    )
  end

  it "compiles two mutually recursive relations into one labelled recursive CTE" do
    @db.create_table(:edges) { Integer :a; Integer :b }
    @db[:edges].import([:a, :b], [[0, 1], [1, 2], [2, 3], [2, 3]])

    relations = parity_relations(@db)
    sql = relations[:odd].sql

    sql.scan(/\bWITH\b/).length.must_equal 1
    sql.must_include "_sequel_mutual_recursive_label"
    sql.must_include " UNION SELECT "
    sql.wont_include "UNION ALL"

    relations[:odd].order(:n).map(:n).must_equal [1, 3]
    relations[:even].order(:n).map(:n).must_equal [2]
  end

  it "matches a Ruby round-by-round fixed point" do
    @db.create_table(:edges) { Integer :a; Integer :b }
    edges = [[0, 1], [1, 2], [2, 3], [3, 4], [2, 3], [4, 4]]
    @db[:edges].import([:a, :b], edges)

    odd = {1 => true}
    even = {}
    changed = true
    while changed
      changed = false
      next_even = edges.each_with_object({}) do |(a, b), values|
        values[b] = true if odd.key?(a)
      end
      next_odd = edges.each_with_object({}) do |(a, b), values|
        values[b] = true if even.key?(a)
      end
      next_even.each_key { |n| changed ||= even[n].nil?; even[n] = true }
      next_odd.each_key { |n| changed ||= odd[n].nil?; odd[n] = true }
    end

    relations = parity_relations(@db)
    relations[:odd].order(:n).map(:n).must_equal odd.keys.sort
    relations[:even].order(:n).map(:n).must_equal even.keys.sort
  end

  it "terminates when a round produces no new tuples and deduplicates with UNION" do
    @db.create_table(:edges) { Integer :a; Integer :b }
    @db[:edges].import([:a, :b], [[0, 1], [1, 2], [1, 2], [2, 1], [2, 3], [3, 2]])

    relations = parity_relations(@db)
    relations[:odd].order(:n).map(:n).must_equal [1, 3]
    relations[:even].order(:n).map(:n).must_equal [2]
  end

  it "preserves NULL and row deduplication while projecting original columns" do
    @db.create_table(:edges) { Integer :a; Integer :b }
    @db[:edges].import([:a, :b], [[0, 1], [1, nil], [1, nil], [nil, 3], [3, nil]])

    relations = parity_relations(@db)
    relations[:odd].order(Sequel.desc(:n, :nulls=>:last)).map(:n).must_equal [1]
    relations[:even].order(:n).map(:n).must_equal [nil]
    relations[:odd].columns.must_equal [:n]
    relations[:even].columns.must_equal [:n]
  end

  it "supports relations with different arities and types using disjoint filled slots" do
    @db.create_table(:edges) { Integer :a; Integer :b }
    @db[:edges].import([:a, :b], [[0, 1], [1, 2], [10, 11]])
    @db.create_table(:things) { Integer :source; Integer :id; String :kind }
    @db[:things].import([:source, :id, :kind], [[1, 10, "ten"], [11, 20, "twenty"]])

    relations = @db.mutual_recursive(
      :odd => {
        :columns => [:n],
        :base => @db[:edges].where(:b => 1).select(Sequel[:b].as(:n)),
        :recursive => lambda do |r|
          @db[:edges].join(r[:even], r[:even][:id] => :a).
            select(Sequel[:b].as(:n))
        end
      },
      :even => {
        :columns => [:id, :kind],
        :recursive => lambda do |r|
          @db[:things].join(r[:odd], r[:odd][:n] => :source).
            select(Sequel[:id].as(:id), Sequel[:kind].as(:kind))
        end
      }
    )

    relations[:odd].order(:n).map(:n).must_equal [1, 11]
    relations[:even].order(:id).map { |row| [row[:id], row[:kind]] }.must_equal [[10, "ten"], [20, "twenty"]]
    relations[:odd].columns.must_equal [:n]
    relations[:even].columns.must_equal [:id, :kind]
  end

  it "raises before SQL generation when a recursive branch references no recursive relation" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => @db[:edges].select(Sequel[:b].as(:n))
        },
        :even => {
          :columns => [:n]
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/exactly one recursive relation/)
  end

  it "raises before SQL generation when a recursive branch uses aggregation" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda do |r|
            @db[:edges].join(r[:odd], r[:odd][:n] => :a).
              select(Sequel.function(:count).*.as(:n))
          end
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/aggregate function/)
  end

  it "raises before SQL generation when a recursive branch uses negation" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda do |r|
            @db[:edges].join(r[:odd], r[:odd][:n] => :a).
              exclude(:b => 1).
              select(Sequel[:b].as(:n))
          end
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/negation/)
  end

  it "raises before SQL generation when a recursive branch contains a compound dataset" do
    @db.create_table(:edges) { Integer :a; Integer :b }
    bad = @db[:edges].join(Sequel[:even], Sequel[:even][:n] => :a).
      select(Sequel[:b].as(:n)).
      union(@db[:edges].select(Sequel[:b].as(:n)), :from_self => false)

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda { |_| bad }
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/compound dataset/)
  end

  it "raises before SQL generation when a recursive relation uses an outer join" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda do |r|
            @db[:edges].left_join(r[:odd], r[:odd][:n] => :a).
              select(Sequel[:b].as(:n))
          end
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/INNER and CROSS joins/)
  end

  it "raises before SQL generation when a recursive relation appears in a subquery" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda do |r|
            @db[:edges].
              join(r[:odd], r[:odd][:n] => :a).
              where(:b => @db.from(r[:odd]).select(r[:odd][:n])).
              select(Sequel[:b].as(:n))
          end
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/subquery/)
  end

  it "raises before SQL generation when a recursive branch contains literal SQL" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda do |r|
            @db[:edges].join(r[:odd], Sequel.lit("1 = 1")).
              select(Sequel[:b].as(:n))
          end
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/literal SQL/)
  end

  it "raises before SQL generation when recursive references occur twice in one branch" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:b].as(:n)),
          :recursive => nil
        },
        :even => {
          :columns => [:n],
          :recursive => lambda do |r|
            @db[:edges].
              join(r[:odd], r[:odd][:n] => :a).
              join(r[:odd], r[:odd][:n] => :b).
              select(Sequel[:b].as(:n))
          end
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/exactly one recursive relation/)
  end

  it "raises before SQL generation when recursive relation arity is wrong" do
    @db.create_table(:edges) { Integer :a; Integer :b }

    proc do
      @db.mutual_recursive(
        :odd => {
          :columns => [:n],
          :base => @db[:edges].select(Sequel[:a].as(:a), Sequel[:b].as(:b)),
          :recursive => nil
        },
        :even => {
          :columns => [:n]
        }
      )
    end.must_raise(Sequel::Error).message.must_match(/explicitly select 1 columns/)
  end
end
