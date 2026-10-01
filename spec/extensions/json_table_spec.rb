# frozen_string_literal: true
require_relative "spec_helper"

Sequel.extension :json_table
begin
  require 'sqlite3'
rescue LoadError
end

describe "Sequel.json_table SQL generation (PostgreSQL)" do
  before do
    @db = Sequel.connect('mock://postgres')
    @db.extend_datasets { def quote_identifiers?; false end }
    @l = proc { |o| @db.literal(o) }
  end

  it "should generate a json_table call with scalar columns" do
    t = Sequel.json_table(:j, '$.items') { String :a; Integer :b }
    @l[t].must_equal "json_table(j, '$.items' COLUMNS(a text PATH '$.\"a\"' NULL ON EMPTY NULL ON ERROR, b integer PATH '$.\"b\"' NULL ON EMPTY NULL ON ERROR))"
  end

  it "should support explicit paths and FOR ORDINALITY" do
    t = Sequel.json_table(:j, '$.x') do
      ordinality :o
      column :b, Integer, path: '$.q'
    end
    @l[t].must_equal "json_table(j, '$.x' COLUMNS(o FOR ORDINALITY, b integer PATH '$.q' NULL ON EMPTY NULL ON ERROR))"
  end

  it "should support per-column ON EMPTY/ON ERROR" do
    t = Sequel.json_table(:j, '$') do
      Integer :a, on_empty: 0, on_error: -1
      String :b, on_empty: :error, on_error: 'x'
    end
    @l[t].must_equal "json_table(j, '$' COLUMNS(a integer PATH '$.\"a\"' DEFAULT 0 ON EMPTY DEFAULT -1 ON ERROR, b text PATH '$.\"b\"' ERROR ON EMPTY DEFAULT 'x' ON ERROR))"
  end

  it "should support nested paths and explicit NULL clauses" do
    t = Sequel.json_table(:j, '$.a') { nested('$.b') { String :c } }
    @l[t].must_equal "json_table(j, '$.a' COLUMNS(NESTED '$.b' COLUMNS(c text PATH '$.\"c\"' NULL ON EMPTY NULL ON ERROR)))"
  end

  it "should support the table level :on_error option" do
    @l[Sequel.json_table(:j, '$', on_error: :empty_array) { String :a }].must_include "EMPTY ARRAY ON ERROR)"
    @l[Sequel.json_table(:j, '$', on_error: :error) { String :a }].must_include "ERROR ON ERROR)"
  end

  it "should support AST transformations" do
    t = Sequel.json_table(:j, '$') { String :a }
    @db.select(t).qualify(:t).sql.must_match(/json_table\(t\.j,/)
  end
end

describe "Sequel.json_table SQL generation (SQLite)" do
  before do
    @db = Sequel.connect('mock://sqlite')
    @db.extend_datasets { def quote_identifiers?; false end }
  end

  it "should expand rows entirely with json_each (no Ruby expansion)" do
    sql = @db.literal(Sequel.json_table(:j, '$.items') { String :a })
    sql.must_include "json_each("
    sql.must_include "json_type("
    sql.wont_include "json_table("
  end

  it "should distinguish missing, json null, and conversion error" do
    sql = @db.literal(Sequel.json_table(:j, '$') { Integer :a, on_empty: 0, on_error: -1 })
    sql.must_include "IS NULL THEN 0"
    sql.must_include "= 'null' THEN NULL"
    sql.must_include "ELSE -1"
  end

  it "should provide a dataset selecting the declared columns" do
    t = Sequel.json_table(:j, '$') { String :a; nested('$.b') { Integer :c } }
    ds = @db.from(t).select(*t.visible_columns)
    ds.sql.must_match(/SELECT a, c FROM \(SELECT /)
  end
end

if defined?(SQLite3)
describe "Sequel.json_table behavior on SQLite" do
  before do
    @db = Sequel.sqlite
  end

  def rows(doc, path='$', opts={}, &block)
    t = Sequel.json_table(Sequel.lit(@db.literal(doc)), path, opts, &block)
    @db.from(t).select(*t.visible_columns).all
  end

  it "expands root arrays with ordinality and scalar columns" do
    result = rows('[1,2,3]') do
      ordinality :o
      Integer :v, path: '$'
    end
    result.must_equal [{o: 1, v: 1}, {o: 2, v: 2}, {o: 3, v: 3}]
  end

  it "wraps a non-array root document into a single row" do
    rows('{"a":1}') { Integer :a }.must_equal [{a: 1}]
    rows('5') { Integer :v, path: '$' }.must_equal [{v: 5}]
  end

  it "returns no rows for an empty root array" do
    rows('[]') { Integer :v, path: '$' }.must_equal []
    rows('{}', '$.missing') { Integer :v, path: '$' }.must_equal []
  end

  it "preserves the parent row when a nested path is empty or missing" do
    doc = '[{"g":[]},{"g":[{"x":1}]},{}]'
    result = rows(doc) do
      nested '$.g' do
        Integer :x
      end
    end
    result.must_equal [{x: nil}, {x: 1}, {x: nil}]
  end

  it "combines sibling NESTED PATH rows with union semantics, never a cartesian product" do
    doc = '{"items":[{"a":[1,2],"b":[9]},{"a":[3],"b":[]},{"z":1}]}'
    result = rows(doc, '$.items') do
      nested '$.a' do
        Integer :x, path: '$'
      end
      nested '$.b' do
        Integer :y, path: '$'
      end
    end
    result.must_equal [
      {x: 1, y: nil}, {x: 2, y: nil}, {x: nil, y: 9},
      {x: 3, y: nil},
      {x: nil, y: nil},
    ]
  end

  it "resets ordinality for each parent row" do
    doc = '[[10,11],[20]]'
    result = rows(doc) do
      nested '$' do
        ordinality :o
        Integer :v, path: '$'
      end
    end
    result.must_equal [{o: 1, v: 10}, {o: 2, v: 11}, {o: 1, v: 20}]
  end

  it "keeps cousins from different sibling branches separate at deeper levels" do
    doc = '[{"a":[{"k":[1,2]}],"b":[{"k":[9]}]}]'
    result = rows(doc) do
      nested '$.a' do
        nested '$.k' do
          Integer :x, path: '$'
        end
      end
      nested '$.b' do
        nested '$.k' do
          Integer :y, path: '$'
        end
      end
    end
    result.must_equal [{x: 1, y: nil}, {x: 2, y: nil}, {x: nil, y: 9}]
  end

  it "assigns scalar columns declared anywhere inside a nested block to that branch" do
    doc = '[{"first":["a"],"second":["b"]}]'
    result = rows(doc) do
      nested '$.first' do
        String :f, path: '$'
      end
      nested '$.second' do
        String :s, path: '$'
      end
    end
    result.must_equal [{f: "a", s: nil}, {f: nil, s: "b"}]
  end

  it "expands three sibling arrays independently" do
    doc = '{"a":[1],"b":[2,3],"c":[]}'
    result = rows(doc, '$') do
      nested '$.a' do
        Integer :x, path: '$'
      end
      nested '$.b' do
        Integer :y, path: '$'
      end
      nested '$.c' do
        Integer :z, path: '$'
      end
    end
    result.must_equal [{x: 1, y: nil, z: nil}, {x: nil, y: 2, z: nil}, {x: nil, y: 3, z: nil}]
  end

  it "emits marker rows through multiple empty nesting levels" do
    doc = '[{"g":[]},{"g":[{}]}]'
    result = rows(doc) do
      nested '$.g' do
        nested '$.h' do
          Integer :v, path: '$'
        end
      end
    end
    result.must_equal [{v: nil}, {v: nil}]
  end

  it "distinguishes missing values, JSON null, and type conversion failures" do
    doc = '[{"i":null},{},{"i":"x"},{"i":5}]'
    result = rows(doc) { Integer :i, on_empty: -1, on_error: -2 }
    result.must_equal [{i: nil}, {i: -1}, {i: -2}, {i: 5}]
  end

  it "supports :error for ON EMPTY/ON ERROR" do
    proc { rows('[{"i":"x"}]') { Integer :i, on_error: :error } }.must_raise Sequel::DatabaseError
    proc { rows('[{}]') { Integer :i, on_empty: :error } }.must_raise Sequel::DatabaseError
  end

  it "supports :empty_array table-level on_error for malformed documents" do
    rows('nope', '$', on_error: :empty_array) { Integer :v, path: '$' }.must_equal []
    proc { rows('nope') { Integer :v, path: '$' } }.must_raise Sequel::DatabaseError
  end

  it "applies strict JSON type rules to scalar columns" do
    doc = '[{"i":1},{"i":1.5},{"i":true},{"f":1},{"b":true},{"b":0}]'
    result = rows(doc) do
      Integer :i, on_empty: -1, on_error: -2
      Float :f, on_empty: -1.0, on_error: -2.0
      TrueClass :b, on_empty: false, on_error: false
    end
    result.must_equal [
      {i: 1, f: -1.0, b: 0},
      {i: -2, f: -1.0, b: 0},
      {i: -2, f: -1.0, b: 0},
      {i: -1, f: 1.0, b: 0},
      {i: -1, f: -1.0, b: 1},
      {i: -1, f: -1.0, b: 0},
    ]
  end
end
end
