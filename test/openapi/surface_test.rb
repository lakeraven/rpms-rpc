# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../../tools/openapi/surface"

# OpenApi::Surface (rpms-rpc#395): the pinned build's RPC surface as OpenAPI 3.1. Hermetic: four
# hand-written RPCs, each a case the generator must get right, read through BuildSurface.
class OpenApiSurfaceTest < Minitest::Test
  Surface = OpenApi::Surface
  TAG = "bcer-0.0-20260101-abc1234-ydb"
  GEM = { "name" => "rpms-rpc", "version" => "0.0.0", "commit" => "c0ffee" }.freeze
  BUILD = { "tag" => TAG }.freeze

  # 1 XUS AV CODE    #8994 defines its parameter; ARRAY reply; a return description
  # 2 ORWPT SELECT   no #8994 parameters: the routine's formals after the reply variable (DFN)
  # 3 BMC GONE       registered, its routine is not on the image; INACTIVE 1
  # 4 ORWU WHO?      a "?" in the name; no description at all
  REGISTRY = "XUS AV CODE^VALIDAV^XUSRB^2^R\nORWPT SELECT^SELECT^ORWPT^1\nBMC GONE^GONE^BMCNOPE^1^^1\nORWU WHO?^WHO^ORWU^1\n"
  SIGNATURES = [
    "RPC|11|XUS AV CODE|VALIDAV|XUSRB|2|R|0||||||1|1|RET,AVCODE",
    "DESC|11|This API checks if a ACCESS/VERIFY code pair is valid.   ",
    "DESC|11|R(0)=DUZ if sign-on was OK, zero if not OK.",
    "PARAM|11|1|AVCODE|1|50|1",
    "PDESC|11|1|The access;verify pair, encrypted.",
    "RET|11|R(0) is the DUZ.",
    "RPC|769|ORWPT SELECT|SELECT|ORWPT|1||||||||1|1|REC,DFN",
    "DESC|769|Selects a patient.",
    "RPC|900|BMC GONE|GONE|BMCNOPE|1||1||||||0|0|",
    "RPC|901|ORWU WHO?|WHO|ORWU|1||||||||1|1|Y",
    "EXPLICIT SUCCESS: rpcs=4 description-lines=3 parameters=1"
  ].map { |l| l.tr("|", "\t") }.join("\n") + "\n"
  REACH = "XUS AV CODE^client-callable^1^1^XUS SIGNON^\nORWPT SELECT^client-callable^1^1^OR CPRS GUI CHART;CIAV VUECENTRIC^\n" \
          "BMC GONE^no-routine^0^0^BMCRPC^\nORWU WHO?^no-context^1^1^^\n"
  # ORWPT is listed as a prefix too: the routine ORWPT matches both, and the longest prefix wins.
  PACKAGES = "XU^KERNEL^8.0\nOR^ORDER ENTRY/RESULTS REPORTING^3.0\nORWPT^SHOULD NOT WIN^9\nBMC^REFERRED CARE INFO SYSTEM^4.0\n"

  def surface(registry: REGISTRY, signatures: SIGNATURES, reach: REACH)
    Dir.mktmpdir do |dir|
      { "broker_8994.txt" => registry, "rpc_signatures.txt" => signatures, "rpc_reach.txt" => reach,
        "packages_9_4.txt" => PACKAGES }.each { |k, v| File.binwrite(File.join(dir, "#{TAG}-#{k}"), v) }
      RpmsRpc::Conformance::BuildSurface.load(dir, TAG)
    end
  end

  def doc(**kw) = Surface.document(surface(**kw), build: BUILD, gem: GEM)

  def op(document, name) = OpenApi.operations(document["paths"]).map(&:last).find { |o| o["x-rpms"]["rpc"] == name }
  def body(o) = o.dig("requestBody", "content", Surface::MEDIA, "schema")
  def reply(o) = o.dig("responses", "200", "content", Surface::MEDIA, "schema")

  def test_one_operation_per_rpc_addressed_as_a_resource_and_sorted_by_path
    d = doc
    assert_equal "3.1.0", d["openapi"]
    assert_equal [ "POST /kernel/av-code XUS AV CODE", "POST /order-entry-results-reporting/who ORWU WHO?",
                   "POST /referred-care-info-system/gone BMC GONE", "GET /should-not-win/select ORWPT SELECT" ],
                 OpenApi.operations(d["paths"]).map { |v, p, o| "#{v.upcase} #{p} #{o['summary']}" }
    assert_equal "broker://{host}:{port}", d["servers"][0]["url"]
    assert_equal [], d["security"]
    assert_equal [ GEM, BUILD ], [ d["x-rpms-gem"], d["x-rpms-build"] ]
    assert_equal({ "GET" => 1, "POST" => 3 }, d["x-rpms-counts"]["verbs"])
    assert_equal "bcer-0.0", d["info"]["version"]
    assert_empty OpenApi.problems(d)
    assert_empty OpenApi.schema_problems(d)
  end

  def test_arguments_from_8994
    a = op(doc, "XUS AV CODE")
    assert_equal "8994", a["x-rpms"]["params_source"]
    p = body(a)["properties"]["AVCODE"]
    assert_equal [ "string", 50, 1, "LITERAL", "The access;verify pair, encrypted." ],
                 p.values_at("type", "maxLength", "x-position", "x-rpms-param-type", "description")
    assert_equal [ "AVCODE" ], body(a)["required"]
    assert_equal "array", reply(a)["type"]
    assert_equal "R(0) is the DUZ.", a["responses"]["200"]["description"]
    assert_equal "This API checks if a ACCESS/VERIFY code pair is valid.\nR(0)=DUZ if sign-on was OK, zero if not OK.", a["description"]
    assert_equal [ "VALIDAV^XUSRB", "RESTRICTED", "ARRAY" ], a["x-rpms"].values_at("entry_point", "availability", "return_value_type")
    assert_equal({ "class" => "client-callable", "contexts" => [ "XUS SIGNON" ], "exempt_on" => [] }, a["x-rpms"]["reach"])
    assert_equal [ "KERNEL" ], a["tags"]
  end

  # rpms-ux#26: SEQUENCE NUMBER is empty on many parameters and repeated on some, and an RPC can register
  # one name twice. Every parameter survives, in walk order, with its own description.
  def test_parameters_keep_walk_order_and_a_repeated_name
    sig = [ "RPC|12|TIU COSIGN|COS|TIUSRVP|1||||||||1|1|Y,A,B,C,D", "PARAM|12||DOC|1||1", "PDESC|12||The document.",
            "PARAM|12||COSIGN|1||0", "PDESC|12||The first cosigner.", "PARAM|12|2|COSIGN|1||0", "PARAM|12|2|WHEN|1||0",
            "EXPLICIT SUCCESS: rpcs=1 description-lines=0 parameters=4" ].map { |l| l.tr("|", "\t") }.join("\n") + "\n"
    d = doc(registry: "TIU COSIGN^COS^TIUSRVP^1\n", signatures: sig, reach: "TIU COSIGN^client-callable^1^1^OR CPRS GUI CHART^\n")
    props = body(OpenApi.operations(d["paths"])[0][2])["properties"]
    assert_equal [ [ "DOC", 1, nil, nil ], [ "COSIGN", 2, nil, nil ], [ "COSIGN (2)", 3, 2, "COSIGN" ], [ "WHEN", 4, 2, nil ] ],
                 props.map { |k, p| [ k, p["x-position"], p["x-rpms-sequence"], p["x-rpms-name"] ] }
    assert_equal [ "The document.", "The first cosigner.", nil ], [ props["DOC"]["description"], props["COSIGN"]["description"], props["COSIGN (2)"]["description"] ]
    assert_equal({ "8994" => 4 }, d["x-rpms-counts"]["parameters"])
    assert_equal({ "8994" => 1, "routine" => 1 }, doc["x-rpms-counts"]["parameters"])
  end

  def test_arguments_from_the_routines_formals_and_the_longest_prefix_wins
    s = op(doc, "ORWPT SELECT")
    assert_equal "routine", s["x-rpms"]["params_source"]
    assert_equal [ "DFN" ], body(s)["properties"].keys
    assert_equal "string", reply(s)["type"]
    assert_equal [ "SHOULD NOT WIN" ], s["tags"]
  end

  def test_an_inactive_rpc_is_deprecated_and_a_missing_description_names_the_entry_point
    g = op(doc, "BMC GONE")
    assert_equal [ false, "none", true ], [ g["x-rpms"]["routine_present"], g["x-rpms"]["params_source"], g["deprecated"] ]
    refute g.key?("requestBody")
    w = op(doc, "ORWU WHO?")
    assert_equal "#8994 carries no description for ORWU WHO? (entry point WHO^ORWU).", w["description"]
    assert_equal "none", w["x-rpms"]["params_source"]
  end

  def test_the_path_is_only_an_address_the_rpc_name_stays_on_the_operation
    OpenApi.operations(doc["paths"]).each do |_, _, o|
      assert_equal o["x-rpms"]["rpc"], o["summary"]
      assert_equal o["x-rpms"]["rpc"].downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, ""), o["operationId"]
      assert_match(/\A(read|read noun|write|delete|act|default): /, o["x-rpms"]["verb_rule"])
      assert_equal "base", o["x-rpms"]["path_rule"]
    end
  end

  def addr(name)
    a = Surface.address(name)
    "#{a[:verb].upcase} #{a[:words].join(' ')}"
  end

  def test_verb_rules
    assert_equal "GET DIVISION", addr("XUS DIVISION GET")
    assert_equal "GET USER INFO", addr("XUS GET USER INFO")
    assert_equal "PUT DIVISION", addr("XUS DIVISION SET")
    assert_equal "GET KAAJEE USER INFO", addr("XUS KAAJEE GET USER INFO")
    assert_equal "PUT REFERRAL STATUS", addr("BMC REFERRAL STATUS UPDATE")
    assert_equal "DELETE UNSIG ORDERS ALERT", addr("ORWORB KILL UNSIG ORDERS ALERT")
    assert_equal "DELETE DEL", addr("BGOVHF DEL")
    assert_equal "POST KEYS", addr("XUS SEND KEYS")
    assert_equal "GET CATS", addr("BGOCPTPR GETCATS")
    assert_equal "GET ALLKEYS", addr("XUS ALLKEYS")
    assert_equal "post", Surface.address("GMV ALLERGY")[:verb]
    assert_equal [ "GET DETAIL", "read noun: DETAIL" ], [ addr("BEHOARCV DETAIL"), Surface.address("BEHOARCV DETAIL")[:verb_rule] ]
    assert_equal [ "POST AV CODE", "default: no verb word" ], [ addr("XUS AV CODE"), Surface.address("XUS AV CODE")[:verb_rule] ]
    assert_equal "POST SIGNON SETUP", addr("XUS SIGNON SETUP"), "SETUP is not SET: words match whole"
    assert_equal [ nil, [ "MAGGPATINFO" ] ], Surface.address("MAGGPATINFO").values_at(:namespace, :words)
    assert_equal "/imaging/maggpatinfo", Surface.addresses([ "MAGGPATINFO" ], "imaging")["MAGGPATINFO"][:path]
  end

  def test_clashing_rpcs_move_up_a_tier_until_every_verb_and_path_is_unique
    names = [ "ORWPCE DELETE", "ORWDX DELETE", "BGOVHF DEL", "BMX EVENT REGISTER", "BMX EVENT UNREGISTER",
              "XHD DEL PARAMETER CATEGORY", "XHD DELETE PARAMETER CATEGORY", "XUS DIVISION GET", "XUS DIVISION SET" ]
    a = Surface.addresses(names, "p")
    assert_equal({
      "ORWPCE DELETE" => "DELETE /p/orwpce/delete (namespace)",
      "ORWDX DELETE" => "DELETE /p/orwdx/delete (namespace)",
      "BGOVHF DEL" => "DELETE /p/del (base)",
      "BMX EVENT REGISTER" => "POST /p/event-register (verb word kept)",
      "BMX EVENT UNREGISTER" => "POST /p/event-unregister (verb word kept)",
      "XHD DEL PARAMETER CATEGORY" => "DELETE /p/del-parameter-category (verb word kept)",
      "XHD DELETE PARAMETER CATEGORY" => "DELETE /p/delete-parameter-category (verb word kept)",
      "XUS DIVISION GET" => "GET /p/division (base)",
      "XUS DIVISION SET" => "PUT /p/division (base)"
    }, names.to_h { |n| [ n, "#{a[n][:verb].upcase} #{a[n][:path]} (#{a[n][:path_rule]})" ] })
    assert_raises(OpenApi::Refused) { Surface.addresses([ "XU WHO?", "XU WHO!" ], "p") }
  end

  # The same four RPCs as rpms-ops#732's <tag>-rpcs.json projects them from the raw files above.
  RPCS_JSON = {
    "schema" => "rpcs.v1", "tag" => TAG, "commit" => "abc1234", "engine" => "yottadb", "rpms_version" => "bcer-0.0", "inputs" => {},
    "rpcs" => [
      [ "BMC GONE", "GONE", "BMCNOPE", [], "1", nil, "1", [], [ "BMC", "REFERRED CARE INFO SYSTEM", "4.0" ], [ "no-routine", false, false, [ "BMCRPC" ] ] ],
      [ "ORWPT SELECT", "SELECT", "ORWPT", %w[REC DFN], "1", nil, nil, [ [ "DFN", nil, nil, "formals" ] ], [ "ORWPT", "SHOULD NOT WIN", "9" ],
        [ "client-callable", true, true, [ "OR CPRS GUI CHART", "CIAV VUECENTRIC" ] ] ],
      [ "ORWU WHO?", "WHO", "ORWU", %w[Y], "1", nil, nil, [], [ "OR", "ORDER ENTRY/RESULTS REPORTING", "3.0" ], [ "no-context", true, true, [] ] ],
      [ "XUS AV CODE", "VALIDAV", "XUSRB", %w[RET AVCODE], "2", "R", "0", [ [ "AVCODE", "1", true, "8994" ] ], [ "XU", "KERNEL", "8.0" ],
        [ "client-callable", true, true, [ "XUS SIGNON" ] ] ]
    ].map do |name, tag, routine, formals, ret, avail, inactive, params, (prefix, pname, version), (klass, rp, tp, contexts)|
      { "name" => name, "entry_point" => { "tag" => tag, "routine" => routine, "formals" => formals }, "availability" => avail,
        "inactive" => inactive, "return_type" => ret,
        "parameters" => params.map { |n, t, r, src| { "name" => n, "type" => t, "required" => r, "source" => src } },
        "package" => { "prefix" => prefix, "name" => pname, "version" => version },
        "reach" => { "class" => klass, "routine_present" => rp, "tag_present" => tp, "contexts" => contexts, "exemptions" => [] } }
    end
  }.freeze

  # #8994's text that rpcs.v1 does not carry: everything else about an operation is the same from either source.
  def without_text(document)
    ops = OpenApi.operations(document["paths"]).to_h do |verb, path, op|
      op = JSON.parse(JSON.generate(op))
      op.delete("description")
      op["responses"]["200"].delete("description")
      op["x-rpms"].delete("version")
      op["x-rpms"].delete("word_wrap")
      op.dig("requestBody", "content", Surface::MEDIA, "schema", "properties")&.each_value { |p| %w[description maxLength x-rpms-sequence].each { |k| p.delete(k) } }
      [ "#{verb} #{path}", op ]
    end
    [ ops, document["tags"], document["x-rpms-counts"] ]
  end

  def test_rpcs_json_gives_the_same_document_as_the_raw_files_but_for_8994_text
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{TAG}-rpcs.json")
      File.write(path, JSON.generate(RPCS_JSON))
      from_json = Surface.document(RpmsRpc::Conformance::BuildSurface.from_rpcs_json(path, tag: TAG), build: BUILD, gem: GEM)
      assert_equal without_text(doc), without_text(from_json)
      assert_equal "XUS AV CODE (entry point VALIDAV^XUSRB). The rpcs.v1 file this document is generated from carries no #8994 DESCRIPTION.",
                   op(from_json, "XUS AV CODE")["description"]
      assert_empty OpenApi.problems(from_json)
    end
  end

  # The same four RPCs as rpcs.v2 (rpms-ops#877) projects them: v1 plus #8994's text, as stored in the walk above.
  RPCS_V2_JSON = RPCS_JSON.merge(
    "schema" => "rpcs.v2",
    "rpcs" => RPCS_JSON["rpcs"].map do |r|
      text = {
        "XUS AV CODE" => { "description" => [ "This API checks if a ACCESS/VERIFY code pair is valid.   ", "R(0)=DUZ if sign-on was OK, zero if not OK." ],
                           "returns" => [ "R(0) is the DUZ." ] },
        "ORWPT SELECT" => { "description" => [ "Selects a patient." ], "returns" => [] }
      }.fetch(r["name"], { "description" => [], "returns" => [] })
      params = r["parameters"].map do |p|
        extra = p["source"] == "8994" ? { "sequence" => "1", "max_length" => "50", "description" => [ "The access;verify pair, encrypted." ] } : { "sequence" => nil, "max_length" => nil, "description" => [] }
        p.merge(extra)
      end
      r.merge(text, "word_wrap" => nil, "version" => nil, "parameters" => params)
    end
  ).freeze

  # With the text, a document from rpcs.json alone is the document from the raw files, field for field.
  def test_rpcs_v2_gives_exactly_the_document_the_raw_files_give
    Dir.mktmpdir do |dir|
      path = File.join(dir, "#{TAG}-rpcs.json")
      File.write(path, JSON.generate(RPCS_V2_JSON))
      from_json = Surface.document(RpmsRpc::Conformance::BuildSurface.from_rpcs_json(path, tag: TAG), build: BUILD, gem: GEM)
      assert_equal OpenApi.pretty(doc), OpenApi.pretty(from_json)
    end
  end

  def test_the_same_inputs_give_the_same_bytes
    assert_equal OpenApi.pretty(doc), OpenApi.pretty(doc)
  end
end
