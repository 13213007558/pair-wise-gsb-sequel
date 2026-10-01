# frozen_string_literal: true
require_relative "spec_helper"
Sequel.extension :keyset_pagination

describe Sequel::KeysetPagination do
  before do
    @db = Sequel.mock
    @orders = [
      Sequel.desc(:priority, :nulls=>:last),
      Sequel.asc(:created_at, :nulls=>:last),
      Sequel.asc(:id, :nulls=>:last)
    ]
    @ds = @db[:items].extension(:keyset_pagination).order(*@orders)
    @secret = "cursor-secret"
  end

  it "returns the first page without an offset or count query" do
    page = @ds.keyset_paginate(2, :cursor_secret=>@secret)

    page.records.must_equal []
    page.has_previous_page?.must_equal false
    page.has_next_page?.must_equal false
    page.before_cursor.must_be_nil
    page.after_cursor.must_be_nil
    @db.sqls.must_equal [
      "SELECT * FROM items ORDER BY priority DESC NULLS LAST, created_at ASC NULLS LAST, id ASC NULLS LAST LIMIT 3"
    ]
  end

  it "builds a forward seek predicate for typed cursor values" do
    cursor = cursor_for(:priority=>2, :created_at=>"2026-01-01 00:00:00", :id=>1)
    @ds.keyset_paginate(2, :after=>cursor, :cursor_secret=>@secret)

    sql = @db.sqls.last
    sql.must_include "((priority < 2) OR (priority IS NULL))"
    sql.must_include "(priority = 2) AND ((created_at > '2026-01-01 00:00:00') OR (created_at IS NULL))"
    sql.must_include "(priority = 2) AND (created_at = '2026-01-01 00:00:00') AND (id > 1)"
  end

  it "builds a reversed seek predicate for the previous page while returning records in original order" do
    cursor = cursor_for(:priority=>2, :created_at=>"2026-01-01 00:00:00", :id=>1)
    @ds.keyset_paginate(2, :before=>cursor, :cursor_secret=>@secret)

    @db.sqls.last.must_equal "SELECT * FROM items WHERE (((priority > 2)) OR ((priority = 2) AND (created_at < '2026-01-01 00:00:00')) OR ((priority = 2) AND (created_at = '2026-01-01 00:00:00') AND (id < 1))) ORDER BY priority ASC NULLS FIRST, created_at DESC NULLS FIRST, id DESC NULLS FIRST LIMIT 3"
  end

  it "handles NULL cursor values according to the ordered NULLS position" do
    cursor = cursor_for(:priority=>nil, :created_at=>"2026-01-01 00:00:00", :id=>4)
    @ds.keyset_paginate(2, :after=>cursor, :cursor_secret=>@secret)

    sql = @db.sqls.last
    sql.must_include "(priority IS NULL) AND ((created_at > '2026-01-01 00:00:00') OR (created_at IS NULL))"
    sql.must_include "(priority IS NULL) AND (created_at = '2026-01-01 00:00:00') AND (id > 4)"
  end

  it "rejects invalid cursor formats and cursors signed with another secret" do
    cursor = cursor_for(:priority=>2, :created_at=>"t", :id=>1)

    proc{@ds.keyset_paginate(2, :after=>"not-base64!", :cursor_secret=>@secret)}.must_raise Sequel::InvalidValue
    proc{@ds.keyset_paginate(2, :after=>cursor, :cursor_secret=>"other")}.must_raise Sequel::InvalidValue
  end

  it "rejects cursors whose bound sort definition does not match the dataset" do
    cursor = cursor_for(:priority=>2, :created_at=>"t", :id=>1)
    changed = @ds.order(Sequel.desc(:priority, :nulls=>:first), Sequel.asc(:created_at, :nulls=>:last), Sequel.asc(:id, :nulls=>:last))

    proc{changed.keyset_paginate(2, :after=>cursor, :cursor_secret=>@secret)}.must_raise Sequel::InvalidValue
  end

  it "rejects cursors whose ordered column set does not match the dataset" do
    cursor = cursor_for(:priority=>2, :created_at=>"t", :id=>1)
    changed = @ds.order(Sequel.desc(:other, :nulls=>:last), Sequel.asc(:created_at, :nulls=>:last), Sequel.asc(:id, :nulls=>:last))

    proc{changed.keyset_paginate(2, :after=>cursor, :cursor_secret=>@secret)}.must_raise Sequel::InvalidValue
  end

  it "preserves typed cursor values across encoding and decoding" do
    timestamp = DateTime.strptime("2026-01-02T03:04:05.678+08:00", "%Y-%m-%dT%H:%M:%S.%L%z")
    cursor = cursor_for(:priority=>BigDecimal("2.5"), :created_at=>timestamp, :id=>9)
    values = Sequel::KeysetPagination::CursorCodec.new(@ds, @orders, :id, @secret).decode(cursor)

    values[0].must_equal BigDecimal("2.5")
    values[1].must_equal timestamp
    values[2].must_equal 9
    values[1].sec_fraction.must_equal Rational(678, 1000)
  end

  it "requires explicit NULLS handling and a final stable unique key" do
    proc{@db[:items].extension(:keyset_pagination).order(:priority, :id).keyset_paginate(2, :cursor_secret=>@secret)}.must_raise Sequel::Error
    proc{@db[:items].extension(:keyset_pagination).order(Sequel.desc(:priority, :nulls=>:last)).keyset_paginate(2, :cursor_secret=>@secret)}.must_raise Sequel::Error
    proc{@db[:items].extension(:keyset_pagination).order(Sequel.desc(Sequel.cast(:priority, Integer), :nulls=>:last), Sequel.asc(:id, :nulls=>:last)).keyset_paginate(2, :cursor_secret=>@secret)}.must_raise Sequel::Error
    proc{@db[:items].extension(:keyset_pagination).order(Sequel.desc(:priority, :nulls=>:last), Sequel.asc(Sequel.as(:id, :identifier), :nulls=>:last)).keyset_paginate(2, :cursor_secret=>@secret)}.must_raise Sequel::Error
  end

  it "supports aliased ordered columns and uses the alias as the row key" do
    db = Sequel.mock(:fetch=>{:p=>1, :created_at=>"t", :id=>2})
    ds = db[:items].extension(:keyset_pagination).order(Sequel.desc(Sequel.as(:priority, :p), :nulls=>:last), Sequel.asc(:created_at, :nulls=>:last), Sequel.asc(:id, :nulls=>:last))
    page = ds.keyset_paginate(1, :cursor_secret=>@secret)

    page.after_cursor.must_be_kind_of String
  end

  it "supports a configured non-id stable unique key" do
    db = Sequel.mock(:fetch=>[])
    ds = db[:items].extension(:keyset_pagination).order(Sequel.desc(:priority, :nulls=>:last), Sequel.asc(:created_at, :nulls=>:last), Sequel.asc(:uuid, :nulls=>:last))

    page = ds.keyset_paginate(2, :unique_key=>:uuid, :cursor_secret=>@secret)
    page.records.must_equal []
  end

  it "filters on the expression behind an aliased ordered column" do
    db = Sequel.mock(:fetch=>{:p=>1, :created_at=>"t", :id=>2})
    orders = [
      Sequel.desc(Sequel.as(Sequel[:priority] + 0, :p), :nulls=>:last),
      Sequel.asc(:created_at, :nulls=>:last),
      Sequel.asc(:id, :nulls=>:last)
    ]
    ds = db[:items].extension(:keyset_pagination).order(*orders)
    codec = Sequel::KeysetPagination::CursorCodec.new(ds, orders, :id, @secret)
    cursor = codec.encode([codec.typed_value(1), codec.typed_value("t"), codec.typed_value(2)])
    ds.keyset_paginate(1, :after=>cursor, :cursor_secret=>@secret)

    db.sqls.last.must_include "((priority + 0) < 1)"
  end

  private

  def cursor_for(values)
    codec = Sequel::KeysetPagination::CursorCodec.new(@ds, @orders, :id, @secret)
    codec.encode(@orders.map do |order|
      codec.typed_value(values[Sequel::KeysetPagination::CursorCodec.row_key(order.expression)])
    end)
  end
end

begin
  gem "sqlite3"
  require "sqlite3"
  class KeysetQueryLogger
    attr_reader :messages

    def initialize
      @messages = []
    end

    def info(message)
      @messages << message
    end
  end

  describe "Sequel::KeysetPagination with sqlite" do
    before do
      @db = Sequel.sqlite
      @db.create_table!(:items) do
        primary_key :id
        Integer :priority
        String :created_at
      end
      @orders = [
        Sequel.desc(:priority, :nulls=>:last),
        Sequel.asc(:created_at, :nulls=>:last),
        Sequel.asc(:id, :nulls=>:last)
      ]
      @ds = @db[:items].extension(:keyset_pagination).order(*@orders)
      @secret = "cursor-secret"
      @logger = KeysetQueryLogger.new
      @db.loggers = [@logger]
      @db[:items].multi_insert([
        {:priority=>2, :created_at=>"2026-01-01T00:00:00Z"},
        {:priority=>1, :created_at=>"2026-01-01T00:00:00Z"},
        {:priority=>1, :created_at=>"2026-01-01T00:00:00Z"},
        {:priority=>nil, :created_at=>"2026-01-01T00:00:00Z"},
        {:priority=>nil, :created_at=>"2026-01-02T00:00:00Z"}
      ])
    end

    after do
      @db.disconnect
    end

    it "pages forward and backward with duplicate values and NULLs in original order" do
      first = @ds.keyset_paginate(2, :cursor_secret=>@secret)
      second = @ds.keyset_paginate(2, :after=>first.after_cursor, :cursor_secret=>@secret)
      third = @ds.keyset_paginate(2, :after=>second.after_cursor, :cursor_secret=>@secret)
      back_to_second = @ds.keyset_paginate(2, :before=>third.before_cursor, :cursor_secret=>@secret)

      first.records.map{|record| record[:id]}.must_equal [1, 2]
      second.records.map{|record| record[:id]}.must_equal [3, 4]
      third.records.map{|record| record[:id]}.must_equal [5]
      back_to_second.records.map{|record| record[:id]}.must_equal [3, 4]

      first.has_previous_page?.must_equal false
      first.has_next_page?.must_equal true
      second.has_previous_page?.must_equal true
      second.has_next_page?.must_equal true
      third.has_previous_page?.must_equal true
      third.has_next_page?.must_equal false
      back_to_second.has_previous_page?.must_equal true
      back_to_second.has_next_page?.must_equal true
      @logger.messages.each{|message| message.wont_match(/\bCOUNT\b/i)}
    end

    it "continues from a cursor whose anchor row was deleted without a count query" do
      first = @ds.keyset_paginate(2, :cursor_secret=>@secret)
      cursor = first.after_cursor
      @db[:items].where(:id=>2).delete

      second = @ds.keyset_paginate(2, :after=>cursor, :cursor_secret=>@secret)

      second.records.map{|record| record[:id]}.must_equal [3, 4]
      @logger.messages.last.wont_match(/\bCOUNT\b/i)
    end

    it "keeps cursors stable when records are inserted at page boundaries" do
      first = @ds.keyset_paginate(2, :cursor_secret=>@secret)
      second = @ds.keyset_paginate(2, :after=>first.after_cursor, :cursor_secret=>@secret)

      @db[:items].insert(:priority=>3, :created_at=>"2026-01-01T00:00:00Z")
      @db[:items].insert(:priority=>nil, :created_at=>"2025-12-31T00:00:00Z")

      next_from_first = @ds.keyset_paginate(2, :after=>first.after_cursor, :cursor_secret=>@secret)
      previous_from_second = @ds.keyset_paginate(2, :before=>second.before_cursor, :cursor_secret=>@secret)

      next_from_first.records.map{|record| record[:id]}.must_equal [3, 7]
      previous_from_second.records.map{|record| record[:id]}.must_equal [1, 2]
    end
  end
rescue LoadError
end
