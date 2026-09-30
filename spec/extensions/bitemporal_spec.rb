# frozen_string_literal: true
require_relative "spec_helper"

describe "Sequel::Plugins::Bitemporal" do
  def self.sqlite_supported?
    require "sqlite3"
    true
  rescue LoadError
    false
  end

  if sqlite_supported?
    it "preserves both sides of a correction and answers current and earlier-known queries" do
      feb1 = Date.new(2026, 2, 1)
      feb15 = Date.new(2026, 2, 15)
      mar1 = Date.new(2026, 3, 1)
      db = Sequel.sqlite
      db.create_table(:integration_product_prices) do
        Integer :tenant_id, null: false
        Integer :product_id, null: false
        Integer :amount, null: false
        Date :valid_from, null: false
        Date :valid_to
        DateTime :system_from, null: false
        DateTime :system_to
        primary_key [:tenant_id, :product_id, :valid_from, :system_from]
      end

      model = Class.new(Sequel::Model(db[:integration_product_prices]))
      model.plugin :bitemporal, :key=>[:tenant_id, :product_id]

      model.record(:tenant_id=>3, :product_id=>7, :amount=>100, :valid_from=>feb1,
        :recorded_at=>Time.utc(2026, 2, 1))
      model.record(:tenant_id=>3, :product_id=>7, :amount=>120, :valid_from=>feb15,
        :valid_to=>mar1, :recorded_at=>Time.utc(2026, 2, 20))

      ds = model.where(:tenant_id=>3)
      ds.visible_at(feb15, Time.utc(2026, 2, 20)).get(:amount).must_equal 120
      ds.known_at(Time.utc(2026, 2, 1)).valid_at(feb15).get(:amount).must_equal 100
      ds.visible_at(mar1, Time.utc(2026, 2, 20)).get(:amount).must_equal 100
      ds.known_at(Time.utc(2026, 2, 1)).valid_at(mar1).get(:amount).must_equal 100

      current = ds.where(:system_to=>nil).order(:valid_from).all
      current.map { |row| [row.amount, row.valid_from, row.valid_to] }.must_equal [
        [100, feb1, feb15],
        [120, feb15, mar1],
        [100, mar1, nil],
      ]
    end
  end

  before do
    @db = Sequel.mock(:numrows=>1, :autoid=>proc{10})
    def @db.schema(*) [[:id, {:primary_key=>true}]] end
    def @db.supports_schema_parsing?() true end
    @model = Class.new(Sequel::Model(@db[:product_prices]))
    @model.class_eval do
      columns :id, :product_id, :amount, :valid_from, :valid_to,
        :system_from, :system_to
      plugin :bitemporal, :key=>:product_id
    end

    @jan1 = Date.new(2026, 1, 1)
    @feb1 = Date.new(2026, 2, 1)
    @feb15 = Date.new(2026, 2, 15)
    @mar1 = Date.new(2026, 3, 1)
    @system_feb1 = Time.utc(2026, 2, 1, 9)
    @system_feb20 = Time.utc(2026, 2, 20, 9)
  end

  def row(overrides={})
    {
      :id=>1,
      :product_id=>7,
      :amount=>100,
      :valid_from=>Date.new(2026, 1, 1),
      :valid_to=>nil,
      :system_from=>Time.utc(2026, 1, 1, 9),
      :system_to=>nil,
    }.merge(overrides)
  end

  it "filters system and business intervals with half-open semantics" do
    sql = @model.known_at(@system_feb1).valid_at(@feb15).sql
    sql.must_include "(product_prices.system_from <= '2026-02-01 09:00:00.000000')"
    sql.must_include "((product_prices.system_to > '2026-02-01 09:00:00.000000') OR (product_prices.system_to IS NULL))"
    sql.must_include "(product_prices.valid_from <= '2026-02-15')"
    sql.must_include "((product_prices.valid_to > '2026-02-15') OR (product_prices.valid_to IS NULL))"
  end

  it "supports asking for the value visible at one business time from an earlier system time" do
    sql = @model.visible_at(@mar1, @system_feb1).sql
    sql.must_equal @model.known_at(@system_feb1).valid_at(@mar1).sql
    sql.must_equal @model.as_of(@system_feb1).during(@mar1).sql
  end

  it "closes overlapping versions and preserves both unaffected sides" do
    @db.fetch = [[row], [row(
      :id=>10,
      :amount=>120,
      :valid_from=>@feb15,
      :valid_to=>@mar1,
      :system_from=>@system_feb20)]]

    result = @model.record(:product_id=>7, :amount=>120,
      :valid_from=>@feb15, :valid_to=>@mar1, :recorded_at=>@system_feb20)

    result.must_equal @model.load(row(
      :id=>10,
      :amount=>120,
      :valid_from=>@feb15,
      :valid_to=>@mar1,
      :system_from=>@system_feb20))
    @db.sqls.must_equal [
      "BEGIN",
      "SELECT * FROM product_prices WHERE (product_id = 7) FOR UPDATE",
      "UPDATE product_prices SET system_to = '2026-02-20 09:00:00.000000' WHERE (id = 1)",
      "INSERT INTO product_prices (product_id, amount, valid_from, valid_to, system_from, system_to) VALUES (7, 100, '2026-01-01', '2026-02-15', '2026-02-20 09:00:00.000000', NULL)",
      "INSERT INTO product_prices (product_id, amount, valid_from, valid_to, system_from, system_to) VALUES (7, 100, '2026-03-01', NULL, '2026-02-20 09:00:00.000000', NULL)",
      "INSERT INTO product_prices (product_id, amount, valid_from, valid_to, system_from, system_to) VALUES (7, 120, '2026-02-15', '2026-03-01', '2026-02-20 09:00:00.000000', NULL)",
      "SELECT * FROM product_prices WHERE id = 10",
      "COMMIT",
    ]
  end

  it "does not split at a touching half-open interval boundary" do
    existing = row(:valid_from=>@jan1, :valid_to=>@feb1)
    @db.fetch = [[existing], [row(
      :id=>10,
      :amount=>120,
      :valid_from=>@feb1,
      :system_from=>@system_feb1)]]

    @model.record(:product_id=>7, :amount=>120,
      :valid_from=>@feb1, :recorded_at=>@system_feb1)

    @db.sqls.must_equal [
      "BEGIN",
      "SELECT * FROM product_prices WHERE (product_id = 7) FOR UPDATE",
      "INSERT INTO product_prices (product_id, amount, valid_from, valid_to, system_from, system_to) VALUES (7, 120, '2026-02-01', NULL, '2026-02-01 09:00:00.000000', NULL)",
      "SELECT * FROM product_prices WHERE id = 10",
      "COMMIT",
    ]
  end

  it "rolls back splitting and insertion when a later statement fails" do
    @db.fetch = [[row]]
    def @db.execute_insert(sql, opts=Sequel::OPTS, &block)
      raise StandardError, "insert failed" if sql.include?("'2026-01-01', '2026-02-15'")
      super
    end

    proc do
      @model.record(:product_id=>7, :amount=>120,
        :valid_from=>@feb15, :valid_to=>@mar1, :recorded_at=>@system_feb20)
    end.must_raise StandardError

    @db.sqls.must_equal [
      "BEGIN",
      "SELECT * FROM product_prices WHERE (product_id = 7) FOR UPDATE",
      "UPDATE product_prices SET system_to = '2026-02-20 09:00:00.000000' WHERE (id = 1)",
      "ROLLBACK",
    ]
  end

  it "uses a savepoint when recording inside an existing transaction" do
    @db.fetch = [[], [row(
      :id=>10,
      :amount=>120,
      :valid_from=>@feb1,
      :system_from=>@system_feb1)]]

    @db.transaction do
      @model.record(:product_id=>7, :amount=>120,
        :valid_from=>@feb1, :recorded_at=>@system_feb1)
    end

    sqls = @db.sqls
    sqls.must_include "SAVEPOINT autopoint_1"
    sqls.must_include "RELEASE SAVEPOINT autopoint_1"
  end

  it "rejects overlapping current versions for the same entity" do
    @db.fetch = [[
      row(:id=>1, :valid_from=>@feb1, :valid_to=>@mar1),
      row(:id=>2, :valid_from=>@feb15, :valid_to=>nil),
    ]]

    proc do
      @model.record(:product_id=>7, :amount=>120,
        :valid_from=>@mar1, :recorded_at=>@system_feb20)
    end.must_raise Sequel::Plugins::Bitemporal::Error
    @db.sqls.must_equal [
      "BEGIN",
      "SELECT * FROM product_prices WHERE (product_id = 7) FOR UPDATE",
      "ROLLBACK",
    ]
  end

  it "allows revisions at the same system time but rejects out-of-order system time" do
    @db.fetch = [[
      row(:id=>1, :system_to=>@system_feb1),
      row(:id=>2, :valid_from=>@feb15, :system_from=>@system_feb1),
    ], row(:id=>10, :amount=>120, :valid_from=>@mar1,
      :system_from=>@system_feb1)]

    @model.record(:product_id=>7, :amount=>120,
      :valid_from=>@mar1, :recorded_at=>@system_feb1)

    @db.fetch = [[
      row(:id=>1, :system_to=>@system_feb1),
      row(:id=>2, :valid_from=>@feb15, :system_from=>@system_feb1),
    ]]
    proc do
      @model.record(:product_id=>7, :amount=>120,
        :valid_from=>@mar1, :recorded_at=>Time.utc(2026, 1, 31))
    end.must_raise Sequel::Plugins::Bitemporal::Error
  end

  it "requires an entity key and a non-empty half-open business interval" do
    @db.fetch = []

    proc do
      @model.record(:amount=>120, :valid_from=>@feb1, :recorded_at=>@system_feb1)
    end.must_raise Sequel::Plugins::Bitemporal::Error
    proc do
      @model.record(:product_id=>7, :amount=>120,
        :valid_from=>@mar1, :valid_to=>@feb1, :recorded_at=>@system_feb1)
    end.must_raise Sequel::Plugins::Bitemporal::Error
  end

  it "requires all composite entity key columns" do
    @db.fetch = []
    model = Class.new(Sequel::Model(@db[:tenant_product_prices]))
    model.class_eval do
      columns :id, :tenant_id, :product_id, :amount, :valid_from, :valid_to,
        :system_from, :system_to
      plugin :bitemporal, :key=>[:tenant_id, :product_id]
    end

    proc do
      model.record(:product_id=>7, :amount=>120,
        :valid_from=>@feb1, :recorded_at=>@system_feb1)
    end.must_raise Sequel::Plugins::Bitemporal::Error
  end

  it "does not allow updating or destroying model rows, because history is append-only" do
    object = @model.load(row)
    proc { object.update(:amount=>120) }.must_raise Sequel::Plugins::Bitemporal::Error
    proc { object.destroy }.must_raise Sequel::Plugins::Bitemporal::Error
  end
end
