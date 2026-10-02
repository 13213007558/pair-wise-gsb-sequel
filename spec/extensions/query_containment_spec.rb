# frozen_string_literal: true
require_relative "spec_helper"

describe "query_containment extension" do
  before do
    @db = Sequel.mock
    @db.extension(:query_containment)
    @schema = {
      :orders=>[:id, :user_id, :status, :total],
      :users=>[:id, :name],
      :r=>[:a, :b],
    }
  end

  def check(old_ds, new_ds)
    old_ds.contained_in?(new_ds, :schema=>@schema)
  end

  it "should report containment when the new query drops a predicate" do
    old_ds = @db[:orders].where(:status=>"paid", :total=>10).select(:id, :user_id).distinct
    new_ds = @db[:orders].where(:status=>"paid").select(:id, :user_id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :contained
    result.contained?.must_equal true
    result.unsupported?.must_equal false
    result.mapping.must_equal(:orders=>:orders)
  end

  it "should report containment when the new query drops a join" do
    old_ds = @db[:orders].join(:users, :id=>:user_id).where(Sequel[:users][:name]=>"x").select(Sequel[:orders][:id]).distinct
    new_ds = @db[:orders].select(:id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :contained
    # the mapping goes from the new (containing) query's aliases to the
    # old query's aliases
    result.mapping.must_equal(:orders=>:orders)
  end

  it "should provide a mapping verifiable with valid_mapping?" do
    old_ds = @db[:orders].join(:users, :id=>:user_id).select(Sequel[:orders][:id], Sequel[:users][:name]).distinct
    new_ds = @db.from(Sequel[:orders].as(:o)).join(Sequel[:users].as(:u), Sequel[:u][:id]=>Sequel[:o][:user_id]).
      select(Sequel[:o][:id], Sequel[:u][:name]).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :contained
    result.mapping.must_equal(:o=>:orders, :u=>:users)
    Sequel::QueryContainment.valid_mapping?(old_ds, new_ds, result.mapping, :schema=>@schema).must_equal true
    Sequel::QueryContainment.valid_mapping?(old_ds, new_ds, {:o=>:users, :u=>:orders}, :schema=>@schema).must_equal false
    Sequel::QueryContainment.valid_mapping?(old_ds, new_ds, {:o=>:orders}, :schema=>@schema).must_equal false
  end

  it "should not be affected by table alias changes" do
    q1 = @db.from(Sequel[:orders].as(:o)).where(Sequel[:o][:status]=>"paid").select(Sequel[:o][:id]).distinct
    q2 = @db.from(Sequel[:orders].as(:x)).where(Sequel[:x][:status]=>"paid").select(Sequel[:x][:id]).distinct
    check(q1, q2).status.must_equal :contained
    check(q2, q1).status.must_equal :contained
  end

  it "should not be affected by duplicate predicates" do
    q1 = @db[:orders].where(:status=>"paid").where(:status=>"paid").select(:id).distinct
    q2 = @db[:orders].where(:status=>"paid").select(:id).distinct
    check(q1, q2).status.must_equal :contained
    check(q2, q1).status.must_equal :contained
  end

  it "should handle self joins" do
    q = @db.from(Sequel[:r].as(:t1)).join(Sequel[:r].as(:t2), Sequel[:t2][:a]=>Sequel[:t1][:b]).
      select(Sequel[:t1][:a], Sequel[:t2][:b]).distinct
    result = check(q, q)
    result.status.must_equal :contained
    result.mapping.must_equal(:t1=>:t1, :t2=>:t2)

    # a self join is not contained in the plain table scan, and
    # the plain table scan is not contained in the self join
    scan = @db[:r].select(:a, :b).distinct
    check(q, scan).status.must_equal :not_contained
    result = check(scan, q)
    result.status.must_equal :not_contained
    result.counterexample.rows.must_equal("r"=>[{:a=>1, :b=>2}])
    result.counterexample.witness.must_equal [1, 2]
  end

  it "should map multiple atoms of the new query to the same atom of the old query" do
    # R(x, x) head(x) is contained in R(x, y) head(x)
    loop_ds = @db[:r].where(Sequel[:r][:a]=>Sequel[:r][:b]).select(:a).distinct
    scan = @db[:r].select(:a).distinct
    result = check(loop_ds, scan)
    result.status.must_equal :contained
    result.mapping.must_equal(:r=>:r)
  end

  it "should handle column equalities in WHERE and JOIN ON conditions" do
    old_ds = @db[:orders].join(:users, :id=>:user_id).
      where(Sequel[:orders][:status]=>Sequel[:users][:name]).
      select(Sequel[:orders][:id]).distinct
    new_ds = @db[:orders].join(:users, :id=>:user_id).select(Sequel[:orders][:id]).distinct
    check(old_ds, new_ds).status.must_equal :contained
    check(new_ds, old_ds).status.must_equal :not_contained
  end

  it "should support cross joins" do
    old_ds = @db[:orders].cross_join(:users).select(Sequel[:orders][:id], Sequel[:users][:id]).distinct
    new_ds = @db[:orders].cross_join(:users).select(Sequel[:orders][:id], Sequel[:users][:id]).distinct
    check(old_ds, new_ds).status.must_equal :contained
  end

  it "should build a verified counterexample when not contained" do
    old_ds = @db[:orders].select(:id, :status).distinct
    new_ds = @db[:orders].where(:status=>"paid").select(:id, :status).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :not_contained
    result.contained?.must_equal false
    ce = result.counterexample
    ce.verified?.must_equal true
    ce.verification_error.must_be_nil
    ce.rows.must_equal("orders"=>[{:id=>1, :user_id=>2, :status=>3, :total=>4}])
    ce.witness.must_equal [1, 3]
    ce.missing_rows.must_equal [[1, 3]]
    ce.database.must_be_kind_of Sequel::Database
  end

  it "should keep constants in the counterexample and avoid colliding fresh values" do
    old_ds = @db[:orders].where(:status=>"paid", :total=>10).select(:id, :user_id).distinct
    new_ds = @db[:orders].where(:status=>"paid", :total=>20).select(:id, :user_id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :not_contained
    ce = result.counterexample
    ce.rows.must_equal("orders"=>[{:id=>21, :user_id=>22, :status=>"paid", :total=>10}])
    ce.witness.must_equal [21, 22]
    ce.missing_rows.must_equal [[21, 22]]
  end

  it "should report not contained for different constants" do
    old_ds = @db[:orders].where(:status=>"paid").select(:id).distinct
    new_ds = @db[:orders].where(:status=>"shipped").select(:id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :not_contained
    result.counterexample.missing_rows.must_equal [[1]]
  end

  it "should report not contained when the projections have different arity" do
    old_ds = @db[:orders].select(:id, :status).distinct
    new_ds = @db[:orders].select(:id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :not_contained
    result.counterexample.verified?.must_equal true
    result.counterexample.missing_rows.must_equal [[1, 3]]
  end

  it "should treat float constants equal to integers as the same constant" do
    old_ds = @db[:orders].where(:total=>10).select(:id).distinct
    new_ds = @db[:orders].where(:total=>10.0).select(:id).distinct
    check(old_ds, new_ds).status.must_equal :contained
    check(new_ds, old_ds).status.must_equal :contained
  end

  it "should report containment vacuously when the first query is unsatisfiable" do
    old_ds = @db[:orders].where(:status=>"a").where(:status=>"b").select(:id).distinct
    new_ds = @db[:orders].select(:id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :contained
    result.mapping.must_be_nil
    result.reason.must_match(/unsatisfiable/)
  end

  it "should report not contained when only the second query is unsatisfiable" do
    old_ds = @db[:orders].select(:id).distinct
    new_ds = @db[:orders].where(:status=>"a").where(:status=>"b").select(:id).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :not_contained
    result.counterexample.verified?.must_equal true
    result.counterexample.missing_rows.must_equal [[1]]
  end

  it "should return unsupported for queries without DISTINCT" do
    result = check(@db[:orders].select(:id), @db[:orders].select(:id).distinct)
    result.status.must_equal :unsupported
    result.unsupported?.must_equal true
    result.reason.must_match(/DISTINCT/)
  end

  it "should return unsupported for queries without an explicit projection" do
    result = check(@db[:orders].distinct, @db[:orders].select(:id).distinct)
    result.status.must_equal :unsupported
    result.reason.must_match(/projection/)
  end

  it "should return unsupported for outer joins" do
    old_ds = @db[:orders].left_join(:users, :id=>:user_id).select(Sequel[:orders][:id]).distinct
    result = check(old_ds, @db[:orders].select(:id).distinct)
    result.status.must_equal :unsupported
    result.reason.must_match(/inner joins/)
  end

  it "should return unsupported for non-equality predicates" do
    old_ds = @db[:orders].where{total > 10}.select(:id).distinct
    result = check(old_ds, @db[:orders].select(:id).distinct)
    result.status.must_equal :unsupported
    result.reason.must_match(/unsupported predicate/)
  end

  it "should return unsupported for NULL constants" do
    old_ds = @db[:orders].where(:status=>nil).select(:id).distinct
    result = check(old_ds, @db[:orders].select(:id).distinct)
    result.status.must_equal :unsupported
  end

  it "should return unsupported for grouping, limits, and set operations" do
    q = @db[:orders].select(:id).distinct
    check(@db[:orders].group(:status).select(:status).distinct, q).status.must_equal :unsupported
    check(@db[:orders].select(:id).distinct.limit(1), q).status.must_equal :unsupported
    check(@db[:orders].select(:id).distinct.union(@db[:orders].select(:id).distinct), q).status.must_equal :unsupported
  end

  it "should return unsupported for projections that are not column references" do
    q = @db[:orders].select(:id).distinct
    check(@db[:orders].select(Sequel.function(:count, :id)).distinct, q).status.must_equal :unsupported
    check(@db[:orders].select(Sequel[:orders].*).distinct, q).status.must_equal :unsupported
  end

  it "should return unsupported for subqueries and JOIN USING" do
    q = @db[:orders].select(:id).distinct
    check(@db.from(@db[:orders]).select(:id).distinct, q).status.must_equal :unsupported
    check(@db[:orders].natural_join(:users).select(Sequel[:orders][:id]).distinct, q).status.must_equal :unsupported
  end

  it "should return unsupported for ambiguous unqualified columns" do
    old_ds = @db[:orders].join(:users, :id=>:user_id).select(:id).distinct
    result = check(old_ds, @db[:orders].select(:id).distinct)
    result.status.must_equal :unsupported
    result.reason.must_match(/ambiguous/)
  end

  it "should raise ArgumentError when the schema does not include a referenced table" do
    proc do
      @db[:orders].select(:id).distinct.contained_in?(@db[:orders].select(:id).distinct, :schema=>{:users=>[:id]})
    end.must_raise ArgumentError
  end

  it "should ignore ORDER BY when checking containment" do
    old_ds = @db[:orders].where(:status=>"paid").select(:id).distinct.order(:id)
    new_ds = @db[:orders].where(:status=>"paid").select(:id).distinct
    check(old_ds, new_ds).status.must_equal :contained
  end

  it "should be loadable into individual datasets" do
    ds = @db[:orders].select(:id).distinct.extension(:query_containment)
    ds.contained_in?(ds, :schema=>@schema).status.must_equal :contained
  end

  it "should find homomorphisms that require mapping to a specific atom" do
    # the new query's constant equality can only be witnessed by one of
    # the old query's two atoms
    old_ds = @db.from(Sequel[:r].as(:t1)).join(Sequel[:r].as(:t2), Sequel[:t2][:a]=>Sequel[:t1][:a]).
      where(Sequel[:t1][:b]=>5).select(Sequel[:t1][:a]).distinct
    new_ds = @db.from(Sequel[:r].as(:s)).where(Sequel[:s][:b]=>5).select(Sequel[:s][:a]).distinct
    result = check(old_ds, new_ds)
    result.status.must_equal :contained
    result.mapping.must_equal(:s=>:t1)
    Sequel::QueryContainment.valid_mapping?(old_ds, new_ds, result.mapping, :schema=>@schema).must_equal true
    Sequel::QueryContainment.valid_mapping?(old_ds, new_ds, {:s=>:t2}, :schema=>@schema).must_equal false
  end

  it "should expose the counterexample database contents" do
    old_ds = @db[:orders].select(:id).distinct
    new_ds = @db[:orders].where(:status=>"paid").select(:id).distinct
    ce = check(old_ds, new_ds).counterexample
    ce.database[:orders].all.must_equal [{:id=>1, :user_id=>2, :status=>3, :total=>4}]
    ce.database[:users].all.must_equal []
  end

  it "should be checkable via Sequel::QueryContainment.check" do
    old_ds = @db[:orders].where(:status=>"paid").select(:id).distinct
    new_ds = @db[:orders].select(:id).distinct
    Sequel::QueryContainment.check(old_ds, new_ds, :schema=>@schema).status.must_equal :contained
  end
end
