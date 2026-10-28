# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/scheduling"

# rpms-rpc#481 — failed BSDX list reads must raise RpcError, not masquerade as
# "nothing on file". Header-only recordset replies stay []. Synthetic wire only.
class SchedulingBsdxListReadTest < Minitest::Test
  RS = "\x1E"
  US = "\x1F"

  AVAILABILITY_HEADER =
    "T00030RESOURCENAME^D00030DATE^T00030ACCESSTYPE^T00030COMMENT"
  ALL_APPOINTMENTS_HEADER =
    "D00030START_TIME^D00030END_TIME^I00010PAT_ID^T00030RES_NAME"
  HOSPITAL_LOC_HEADER =
    "I00010HOSPITAL_LOCATION_ID^T00030HOSPITAL_LOCATION^T00030DEFAULT_PROVIDER^" \
    "T00030STOP_CODE_NUMBER^D00030INACTIVATE_DATE^D00030REACTIVATE_DATE"
  CLINIC_SETUP_HEADER =
    "I00010HOSPITAL_LOCATION_ID^T00030HOSPITAL_LOCATION^T00030CREATE_VISIT^" \
    "T00030VISIT_SERVICE_CATEGORY^T00030MULTIPLE_CLINIC_CODES_USED?^" \
    "T00030VISIT_PROVIDER_REQUIRED^T00030GENERATE_PCCPLUS_FORMS?^T00010MAX_OVERBOOKS"

  RESOURCES_HEADER =
    "I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^" \
    "T00030LETTER_TEXT^T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^" \
    "I00010MODIFY_SCHEDULE^I00010MODIFY_APPOINTMENTS"
  SLOTS_HEADER =
    "D00030START_TIME^D00030END_TIME^I00010SLOTS^T00030RESOURCE^T00010ACCESS_TYPE^T00250NOTE^I00030AVAILABILITYID"
  APPTS_HEADER =
    "I00020APPOINTMENTID^D00030START_TIME^D00030END_TIME^D00030CHECKIN^D00030AUXTIME^I00020PATIENTID^" \
    "T00030PATIENTNAME^T00030RESOURCENAME^I00005NOSHOW^T00020HRN^I00005ACCESSTYPEID^I00005WALKIN^" \
    "D00030CHECKOUT^I00020VPROVIDER^T00020CANCELLED^T00250NOTE"

  # BSDX list routines trap failures through BMX recordset output: many paths
  # emit a single ERRORID column header (T00030ERRORID) and put the message in
  # the next row — see CHECKIN^BSDX25 (ERR^BSDX25 failure text in the data row,
  # scheduling.rb module comment) and the #-1^Invalid resource repro in #481.
  # Plain-text error rows (no leading -N^) appear on the same ERRORID recordset
  # shape in live BSDX reads; both must raise, not parse as data or as [].
  ERRORID_HEADER = "T00030ERRORID"

  class RawResponseClient
    def initialize(response) = @response = response
    def call_rpc(*) = @response
  end

  class RecordsetClient
    def initialize(replies) = @replies = replies
    def with_context(_name) = yield
    def call_rpc_global_array(rpc, *) = @replies.fetch(rpc)
  end

  FETCH_MANY_READS = {
    availability: {
      rpc: "BSDX SEARCH AVAILABILITY",
      header: AVAILABILITY_HEADER,
      call: lambda {
        RpmsRpc::Scheduling.availability(
          resources: "PEDIATRICIAN,DEMO",
          start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30)
        )
      }
    },
    all_appointments: {
      rpc: "BSDX ALL APPOINTMENTS",
      header: ALL_APPOINTMENTS_HEADER,
      call: lambda {
        RpmsRpc::Scheduling.all_appointments(
          start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30)
        )
      }
    },
    hospital_locations: {
      rpc: "BSDX HOSPITAL LOCATION",
      header: HOSPITAL_LOC_HEADER,
      call: -> { RpmsRpc::Scheduling.hospital_locations }
    },
    clinic_setup: {
      rpc: "BSDX CLINIC SETUP",
      header: CLINIC_SETUP_HEADER,
      call: -> { RpmsRpc::Scheduling.clinic_setup }
    }
  }.freeze

  RECORDSET_READS = {
    resources: {
      rpc: "BSDX RESOURCES",
      header: RESOURCES_HEADER,
      call: -> { RpmsRpc::Scheduling.resources }
    },
    slot_schedule: {
      rpc: "BSDX CREATE ASGND SLOT SCHED",
      header: SLOTS_HEADER,
      call: lambda {
        RpmsRpc::Scheduling.slot_schedule(
          resource: "DEMO IHS CLINIC",
          start_date: Date.new(2026, 10, 28), end_date: Date.new(2026, 10, 28)
        )
      }
    },
    appointments: {
      rpc: "BSDX CREATE APPT SCHEDULE",
      header: APPTS_HEADER,
      call: lambda {
        RpmsRpc::Scheduling.appointments(
          resource: "DEMO IHS CLINIC",
          start_date: Date.new(2026, 10, 28), end_date: Date.new(2026, 10, 28)
        )
      }
    }
  }.freeze

  def setup = RpmsRpc.mock!

  def teardown = RpmsRpc.reset!

  def stub_call_rpc(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  def stub_recordset(replies)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RecordsetClient.new(replies) }
  end

  def wire_recordset(header, *data_rows)
    body = +"1\x00"
    body << header << RS
    data_rows.each { |row| body << row << RS }
    body << US
  end

  def header_line(header, with_rs:)
    with_rs ? "#{header}#{RS}" : header
  end

  def assert_rpc_error_includes_rpc(method, rpc, &block)
    err = assert_raises(RpmsRpc::Client::RpcError, "#{method}: failed read must raise RpcError") { block.call }
    assert_includes err.message, rpc,
                    "#{method}: RpcError message must name the RPC (#{rpc.inspect}), got #{err.message.inspect}"
    err
  end

  # -- Failed reads: fetch_many / call_rpc path --------------------------------

  {
    nil: nil,
    empty_array: [],
    empty_string: "",
    error_row_first: [ "-1^Some failure" ],
    error_after_header: :error_after_header,
    bsdx_error_recordset_caret: [ "#{ERRORID_HEADER}#{RS}", "-1^Invalid resource#{RS}" ],
    bsdx_error_recordset_plain: [ "#{ERRORID_HEADER}#{RS}", "Resource not found#{RS}" ]
  }.each do |failure_label, reply_or_marker|
    FETCH_MANY_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_failed_read_#{failure_label}") do
        reply = if reply_or_marker == :error_after_header
                  [ header_line(cfg[:header], with_rs: true), "-1^Invalid resource#{RS}" ]
        else
                  reply_or_marker
        end
        stub_call_rpc(reply)
        err = assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
        if %i[error_after_header error_row_first bsdx_error_recordset_caret bsdx_error_recordset_plain].include?(failure_label)
          assert_match(/Invalid resource|Some failure|Resource not found/, err.message,
                       "#{method}: RpcError should carry broker error text when present")
        end
      end
    end
  end

  # -- Failed reads: recordset / call_rpc_global_array path --------------------

  {
    nil: nil,
    empty_array: [],
    empty_string: "",
    error_row_first: [ "-1^Some failure" ],
    error_after_header: :error_after_header,
    bsdx_error_recordset_caret: :bsdx_error_caret,
    bsdx_error_recordset_plain: :bsdx_error_plain
  }.each do |failure_label, reply_or_marker|
    RECORDSET_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_failed_read_#{failure_label}") do
        reply = case reply_or_marker
        when :error_after_header
                  wire_recordset(cfg[:header], "-1^Invalid resource")
        when :bsdx_error_caret
                  wire_recordset(ERRORID_HEADER, "-1^Invalid resource")
        when :bsdx_error_plain
                  wire_recordset(ERRORID_HEADER, "Resource not found")
        else
                  reply_or_marker
        end
        stub_recordset(cfg[:rpc] => reply)
        err = assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
        next unless %i[error_after_header error_row_first bsdx_error_recordset_caret bsdx_error_recordset_plain].include?(failure_label)

        assert_match(/Invalid resource|Some failure|Resource not found/, err.message,
                     "#{method}: RpcError should carry broker error text when present")
      end
    end
  end

  # -- Genuine empty: header-only (with and without trailing RS) ---------------

  FETCH_MANY_READS.each do |method, cfg|
    [ true, false ].each do |with_rs|
      suffix = with_rs ? "with_recordset_separator" : "without_recordset_separator"
      define_method("test_#{method}_header_only_empty_#{suffix}") do
        stub_call_rpc([ header_line(cfg[:header], with_rs: with_rs), "" ])
        rows = cfg[:call].call
        assert_equal [], rows, "#{method}: header-only reply must be a genuine empty list, not a failure"
      end
    end
  end

  RECORDSET_READS.each do |method, cfg|
    [ true, false ].each do |with_rs|
      suffix = with_rs ? "with_recordset_separator" : "without_recordset_separator"
      define_method("test_#{method}_header_only_empty_#{suffix}") do
        wire = if with_rs
                 wire_recordset(cfg[:header])
        else
                 "1\x00#{cfg[:header]}#{US}"
        end
        stub_recordset(cfg[:rpc] => wire)
        rows = cfg[:call].call
        assert_equal [], rows, "#{method}: header-only reply must be a genuine empty list, not a failure"
      end
    end
  end

  # Reply.from_wire flattens control bytes to spaces (scheduling.rb module comment);
  # a truncated read can surface as "  I00020…" — header-only must stay [], not a row.
  def test_hospital_locations_flattened_header_only_reply_is_empty_not_bogus_record
    stub_call_rpc([ "  #{HOSPITAL_LOC_HEADER}" ])
    assert_equal [], RpmsRpc::Scheduling.hospital_locations
  end
end
