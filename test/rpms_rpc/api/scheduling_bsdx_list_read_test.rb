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

  ERRORID_HEADER = "T00030ERRORID"

  # One caret-delimited data row per RPC (synthetic names only).
  SAMPLE_DATA_ROW = {
    "BSDX SEARCH AVAILABILITY" => "PEDIATRICIAN,DEMO^SEP 04, 2026^ROUTINE^",
    "BSDX ALL APPOINTMENTS" => "SEP 04, 2026 09:00^SEP 04, 2026 09:30^100^PEDIATRICIAN,DEMO",
    "BSDX HOSPITAL LOCATION" => "99^DEMO CLINIC^DEMO,PROVIDER^000^^",
    "BSDX CLINIC SETUP" => "44^DEMO CLINIC^YES^A^NO^YES^NO^2",
    "BSDX RESOURCES" => "1^DEMO PRIMARY CARE^0^15^6^^^^1^1^1^1",
    "BSDX CREATE ASGND SLOT SCHED" =>
      "OCT 28,2026 08:00^OCT 28,2026 17:00^4^DEMO IHS CLINIC^1^^44",
    "BSDX CREATE APPT SCHEDULE" =>
      "1^OCT 28,2026 09:00^OCT 28,2026 09:20^^^3^MOUSE,MICKEY M^DEMO IHS CLINIC^0^1001^0^0^^^0^"
  }.freeze

  BROKER_TEXT_IN_ERROR_ASSERTIONS = [
    /Invalid resource/,
    /Some failure/,
    /Resource not found/
  ].freeze

  SANITIZED_ERROR_BROKER_ROWS = {
    caret_conflict: "-1^Patient Demo Patient has a conflict",
    plain_not_found: "Demo Patient not found",
    caps_name: "DOE,DEMO"
  }.freeze

  FORBIDDEN_BROKER_LEAKS = [
    /Demo/i,
    /Patient/i,
    /conflict/i,
    /DOE/i,
    /not found/i
  ].freeze

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

  ALL_LIST_READS = FETCH_MANY_READS.merge(RECORDSET_READS).freeze

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

  LEADING_JUNK = {
    spaces: "  ",
    replacement: "\u{FFFD}"
  }.freeze

  def wire_recordset(header, *data_rows, header_prefix: "")
    body = +"1\x00"
    body << header_prefix.to_s << header << RS
    data_rows.each { |row| body << row << RS }
    body << US
  end

  def header_line(header, with_rs:)
    with_rs ? "#{header}#{RS}" : header
  end

  def sample_row(cfg) = SAMPLE_DATA_ROW.fetch(cfg[:rpc])

  def fetch_many_multiline_reply(cfg, *extra_data_rows)
    row = sample_row(cfg)
    rows = extra_data_rows.empty? ? [ row ] : extra_data_rows
    [ header_line(cfg[:header], with_rs: true), *rows.map { |r| "#{r}#{RS}" }, "" ]
  end

  def assert_rpc_error_includes_rpc(method, rpc, &block)
    err = assert_raises(RpmsRpc::Client::RpcError, "#{method}: failed read must raise RpcError") { block.call }
    assert_includes err.message, rpc,
                    "#{method}: RpcError message must name the RPC (#{rpc.inspect}), got #{err.message.inspect}"
    err
  end

  def refute_broker_text_in_rpc_error(method, err)
    BROKER_TEXT_IN_ERROR_ASSERTIONS.each do |pat|
      refute_match pat, err.message,
                   "#{method}: RpcError must not echo broker text (#{pat.source}), got #{err.message.inspect}"
    end
  end

  def assert_sanitized_error_message(method, rpc, err, expect_code: false)
    assert_includes err.message, rpc, "#{method}: message must name RPC"
    assert_includes err.message, "-1", "#{method}: message must include numeric code -1" if expect_code
    FORBIDDEN_BROKER_LEAKS.each do |pat|
      refute_match pat, err.message,
                   "#{method}: RpcError must not leak broker text (#{pat.source}), got #{err.message.inspect}"
    end
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
          refute_broker_text_in_rpc_error(method, err)
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

        refute_broker_text_in_rpc_error(method, err)
      end
    end
  end

  # -- Pin 1: one Array line with embedded recordset bytes (split_response) ----

  {
    plain: "Demo Patient not found",
    caret: "-1^Invalid resource"
  }.each do |variant, broker_row|
    ALL_LIST_READS.each do |method, cfg|
      define_method("test_#{method}_raises_when_global_array_is_one_split_line_errorid_#{variant}") do
        embedded = "#{ERRORID_HEADER}#{RS}#{broker_row}#{RS}#{US}"
        if RECORDSET_READS.key?(method)
          stub_recordset(cfg[:rpc] => "1\x00#{embedded}")
        else
          stub_call_rpc([ embedded ])
        end
        assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
      end
    end
  end

  FETCH_MANY_READS.each do |method, cfg|
    define_method("test_#{method}_one_split_line_wire_parses_like_multiline") do
      row = sample_row(cfg)
      stub_call_rpc(fetch_many_multiline_reply(cfg))
      expected = cfg[:call].call
      RpmsRpc.reset!
      RpmsRpc.mock!
      one_line = "1\x00#{cfg[:header]}#{RS}#{row}#{RS}#{US}"
      stub_call_rpc([ one_line ])
      assert_equal expected, cfg[:call].call,
                   "#{method}: one split_response line must parse like multiline rows"
    end

    define_method("test_#{method}_one_split_line_header_only_is_empty") do
      one_line = "1\x00#{cfg[:header]}#{RS}#{US}"
      stub_call_rpc([ one_line ])
      assert_equal [], cfg[:call].call,
                   "#{method}: header-only one-line global array must be []"
    end
  end

  RECORDSET_READS.each do |method, cfg|
    define_method("test_#{method}_one_line_global_array_parses_like_multiline") do
      row = sample_row(cfg)
      wire = wire_recordset(cfg[:header], row)
      stub_recordset(cfg[:rpc] => wire)
      expected = cfg[:call].call
      RpmsRpc.reset!
      RpmsRpc.mock!
      stub_recordset(cfg[:rpc] => [ wire ])
      assert_equal expected, cfg[:call].call,
                   "#{method}: one-element array global array must parse like the string wire"
    end

    define_method("test_#{method}_one_line_global_array_header_only_is_empty") do
      stub_recordset(cfg[:rpc] => wire_recordset(cfg[:header]))
      assert_equal [], cfg[:call].call,
                   "#{method}: header-only one-line global array must be []"
    end
  end

  # -- Pin 2: String reply with CR/LF (MockClient Reply.text shape) ------------

  {
    lf_caret: "#{ERRORID_HEADER}\n-1^Invalid resource",
    crlf_plain: "#{ERRORID_HEADER}\r\nResource not found"
  }.each do |variant, body|
    FETCH_MANY_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_reply_text_#{variant}") do
        stub_call_rpc(RpmsRpc::Reply.text(body))
        assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
      end
    end
  end

  FETCH_MANY_READS.each do |method, cfg|
    define_method("test_#{method}_reply_text_with_lf_row_parses_like_multiline") do
      row = sample_row(cfg)
      stub_call_rpc(fetch_many_multiline_reply(cfg))
      expected = cfg[:call].call
      RpmsRpc.reset!
      RpmsRpc.mock!
      stub_call_rpc(RpmsRpc::Reply.text("#{cfg[:header]}\n#{row}"))
      assert_equal expected, cfg[:call].call,
                   "#{method}: header + LF + row must parse like multiline"
    end

    define_method("test_#{method}_reply_text_header_only_is_empty") do
      stub_call_rpc(RpmsRpc::Reply.text(cfg[:header]))
      assert_equal [], cfg[:call].call,
                   "#{method}: header-only Reply.text must be []"
    end
  end

  # -- Pin 3: malformed / non-replies must raise, not [] -----------------------

  {
    errorid_header_only_rs: [ "#{ERRORID_HEADER}#{RS}" ],
    errorid_then_empty_row: [ "#{ERRORID_HEADER}#{RS}", "" ],
    no_header_blank_line: [ "" ]
  }.each do |label, fetch_reply|
    FETCH_MANY_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_malformed_fetch_reply_#{label}") do
        stub_call_rpc(fetch_reply)
        assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
      end
    end
  end

  {
    errorid_empty_data: ->(_cfg) { "1\x00#{ERRORID_HEADER}#{RS}#{RS}#{US}" },
    errorid_lone_rs: ->(_cfg) { "1\x00#{ERRORID_HEADER}#{RS}#{US}" },
    missing_header_body: ->(_cfg) { "1\x00" },
    missing_header_us_only: ->(_cfg) { "1\x00#{US}" }
  }.each do |label, wire_builder|
    RECORDSET_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_malformed_recordset_#{label}") do
        stub_recordset(cfg[:rpc] => wire_builder.call(cfg))
        assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
      end
    end
  end

  [ false, 0, { rows: [] } ].each do |bad_reply|
    label = bad_reply.class.name.downcase
    ALL_LIST_READS.each do |method, cfg|
      define_method("test_#{method}_raises_when_reply_is_#{label}") do
        if RECORDSET_READS.key?(method)
          stub_recordset(cfg[:rpc] => bad_reply)
        else
          stub_call_rpc(bad_reply)
        end
        assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
      end
    end
  end

  # -- Pin 4: truncated header (leading spaces / U+FFFD) ---------------------

  FETCH_MANY_READS.each do |method, cfg|
    row = SAMPLE_DATA_ROW.fetch(cfg[:rpc])
    [ "  ", "#{RpmsRpc::Reply::REPLACEMENT * 2}" ].each do |prefix|
      tag = prefix.include?(" ") ? "spaces" : "replacement_chars"
      define_method("test_#{method}_truncated_#{tag}_header_with_row_parses_row_only") do
        stub_call_rpc([ "#{prefix}#{cfg[:header]}", row ])
        rows = cfg[:call].call
        assert_equal 1, rows.size, "#{method}: must yield exactly one row"
        refute rows.first.values.all?(&:nil?), "#{method}: row must be parsed data, not a bogus header"
      end

      define_method("test_#{method}_truncated_#{tag}_header_alone_is_empty") do
        stub_call_rpc([ "#{prefix}#{cfg[:header]}" ])
        assert_equal [], cfg[:call].call,
                     "#{method}: truncated header alone must be []"
      end
    end
  end

  # -- Round 2: leading junk applies to header detection only (#481) -----------

  LEADING_JUNK.each do |junk_label, prefix|
    FETCH_MANY_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_prefixed_error_row_#{junk_label}") do
        stub_call_rpc([ "#{prefix}-1^Invalid resource" ])
        err = assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
        assert_includes err.message, "-1",
                        "#{method}: prefixed error row must fail closed with code -1"
        refute_broker_text_in_rpc_error(method, err)
      end
    end

    ALL_LIST_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_flattened_empty_reply_#{junk_label}") do
        reply = [ prefix ]
        if RECORDSET_READS.key?(method)
          stub_recordset(cfg[:rpc] => reply)
        else
          stub_call_rpc(reply)
        end
        assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
      end
    end
  end

  {
    reply_text: -> { RpmsRpc::Reply.text("  -1^Invalid resource") },
    one_element_array: -> { [ "  -1^Invalid resource" ] }
  }.each do |shape, reply_builder|
    RECORDSET_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_prefixed_error_row_#{shape}") do
        stub_recordset(cfg[:rpc] => reply_builder.call)
        err = assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
        assert_includes err.message, "-1",
                        "#{method}: prefixed error row must fail closed with code -1"
        refute_broker_text_in_rpc_error(method, err)
      end
    end
  end

  RECORDSET_READS.each do |method, cfg|
    define_method("test_#{method}_prefixed_header_recordset_parses_like_unprefixed") do
      row = sample_row(cfg)
      stub_recordset(cfg[:rpc] => wire_recordset(cfg[:header], row))
      expected = cfg[:call].call
      RpmsRpc.reset!
      RpmsRpc.mock!
      stub_recordset(cfg[:rpc] => wire_recordset(cfg[:header], row, header_prefix: "  "))
      actual = cfg[:call].call
      assert_equal expected, actual,
                   "#{method}: flattened header recordset must parse like unprefixed wire"
      refute_equal 0, actual.first.values_at(:id, :availability_id, :appointment_id).compact.first,
                   "#{method}: first row must use real ids from data, not header column widths"
    end
  end

  {
    unframed_data_row: ->(cfg) { [ SAMPLE_DATA_ROW.fetch(cfg[:rpc]) ] },
    unframed_plain_message: ->(_cfg) { [ "Invalid resource" ] }
  }.each do |label, reply_builder|
    RECORDSET_READS.each do |method, cfg|
      define_method("test_#{method}_raises_on_headerless_unframed_#{label}") do
        stub_recordset(cfg[:rpc] => reply_builder.call(cfg))
        err = assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
        assert_includes err.message, "no recordset header",
                        "#{method}: headerless recordset read must not return []"
      end
    end
  end

  # -- Pin 5: RpcError message sanitization ------------------------------------

  SANITIZED_ERROR_BROKER_ROWS.each do |variant, broker_row|
    ALL_LIST_READS.each do |method, cfg|
      define_method("test_#{method}_error_message_sanitized_#{variant}") do
        if RECORDSET_READS.key?(method)
          stub_recordset(cfg[:rpc] => wire_recordset(ERRORID_HEADER, broker_row))
        else
          stub_call_rpc([ "#{ERRORID_HEADER}#{RS}", "#{broker_row}#{RS}" ])
        end
        err = assert_rpc_error_includes_rpc(method, cfg[:rpc]) { cfg[:call].call }
        assert_sanitized_error_message(
          method, cfg[:rpc], err,
          expect_code: variant == :caret_conflict || broker_row.start_with?("-1^")
        )
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

  def test_hospital_locations_flattened_header_only_reply_is_empty_not_bogus_record
    stub_call_rpc([ "  #{HOSPITAL_LOC_HEADER}" ])
    assert_equal [], RpmsRpc::Scheduling.hospital_locations
  end
end
