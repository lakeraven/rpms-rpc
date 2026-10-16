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
    assert_raises(Surface::Error) { from_json(rpcs_doc([ rpc_record("X Y", tag: "A", routine: "B") ], schema: "rpcs.v3")) }
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

  # rpcs.v2 (rpms-ops#877) adds #8994's text, as stored: each byte is the Latin-1 code point of its value.
  def test_rpcs_v2_carries_the_8994_text
    rec = rpc_record("XUS AV CODE", tag: "VALIDAV", routine: "XUSRB", formals: %w[RET AVCODE],
                                    parameters: [ { "name" => "AVCODE", "type" => "1", "required" => true, "source" => "8994",
                                                    "sequence" => "1", "max_length" => "50", "description" => [ "The pair." ] } ])
    rec = rec.merge("description" => [ "· Checks a pair.", "" ], "returns" => [ "R(0) is the DUZ." ], "word_wrap" => "1", "version" => "2")
    s = from_json(rpcs_doc([ rec ], schema: "rpcs.v2"))
    assert s.texts?
    r = s["XUS AV CODE"]
    assert_equal [ [ "· Checks a pair.", "" ], [ "R(0) is the DUZ." ], "1", "2" ], [ r.description, r.returns, r.word_wrap, r.version ]
    assert_equal [ [ "1", "50", [ "The pair." ] ] ], r.params.map { |p| [ p.seq, p.max_length, p.description ] }

    v1 = from_json(rpcs_doc([ rec ]))["XUS AV CODE"]
    refute from_json(rpcs_doc([ rec ])).texts?, "rpcs.v1 carries no text, so none is read"
    assert_equal [ [], [], nil, nil, nil, nil ], [ v1.description, v1.returns, v1.word_wrap, v1.version, v1.params[0].seq, v1.params[0].max_length ]
  end

  # --- <tag>-contexts_19_05.txt (rpms-rpc#416, rpms-ops#626) -------------------------------------

  CONTEXTS = [
    "OPTION|TYPE|LOCK|RPC|RPC_KEY|RPC_RULES",
    "ADEKRPC|B|ADEZMENU|XQ OPT|ADEZMENU|",
    "OR CPRS GUI CHART|B||XQ OPT||",
    "XUS SIGNON|B||XUS AV CODE||"
  ].map { |l| l.tr("|", "\t") }.join("\n") + "\n"

  def with_contexts(contexts = CONTEXTS, reach: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "#{TAG}-broker_8994.txt"),
                 "XQ OPT^OPT^XQ^1\nXUS AV CODE^VALIDAV^XUSRB^2\nXWB CREATE CONTEXT^CRCONTXT^XWBSEC^1\nORWPT SELECT^SELECT^ORWPT^1\n")
      File.write(File.join(dir, "#{TAG}-rpc_reach.txt"), reach) if reach
      File.write(File.join(dir, "#{TAG}-contexts_19_05.txt"), contexts)
      yield Surface.load(dir, TAG)
    end
  end

  def test_a_context_serves_only_the_rpcs_its_rpc_multiple_lists
    with_contexts do |s|
      assert s.contexts?
      assert_nil s.context_refusal("OR CPRS GUI CHART", "XQ OPT")
      assert_equal "OR CPRS GUI CHART does not serve ORWPT SELECT on #{TAG}", s.context_refusal("OR CPRS GUI CHART", "ORWPT SELECT")
      assert_equal "NO SUCH OPTION serves no RPC on #{TAG}", s.context_refusal("NO SUCH OPTION", "XQ OPT")
    end
  end

  def test_a_locked_context_or_a_keyed_rpc_needs_its_key
    with_contexts do |s|
      assert_equal "ADEKRPC is locked by ADEZMENU", s.bind_refusal("ADEKRPC")
      assert_nil s.bind_refusal("ADEKRPC", keys: [ "ADEZMENU" ])
      assert_nil s.bind_refusal("OR CPRS GUI CHART")
      assert_equal "The context 'NO SUCH OPTION' does not exist on server.", s.bind_refusal("NO SUCH OPTION")
      assert_equal "XQ OPT under ADEKRPC needs key ADEZMENU", s.context_refusal("ADEKRPC", "XQ OPT")
      assert_nil s.context_refusal("ADEKRPC", "XQ OPT", keys: [ "ADEZMENU" ])
    end
  end

  # XWBSEC lets a session run XUS SIGNON's RPCs and the broker-exempt ones whatever is bound:
  # sign-on is never refused by the context table.
  def test_sign_on_and_broker_exempt_rpcs_are_never_refused
    reach = "XQ OPT^client-callable^1^1^OR CPRS GUI CHART^\nXUS AV CODE^client-callable^1^1^XUS SIGNON^\n" \
            "XWB CREATE CONTEXT^broker-exempt^1^1^^xwb\nORWPT SELECT^no-context^1^1^^\n"
    with_contexts(reach: reach) do |s|
      assert_nil s.context_refusal("OR CPRS GUI CHART", "XUS AV CODE")
      assert_nil s.context_refusal("OR CPRS GUI CHART", "XWB CREATE CONTEXT")
      refute_nil s.context_refusal("OR CPRS GUI CHART", "ORWPT SELECT")
    end
  end

  def test_a_contexts_file_without_its_header_or_with_a_short_row_is_refused
    e = assert_raises(Surface::Error) { with_contexts(CONTEXTS.lines.drop(1).join) { nil } }
    assert_match(/header is not OPTION TYPE LOCK RPC RPC_KEY RPC_RULES/, e.message)
    e = assert_raises(Surface::Error) { with_contexts(CONTEXTS + "XUS SIGNON\tB\n") { nil } }
    assert_match(/has 2 fields, not 6/, e.message)
  end

  def test_without_a_contexts_file_the_refusal_question_is_an_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "#{TAG}-broker_8994.txt"), "XQ OPT^OPT^XQ^1\n")
      s = Surface.load(dir, TAG)
      refute s.contexts?
      assert_raises(Surface::Error) { s.context_refusal("OR CPRS GUI CHART", "XQ OPT") }
    end
  end
end
