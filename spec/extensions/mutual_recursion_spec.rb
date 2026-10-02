# frozen_string_literal: true
require_relative "spec_helper"

describe "mutual_recursion extension" do
  before do
    @db = Sequel.mock
    @db.extend_datasets{def supports_cte?(*) true end}
    @db.extension(:mutual_recursion)
    @even = {
      :columns=>[:node],
      :nonrecursive=>@db[:starts].select(:node),
      :recursive=>@db[:edges].
        join(:odd, Sequel[:odd][:node]=>Sequel[:edges][:src]).
        select(Sequel[:edges][:dst])
    }
    @odd = {
      :columns=>[:node],
      :recursive=>@db[:edges].
        join(:even, Sequel[:even][:node]=>Sequel[:edges][:src]).
        select(Sequel[:edges][:dst])
    }
  end

  def parity_relations(overrides={})
    {:even=>@even.merge(overrides[:even] || {}), :odd=>@odd.merge(overrides[:odd] || {})}
  end

  def assert_invalid(message, relations)
    ex = proc{@db.mutual_recursive(relations)}.must_raise(Sequel::MutualRecursion::Error)
    ex.message.must_match(message)
    @db.sqls.must_equal []
  end

  it "should compile mutual recursion to a single recursive CTE with a relation tag" do
    rels = @db.mutual_recursive(parity_relations)
    cte = "WITH mutual_recursive(relation, c1) AS ("       "SELECT 'even' AS relation, mutual_recursive_even.node AS c1 FROM (SELECT node FROM starts) AS mutual_recursive_even "       "UNION SELECT 'even' AS relation, edges.dst AS c1 FROM edges INNER JOIN mutual_recursive AS odd ON (odd.c1 = edges.src) WHERE (odd.relation = 'odd') "       "UNION SELECT 'odd' AS relation, edges.dst AS c1 FROM edges INNER JOIN mutual_recursive AS even ON (even.c1 = edges.src) WHERE (even.relation = 'even'))"
    rels[:even].sql.must_equal "#{cte} SELECT mutual_recursive.c1 AS node FROM mutual_recursive WHERE (mutual_recursive.relation = 'even')"
    rels[:odd].sql.must_equal "#{cte} SELECT mutual_recursive.c1 AS node FROM mutual_recursive WHERE (mutual_recursive.relation = 'odd')"
  end

  it "should pad narrower relations with NULL columns and project declared columns back" do
    rels = @db.mutual_recursive(
      :reachable=>{
        :columns=>[:node],
        :nonrecursive=>@db[:start].select(:node),
        :recursive=>@db[:step].select(Sequel[:step][:dst])
      },
      :step=>{
        :columns=>[:src, :dst],
        :nonrecursive=>@db[:edge].select(:src, :dst),
        :recursive=>@db[:edge].
          join(:reachable, Sequel[:reachable][:node]=>Sequel[:edge][:src]).
          select(Sequel[:edge][:src], Sequel[:edge][:dst])
      }
    )
    cte = "WITH mutual_recursive(relation, c1, c2) AS ("       "SELECT 'reachable' AS relation, mutual_recursive_reachable.node AS c1, NULL AS c2 FROM (SELECT node FROM start) AS mutual_recursive_reachable "       "UNION SELECT 'step' AS relation, mutual_recursive_step.src AS c1, mutual_recursive_step.dst AS c2 FROM (SELECT src, dst FROM edge) AS mutual_recursive_step "       "UNION SELECT 'reachable' AS relation, step.c2 AS c1, NULL AS c2 FROM mutual_recursive AS step WHERE (step.relation = 'step') "       "UNION SELECT 'step' AS relation, edge.src AS c1, edge.dst AS c2 FROM edge INNER JOIN mutual_recursive AS reachable ON (reachable.c1 = edge.src) WHERE (reachable.relation = 'reachable'))"
    rels[:reachable].sql.must_equal "#{cte} SELECT mutual_recursive.c1 AS node FROM mutual_recursive WHERE (mutual_recursive.relation = 'reachable')"
    rels[:step].sql.must_equal "#{cte} SELECT mutual_recursive.c1 AS src, mutual_recursive.c2 AS dst FROM mutual_recursive WHERE (mutual_recursive.relation = 'step')"
  end

  it "should support :name and :tag_column options" do
    rels = @db.mutual_recursive({
      :a=>{:columns=>[:x], :nonrecursive=>@db[:t1].select(:x), :recursive=>@db[:b].select(Sequel[:b][:x])},
      :b=>{:columns=>[:x], :nonrecursive=>@db[:t2].select(:x), :recursive=>@db[:a].select(Sequel[:a][:x])}
    }, :name=>:mr, :tag_column=>:rel)
    rels[:a].sql.must_equal "WITH mr(rel, c1) AS ("       "SELECT 'a' AS rel, mr_a.x AS c1 FROM (SELECT x FROM t1) AS mr_a "       "UNION SELECT 'b' AS rel, mr_b.x AS c1 FROM (SELECT x FROM t2) AS mr_b "       "UNION SELECT 'a' AS rel, b.c1 AS c1 FROM mr AS b WHERE (b.rel = 'b') "       "UNION SELECT 'b' AS rel, a.c1 AS c1 FROM mr AS a WHERE (a.rel = 'a')) "       "SELECT mr.c1 AS x FROM mr WHERE (mr.rel = 'a')"
  end

  it "should require a hash of at least two relations" do
    assert_invalid(/requires a hash of at least two relation definitions/, [])
    assert_invalid(/requires a hash of at least two relation definitions/, {:even=>@even})
  end

  it "should require declared columns" do
    assert_invalid(/must declare :columns/, parity_relations(:odd=>{:columns=>nil}))
    assert_invalid(/must declare :columns/, parity_relations(:odd=>{:columns=>[]}))
    assert_invalid(/declares duplicate columns/, parity_relations(:odd=>{:columns=>[:node, :node]}))
  end

  it "should require each relation to declare a branch" do
    assert_invalid(/must declare a :nonrecursive and\/or :recursive branch/, parity_relations(:odd=>{:recursive=>nil}))
  end

  it "should require a base case and at least one recursive branch" do
    assert_invalid(/base case is required/, parity_relations(:even=>{:nonrecursive=>nil}))
    assert_invalid(/at least one relation must declare a :recursive branch/,
      {:even=>{:columns=>[:node], :nonrecursive=>@db[:starts]}, :odd=>{:columns=>[:node], :nonrecursive=>@db[:starts]}})
  end

  it "should reject a relation name conflicting with the shared recursive table name" do
    assert_invalid(/conflicts with the shared recursive table name/,
      {:mutual_recursive=>@even, :odd=>@odd})
  end

  it "should reject aggregation" do
    assert_invalid(/aggregation is not supported/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].group(:node)}))
    assert_invalid(/aggregate function count/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].select(Sequel.function(:count, :node))}))
    assert_invalid(/aggregate function max/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].where(:node=>@db[:starts].select(Sequel.function(:max, :node)))}))
  end

  it "should reject negation" do
    assert_invalid(/negation is not supported/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].where(Sequel.~(@db[:s2].where(:node=>1).exists))}))
    assert_invalid(/EXCEPT\/INTERSECT/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].except(@db[:starts])}))
    assert_invalid(/EXCEPT\/INTERSECT/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].intersect(@db[:starts])}))
  end

  it "should reject UNION ALL but allow duplicate-eliminating UNION" do
    assert_invalid(/UNION ALL/, parity_relations(:odd=>{:nonrecursive=>@db[:starts].union(@db[:starts], :all=>true)}))
    @db.mutual_recursive(parity_relations(:odd=>{:nonrecursive=>@db[:starts].union(@db[:starts])}))
  end

  it "should reject recursive branches referencing recursive relations more than once" do
    assert_invalid(/at most once/, parity_relations(:odd=>{
      :recursive=>@db[:even].
        join(:odd, Sequel[:odd][:node]=>Sequel[:even][:node]).
        select(Sequel[:even][:node])
    }))
  end

  it "should reject recursive references in nonrecursive branches" do
    assert_invalid(/nonrecursive branch of relation odd references recursive relation even/,
      parity_relations(:odd=>{:nonrecursive=>@db[:even].select(:node)}))
  end

  it "should reject recursive references in subqueries" do
    assert_invalid(/inside a subquery/, parity_relations(:odd=>{
      :recursive=>@db[:edges].
        where(:src=>@db[:even].select(:node)).
        select(Sequel[:edges][:dst])
    }))
  end

  it "should reject compounds in recursive branches" do
    rec = @db[:edges].join(:even, Sequel[:even][:node]=>Sequel[:edges][:src]).select(Sequel[:edges][:dst])
    assert_invalid(/cannot use UNION\/EXCEPT\/INTERSECT compounds/, parity_relations(:odd=>{
      :recursive=>rec.union(rec, :from_self=>false)
    }))
  end

  it "should reject recursive branches without an explicit select list matching the declared columns" do
    assert_invalid(/must explicitly select/, parity_relations(:odd=>{
      :recursive=>@db[:edges].join(:even, Sequel[:even][:node]=>Sequel[:edges][:src])
    }))
    assert_invalid(/must explicitly select/, parity_relations(:odd=>{
      :recursive=>@db[:edges].join(:even, Sequel[:even][:node]=>Sequel[:edges][:src]).select(:src, :dst)
    }))
  end

  it "should reject USING joins against recursive relations" do
    assert_invalid(/USING join/, parity_relations(:odd=>{
      :recursive=>@db[:edges].join(:even, [:node]).select(Sequel[:edges][:dst])
    }))
  end

  it "should reject references to undeclared columns of recursive relations" do
    assert_invalid(/has no column nope/, parity_relations(:odd=>{
      :recursive=>@db[:edges].join(:even, Sequel[:even][:nope]=>Sequel[:edges][:src]).select(Sequel[:edges][:dst])
    }))
  end
end

begin
  Sequel.sqlite
  MUTUAL_RECURSION_SQLITE = true
rescue LoadError, Sequel::AdapterNotFound
  MUTUAL_RECURSION_SQLITE = false
end

describe "mutual_recursion extension on SQLite" do
  before do
    skip "sqlite3 not available" unless MUTUAL_RECURSION_SQLITE
    @db = Sequel.sqlite
    @db.extension(:mutual_recursion)
  end

  after do
    @db.disconnect if @db
  end

  def sort_nullable(rows)
    rows.sort_by{|r| Array(r).map{|x| [x.nil? ? 0 : 1, x.nil? ? 0 : x]}}
  end

  # Round-by-round fixpoint evaluation of the parity reachability
  # program, used as a reference for the SQL results.
  def ruby_parity(starts, edges)
    even = starts.uniq
    odd = []
    loop do
      new_odd = edges.select{|s, _| even.include?(s)}.map{|_, d| d} - odd
      new_even = edges.select{|s, _| odd.include?(s)}.map{|_, d| d} - even
      break if new_odd.empty? && new_even.empty?
      odd |= new_odd
      even |= new_even
    end
    [even.sort, odd.sort]
  end

  # Round-by-round fixpoint evaluation of the reachable/step program,
  # using SQL join semantics (NULL never joins).
  def ruby_reachable_step(starts, edges)
    reachable = starts.uniq
    step = edges.uniq
    loop do
      new_step = edges.select{|s, _| !s.nil? && reachable.include?(s)}.uniq - step
      new_reachable = step.map{|_, d| d} - reachable
      break if new_step.empty? && new_reachable.empty?
      step |= new_step
      reachable |= new_reachable
    end
    [reachable, step]
  end

  it "should compute parity reachability and terminate on cyclic graphs" do
    @db.create_table(:starts){Integer :node}
    @db.create_table(:edges){Integer :src; Integer :dst}
    @db[:starts].insert(0)
    [[0, 1], [1, 2], [2, 3], [3, 1], [2, 4]].each{|s, d| @db[:edges].insert(s, d)}

    rels = @db.mutual_recursive(
      :even=>{
        :columns=>[:node],
        :nonrecursive=>@db[:starts].select(:node),
        :recursive=>@db[:edges].
          join(:odd, Sequel[:odd][:node]=>Sequel[:edges][:src]).
          select(Sequel[:edges][:dst])
      },
      :odd=>{
        :columns=>[:node],
        :recursive=>@db[:edges].
          join(:even, Sequel[:even][:node]=>Sequel[:edges][:src]).
          select(Sequel[:edges][:dst])
      }
    )
    even, odd = ruby_parity([0], [[0, 1], [1, 2], [2, 3], [3, 1], [2, 4]])
    rels[:even].all.map{|r| r[:node]}.sort.must_equal even
    rels[:odd].all.map{|r| r[:node]}.sort.must_equal odd
    rels[:even].all.all?{|r| r.keys == [:node]}.must_equal true
  end

  it "should support relations with different arities, preserving NULL and duplicate elimination semantics" do
    @db.create_table(:starts){Integer :node}
    @db.create_table(:edges){Integer :src; Integer :dst}
    @db[:starts].insert(1)
    edges = [[1, 2], [2, 3], [1, 2], [2, nil], [nil, 9], [9, 9]]
    edges.each{|s, d| @db[:edges].insert(s, d)}

    rels = @db.mutual_recursive(
      :reachable=>{
        :columns=>[:node],
        :nonrecursive=>@db[:starts].select(:node),
        :recursive=>@db[:step].select(Sequel[:step][:dst])
      },
      :step=>{
        :columns=>[:src, :dst],
        :nonrecursive=>@db[:edges].select(:src, :dst),
        :recursive=>@db[:edges].
          join(:reachable, Sequel[:reachable][:node]=>Sequel[:edges][:src]).
          select(Sequel[:edges][:src], Sequel[:edges][:dst])
      }
    )
    reachable, step = ruby_reachable_step([1], edges)
    sort_nullable(rels[:reachable].all.map{|r| r[:node]}).must_equal sort_nullable(reachable)
    sort_nullable(rels[:step].all.map{|r| [r[:src], r[:dst]]}).must_equal sort_nullable(step)
    # NULL values are preserved, and duplicate input tuples are eliminated
    rels[:reachable].all.count{|r| r[:node].nil?}.must_equal 1
    rels[:step].all.count{|r| r[:src] == 1 && r[:dst] == 2}.must_equal 1
    rels[:step].all.all?{|r| r.keys == [:src, :dst]}.must_equal true
  end

  it "should return the same result when evaluated repeatedly after the fixpoint is reached" do
    @db.create_table(:starts){Integer :node}
    @db.create_table(:edges){Integer :src; Integer :dst}
    @db[:starts].insert(0)
    [[0, 1], [1, 0]].each{|s, d| @db[:edges].insert(s, d)}
    rels = @db.mutual_recursive(
      :even=>{
        :columns=>[:node],
        :nonrecursive=>@db[:starts].select(:node),
        :recursive=>@db[:edges].
          join(:odd, Sequel[:odd][:node]=>Sequel[:edges][:src]).
          select(Sequel[:edges][:dst])
      },
      :odd=>{
        :columns=>[:node],
        :recursive=>@db[:edges].
          join(:even, Sequel[:even][:node]=>Sequel[:edges][:src]).
          select(Sequel[:edges][:dst])
      }
    )
    first = rels[:even].all
    rels[:even].all.must_equal first
    first.map{|r| r[:node]}.sort.must_equal [0]
    rels[:odd].all.map{|r| r[:node]}.sort.must_equal [1]
  end
end
