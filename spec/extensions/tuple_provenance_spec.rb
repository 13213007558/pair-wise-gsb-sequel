# frozen_string_literal: true
require_relative "spec_helper"

begin
  require "sqlite3"
rescue LoadError
  nil
end

if defined?(SQLite3)
describe "tuple_provenance extension" do
  before do
    @db = Sequel.sqlite
    @db.extension(:tuple_provenance)
    @db.create_table(:items){primary_key :id; String :name}
    @db.create_table(:orders){primary_key :id; Integer :item_id; Integer :qty}
    @db[:items].import([:id, :name], [[1, "a"], [2, "b"]])
    @db[:orders].import([:id, :item_id, :qty], [[1, 1, 10], [2, 1, 20], [3, 2, 5]])
  end

  after do
    @db.disconnect
  end

  def terms(provenance)
    provenance.split("+").sort
  end

  it "tracks provenance through selection and projection" do
    ds = @db[:orders].where{qty > 5}.select(:qty)
    ds.with_tuple_provenance.order(:qty).all.must_equal [
      {qty: 10, tuple_provenance: "orders[1]"},
      {qty: 20, tuple_provenance: "orders[2]"}
    ]
  end

  it "multiplies provenance for inner joins" do
    ds = @db[:items].join(:orders, item_id: :id).select(:name, :qty)
    ds.with_tuple_provenance.order(:name, :qty).all.must_equal [
      {name: "a", qty: 10, tuple_provenance: "items[1]*orders[1]"},
      {name: "a", qty: 20, tuple_provenance: "items[1]*orders[2]"},
      {name: "b", qty: 5, tuple_provenance: "items[2]*orders[3]"}
    ]
  end

  it "adds provenance for duplicate derivations of the same tuple" do
    rows = @db[:orders].select(:item_id).with_tuple_provenance.order(:item_id).all
    rows.map{|r| terms(r[:tuple_provenance])}.must_equal [
      ["orders[1]", "orders[2]"],
      ["orders[3]"]
    ]
  end

  it "adds provenance across UNION ALL branches" do
    ds = @db[:items].where(id: 1).select(:name).
      union(@db[:items].where(id: 1).select(:name), all: true)
    rows = ds.with_tuple_provenance.all
    rows.length.must_equal 1
    rows[0][:name].must_equal "a"
    terms(rows[0][:tuple_provenance]).must_equal ["items[1]", "items[1]"]
  end

  it "supports UNION ALL over different base tables" do
    ds = @db[:items].where(id: 1).select(:name).
      union(@db[:items].where(id: 2).select(:name), all: true)
    rows = ds.with_tuple_provenance.order(:name).all
    rows.map{|r| r[:tuple_provenance]}.must_equal ["items[1]", "items[2]"]
  end

  it "matches plain result multiplicities in provenance term counts" do
    ds = @db[:items].join(:orders, item_id: :id).where{qty > 5}.select(:name)
    plain_counts = Hash.new(0)
    ds.all.each{|r| plain_counts[r[:name]] += 1}
    ds.with_tuple_provenance.all.each do |row|
      row[:tuple_provenance].split("+").length.must_equal plain_counts[row[:name]]
    end
  end

  it "predicts result multiplicity changes when a base row is deleted" do
    ds = @db[:items].join(:orders, item_id: :id).where{qty > 5}.select(:name)
    plain_before = ds.all.length
    provenance = ds.with_tuple_provenance.all.map{|r| r[:tuple_provenance]}.join("+")

    # The provenance expression predicts that deleting orders[2] removes
    # exactly one result row, and deleting items[1] removes two.
    orders_removed = provenance.scan("orders[2]").length
    items_removed = provenance.scan("items[1]").length
    orders_removed.must_equal 1
    items_removed.must_equal 2

    @db[:orders].where(id: 2).delete
    ds.all.length.must_equal plain_before - orders_removed

    @db[:items].where(id: 1).delete
    ds.all.length.must_equal plain_before - orders_removed - (items_removed - orders_removed)
  end

  it "uses rowid as stable identifier for tables without a primary key on SQLite" do
    @db.create_table(:logs){String :msg}
    @db[:logs].insert("x")
    @db[:logs].insert("x")
    rows = @db[:logs].select(:msg).with_tuple_provenance.all
    rows.length.must_equal 1
    terms(rows[0][:tuple_provenance]).must_equal ["logs[1]", "logs[2]"]
  end

  it "supports composite primary keys" do
    @db.create_table(:pairs){Integer :a; Integer :b; primary_key [:a, :b]}
    @db[:pairs].insert(1, 2)
    @db[:pairs].select(:b).with_tuple_provenance.first[:tuple_provenance].must_equal "pairs[1,2]"
  end

  it "supports aliased base tables" do
    ds = @db.from(Sequel[:items].as(:i)).where(Sequel[:i][:id] => 1).select(Sequel[:i][:name])
    ds.with_tuple_provenance.first[:tuple_provenance].must_equal "items[1]"
  end

  it "supports subqueries in FROM built from supported operations" do
    ds = @db.from(@db[:orders].where{qty > 5}.as(:o)).select(:qty)
    ds.with_tuple_provenance.order(:qty).all.must_equal [
      {qty: 10, tuple_provenance: "orders[1]"},
      {qty: 20, tuple_provenance: "orders[2]"}
    ]

    ds = @db.from(@db[:orders].where{qty > 15}).select(:qty)
    ds.with_tuple_provenance.all.must_equal [
      {qty: 20, tuple_provenance: "orders[2]"}
    ]
  end

  it "works when loaded as a dataset extension" do
    ds = @db[:orders].extension(:tuple_provenance).where(id: 3).select(:qty)
    ds.with_tuple_provenance.first[:tuple_provenance].must_equal "orders[3]"
  end

  it "raises Sequel::InvalidOperation for aggregation" do
    proc{@db[:orders].group(:item_id).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    proc{@db[:orders].having{qty > 5}.with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    proc{@db[:orders].select(Sequel.function(:count, :id)).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
  end

  it "raises Sequel::InvalidOperation for EXCEPT, INTERSECT, and plain UNION" do
    proc{@db[:orders].except(@db[:orders]).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    proc{@db[:orders].intersect(@db[:orders]).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    proc{@db[:orders].union(@db[:orders]).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
  end

  it "raises Sequel::InvalidOperation for other unsupported constructs" do
    [
      @db[:orders].distinct,
      @db[:orders].limit(1),
      @db[:orders].offset(1),
      @db[:orders].order(:id),
      @db[:items].left_join(:orders, item_id: :id),
      @db[:orders].where(item_id: @db[:items].select(:id)),
      @db[:orders].where(Sequel.lit("qty > ?", 5)),
      @db[:orders].select(Sequel[:qty] + 1),
      @db.select(1)
    ].each do |ds|
      proc{ds.with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    end
  end

  it "raises Sequel::InvalidOperation with a descriptive message" do
    e = proc{@db[:orders].group(:item_id).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    e.message.must_equal "tuple provenance does not support GROUP BY"
    e = proc{@db[:orders].except(@db[:orders]).with_tuple_provenance}.must_raise(Sequel::InvalidOperation)
    e.message.must_equal "tuple provenance only supports UNION ALL compound queries, not EXCEPT"
  end
end
end
