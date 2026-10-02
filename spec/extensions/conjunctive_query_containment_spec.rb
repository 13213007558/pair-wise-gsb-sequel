# frozen_string_literal: true
require_relative "spec_helper"

begin
  require 'sqlite3'
  HAVE_SQLITE3 = true
rescue LoadError
  HAVE_SQLITE3 = false
end

describe "conjunctive_query_containment extension" do
  before do
    @db = Sequel.mock
    @db.extension(:conjunctive_query_containment)
    @schema = {:users=>[:id, :name], :orders=>[:id, :user_id]}
  end

  def check(q1, q2, schema=@schema)
    q1.cq_containment(q2, schema)
  end

  def joined_users_orders
    @db[:users].join(:orders, :user_id=>:id)
  end

  it "should be contained when the first query only adds a constant filter" do
    q1 = joined_users_orders.where(Sequel[:users][:id]=>1).select(Sequel[:orders][:id])
    q2 = joined_users_orders.select(Sequel[:orders][:id])
    result = check(q1, q2)
    result.must_be :contained?
    result.wont_be :not_contained?
    result.wont_be :unsupported?
    result.status.must_equal :contained
    result.mapping[:aliases].must_equal({:users=>:users, :orders=>:orders})
    result.mapping[:variables][[:orders, :id]].must_equal [:orders, :id]
  end

  it "should not be contained when the second query adds a constant filter" do
    q1 = joined_users_orders.select(Sequel[:orders][:id])
    q2 = joined_users_orders.where(Sequel[:users][:id]=>1).select(Sequel[:orders][:id])
    result = check(q1, q2)
    result.must_be :not_contained?
    result.mapping.must_be_nil
    result.counterexample[:missing_row].length.must_equal 1
    result.counterexample[:tables].keys.sort_by(&:to_s).must_equal [:orders, :users]
  end

  it "should not be affected by table aliasing" do
    u = Sequel[:users].as(:u)
    o = Sequel[:orders].as(:o)
    q1 = @db[u].join(o, :user_id=>:id).where(Sequel[:u][:id]=>1).select(Sequel[:o][:id])
    q2 = joined_users_orders.where(Sequel[:users][:id]=>1).select(Sequel[:orders][:id])
    check(q1, q2).must_be :contained?
    result = check(q2, q1)
    result.must_be :contained?
    result.mapping[:aliases].must_equal({:u=>:users, :o=>:orders})
  end

  it "should provide a checkable variable mapping" do
    q1 = @db[:users].where(:id=>1).select(:id)
    q2 = @db[Sequel[:users].as(:u)].where(Sequel[:u][:id]=>1).select(Sequel[:u][:id])
    result = check(q1, q2)
    result.must_be :contained?
    result.mapping.must_equal({
      :aliases=>{:u=>:users},
      :variables=>{[:u, :id]=>[:users, :id], [:u, :name]=>[:users, :name]}
    })
  end

  it "should handle self joins" do
    q1 = @db[:users].join(Sequel[:users].as(:u2), :id=>:id).select(Sequel[:users][:id])
    q2 = @db[:users].select(:id)
    check(q1, q2).must_be :contained?
    check(q2, q1).must_be :contained?
  end

  it "should not be affected by duplicate predicates" do
    q1 = @db[:users].where(:id=>1).where(Sequel[:users][:id]=>1).select(:id)
    q2 = @db[:users].where(:id=>1).select(:id)
    check(q1, q2).must_be :contained?
    check(q2, q1).must_be :contained?
  end

  it "should propagate constants through column equalities" do
    q1 = joined_users_orders.where(Sequel[:orders][:user_id]=>3).select(Sequel[:users][:id])
    q2 = @db[:users].where(:id=>3).select(:id)
    check(q1, q2).must_be :contained?
    check(q2, q1).must_be :not_contained?
  end

  it "should support USING joins" do
    schema = {:a=>[:id, :x], :b=>[:id, :y]}
    q1 = @db[:a].join(:b, [:id]).select(Sequel[:a][:x])
    q2 = @db[:a].join(:b, Sequel[:a][:id]=>Sequel[:b][:id]).select(Sequel[:a][:x])
    check(q1, q2, schema).must_be :contained?
    check(q2, q1, schema).must_be :contained?
  end

  it "should support cross joins and multiple FROM sources" do
    schema = {:a=>[:id], :b=>[:id]}
    q1 = @db[:a].cross_join(:b).select(Sequel[:a][:id])
    q2 = @db[:a, :b].select(Sequel[:a][:id])
    check(q1, q2, schema).must_be :contained?
    check(q2, q1, schema).must_be :contained?
  end

  it "should ignore DISTINCT and ORDER BY under set semantics" do
    q1 = @db[:users].select(:id).distinct.order(:id)
    q2 = @db[:users].select(:id)
    check(q1, q2).must_be :contained?
    check(q2, q1).must_be :contained?
  end

  it "should treat queries with conflicting constant equalities as empty" do
    empty = @db[:users].where(:id=>1).where(:id=>2).select(:id)
    result = check(empty, @db[:orders].select(:id))
    result.must_be :contained?
    result.mapping.must_be_nil
    result.reason.must_match(/empty/)

    q1 = @db[:users].where(:id=>1).select(:id)
    result = check(q1, empty)
    result.must_be :not_contained?
    result.counterexample[:tables].must_equal({:users=>[{:id=>1, :name=>"cq_var_1"}]})
    result.counterexample[:missing_row].must_equal [1]
  end

  it "should not be contained when projections have different widths" do
    q1 = @db[:users].select(:id, :name)
    q2 = @db[:users].select(:id)
    check(q1, q2).must_be :not_contained?
  end

  it "should avoid collisions between symbolic counterexample values and constants" do
    q1 = @db[:users].select(:id)
    q2 = @db[:users].where(:name=>'cq_var_1').select(:id)
    result = check(q1, q2)
    result.must_be :not_contained?
    result.counterexample[:missing_row].must_equal ["_cq_var_1"]
  end

  it "should return unsupported for queries outside the conjunctive fragment" do
    schema = {:a=>[:id, :x], :b=>[:id, :x]}
    simple = @db[:a].select(:id)
    unsupported_queries = [
      @db[:a], # SELECT *
      @db[:a].select{count(id)}, # aggregate
      @db[:a].select(Sequel[:a][:id]).left_join(:b, :id=>:id), # outer join
      @db[:a].select(:id).where{x > 1}, # inequality
      @db[:a].select(:id).where(Sequel.|({:x=>1}, {:x=>2})), # OR
      @db[:a].select(:id).limit(1), # LIMIT
      @db[:a].select(:id).group(:id), # GROUP BY
      @db[:a].select(:id).union(@db[:a].select(:id)), # UNION
      @db[@db[:a]].select(:id), # subquery source
      @db[:a].select(:id).where(:x=>nil), # IS NULL
      @db[:a].select(:id).where(:x=>true), # IS TRUE
      @db[:a].join(:b, :id=>:id).select(:id), # ambiguous unqualified column
      @db[:nope].select(:id) # table missing from schema
    ]
    unsupported_queries.each do |q|
      result = check(q, simple, schema)
      result.must_be :unsupported?
      result.reason.must_be_kind_of String
      check(simple, q, schema).must_be :unsupported?
    end
  end

  it "should be callable without loading the dataset extension" do
    q1 = Sequel.mock[:users].where(:id=>1).select(:id)
    q2 = Sequel.mock[:users].select(:id)
    result = Sequel::ConjunctiveQueryContainment.check(q1, q2, @schema)
    result.must_be :contained?
  end

  if HAVE_SQLITE3
    describe "counterexample verification with in-memory SQLite" do
      before do
        @sdb = Sequel.sqlite
        @sdb.extension(:conjunctive_query_containment)
      end

      after do
        @sdb.disconnect
      end

      def verify_counterexample(schema, q1, q2)
        result = q1.cq_containment(q2, schema)
        result.must_be :not_contained?
        schema.each do |table, columns|
          @sdb.run("CREATE TABLE #{table} (#{columns.join(', ')})")
        end
        result.counterexample[:tables].each do |table, rows|
          rows.each{|row| @sdb[table].insert(row)}
        end
        missing = result.counterexample[:missing_row]
        q1.all.map{|row| row.values}.must_include missing
        q2.all.map{|row| row.values}.wont_include missing
        result
      end

      it "should witness a dropped constant filter" do
        q1 = @sdb[:users].join(:orders, :user_id=>:id).select(Sequel[:orders][:id])
        q2 = @sdb[:users].join(:orders, :user_id=>:id).where(Sequel[:users][:id]=>1).select(Sequel[:orders][:id])
        verify_counterexample(@schema, q1, q2)
      end

      it "should witness a dropped join" do
        q1 = @sdb[:users].select(:id)
        q2 = @sdb[:users].join(:orders, :user_id=>:id).select(Sequel[:users][:id])
        verify_counterexample(@schema, q1, q2)
      end

      it "should witness a self join the first query cannot match" do
        schema = {:users=>[:id, :name]}
        q1 = @sdb[:users].select(:id)
        q2 = @sdb[:users].join(Sequel[:users].as(:u2), :id=>:name).select(Sequel[:users][:id])
        verify_counterexample(schema, q1, q2)
      end

      it "should witness an unsatisfiable second query" do
        schema = {:users=>[:id, :name]}
        q1 = @sdb[:users].where(:id=>1).select(:id)
        q2 = @sdb[:users].where(:id=>1).where(:id=>2).select(:id)
        result = verify_counterexample(schema, q1, q2)
        result.counterexample[:missing_row].must_equal [1]
      end

      it "should witness string constant differences" do
        schema = {:users=>[:id, :name]}
        q1 = @sdb[:users].select(:name)
        q2 = @sdb[:users].where(:name=>'alice').select(:name)
        result = verify_counterexample(schema, q1, q2)
        result.counterexample[:missing_row].must_equal ["cq_var_2"]
      end
    end
  end
end
