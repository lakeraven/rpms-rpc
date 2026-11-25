# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "rpms_rpc/conformance/build_surface"
require_relative "../pinned_rpcs_test_helper"
require_relative "../rpcs_v3_fixture"

# BuildSurface (rpms-rpc#394, #395, #406): the one reader of a build's <tag>-rpcs.json, on the pinned
# build's own document, records taken from it, a real rpcs.v2 extract and a real rpcs.v3 file.
class RpmsRpc::Conformance::BuildSurfaceTest < Minitest::Test
  Surface = RpmsRpc::Conformance::BuildSurface
  P = PinnedRpcsTestHelper
  TAG = P::TAG
  # Two records, verbatim, from bcer-9.0-20261108-095b233-ydb-rpcs.json (schema rpcs.v2, openrpms#877).
  V2_EXTRACT = File.expand_path("../../fixtures/rpcs/bcer-9.0-20261108-095b233-ydb-rpcs.extract.json", __dir__)

  def pinned = @pinned ||= Surface.load(P::INVENTORY_DIR, TAG)

  def from_doc(doc)
    Dir.mktmpdir { |dir| Surface.load(P.write_inventory(dir, TAG, document: doc), TAG) }
  end

  def from_records(records, sort: true) = from_doc(P.doc(records, sort: sort))

  # The pinned document read whole: every record, its header, and the fields the gates use.
  def test_the_pinned_rpcs_json_reads_as_the_build_surface
    assert_equal P.pinned_doc["rpcs"].size, pinned.rpcs.size
    assert_equal P.pinned_doc.except("rpcs"), pinned.meta
    assert pinned.reach? && pinned.signatures? && pinned.contexts?
    refute pinned.texts?, "#{TAG} publishes rpcs.v1, which carries no #8994 text"
    pmr = pinned["BPC PMR"]
    assert_equal [ "^BGUPMR", nil, [], "no-context" ], [ pmr.entry_point, pmr.inactive, pmr.params, pmr.reach ]
    av = pinned["XUS AV CODE"]
    assert_equal [ "VALIDAV^XUSRB", "client-callable", [ "XUS SIGNON" ], %w[RET AVCODE] ], [ av.entry_point, av.reach, av.contexts, av.formals ]
    assert_equal [ [ "AVCODE", "1", true ] ], av.params.map { |p| [ p.name, p.type, p.required ] }
    assert_equal({ prefix: "XU", name: "KERNEL", version: "8.0" }, av.package)
    assert_equal "3", pinned["XUS CCOW VAULT PARAM"].inactive
    assert_equal [ "DFN" ], P.record("ORWPT SELECT")["parameters"].map { |p| p["name"] }
    assert_empty pinned["ORWPT SELECT"].params, "formals-sourced parameters are not #8994 INPUT PARAMETERs"
    assert_equal pinned.rpcs.map(&:reach).tally.sort.to_h, pinned.reach_counts
  end

  def test_a_document_for_another_schema_or_another_tag_is_refused
    e = assert_raises(Surface::Error) { from_doc(P.doc(P.records("XUS AV CODE")).merge("schema" => "rpcs.v4")) }
    assert_match(/schema "rpcs.v4", not one of rpcs.v1, rpcs.v2, rpcs.v3/, e.message)
    e = assert_raises(Surface::Error) { from_doc(P.doc(P.records("XUS AV CODE")).merge("tag" => "bcer-9.0-20990101-0000000-ydb")) }
    assert_match(/names tag "bcer-9.0-20990101-0000000-ydb", not #{TAG}/, e.message)
  end

  def test_formals_sourced_parameters_must_be_what_the_formals_say
    rec = P.record("ORWPT SELECT")
    rec["parameters"][0]["name"] = "IEN"
    e = assert_raises(Surface::Error) { from_records([ rec ]) }
    assert_match(/formals-sourced parameters \["IEN"\] are not \["DFN"\]/, e.message)
  end

  def test_an_empty_a_repeated_or_an_unsorted_list_of_rpcs_is_refused
    assert_match(/lists no RPCs/, assert_raises(Surface::Error) { from_records([]) }.message)
    twice = P.records("XUS AV CODE", "XUS AV CODE")
    assert_match(/lists XUS AV CODE more than once/, assert_raises(Surface::Error) { from_records(twice) }.message)
    unsorted = P.records("XUS AV CODE", "ORWPT SELECT")
    assert_match(/byte order of name/, assert_raises(Surface::Error) { from_records(unsorted, sort: false) }.message)
    assert_equal [ "ORWPT SELECT", "XUS AV CODE" ], from_records(unsorted).names
  end

  def test_an_unknown_reach_class_is_refused
    e = assert_raises(Surface::Error) { from_records([ P.record("ORWPT SELECT", reach: { "class" => "maybe-callable" }) ]) }
    assert_match(/"ORWPT SELECT" has reach "maybe-callable", not one of/, e.message)
  end

  # rpcs.v2 (openrpms#877) adds #8994's text, as stored: XWB CREATE CONTEXT's description carries the
  # Latin-1 bullet (U+00B7) its #8994 entry stores.
  def test_rpcs_v2_carries_the_8994_text
    s = Surface.from_rpcs_json(V2_EXTRACT, tag: "bcer-9.0-20261108-095b233-ydb")
    assert s.texts?
    av = s["XUS AV CODE"]
    assert_equal "This API checks if a ACCESS/VERIFY code pair is valid.", av.description.first
    assert_equal [ [ "AVCODE", nil, "60", [ "accessCode_\";\"_verifyCode in unencrypted form." ] ] ],
                 av.params.map { |p| [ p.name, p.seq, p.max_length, p.description ] }
    bullet = s["XWB CREATE CONTEXT"].description.find { |l| l.include?("no access") }
    assert_equal "       · The user has no access to that option", bullet
    assert(s["XWB CREATE CONTEXT"].description.all? { |d| d.encoding == Encoding::UTF_8 && d.valid_encoding? })

    v1 = from_doc(JSON.parse(File.read(V2_EXTRACT)).merge("schema" => "rpcs.v1", "tag" => TAG))
    refute v1.texts?, "rpcs.v1 carries no text, so none is read"
    r = v1["XUS AV CODE"]
    assert_equal [ [], [], nil, nil, nil ], [ r.description, r.returns, r.word_wrap, r.params[0].seq, r.params[0].max_length ]
  end

  # --- rpcs.v3: reach.via, the nested reach (openrpms#1359), on a real v3 file (test/rpms_rpc/rpcs_v3_fixture.rb) --

  V3 = RpcsV3Fixture
  VC = "CIAV VUECENTRIC"
  CPRS = "OR CPRS GUI CHART"

  def v3_surface(document = nil) = Dir.mktmpdir { |dir| Surface.load(V3.write(dir, document), V3::TAG) }
  def v3 = @v3 ||= v3_surface

  def test_rpcs_v3_keeps_each_nested_chain
    assert v3.via? && v3.texts?
    assert_equal 5592, v3.rpcs.size
    orwpt = v3["ORWPT SELECT"]
    assert_equal [ "#{VC}>#{CPRS}", "MWVS MEDICAL DOMAIN WEB SVCS>#{CPRS}" ], orwpt.via.map(&:chain)
    assert_equal [ [ VC, [ CPRS ], false ] ], orwpt.via.first(1).map { |v| [ v.context, v.through, v.out_of_order ] }
    assert_equal [ [ "BQIRPC", [ "BTPWRPC" ] ] ], v3["BTPW BATCH EVENT INITIAL"].via.map { |v| [ v.context, v.through ] }
    assert_equal [ [ "BJPNRPC", [ "BSTSRPC" ] ] ], v3["BEHUTIL CVERPAT"].via.map { |v| [ v.context, v.through ] }
    assert_equal [], v3["XUS AV CODE"].via
    assert_equal 1104, v3.rpcs.count { |r| r.via.any? }
  end

  # VueCentric reaches GMV ADD VM only through OR CPRS GUI CHART: contexts does not name it, reaching_contexts does.
  # Across the release that is 256 RPCs, the count openrpms' releases/README.md gives for bcer-9.0.
  def test_an_rpc_vuecentric_reaches_through_the_cprs_option_names_vuecentric
    gmv = v3["GMV ADD VM"]
    refute_includes gmv.contexts, VC
    assert_includes gmv.reaching_contexts, VC
    assert gmv.reached_via?(VC)
    refute gmv.reached_via?(CPRS), "OR CPRS GUI CHART lists it itself; it is not reached through a nested option"
    assert_equal 256, v3.rpcs.count { |r| !r.contexts.include?(VC) && r.reaching_contexts.include?(VC) }

    stopped = V3.doc
    stopped["rpcs"].find { |r| r["name"] == "GMV ADD VM" }["reach"]["via"].each { |v| v["out_of_order"] = true }
    refute v3_surface(stopped)["GMV ADD VM"].reached_via?(VC), "a chain with an option out of order serves no one"
  end

  # The same records as rpcs.v2 (the release's published document): read as before, field for field, without via.
  def test_the_v2_document_reads_the_same_records_without_via
    v2 = v3_surface(V3.as_v2)
    refute v2.via?
    assert v2.texts?
    assert(v2.rpcs.all? { |r| r.via.nil? })
    assert_equal v3.rpcs.map { |r| r.to_h.except(:via) }, v2.rpcs.map { |r| r.to_h.except(:via) }
    gmv = v2["GMV ADD VM"]
    assert_equal gmv.contexts, gmv.reaching_contexts
    refute gmv.reached_via?(VC)
  end

  def test_an_rpcs_v3_record_without_via_or_with_a_broken_chain_is_refused
    bare = V3.doc
    bare["rpcs"].find { |r| r["name"] == "ORWPT SELECT" }["reach"].delete("via")
    e = assert_raises(Surface::Error) { v3_surface(bare) }
    assert_match(/"ORWPT SELECT" has no reach.via, which rpcs.v3 carries on every record/, e.message)

    [ { "context" => VC, "through" => [], "out_of_order" => false }, { "context" => VC, "through" => [ CPRS ] },
      "#{VC}>#{CPRS}" ].each do |chain|
      broken = V3.doc
      broken["rpcs"].find { |r| r["name"] == "ORWPT SELECT" }["reach"]["via"] = [ chain ]
      e = assert_raises(Surface::Error) { v3_surface(broken) }
      assert_match(/"ORWPT SELECT" has reach.via .*, not \{context, through, out_of_order\}/, e.message)
    end
  end

  # --- <tag>-contexts_19_05.txt (rpms-rpc#416, openrpms#626) -------------------------------------

  CONTEXTS = [
    "OPTION|TYPE|LOCK|RPC|RPC_KEY|RPC_RULES",
    "ADEKRPC|B|ADEZMENU|XQ OPT|ADEZMENU|",
    "OR CPRS GUI CHART|B||XQ OPT||",
    "XUS SIGNON|B||XUS AV CODE||"
  ].map { |l| l.tr("|", "\t") }.join("\n") + "\n"

  # Real records of the four RPCs, beside a contexts file of the shapes openrpms#626 writes.
  # XQ OPT stands for an RPC a keyed and a locked context list; it is the pinned XUS DIVISION GET.
  def with_contexts(contexts = CONTEXTS, reach: {})
    Dir.mktmpdir do |dir|
      records = [ "XUS DIVISION GET", "XUS AV CODE", "XWB CREATE CONTEXT", "ORWPT SELECT" ].map do |name|
        rec = P.record(name, reach: reach[name])
        rec["name"] = "XQ OPT" if name == "XUS DIVISION GET"
        rec
      end
      inv = P.write_inventory(dir, TAG, records)
      File.write(File.join(inv, "#{TAG}-contexts_19_05.txt"), contexts)
      yield Surface.load(inv, TAG)
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
    with_contexts(reach: { "ORWPT SELECT" => { "class" => "no-context", "contexts" => [] } }) do |s|
      assert_equal "broker-exempt", s.reach("XWB CREATE CONTEXT"), "the pinned build exempts XWB CREATE CONTEXT"
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
      s = Surface.load(P.write_inventory(dir, TAG, P.records("ORWPT SELECT")), TAG)
      refute s.contexts?
      assert_raises(Surface::Error) { s.context_refusal("OR CPRS GUI CHART", "XQ OPT") }
    end
  end
end
