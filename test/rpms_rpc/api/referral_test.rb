# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/referral"
require_relative "../captured_replies"

# RpmsRpc::Referral's BMC* calls. Every reply is the build's
# (test/fixtures/captured_replies/referral-calls.yml), captured as PROFILE,MD
# on a fresh throwaway container: one flow per public method that reaches the
# wire, M errors included, after setup filed referrals 1 and 2 for demo
# patient 990002. The record layouts are in referral_wire_test.rb.
class ReferralTest < Minitest::Test
  SLUG = "referral-calls"
  DFN = "990002"

  # A CIA session that also records the option bound when each RPC went out.
  class Replay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end

    def binds = @calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }
  end

  def setup
    replay
  end

  def teardown
    RpmsRpc.reset!
  end

  # A client with no replies unless a flow is named: a test that reaches the
  # wire without one fails.
  def replay(flow = nil, client_class: Replay)
    @client = client_class.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def flow_inputs(flow) = CapturedReplies.flow_calls(SLUG, flow).first.last

# Referral.create is honestly :not_implemented (#217): its former binding
# BGOREF SET is the personal REFUSALS writer (SET^BGOREF files ^AUPNPREF —
# BGOREF.m:8,29), and the real referral writer (BMC ADD REFERRAL =
# SETREFRL^BMCRPC2, 39 positional formals) is exposed as Referral.add.

def test_create_is_not_implemented_and_calls_no_rpc
  result = RpmsRpc::Referral.create(DFN, { specialty: "CARDIOLOGY" })

  refute result[:success]
  assert_equal :not_implemented, result[:error]
  assert_match(/BGOREF SET writes refusals/, result[:message])
  assert_empty @client.calls, "create must not touch the broker — BGOREF SET would file a refusal"
end

def test_create_raises_on_non_hash_params
  err = assert_raises(ArgumentError) { RpmsRpc::Referral.create(DFN, "not a hash") }
  assert_match(/must be a Hash/, err.message)
end

def test_create_blank_dfn_returns_failure
  result = RpmsRpc::Referral.create(nil, { provider_ien: 1 })
  refute result[:success]
  assert_nil result[:ien]
end

# SETREFRL^BMCRPC2 takes 40 formals; the capture sent the date, the patient
# and the required pieces. Success is "~`1^IEN" (BMCRPC2.m:155).
def test_add_referral_sigil_success_is_success_with_the_ien
  replay("add")

  result = RpmsRpc::Referral.add(*flow_inputs("add"))

  assert result[:success]
  assert_equal "3", result[:ien]
  assert_equal CapturedReplies.flow_calls(SLUG, "add"), sent
end

# SETREFRL^BMCRPC2 (BMCRPC2.m:58): failure is "~`0^message".
def test_add_referral_sigil_failure_carries_the_message
  replay("add_missing")

  result = RpmsRpc::Referral.add(*flow_inputs("add_missing"))

  refute result[:success]
  assert_equal "Required field missing", result[:message]
  assert_equal CapturedReplies.flow_calls(SLUG, "add_missing"), sent
end

# The capture shows the build refusing a two-parameter frame for argument
# count (on YottaDB the broker packs only frames past 31 into SETREFRL's
# array formal); the gem now refuses that frame before anything is sent.
def test_add_refuses_a_frame_short_of_setrefrls_forty_parameters
  replay("add_short")
  assert_match(/More actual parameters than formal parameters/, CapturedReplies.raw(SLUG, "add_short/1"))

  err = assert_raises(ArgumentError) { RpmsRpc::Referral.add(*flow_inputs("add_short")) }

  assert_match(/all 40 of SETREFRL\^BMCRPC2's parameters/, err.message)
  assert_empty @client.calls, "a refused frame binds no context and sends nothing"
end

def test_add_refuses_a_frame_past_forty_parameters
  assert_raises(ArgumentError) { RpmsRpc::Referral.add(*flow_inputs("add"), "") }
  assert_empty @client.calls
end

# GTREFTYP^BMCRPC3 (BMCRPC3.m:155-174): one node of CONCEPT^DESCRIPTION^TERM
# records joined by "~", sorted by term.
def test_purposes_splits_the_rcis_records_into_snomed_concepts
  replay("purposes")

  purposes = RpmsRpc::Referral.purposes

  assert_equal 112, purposes.size
  assert_equal({ concept_id: "183555005", description_id: "283668011", name: "Burns referral" }, purposes.first)
  assert_equal({ concept_id: "307777008", description_id: "451149013", name: "Referral to vascular surgeon" }, purposes.last)
  assert(purposes.none? { |row| row.values.any? { |v| v.to_s.include?("~") } }, "no record keeps a \"~\"")
  assert_equal CapturedReplies.flow_calls(SLUG, "purposes"), sent
end

# GTREFDT^BMCRPC5 (BMCRPC5.m:211-259): five "~`" nodes, records joined by "~".
def test_reference_data_names_its_five_sections_and_strips_the_sigils
  replay("reference_data")

  data = RpmsRpc::Referral.reference_data

  assert_equal %i[icd_categories cpt_categories purpose_texts statuses priorities], data.keys
  assert_equal [ 52, 7, 5, 4, 17 ], data.values.map(&:size)
  assert_equal({ ien: "59", name: "ALCOHOL/DRUG USE & ALCOHOL/DRUG INDUCED ORGANIC MENTAL DISORDERS",
                 active_date: "OCT 01, 2015", inactive_date: "" }, data[:icd_categories].first)
  assert_equal({ ien: "23", name: "CARDIOVASCULAR DISORDERS", active_date: "", inactive_date: "OCT 01, 2015" },
               data[:icd_categories].find { |row| row[:ien] == "23" })
  assert_equal({ ien: "4", name: "DIAGNOSTIC IMAGING" }, data[:cpt_categories].first)
  assert_equal({ ien: "1", name: "Call-In" }, data[:purpose_texts].first)
  assert_equal [ %w[A ACTIVE], %w[A1 APPROVED], %w[C1 CLOSED-COMPLETED], [ "X", "CLOSED-NOT COMPLETED" ] ],
               data[:statuses].map(&:values)
  assert_equal({ ien: "1", name: "1A CORE-PREVENTIVE AND REHABILITATIVE SERVICES" }, data[:priorities].first)
  assert(data.values.flatten.none? { |row| row.values.any? { |v| v.to_s.include?("~") } }, "no record keeps a sigil")
  assert_equal CapturedReplies.flow_calls(SLUG, "reference_data"), sent
end

# SRVNDR^BMCRPC1 (BMCRPC1.m:163-182): a CHS search answers VENDOR records.
def test_search_referred_to_reads_a_vendor_record_without_its_sigil
  replay("search_referred_to")

  assert_equal [ { ien: "1", name: "UNSPECIFIED", uei: "", ein: "1000000000", ein_suffix: "", mail_to: ",", remit_to: ",," } ],
               RpmsRpc::Referral.search_referred_to("UNSP", "C")
  assert_equal CapturedReplies.flow_calls(SLUG, "search_referred_to"), sent
end

def test_search_referred_to_refuses_a_type_the_routine_does_not_search
  err = assert_raises(ArgumentError) { RpmsRpc::Referral.search_referred_to("UNSP", "Z") }

  assert_match(/C, I, O, N/, err.message)
  assert_empty @client.calls
end

# GTTMPLST^BMCRPC3 (BMCRPC3.m:10-19): "~`IEN^NAME~IEN^NAME...".
def test_rcis_templates_splits_the_template_records
  replay("rcis_templates")

  assert_equal [ { ien: "937", name: "BREAST ULTRASOUND" }, { ien: "931", name: "CARDIOLOGY" },
                 { ien: "938", name: "DIABETES" }, { ien: "939", name: "OPTOMETRY" },
                 { ien: "936", name: "ULTRASOUND" } ],
               RpmsRpc::Referral.rcis_templates
  assert_equal CapturedReplies.flow_calls(SLUG, "rcis_templates"), sent
end

# UPDREFRL^BMCRPC2 takes 35 formals; update sends every one, "" for a field
# not given, and the build answers "~`1" (BMCRPC2.m:271). The flow after it
# reads referral 1 back: each named field is filed where find reads it.
UPDATE = { purpose: "FOLLOW-UP CARDIOLOGY", visit_number: "2", scheduling_notes: "Call before booking",
           include_face_sheet: true, schedule_within_days: "30", expected_begin: Time.new(2026, 12, 1, 10, 30) }.freeze

def test_update_sends_updrefrls_35_parameters_with_the_named_fields_in_place
  replay("update")

  result = RpmsRpc::Referral.update("1", **UPDATE)

  assert result[:success]
  assert_equal CapturedReplies.flow_calls(SLUG, "update"), sent
  params = sent.first.last
  assert_equal 35, params.size
  assert_equal [ "1", "FOLLOW-UP CARDIOLOGY", "2", "Call before booking", "30^12/01/2026@10:30", "Y" ],
               params.values_at(0, 5, 8, 9, 11, 13)
end

def test_find_after_update_reads_the_filed_fields_back
  replay("find_updated")

  record = RpmsRpc::Referral.find("1")

  assert_equal "FOLLOW-UP CARDIOLOGY", record[:purpose]
  assert_equal "2", record[:visit_number]
  assert_equal "Call before booking", record[:scheduling_notes]
  assert_equal "30", record[:schedule_within_days]
  assert_equal "12/1/26 10:30 am", record[:appointment_date], "expected begin of service, 1106"
  assert_equal "YES", record[:include_face_sheet]
  assert_equal "", record[:include_ekg].to_s, "a flag not given is cleared"
end

def test_update_refuses_an_unknown_field_before_sending
  err = assert_raises(ArgumentError) { RpmsRpc::Referral.update("1", diagnosis_code: "R69.") }

  assert_match(/unknown field\(s\) diagnosis_code/, err.message)
  assert_empty @client.calls
end

def test_update_refuses_a_flag_that_is_not_true_or_false
  assert_raises(ArgumentError) { RpmsRpc::Referral.update("1", include_ekg: "Y") }
  assert_raises(ArgumentError) { RpmsRpc::Referral.update("1", expected_begin: Date.new(2026, 12, 1)) }
  assert_empty @client.calls
end

# UPCNRINF^BMCRPC3(RSLT,REFIEN,CONSULTBY,CONSULTDT,CONSULTSTATUS) files
# 1308, 1307 and 1306 and answers "~`1^" (BMCRPC3.m:210-216).
REVIEW = { status: "R", reviewed_by: "206", reviewed_at: Time.new(2026, 11, 19, 10, 30) }.freeze

def test_update_consultation_status_files_the_reviewer_time_and_status
  replay("update_consultation_status")

  result = RpmsRpc::Referral.update_consultation_status("1", **REVIEW)

  assert result[:success]
  assert_nil result[:message]
  assert_equal [ [ "BMC CONSULTATION STATUS UPDATE", [ "1", "206", "11/19/2026@10:30", "R" ] ] ], sent
end

def test_find_after_update_consultation_status_reads_the_review_back
  replay("find_reviewed")

  record = RpmsRpc::Referral.find("1")

  assert_equal "REVIEWED", record[:consultation_status]
  assert_equal "NOV 19, 2026@10:30", record[:consultation_date]
  assert_equal "PROFILE,MD", record[:consulted_by]
end

# The same status again is not filed: "~`1^<patient> has already been
# reviewed by ..." (BMCRPC3.m:202-206), a message and not an IEN.
def test_update_consultation_status_already_reviewed_is_a_message
  replay("update_consultation_status_again")

  result = RpmsRpc::Referral.update_consultation_status("1", **REVIEW)

  assert result[:success]
  assert_nil result[:ien]
  assert_equal "BRAVO,ALEX has already been reviewed by PROFILE,MD on NOV 19, 2026@10:30.", result[:message]
end

def test_update_consultation_status_refuses_a_status_that_is_not_a_code
  assert_raises(ArgumentError) { RpmsRpc::Referral.update_consultation_status("1", **REVIEW, status: "COMPLETE") }
  assert_raises(ArgumentError) { RpmsRpc::Referral.update_consultation_status("1", **REVIEW, reviewed_at: "11/19/2026") }
  assert_empty @client.calls
end

# ADDC32LG^BMCRPC3 answers "~`1^" and the new C32 PRINTED entry (BMCRPC3.m:71).
def test_add_c32_print_log_sends_the_time_the_routine_parses
  replay("add_c32_print_log")

  result = RpmsRpc::Referral.add_c32_print_log("1", user_ien: "206", printed_at: Time.new(2026, 11, 19, 10, 30))

  assert result[:success]
  assert_equal "1", result[:ien]
  assert_equal [ [ "BMC ADD C32 PRINT LOG", [ "1", "206", "11/19/2026@1030" ] ] ], sent
end

# With no user and no time the routine uses DUZ and now; an empty date would
# be refused, so the frame is the referral alone.
def test_add_c32_print_log_without_a_time_leaves_the_parameters_off
  replay("add_c32_print_log_now")

  result = RpmsRpc::Referral.add_c32_print_log("1")

  assert result[:success]
  assert_equal "2", result[:ien]
  assert_equal [ [ "BMC ADD C32 PRINT LOG", [ "1" ] ] ], sent
end

# UPDTSTRF^BMCRPC3 (BMCRPC3.m:176-187) answers "1" when it files.
def test_update_referral_status_calls_bmc_status_rpc
  replay("update_status")

  result = RpmsRpc::Referral.update_status(1, "A1")

  assert result[:success]
  assert_equal [ [ "BMC REFERRAL STATUS UPDATE", [ "1", "A1" ] ] ], sent
end

def test_update_status_sigil_failure_carries_the_message
  replay("update_status_missing")

  result = RpmsRpc::Referral.update_status("999999", "A1")

  refute result[:success]
  assert_equal "Error updating referral:The entry does not exist.", result[:message]
end

# Cancel files status X through the same RPC.
def test_cancel_files_the_cancelled_status
  replay("cancel")

  result = RpmsRpc::Referral.cancel("2")

  assert result[:success]
  assert_equal "1", result[:raw]
  assert_equal [ [ "BMC REFERRAL STATUS UPDATE", [ "2", "X" ] ] ], sent
end

def test_cancel_sigil_failure_carries_the_message
  replay("cancel_missing")

  result = RpmsRpc::Referral.cancel("999999")

  refute result[:success]
  assert_equal "Error updating referral:The entry does not exist.", result[:message]
end

def test_rcis_template_detail_returns_text_blob
  replay("rcis_template_detail")

  assert_equal "~`I^O^31^4^ROUTINE MAMMOGRAM^5~2A INTERMEDIATE-PREVENTIVE AND REHABILITATIVE SERVICES^^^1^^^^^^",
               RpmsRpc::Referral.rcis_template_detail(937)
  assert_equal CapturedReplies.flow_calls(SLUG, "rcis_template_detail"), sent
end

# GTPTELST^BMCRPC4 (BMCRPC4.m:129): ELIGIBILITY STATUS (external) ^ preferred name.
def test_patient_eligibility_status_reads_the_status_text_and_preferred_name
  replay("patient_eligibility_status")

  result = RpmsRpc::Referral.patient_eligibility_status("990001")

  assert_equal "DIRECT ONLY", result[:status]
  assert_nil result[:preferred_name], "demo patient 990001 has no preferred name"
  refute result.key?(:eligible), "the routine returns no eligible flag"
end

# PROV^BMCRPC4 (BMCRPC4.m:136-141): one node, "-1^All~" then IEN^NAME~ per user.
def test_users_providers_parses_the_single_tilde_node
  replay("users_providers")

  assert_equal [ { ien: "4", name: "MANAGER,SYSTEM" }, { ien: "204", name: "PROFILE,MA" },
                 { ien: "206", name: "PROFILE,MD" }, { ien: "205", name: "PROFILE,RN" },
                 { ien: "200", name: "PROVIDER,TEST" } ],
               RpmsRpc::Referral.users_providers
end

# -- BMCRPC context binding (rpms-rpc#258) ---------------------------------
#
# RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built 9.0
# image the BMC* RPCs are listed in the RPC multiple of ONE file-19 option,
# BMCRPC (22 entries: the 21 BMC names this module calls plus ORWDXIHS
# CLININD), and in no other — not CIAV VUECENTRIC, not OR CPRS GUI CHART.
# So every BMC call here must run under BMCRPC
# and hand the caller's option back afterward, the way RpmsRpc::Agg does
# for AGGRPC.

# Each public method that reaches the wire, its arguments, and the capture
# flow that answers it. A flow whose call the build answered with an M error
# still proves the bind, and that the caller's option is handed back on a raise.
BMC_CALLS = {
  for_patient: [ [ DFN ], "for_patient" ],
  pending: [ [ { from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30) } ], "pending" ],
  find: [ [ "1" ], "find" ],
  cancel: [ [ "2" ], "cancel" ],
  add: [ CapturedReplies.flow_calls(SLUG, "add").first.last, "add" ],
  update: [ [ "1", UPDATE ], "update" ],
  print: [ [ "1" ], "print" ],
  update_status: [ [ "1", "A1" ], "update_status" ],
  update_consultation_status: [ [ "1", REVIEW ], "update_consultation_status" ],
  purposes: [ [], "purposes" ],
  reference_data: [ [], "reference_data" ],
  users_providers: [ [], "users_providers" ],
  providers: [ [], "providers" ],
  search_referred_to: [ [ "UNSP", "C" ], "search_referred_to" ],
  rcis_templates: [ [], "rcis_templates" ],
  rcis_template_detail: [ [ "937" ], "rcis_template_detail" ],
  patient_eligibility_status: [ [ "990001" ], "patient_eligibility_status" ],
  patient_face_sheet: [ [ "990001" ], "patient_face_sheet" ],
  patient_health_summary: [ [ "990001", "7" ], "patient_health_summary" ],
  health_summary_types: [ [], "health_summary_types" ],
  check_year_site_param: [ [], "check_year_site_param" ],
  add_c32_print_log: [ [ "1", { user_ien: "206", printed_at: Time.new(2026, 11, 19, 10, 30) } ], "add_c32_print_log" ]
}.freeze

def test_the_bind_table_names_every_public_method_that_reaches_the_wire
  expected = RpmsRpc::Referral.public_instance_methods(false).sort - [ :create ]

  assert_equal expected, BMC_CALLS.keys.sort,
    "a new Referral method must be added to BMC_CALLS so its context bind is proven"
end

def test_every_bmc_call_runs_under_bmcrpc_and_restores_the_callers_context
  BMC_CALLS.each do |method, (args, flow)|
    client = replay(flow)
    caller_context = client.current_context

    *positional, keywords = args.last.is_a?(Hash) ? args : [ *args, {} ]
    begin
      RpmsRpc::Referral.public_send(method, *positional, **keywords)
    rescue RpmsRpc::Client::RpcError
      nil # the build's M error for this frame; the bind is what is checked
    end

    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent, "#{method} sent the recorded calls"
    sent_calls = client.calls.reject { |c| c[:rpc] == :create_context }
    sent_calls.each do |call|
      # find's pre-check reads the entry with the stock FileMan RPC, which
      # BMCRPC does not list, under the caller's option (#767).
      next assert_equal(caller_context, call[:context]) if method == :find && call[:rpc] == "DDR GETS ENTRY DATA"

      assert_equal "BMCRPC", call[:context],
        "#{method} sent #{call[:rpc]} under #{call[:context].inspect}; the BMC* RPCs " \
        "are registered under BMCRPC only, so it is denied there"
    end
    assert_equal caller_context, client.current_context, "#{method} left the session on #{client.current_context.inspect}"
    assert_equal [ "BMCRPC", caller_context ], client.binds, "#{method}: expected one bind and one restore"
  end
end

def test_create_binds_no_context
  RpmsRpc::Referral.create(DFN, { specialty: "CARDIOLOGY" })

  assert_empty @client.binds, "create touches no RPC, so it has no option to bind"
end

def test_a_bmcrpc_that_will_not_bind_raises_before_any_rpc_is_sent
  # The broker refusing the option (not installed, or not on the user's
  # menu tree) is a session-level failure the caller must see — a BMC call
  # sent anyway would be answered a truthful "not runnable here".
  refusing = Class.new(Replay) do
    def create_context(option_name = SIGNON_CONTEXT)
      raise RpmsRpc::Client::RpcError, "context refused" if option_name == "BMCRPC"

      super
    end
  end
  replay("purposes", client_class: refusing)

  assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Referral.purposes }
  assert_empty sent
end

  def test_a_client_that_cannot_scope_contexts_runs_as_is
    plain = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def call_rpc(rpc, *params)
        @calls << rpc
        "1^3001"
      end
    end.new
    RpmsRpc.configure { |c| c.client = plain }

    result = RpmsRpc::Referral.add(*CapturedReplies.flow_calls(SLUG, "add").first.last)

    assert result[:success]
    assert_equal [ "BMC ADD REFERRAL" ], plain.calls
  end

  RESULT_FROM_RAW_CASES = [
    [ "~`1^3001", :success, { ien: "3001" } ],
    [ "~`0^Required field missing", :failure, { message: "Required field missing" } ],
    [ "~`-1^dup prompt", :failure, {} ],
    [ "~` ", :failure, {} ],
    [ "~`x^y", :failure, {} ],
    [ "1", :success, {} ],
    [ "1^OK", :success, { message: "OK" } ],
    [ "10", :success, {} ],
    [ "1garbage", :failure, {} ],
    [ "0", :failure, {} ],
    [ "0^no", :failure, {} ],
    [ "~0^no", :failure, {} ],
    [ "", :failure, {} ],
    [ nil, :failure, {} ],
    [ "  \n", :failure, {} ],
    [ "Not a valid Referral Ien", :failure, {} ]
  ].freeze

  def test_result_from_raw_fail_closed_table
    RESULT_FROM_RAW_CASES.each do |raw, expectation, attrs|
      result = RpmsRpc::Referral.send(:result_from_raw, raw)
      label = raw.inspect

      if expectation == :success
        assert result[:success], "expected success for #{label}"
        attrs.each { |key, val| assert_equal val, result[key], "for #{label}" }
      else
        refute result[:success], "expected failure for #{label}"
        attrs.each { |key, val| assert_equal val, result[key], "for #{label}" }
      end
    end
  end
end
