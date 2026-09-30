# frozen_string_literal: true
require_relative "spec_helper"

describe "Sequel::Plugins::Bitemporal" do
  before do
    @db = Sequel.sqlite
    @db.create_table :prices do
      primary_key :id
      Integer :product_id, null: false
      Integer :amount, null: false
      Time :valid_from, null: false
      Time :valid_to
      Time :system_from, null: false
      Time :system_to
    end

    @price = Class.new(Sequel::Model(@db[:prices]))
    @price.plugin :bitemporal, entity: :product_id
  end

  def utc_time(year, month, day)
    Time.utc(year, month, day)
  end

  def amount(product, valid_at, known_at=nil)
    return @price.current.visible_at(valid_at).get(:amount) if known_at.nil?
    @price.known_at(known_at).valid_at(valid_at).get(:amount)
  end

  it "distinguishes the expected future price from the later actual price" do
    jan25 = utc_time(2026, 1, 25)
    jan31 = utc_time(2026, 1, 31)
    feb1 = utc_time(2026, 2, 1)
    feb20 = utc_time(2026, 2, 20)
    mar1 = utc_time(2026, 3, 1)

    @price.record(product_id: 1, amount: 10, valid_from: feb1, record_at: jan25)
    @price.record(product_id: 1, amount: 12, valid_from: feb1, valid_to: mar1, record_at: feb20)

    @price.visible_at(feb1, known_at: jan31).get(:amount).must_equal 10
    amount(1, feb1).must_equal 12
    amount(1, feb1, feb20).must_equal 12
  end

  it "preserves unaffected portions of a revised interval" do
    jan1 = utc_time(2026, 1, 1)
    feb1 = utc_time(2026, 2, 1)
    mar1 = utc_time(2026, 3, 1)
    apr1 = utc_time(2026, 4, 1)

    @price.record(product_id: 1, amount: 10, valid_from: jan1, valid_to: apr1, record_at: jan1)
    @price.record(product_id: 1, amount: 12, valid_from: feb1, valid_to: mar1, record_at: feb1)

    amount(1, jan1).must_equal 10
    amount(1, feb1).must_equal 12
    amount(1, mar1).must_equal 10
    amount(1, jan1, jan1 + 1).must_equal 10
    amount(1, feb1, jan1 + 1).must_equal 10
    amount(1, feb1, feb1).must_equal 12
    @price.where(product_id: 1).count.must_equal 4
  end

  it "uses half-open interval boundaries" do
    jan1 = utc_time(2026, 1, 1)
    feb1 = utc_time(2026, 2, 1)

    @price.record(product_id: 1, amount: 10, valid_from: jan1, valid_to: feb1, record_at: jan1)
    @price.record(product_id: 1, amount: 12, valid_from: feb1, record_at: jan1)

    amount(1, jan1).must_equal 10
    amount(1, feb1).must_equal 12
  end

  it "accepts a model instance without manual system interval columns" do
    at = utc_time(2026, 1, 1)
    price = @price.new(product_id: 1, amount: 10, valid_from: at)

    @price.record(price).must_be_kind_of Array
    amount(1, at).must_equal 10
  end

  it "backfills last month's adjustment while retaining the prior belief" do
    jan25 = utc_time(2026, 1, 25)
    feb1 = utc_time(2026, 2, 1)
    mar1 = utc_time(2026, 3, 1)
    mar5 = utc_time(2026, 3, 5)

    @price.record(product_id: 1, amount: 10, valid_from: feb1, record_at: jan25)
    @price.record(product_id: 1, amount: 9, valid_from: feb1, valid_to: mar1, record_at: mar5)

    amount(1, feb1, mar1).must_equal 10
    amount(1, feb1).must_equal 9
    amount(1, mar1).must_equal 10
    @price.known_at(mar5).valid_at(feb1).get(:amount).must_equal 9
  end

  it "rejects overlapping intervals for one entity at the same system time" do
    jan1 = utc_time(2026, 1, 1)
    feb1 = utc_time(2026, 2, 1)
    mar1 = utc_time(2026, 3, 1)

    @price.record(product_id: 1, amount: 10, valid_from: jan1, valid_to: mar1, record_at: jan1)

    proc do
      @price.record(product_id: 1, amount: 12, valid_from: feb1, record_at: jan1)
    end.must_raise Sequel::Plugins::Bitemporal::OverlapError

    amount(1, feb1).must_equal 10
  end

  it "leaves no partial changes when the write fails" do
    jan1 = utc_time(2026, 1, 1)
    feb1 = utc_time(2026, 2, 1)
    mar1 = utc_time(2026, 3, 1)

    @price.record(product_id: 1, amount: 10, valid_from: jan1, valid_to: mar1, record_at: jan1)

    proc do
      @price.record(product_id: 1, amount: 12, valid_from: feb1, valid_to: jan1, record_at: feb1)
    end.must_raise Sequel::Plugins::Bitemporal::Error

    @price.where(product_id: 1).map(:amount).must_equal [10]
  end

  it "performs splitting and insertion in a transaction" do
    db = Sequel.mock(:autoid=>proc{1}, :numrows=>1)
    db.fetch = [[], [], [], []]
    price = Class.new(Sequel::Model(db[:prices]))
    price.class_eval do
      columns :id, :product_id, :amount, :valid_from, :valid_to, :system_from, :system_to
      plugin :bitemporal, entity: :product_id
    end

    db.sqls
    at = utc_time(2026, 2, 1)
    price.record(product_id: 1, amount: 12, valid_from: at, record_at: at)
    sqls = db.sqls

    sqls.first.must_equal "BEGIN"
    sqls.last.must_equal "COMMIT"
  end

  it "rolls back all changes when a split write fails" do
    jan1 = utc_time(2026, 1, 1)
    feb1 = utc_time(2026, 2, 1)
    mar1 = utc_time(2026, 3, 1)

    @price.record(product_id: 1, amount: 10, valid_from: jan1, valid_to: mar1, record_at: jan1)
    writes = 0
    original_execute_insert = @db.method(:execute_insert)
    @db.define_singleton_method(:execute_insert) do |sql, opts={}|
      writes += 1
      raise Sequel::DatabaseError, "split failed" if writes == 2
      original_execute_insert.call(sql, opts)
    end

    proc do
      @price.record(product_id: 1, amount: 12, valid_from: feb1, record_at: feb1)
    end.must_raise Sequel::DatabaseError

    @price.where(product_id: 1).map(:amount).must_equal [10]
  end

  it "raises validation failures before opening the write transaction" do
    at = utc_time(2026, 1, 1)
    db = Sequel.mock(:autoid=>proc{1}, :numrows=>1)
    price = Class.new(Sequel::Model(db[:prices])) do
      columns :id, :product_id, :amount, :valid_from, :valid_to, :system_from, :system_to

      def validate
        errors.add(:amount, "is required") if amount.nil?
      end
    end
    price.plugin :bitemporal, entity: :product_id
    db.sqls

    proc do
      price.record(product_id: 1, valid_from: at, record_at: at)
    end.must_raise Sequel::HookFailed

    db.sqls.must_equal []
  end
end
