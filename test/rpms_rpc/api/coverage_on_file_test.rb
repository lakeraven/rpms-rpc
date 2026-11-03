# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/coverage"

# Coverage.on_file reads a patient's coverage through AG's own window RPCs,
# and add_medicaid / add_medicare / add_private_insurance file what the front
# desk records (rpms-ux S-REG-03.1). The replies below are AG's, captured from
# the pinned build on 2026-11-03 (insurer address pieces replaced).
class CoverageOnFileTest < Minitest::Test
  Cov = RpmsRpc::Coverage
  RS = "\x1e"
  FS = "\x1c"
  EOA = "\x1f"

  MCD_HEADER = "T00030AGGMDNME^T00030AGGMDNUM^D00015AGGMDDOB^T00030AGGMDINS^T00040AGGMDSTE^T00040AGGMDPLN^" \
               "T00007AGGMDCCF^D00015AGGMDCRD^T00040AGGMDREL^T00040AGGMDGRP^T00017AGGMDGRN^T00035AGGMDINM^" \
               "T00035AGGMDPCP^T00006AGGMDRCD^I00010RIEN^T00010SEQNBR^D00015AGGMDESD^D00015AGGMDEED^" \
               "T00015AGGMDSTS^D00015AGGLSTDT"
  MCD_ROWS = [
    "^ZZ1234567^^MEDICAID^48#{FS}WASHINGTON^#{FS}^#{FS}^^#{FS}^#{FS}^#{FS}^^^^3^^^^ACTIVE^",
    "^ZZLAPSED1^^MEDICAID^48#{FS}WASHINGTON^#{FS}^#{FS}^^#{FS}^#{FS}^#{FS}^^^^4^^^^INACTIVE^"
  ].freeze
  MCD_ELIG_HEADER = "D00015AGGMDESD^D00015AGGMDEED^T00002AGGMDECV^I00010MIEN"
  MCR_HEADER = "T00035AGGMCNME^T00009AGGMCNUM^T00007AGGMCSUF^T00040AGGMCINS^T00030AGGMCPCP^D00015AGGMCDOB^" \
               "T00007AGGMCCCF^D00015AGGMCCRD^T00010AGGMCQMB^D00015AGGMCROI^T01024MCELIG^T00010SEQNBR^" \
               "D00015AGGLSTDT^T00015AGGMCSTS^D00015AGGMCIMP^D00015AGGMCABN"
  MCR_ELIG_HEADER = "D00015AGGMCESD^T00005AGGMCCOV^D00015AGGMCEED^T00030AGGMCPN^T00030AGGMCMN^T00030AGGMCIDN^" \
                    "T00010AGGMCPC^T00010AGGMCG^D00015AGGMRDOB^T00030AGGMCGN^I00010MIEN"
  PVT_HEADER = "T00040AGGPIINS^T00010AGGPIPCD^T00035AGGPIPCP^T00007AGGPICCF^D00016AGGPICRD^T00020AGGPIMBN^" \
               "T00050AGGPIREL^T00040AGGPIHLN^I00010AGGPLIEN^T00010SEQNBR^D00015AGGPIESD^D00015AGGPIEED^" \
               "T00010AGGPISTS^T00020AGGINADR^T00050AGGINCSZ^T00020AGGINPHN^I00010AGGPIIEN"
  PVT_ROW = "5#{FS}VETERANS MEDICAL BENEFIT^^^^^ZZMEM1^#{FS}^ZEPHYR,QUINN^1^2^JAN 1,2026^^ACTIVE^" \
            "1 MAIN ST^ANYTOWN, ST 00000^(555)555-0100^1"

  DFN = "990049"

  class RecordingClient
    include RpmsRpc::ContextScope

    attr_reader :calls

    def initialize(replies)
      @replies = replies
      @calls = []
      @current_context = "CIAV VUECENTRIC"
    end

    def create_context(name)
      @current_context = name
      true
    end

    def current_context = @current_context

    def call_rpc_global_array(rpc, *params)
      @calls << [ rpc, *params.map(&:to_s), @current_context ]
      @replies.fetch([ rpc, *params.map(&:to_s) ]) { @replies.fetch(rpc, "") }
    end

    def call_rpc(rpc, *params)
      @calls << [ rpc, *params.map(&:to_s), @current_context ]
      Array(@replies.fetch(rpc, []))
    end
  end

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def array(header, *rows)
    "#{header}#{RS}" + rows.map { |row| "#{row}#{RS}" }.join + EOA
  end

  def replies
    {
      [ "AGG BUILD WINDOW MANY", "Medicaid", "B", DFN ] => array(MCD_HEADER, *MCD_ROWS),
      [ "AGG BUILD WINDOW MULTIPLE", "Medicaid Eligibility", "11", "3", "" ] =>
        array(MCD_ELIG_HEADER, "JAN 1,2026^DEC 31,2026^F^3260101"),
      [ "AGG BUILD WINDOW MULTIPLE", "Medicaid Eligibility", "11", "4", "" ] =>
        array(MCD_ELIG_HEADER, "JAN 1,2024^JUN 30,2025^^3240101"),
      [ "AGG BUILD WINDOW DISPLAY", "Medicare", DFN ] =>
        array(MCR_HEADER, "ZEPHYR,QUINN^1EG4TE5MK73^#{FS}^2#{FS}MEDICARE^^^#{FS}^^#{FS}^^^^^ACTIVE^^"),
      [ "AGG BUILD WINDOW MULTIPLE", "Medicare Eligibility", "11", DFN, "" ] =>
        array(MCR_ELIG_HEADER, "JAN 1,2026^B#{FS}PART B^^#{FS}^^^^#{FS}^^#{FS}^1"),
      [ "AGG BUILD WINDOW MULTIPLE", "Private Insurance", "11", DFN, "" ] => array(PVT_HEADER, PVT_ROW),
      "DDR GETS ENTRY DATA" => [ "[Data]", "9000006.11^1,#{DFN},^.06^3260101", "9000006.11^1,#{DFN},^.07^3271231" ]
    }
  end

  def test_s_reg_03_1_on_file_reads_each_payer_with_number_dates_and_whether_it_is_in_force
    client = RecordingClient.new(replies)
    got = Cov.on_file(DFN, client: client)

    lapsed, current = got[:medicaid].partition { |e| e[:number] == "ZZLAPSED1" }.map(&:first)
    assert_equal [ "MEDICAID", "ZZ1234567", "WASHINGTON", true ], current.values_at(:payer, :number, :state, :active)
    assert_equal({ ien: "3260101", starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31), coverage: "F" },
                 current[:eligibility].first)
    assert_equal false, lapsed[:active]
    assert_equal Date.new(2025, 6, 30), lapsed[:eligibility].first[:ends_on]

    medicare = got[:medicare].first
    assert_equal [ "MEDICARE", "1EG4TE5MK73", true ], medicare.values_at(:payer, :number, :active)
    assert_equal "PART B", medicare[:eligibility].first[:coverage]

    policy = got[:private].first
    assert_equal [ "VETERANS MEDICAL BENEFIT", "5", "ZZMEM1", "ZEPHYR,QUINN", true ],
                 policy.values_at(:payer, :payer_ien, :number, :policy_holder, :active)
    assert_equal [ Date.new(2026, 1, 1), Date.new(2027, 12, 31) ], policy.values_at(:starts_on, :ends_on),
                 "the member's own dates, not AG's display, which blanks an end date still to come"

    agg_calls = client.calls.reject { |call| call.first.start_with?("DDR") }
    assert(agg_calls.all? { |call| call.last == "AGGRPC" }, "every window read runs in AGGRPC")
  end

  def test_on_file_has_no_medicare_when_the_window_answers_a_blank_row
    r = replies.merge([ "AGG BUILD WINDOW DISPLAY", "Medicare", DFN ] => array(MCR_HEADER, "^^#{FS}^#{FS}^^^^#{FS}^^#{FS}^^^^^^^"))
    assert_equal [], Cov.on_file(DFN, client: RecordingClient.new(r))[:medicare]
  end

  def test_on_file_is_nil_when_any_window_gives_no_typed_reply
    r = replies.merge([ "AGG BUILD WINDOW MULTIPLE", "Medicaid Eligibility", "11", "4", "" ] => "")
    assert_nil Cov.on_file(DFN, client: RecordingClient.new(r))
  end

  def test_on_file_sends_nothing_for_a_bad_dfn
    client = RecordingClient.new({})
    assert_nil Cov.on_file("0", client: client)
    assert_empty client.calls
  end

  def test_add_medicaid_files_the_number_and_state_on_the_record_and_the_end_date_on_the_row
    ok = array("I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN", "1^^7^")
    row = array("I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN", "1^^7^3260101")
    client = RecordingClient.new({ [ "AGG UPDATE MEDICAID", DFN, "A", "Medicaid", "", "",
                                     "AGGMDNUM=ZZ1#{FS}AGGMDSTE=48" ] => ok,
                                   "AGG UPDATE MEDICAID" => row })
    got = Cov.add_medicaid(DFN, effective_on: "01/01/2026", ends_on: "12/31/2026", number: "ZZ1", state_ien: 48,
                                coverage: nil, client: client)

    assert got[:success], got.inspect
    assert_equal [ "AGG UPDATE MEDICAID", DFN, "A", "Medicaid Eligibility", "7", "",
                   "AGGMDESD=01/01/2026#{FS}AGGMDEED=12/31/2026", "AGGRPC" ], client.calls.last
  end

  def test_add_medicare_sends_the_part_by_its_window_choice_name
    ok = array("I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN", "1^^#{DFN}^1")
    client = RecordingClient.new({ "AGG UPDATE MEDICARE" => ok })
    Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZEPHYR,QUINN", number: "1EG4TE5MK73",
                          effective_on: "01/01/2026", ends_on: "12/31/2027", part: "b", client: client)

    assert_equal "AGGMCESD=01/01/2026#{FS}AGGMCEED=12/31/2027#{FS}AGGMCCOV=PART B", client.calls.last[-2]
    assert_raises(ArgumentError) { Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "X", number: "1", effective_on: "01/01/2026", part: "C", client: client) }
  end

  def test_add_private_insurance_files_through_ags_insurance_window
    ok = array("I00010RESULT^T01024ERROR^I00010AGGPIIEN^I00010AGGPLHIN", "1^^2^3")
    client = RecordingClient.new({ "AGG UPDATE PRIVATE INSUR" => ok })
    got = Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "ZEPHYR,QUINN", member_number: "ZZM49",
                                         effective_on: "01/01/2026", ends_on: "12/31/2027", client: client)

    assert_equal({ success: true, error: nil, record_ien: "2", policy_holder_ien: "3" }, got)
    rpc, proc, dfn, record, holder, parms, context = client.calls.last
    assert_equal [ "AGG UPDATE PRIVATE INSUR", "A", DFN, "", "", "AGGRPC" ], [ rpc, proc, dfn, record, holder, context ]
    assert_equal %w[AGGPIINS=5 AGGPIHLN=ZEPHYR,QUINN AGGPIMBN=ZZM49 AGGPIESD=01/01/2026 AGGPIEED=12/31/2027
                    AGGPHESD=01/01/2026 AGGPHEED=12/31/2027], parms.split(FS)
  end

  def test_add_private_insurance_refuses_before_sending_without_holder_member_or_start
    client = RecordingClient.new({})
    assert_raises(ArgumentError) do
      Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "", member_number: "M", effective_on: "01/01/2026",
                                     client: client)
    end
    assert_raises(ArgumentError) do
      Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "H", member_number: "M", effective_on: "13/01/2026",
                                     client: client)
    end
    assert_empty client.calls
  end

  def test_add_private_insurance_reports_ags_refusal
    no = array("I00010RESULT^T01024ERROR^I00010AGGPIIEN^I00010AGGPLHIN", "-1^The value is not valid^")
    got = Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "H", member_number: "M",
                                         effective_on: "01/01/2026", client: RecordingClient.new({ "AGG UPDATE PRIVATE INSUR" => no }))
    assert_equal({ success: false, error: :coverage_rejected, message: "The value is not valid" }, got)
  end

  def test_insurers_lists_ags_insurer_pick
    reply = array("I00010IEN^T00030NAME^T00030STREET^T00015CITY^T00030STATE^T00010ZIP^T00015PHONE^T00015STATUS^T00025TYPE",
                  "3^MEDICAID^1 MAIN ST^ANYTOWN^WASHINGTON^00000^^BILLABLE^MEDICAID FI")
    got = Cov.insurers(client: RecordingClient.new({ "AGG GET INSURANCE DATA" => reply }))
    assert_equal [ { ien: "3", name: "MEDICAID", city: "ANYTOWN", state: "WASHINGTON", status: "BILLABLE", type: "MEDICAID FI" } ], got
  end
end
