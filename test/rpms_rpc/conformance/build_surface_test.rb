# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "rpms_rpc/conformance/build_surface"

# BuildSurface's signatures walk (rpms-rpc#394, #395): M text that is Latin-1, and the walk's own counts.
class RpmsRpc::Conformance::BuildSurfaceTest < Minitest::Test
  Surface = RpmsRpc::Conformance::BuildSurface
  TAG = "bcer-0.0-20260101-abc1234-ydb"

  def load(signatures)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "#{TAG}-broker_8994.txt"), "XQ OPT^OPT^XQ^1\n")
      File.binwrite(File.join(dir, "#{TAG}-rpc_signatures.txt"), signatures)
      Surface.load(dir, TAG)
    end
  end

  def walk(*lines) = (lines.map { |l| l.b.tr("|", "\t") } + [ "" ]).join("\n".b)

  # bcer-9.0-20260930's XQ descriptions carry a \xB7 bullet: Latin-1, not UTF-8.
  def test_a_latin1_line_is_read_as_latin1
    rpc = load(walk("RPC|1|XQ OPT|OPT|XQ|1||||||||1|1|Y", "DESC|1|\xB7 no access".b, "DESC|1|café", "EXPLICIT SUCCESS: rpcs=1 parameters=0"))["XQ OPT"]
    assert_equal [ "· no access", "café" ], rpc.description
    assert(rpc.description.all? { |d| d.encoding == Encoding::UTF_8 && d.valid_encoding? })
  end

  def test_a_walk_whose_parameter_count_disagrees_is_refused
    e = assert_raises(Surface::Error) do
      load(walk("RPC|1|XQ OPT|OPT|XQ|1||||||||1|1|Y,A", "PARAM|1|1|A|1||0", "EXPLICIT SUCCESS: rpcs=1 parameters=2"))
    end
    assert_match(/1 parameters read, the walk reports parameters=2/, e.message)
    assert load(walk("RPC|1|XQ OPT|OPT|XQ|1||||||||1|1|Y,A", "PARAM|1|1|A|1||0", "EXPLICIT SUCCESS: rpcs=1 parameters=1"))["XQ OPT"]
  end
  # rpms-ops#732's <tag>-rpcs.json, schema rpcs.v1: one record per RPC, codes as stored.
  def rpcs_doc(rpcs, schema: "rpcs.v1")
    { "schema" => schema, "tag" => TAG, "commit" => "abc1234", "engine" => "yottadb", "rpms_version" => "bcer-0.0",
      "inputs" => {}, "rpcs" => rpcs }
  end

  def rpc_record(name, tag:, routine:, formals: [], parameters: [], package: nil, reach: "client-callable")
    { "name" => name, "entry_point" => { "tag" => tag, "routine" => routine, "formals" => formals },
      "availability" => "P", "inactive" => "0", "return_type" => "1", "parameters" => parameters, "package" => package,
      "reach" => { "class" => reach, "routine_present" => true, "tag_present" => true, "contexts" => [ "OR CPRS GUI CHART" ], "exemptions" => [ "xwb" ] } }
  end

  def from_json(doc)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{TAG}-rpcs.json")
      File.write(path, JSON.generate(doc))
      Surface.from_rpcs_json(path, tag: TAG)
    end
  end

  def test_rpcs_json_reads_the_same_facts_as_the_raw_files
    kernel = { "prefix" => "XU", "name" => "KERNEL", "version" => "8.0" }
    s = from_json(rpcs_doc([
      rpc_record("BPC PMR", tag: nil, routine: "BGUPMR", formals: %w[RET DFN], parameters: [ { "name" => "DFN", "type" => nil, "required" => nil, "source" => "formals" } ]),
      rpc_record("XUS AV CODE", tag: "VALIDAV", routine: "XUSRB", formals: %w[RET AV], package: kernel,
                                parameters: [ { "name" => "AVCODE", "type" => "1", "required" => true, "source" => "8994" } ])
    ]))
    assert s.rpcs_json? && s.reach? && s.signatures?
    refute s.texts?, "rpcs.v1 carries no #8994 text"
    pmr = s["BPC PMR"]
    assert_equal [ "^BGUPMR", nil, [], %w[RET DFN] ], [ pmr.entry_point, pmr.inactive, pmr.params, pmr.formals ]
    av = s["XUS AV CODE"]
    assert_equal [ "VALIDAV^XUSRB", "client-callable", [ "OR CPRS GUI CHART" ], [ "xwb" ] ], [ av.entry_point, av.reach, av.contexts, av.exempt_on ]
    assert_equal [ [ "AVCODE", "1", true ] ], av.params.map { |p| [ p.name, p.type, p.required ] }
    assert_equal({ prefix: "XU", name: "KERNEL", version: "8.0" }, av.package)
    assert_equal [ { prefix: "XU", name: "KERNEL", version: "8.0" } ], s.packages
    assert_equal({ "client-callable" => 2 }, s.reach_counts)
    assert_equal "abc1234", s.meta["commit"]
  end

  def test_rpcs_json_is_refused_for_another_schema_another_tag_or_formals_that_disagree
    assert_raises(Surface::Error) { from_json(rpcs_doc([ rpc_record("X Y", tag: "A", routine: "B") ], schema: "rpcs.v2")) }
    assert_raises(Surface::Error) { from_json(rpcs_doc([ rpc_record("X Y", tag: "A", routine: "B") ]).merge("tag" => "bcer-0.0-other-ydb")) }
    e = assert_raises(Surface::Error) do
      from_json(rpcs_doc([ rpc_record("X Y", tag: "A", routine: "B", formals: %w[RET DFN], parameters: [ { "name" => "IEN", "type" => nil, "required" => nil, "source" => "formals" } ]) ]))
    end
    assert_match(/formals-sourced parameters \["IEN"\] are not \["DFN"\]/, e.message)
  end

  # The raw files' package rule is rpcs.json's: the longest #9.4 prefix of the routine, the first among equals.
  def test_the_raw_files_assign_each_rpc_its_package
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "#{TAG}-broker_8994.txt"), "ORWPT SELECT^SELECT^ORWPT^1\nZZ NONE^X^QQQ^1\nBPC GETLABVISITDATA\n")
      File.write(File.join(dir, "#{TAG}-packages_9_4.txt"), "OR^ORDER ENTRY^3.0\nORWPT^LONGER^1\nORWPT^SAME LENGTH, LATER^2\n")
      s = Surface.load(dir, TAG)
      assert_equal [ "LONGER", nil, nil ], [ s["ORWPT SELECT"].package&.dig(:name), s["ZZ NONE"].package, s["BPC GETLABVISITDATA"].package ]
    end
  end
end
