# frozen_string_literal: true
require_relative "spec_helper"

Sequel.extension :json_table

describe "json_table extension" do
  before do
    @db = Sequel.sqlite
    @pg = Sequel.connect("mock://postgres")
    @pg.extend_datasets { def quote_identifiers?; false end }
  end

  it "supports scalar columns and FOR ORDINALITY on SQLite" do
    table = Sequel.json_table('[{"id":10},{"id":11}]', '$[*]') do
      ordinality :position
      Integer :id
    end

    @db.from(table).all.must_equal [
      {:position=>1, :id=>10},
      {:position=>2, :id=>11},
    ]
  end

  it "preserves the parent row when nested arrays are empty or missing" do
    table = Sequel.json_table('{"id":2,"movies":[],"books":[]}', '$') do
      Integer :id
      nested '$.movies[*]' do
        ordinality :movie_id
        String :movie_name, :path=>'$.name'
      end
      nested '$.books[*]' do
        ordinality :book_id
        String :book_name, :path=>'$.name'
      end
    end

    @db.from(table).all.must_equal [{
      :id=>2,
      :movie_id=>nil, :movie_name=>nil,
      :book_id=>nil, :book_name=>nil,
    }]

    table = Sequel.json_table('{"id":3}', '$') do
      Integer :id
      nested '$.movies[*]' do
        String :movie_name, :path=>'$.name'
      end
    end
    @db.from(table).all.must_equal [{:id=>3, :movie_name=>nil}]
  end

  it "combines sibling NESTED PATH branches using union rather than cartesian product" do
    json = '{"id":1,"movies":[{"name":"One"},{"name":"Two"}],"books":[{"name":"Mystery"}]}'
    table = Sequel.json_table(json, '$') do
      Integer :id
      nested '$.movies[*]' do
        ordinality :movie_id
        String :movie_name, :path=>'$.name'
      end
      nested '$.books[*]' do
        ordinality :book_id
        String :book_name, :path=>'$.name'
      end
    end

    @db.from(table).all.must_equal [
      {:id=>1, :movie_id=>1, :movie_name=>"One", :book_id=>nil, :book_name=>nil},
      {:id=>1, :movie_id=>2, :movie_name=>"Two", :book_id=>nil, :book_name=>nil},
      {:id=>1, :movie_id=>nil, :movie_name=>nil, :book_id=>1, :book_name=>"Mystery"},
    ]
  end

  it "resets nested ordinality independently for every parent row" do
    json = '[{"items":[{"name":"a"}]},{"items":[{"name":"b"},{"name":"c"}]}]'
    table = Sequel.json_table(json, '$[*]') do
      ordinality :parent_id
      nested '$.items[*]' do
        ordinality :item_id
        String :name
      end
    end

    @db.from(table).all.must_equal [
      {:parent_id=>1, :item_id=>1, :name=>"a"},
      {:parent_id=>2, :item_id=>1, :name=>"b"},
      {:parent_id=>2, :item_id=>2, :name=>"c"},
    ]
  end

  it "supports fixed array indexes before and after a wildcard path" do
    table = Sequel.json_table('[[{"value":10}],[{"value":20},{"value":30}]]', '$[*][0]') do
      Integer :value
    end

    @db.from(table).all.must_equal [{:value=>10}, {:value=>20}]
  end

  it "returns no rows for an empty root wildcard array" do
    table = Sequel.json_table('[]', '$[*]') { Integer :value }
    @db.from(table).all.must_equal []
  end

  it "distinguishes missing values, JSON null, and type conversion failures" do
    json = '{"nullable":null,"number":"x","text":"ok"}'
    table = Sequel.json_table(json, '$') do
      Integer :missing, :on_empty=>-1, :on_error=>-2
      Integer :nullable, :on_empty=>-1, :on_error=>-2
      Integer :number, :on_empty=>-1, :on_error=>-2
      String :text, :on_empty=>"empty", :on_error=>"error"
    end

    @db.from(table).all.must_equal [{
      :missing=>-1,
      :nullable=>nil,
      :number=>-2,
      :text=>"ok",
    }]
  end

  it "raises on SQLite conversion errors when ERROR ON ERROR is requested" do
    table = Sequel.json_table('{"number":"x"}', '$') do
      Integer :number, :on_error=>:error
    end

    proc{@db.from(table).all}.must_raise Sequel::DatabaseError
  end

  it "emits the same restricted JSON_TABLE contract for PostgreSQL" do
    table = Sequel.json_table(:j, '$.items[*]') do
      ordinality :id
      Integer :count, :on_empty=>0, :on_error=>:error
      nested '$.tags[*]' do
        String :tag, :path=>'$.name', :on_empty=>"unknown", :on_error=>"bad"
      end
    end

    @pg.from(table).sql.must_equal(
      "SELECT * FROM json_table(j, '$.items[*]' COLUMNS(id FOR ORDINALITY, count integer PATH '$.count' DEFAULT 0 ON EMPTY ERROR ON ERROR, NESTED '$.tags[*]' COLUMNS(tag text PATH '$.name' DEFAULT 'unknown' ON EMPTY DEFAULT 'bad' ON ERROR)))"
    )
  end
end
