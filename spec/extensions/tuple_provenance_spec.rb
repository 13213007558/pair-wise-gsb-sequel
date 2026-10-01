# frozen_string_literal: true
require_relative "spec_helper"

describe "tuple_provenance extension" do
  before do
    @db = Sequel.sqlite
    @db.create_table(:items) do
      primary_key :id
      String :kind
      Integer :amount
    end
    @db.create_table(:tags) do
      primary_key :id
      Integer :item_id
      String :label
    end
    @db.create_table(:others) do
      primary_key :id
      Integer :amount
    end

    @db[:items].multi_insert([
      {id: 1, kind: "x", amount: 10},
      {id: 2, kind: "x", amount: 20},
      {id: 3, kind: "y", amount: 20}
    ])
    @db[:tags].multi_insert([
      {id: 10, item_id: 1, label: "a"},
      {id: 11, item_id: 2, label: "a"},
      {id: 12, item_id: 2, label: "b"}
    ])
    @db[:others].multi_insert([
      {id: 20, amount: 10},
      {id: 21, amount: 20}
    ])

    @keys = {items: :id, tags: :id, others: :id}
  end

  def with_provenance(dataset, keys = @keys)
    dataset.extension(:tuple_provenance).with_tuple_provenance(keys)
  end

  def occurrence_count(polynomial, relation, id)
    polynomial.terms.sum do |monomial, coefficient|
      variable = monomial.variables.find { |candidate| candidate.relation == relation }
      variable && variable.key[:id] == id ? coefficient : 0
    end
  end

  it "annotates selection and projection with the originating base row" do
    plain = @db[:items].where(kind: "x").select(:amount).all
    annotated = with_provenance(@db[:items].where(kind: "x").select(:amount)).all

    annotated.map { |row| row.reject { |key| key == :_tuple_provenance } }.must_equal plain
    annotated.map { |row| row[:_tuple_provenance].to_s }.must_equal [
      "items[id=1]",
      "items[id=2]"
    ]
  end

  it "multiplies provenance for inner joins" do
    query = @db[:items].
      inner_join(:tags, item_id: :id).
      where(label: "a").
      select(:amount)
    plain = query.all
    provenance = with_provenance(query).tuple_provenance

    provenance.keys.must_equal plain
    provenance[{amount: 10}].to_s.must_equal "items[id=1] * tags[id=10]"
    provenance[{amount: 20}].to_s.must_equal "items[id=2] * tags[id=11]"
  end

  it "distinguishes occurrences in a self-join using aliases" do
    left = Sequel[:items].as(:left_items)
    right = Sequel[:items].as(:right_items)
    query = @db.from(left).
      inner_join(right, Sequel[:right_items][:amount] => Sequel[:left_items][:amount]).
      select(Sequel[:left_items][:id])
    keys = {left_items: :id, right_items: :id}

    with_provenance(query, keys).tuple_provenance[{id: 2}].to_s.
      must_equal "left_items[id=2] * right_items[id=2] + left_items[id=2] * right_items[id=3]"
  end

  it "adds provenance for the multiple derivations produced by UNION ALL" do
    query = @db[:items].where(kind: "x").select(:amount).
      union(@db[:others].where(amount: 20).select(:amount), all: true, from_self: false)
    plain = query.all
    provenance = with_provenance(query).tuple_provenance

    provenance.keys.must_equal plain.uniq
    provenance[{amount: 10}].to_s.must_equal "items[id=1]"
    provenance[{amount: 20}].to_s.must_equal "items[id=2] + others[id=21]"
  end

  it "preserves duplicate derivations as polynomial coefficients" do
    query = @db[:items].where(kind: "x").select(:amount).
      union(@db[:items].where(id: 2).select(:amount), all: true, from_self: false)

    with_provenance(query).tuple_provenance[{amount: 20}].to_s.
      must_equal "2 * items[id=2]"
  end

  it "supports the default wrapped UNION ALL dataset" do
    query = @db[:items].where(kind: "x").select(:amount).
      union(@db[:others].where(amount: 10).select(:amount), all: true)

    with_provenance(query).tuple_provenance[{amount: 10}].to_s.
      must_equal "items[id=1] + others[id=20]"
  end

  it "predicts the multiplicity change when a base row is deleted" do
    query = @db[:items].
      inner_join(:tags, item_id: :id).
      where(label: "a").
      select(:amount)
    provenance = with_provenance(query).tuple_provenance
    before = plain_output_counts(query)

    @db[:items].where(id: 2).delete
    after = plain_output_counts(query)

    before.each do |row, count|
      predicted = count - occurrence_count(provenance.fetch(row), :items, 2)
      after.fetch(row, 0).must_equal predicted
    end
  end

  it "rejects aggregation before executing a query" do
    query = with_provenance(@db[:items].group(:kind).select(:kind))

    proc { query.sql }.must_raise Sequel::InvalidOperation
  end

  it "rejects aggregate functions before executing a query" do
    query = with_provenance(@db[:items]).select { count(:id) }

    proc { query.sql }.must_raise Sequel::InvalidOperation
  end

  it "rejects EXCEPT queries before executing a query" do
    query = @db[:items].select(:amount).
      except(@db[:others].select(:amount), from_self: false)

    proc { with_provenance(query).sql }.must_raise Sequel::InvalidOperation
  end

  it "rejects unsupported outer joins before executing a query" do
    query = @db[:items].left_join(:tags, item_id: :id)

    proc { with_provenance(query).sql }.must_raise Sequel::InvalidOperation
  end

  it "rejects implicit projections over joins before executing a query" do
    query = @db[:items].inner_join(:tags, item_id: :id)

    proc { with_provenance(query).sql }.must_raise Sequel::InvalidOperation
  end

  it "rejects literal SQL expressions before executing a query" do
    query = with_provenance(@db[:items]).where(Sequel.lit("kind = 'x'"))

    proc { query.sql }.must_raise Sequel::InvalidOperation
  end

  def plain_output_counts(query)
    query.all.group_by(&:itself).transform_values(&:length)
  end
end
