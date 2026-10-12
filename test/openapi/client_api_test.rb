# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../tools/openapi/client_api"

# OpenApi::ClientApi (rpms-rpc#395): rake rpc:api_coverage's methods as a resource-oriented OpenAPI
# document. Hermetic: hand-written methods, one per mapping rule.
class OpenApiClientApiTest < Minitest::Test
  Api = OpenApi::ClientApi
  GEM = { "name" => "rpms-rpc", "version" => "0.0.0", "commit" => "c0ffee" }.freeze

  def req(*names) = names.map { |n| { "name" => n, "kind" => "req" } }
  def rpc(name) = { "name" => name, "registered" => true, "entry_point" => "X^#{name.split.first}", "reach" => "client-callable", "via" => "literal" }

  def method(mod, name, params = [], rpc: "ORWPT SELECT", proven: false)
    { "module" => "RpmsRpc::#{mod}", "method" => name, "arity" => params.size, "params" => params, "rpcs" => [ rpc(rpc) ],
      "unresolved" => [], "live_specs" => proven ? [ "test/live/x_test.rb:1" ] : [], "personas" => [],
      "status" => proven ? "proven" : "not_in_contract" }
  end

  def at(m)
    a = Api.address(m)
    "#{a[:verb].upcase} #{a[:path]}"
  end

  def ops(methods) = Api.catalog({ "schema" => 1, "methods" => methods })[:entries]

  def test_reads
    assert_equal "GET /patients/{dfn}", at(method("Patient", "find", req("dfn")))
    assert_equal "GET /patients/{dfn}/procedures", at(method("Procedure", "for_patient", req("dfn")))
    assert_equal "GET /patients/{dfn}/brief-header", at(method("Patient", "brief_header", req("dfn")))
    assert_equal "GET /patients/{dfn}/problems/{ien}", at(method("Problem", "details", req("dfn", "ien")))
    assert_equal "GET /problems/{ien}/audit-history", at(method("Problem", "audit_history", req("ien")))
    assert_equal "GET /visits/{visit_ien}/measurements", at(method("Measurement", "for_visit", req("visit_ien")))
    assert_equal "GET /users/{user_duz}/orders/unsigned", at(method("Order", "unsigned_for_user", req("user_duz")))
    assert_equal "GET /orders/{order_ien}/expired", at(method("Order", "expired?", req("order_ien")))
  end

  def test_search_is_a_query_on_the_collection
    q = ->(ms) { ops(ms).map { |e| [ e[:op]["operationId"], "#{e[:addr][:verb].upcase} #{e[:addr][:path]}", e[:op]["parameters"].select { |p| p["in"] == "query" }.map { |p| p["name"] } ] } }
    assert_equal [ [ "Patient.search", "GET /patients", [ "name_pattern" ] ] ], q.([ method("Patient", "search", req("name_pattern")) ])
    assert_equal [ [ "Patient.find_by_ssn", "GET /patients", [ "ssn" ] ] ], q.([ method("Patient", "find_by_ssn", req("ssn")) ])
    assert_equal "GET /referrals/referred-to", at(method("Referral", "search_referred_to", [ { "name" => "params", "kind" => "rest" } ]))
  end

  def test_two_queries_on_one_collection
    r = ->(ms) { ops(ms).to_h { |e| [ e[:op]["operationId"], "#{e[:addr][:verb].upcase} #{e[:addr][:path]} #{e[:op]['x-rpms']['rule']}" ] } }
    assert_equal({ "Patient.search" => "GET /patients query", "Patient.lookup" => "GET /patients/lookup query-sub-path",
                   "Patient.find_by_ssn" => "GET /patients/by-ssn query-sub-path" },
                 r.([ method("Patient", "find_by_ssn", req("ssn"), rpc: "ORWPT FULLSSN"), method("Patient", "lookup", req("text"), rpc: "AGG LOOKUP PATIENTS"),
                      method("Patient", "search", req("name_pattern"), rpc: "ORWPT LIST ALL") ]).sort_by { |k, _| [ "Patient.search", "Patient.lookup", "Patient.find_by_ssn" ].index(k) }.to_h)
    assert_equal "GET /practitioners/search query-sub-path",
                 r.([ method("Practitioner", "list"), method("Practitioner", "search", req("name_pattern")) ])["Practitioner.search"]
    same = ops([ method("Patient", "search", req("name_pattern")), method("Patient", "find_by_name", req("name")) ])
    assert_equal 1, same.size, "the same RPCs on the same path are one query: folded"
    assert_equal [ [ "name_pattern", true ], [ "name", false ] ], same[0][:op]["parameters"].map { |p| [ p["name"], p["required"] ] }
    assert_equal [ "Patient.find_by_name" ], same[0][:op]["x-rpms"]["folded"]
  end

  def test_writes_and_actions
    assert_equal "POST /patients/{dfn}/procedures", at(method("Procedure", "add", req("dfn", "visit_ien", "cpt_code")))
    assert_equal "POST /patients", at(method("Patient", "register", req("attrs")))
    assert_equal "PUT /patients/{dfn}", at(method("Patient", "update", [ { "name" => "dfn", "kind" => "req" }, { "name" => "patient_fields", "kind" => "key" } ]))
    assert_equal "PUT /progress-notes/{note_ien}/text", at(method("ProgressNote", "update_text", req("note_ien", "text")))
    assert_equal "DELETE /patients/{dfn}/problems/{ien}", at(method("Problem", "delete", [ *req("dfn", "ien"), { "name" => "reason", "kind" => "keyreq" } ]))
    assert_equal "POST /referrals/{ien}/cancel", at(method("Referral", "cancel", req("ien")))
    assert_equal "POST /appointments/{appointment_ien}/cancel", at(method("Scheduling", "cancel_appointment", req("appointment_ien")))
  end

  def test_read_only_queries_named_like_actions_are_get
    assert_equal "GET /progress-notes/{note_ien}/authorize", at(method("ProgressNote", "authorize", req("note_ien")))
    assert_equal "GET /progress-notes/{note_ien}/signatures/which-action", at(method("ESignature", "which_action", req("note_ien", "user_duz")))
    assert_equal "GET /users/{user_duz}/sessions/bootstrap", at(method("Session", "bootstrap", req("user_duz")))
    assert_equal "GET /users/{duz}/has-key", at(method("Authentication", "has_key", req("duz")))
    assert_equal "POST /appointments/{appointment_ien}/checkin", at(method("Scheduling", "checkin_appointment", req("appointment_ien")))
  end

  def test_identifiers
    kw = ->(n) { { "name" => n, "kind" => "keyreq" } }
    assert_equal "GET /files/{file}/entries/{iens}", at(method("DdrFileman", "gets_entry", [ kw.("file"), kw.("iens"), kw.("fields") ]))
    assert_equal "GET /behavioral-health/treatment-plans/{plan_ien}/narrative", at(method("BehavioralHealth", "treatment_plan_narrative", req("plan_ien")))
    assert_equal "GET /referrals/rcis-templates/{template_ien}", at(method("Referral", "rcis_template_detail", req("template_ien")))
    assert_equal "GET /patients/{dfn}/reminders/applicable",
                 at(method("Reminders", "applicable", [ { "name" => "dfn", "kind" => "req" }, { "name" => "location_ien", "kind" => "opt" } ]))
    assert_equal "allergies", Api.plural("allergy")
  end

  def test_one_document_with_a_tag_per_collection
    d = Api.document({ "schema" => 1, "registry" => "bcer-0.0", "methods" => [
      method("Authentication", "user_info", req("duz"), proven: true), method("UserManagement", "find", req("duz")),
      method("BehavioralHealth::Groups", "groups")
    ] }, gem: GEM)
    assert_equal [ "/behavioral-health", "/users" ], d["tags"].map { |t| t["name"] }
    assert_equal [ [ "users", [ "RpmsRpc::Authentication", "RpmsRpc::UserManagement" ], 2, 1 ] ],
                 d["x-rpms-api"]["collections"].select { |c| c["name"] == "users" }.map { |c| c.values_at("name", "modules", "operations", "proven") }
    find = OpenApi.operations(d["paths"]).map(&:last).find { |o| o["operationId"] == "UserManagement.find" }
    assert_equal [ "/users" ], find["tags"]
    assert_equal "RpmsRpc::UserManagement.find(duz)", find["summary"]
    assert_equal [ [ "ORWPT SELECT", true, "client-callable" ] ], find["x-rpms"]["rpcs"].map { |r| r.values_at("name", "registered", "reach") }
    assert_equal [ GEM, { "tag" => "bcer-0.0" } ], [ d["x-rpms-gem"], d["x-rpms-build"] ]
    assert_empty OpenApi.problems(d)
    assert_empty OpenApi.schema_problems(d)
  end

  def test_only_rpc_backed_methods_become_operations_and_a_clash_is_refused
    helper = method("Patient", "age_from", req("dob")).merge("rpcs" => [])
    ghost = method("Patient", "ghost", req("dfn")).merge("rpcs" => [ rpc("ZZ GHOST").merge("registered" => false) ])
    cat = Api.catalog({ "schema" => 1, "methods" => [ helper, ghost, method("Patient", "find", req("dfn")) ] })
    assert_equal({ "no_rpc" => [ "Patient.age_from" ], "unresolved" => [], "unregistered" => [ "Patient.ghost" ] }, cat[:excluded])
    assert_equal 1, cat[:entries].size
    assert_raises(OpenApi::Refused) { ops([ method("Patient", "find", req("dfn")), method("Patient", "fetch", req("dfn")) ]) }
  end
end
