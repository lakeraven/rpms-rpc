# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
require "json"
require "open3"
require "rake"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"

# Issue #565 / #224 scheduling write slice — wire-capture side (recordset rows,
# write-fixture validation, RecordingClient, capture_writes guardrails).
class RpmsRpc::WireCaptureWriteTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WIRE_RAKE_PATH = File.join(ROOT, "lib/tasks/wire.rake")
  FIXTURES_DIR = RpmsRpc::WireCapture::FIXTURES_DIR

  RS = "\x1e".b
  END_MARKER = "\x1f".b

  ADD_SUCCESS_RAW = "6\x00I00020APPOINTMENTID^T00020ERRORID#{RS}1^#{RS}".b
  PERSONA_PROBE_REFUSAL_RAW =
    "5\x00I00020APPOINTMENTID^T00020ERRORID#{RS}0^BSDX07 Error: No file room printer is defined for the chart request.#{RS}#{END_MARKER}".b
  PERSONA_PROBE_SUCCESS_RAW = "3\x00I00020APPOINTMENTID^T00020ERRORID#{RS}4^#{RS}#{END_MARKER}".b
  CHECKIN_SUCCESS_RAW = "8\x00T00020ERRORID^T00150MESSAGE#{RS}0^#{RS}".b
  CANCEL_SUCCESS_RAW = "8\x00T00020ERRORID#{RS}#{RS}".b
  NOSHOW_SUCCESS_RAW = "8\x00I00020ERRORID^T00030ERRORTEXT#{RS}1^#{RS}".b

  VALID_DDR_READ_BACK_RAW = "5\x00[Data]\r\n2.98^3270107.09,3,^16^5^\r\n".b

  SCHEDULING_WRITE_RPCS = [
    "BSDX ADD NEW APPOINTMENT",
    "BSDX CHECKIN APPOINTMENT",
    "BSDX CANCEL APPOINTMENT",
    "BSDX NOSHOW"
  ].freeze

  def fields_write_fixture(overrides = {})
    raw = ADD_SUCCESS_RAW
    read_raw = VALID_DDR_READ_BACK_RAW
    data = {
      "rpc" => "BSDX ADD NEW APPOINTMENT",
      "mapping" => "scheduling_add_appointment",
      "kind" => "fields",
      "source" => "live-capture",
      "write" => true,
      "cite" => "APPADD^BSDX07 (synthetic spec fixture)",
      "release_tag" => "bcer-9.0-ydb",
      "captured_at" => "2026-11-05T00:00:00Z",
      "signed_on_as" => "PROV123",
      "inputs" => [ "3270107.09", "3270107.093", "3", "ZZ PILOT SCHED CAPTURE", "30", "", "", "" ],
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw),
      "pieces" => [
        { "position" => 0, "attribute" => "appointment_id", "fileman_type" => "integer" },
        { "position" => 1, "attribute" => "error" }
      ],
      "read_back" => [
        {
          "rpc" => "DDR GETS ENTRY DATA",
          "inputs" => { "FILE" => "9002018.4", "IENS" => "1,", "FIELDS" => ".01", "FLAGS" => "I" },
          "raw_return" => read_raw,
          "sha256" => Digest::SHA256.hexdigest(read_raw)
        }
      ]
    }.merge(overrides)
    overrides.each_key { |k| data.delete(k) if overrides[k].nil? }
    data
  end

  # -- recordset data rows (BMX \x1e framing) ---------------------------------

  def test_fixture_captured_data_rows_split_bsdx_add_success_recordset
    fx = RpmsRpc::WireCapture::Fixture.new(fields_write_fixture)
    assert_equal [ "1^" ], fx.captured_data_rows
  end

  def test_wire_capture_data_rows_split_bsdx_add_success_recordset
    assert_equal [ "1^" ], RpmsRpc::WireCapture.data_rows(ADD_SUCCESS_RAW)
  end

  def test_fixture_captured_data_rows_split_bsdx_cancel_empty_recordset
    cancel_attrs = {
      "rpc" => "BSDX CANCEL APPOINTMENT",
      "mapping" => "scheduling_cancel_appointment",
      "raw_return" => CANCEL_SUCCESS_RAW,
      "sha256" => Digest::SHA256.hexdigest(CANCEL_SUCCESS_RAW),
      "pieces" => [ { "position" => 0, "attribute" => "error" } ]
    }
    fx = RpmsRpc::WireCapture::Fixture.new(
      fields_write_fixture(cancel_attrs.merge("source" => "no-data"))
    )
    assert_empty fx.captured_data_rows

    assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture(cancel_attrs))
    end
  end

  def test_wire_capture_data_rows_split_bsdx_cancel_empty_recordset
    assert_empty RpmsRpc::WireCapture.data_rows(CANCEL_SUCCESS_RAW)
  end

  def test_wire_capture_data_rows_non_recordset_keeps_header_shaped_lines
    assert_equal [ "S72001A", "E1165" ], RpmsRpc::WireCapture.data_rows("1\x00S72001A\r\nE1165\r\n")
  end

  def test_fixture_captured_data_rows_split_bsdx_noshow_success_recordset
    fx = RpmsRpc::WireCapture::Fixture.new(
      fields_write_fixture(
        "rpc" => "BSDX NOSHOW",
        "mapping" => "scheduling_noshow_appointment",
        "raw_return" => NOSHOW_SUCCESS_RAW,
        "sha256" => Digest::SHA256.hexdigest(NOSHOW_SUCCESS_RAW),
        "pieces" => [
          { "position" => 0, "attribute" => "result", "fileman_type" => "integer" },
          { "position" => 1, "attribute" => "error" }
        ]
      )
    )
    assert_equal [ "1^" ], fx.captured_data_rows
  end

  def test_typed_bmx_header_row_is_never_a_data_row
    header = "I00020APPOINTMENTID^T00020ERRORID"
    refute_includes RpmsRpc::WireCapture.data_rows("6\x00#{header}#{RS}1^#{RS}"), header
  end

  def test_committed_orqqvi_vitals_fixture_row_count_unchanged
    path = File.join(FIXTURES_DIR, "orqqvi-vitals.yml")
    fx = RpmsRpc::WireCapture::Fixture.load_file(path)
    assert_equal 4, fx.captured_data_rows.size
    assert_equal 4, fx.rows.size
  end

  # -- write-fixture validation -----------------------------------------------

  def test_write_fixture_without_read_back_is_rejected
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("read_back" => []))
    end
    assert_match(/read_back/i, error.message)
  end

  def test_write_fixture_read_back_sha256_mismatch_is_rejected
    entry = fields_write_fixture["read_back"].first
    bad = fields_write_fixture(
      "read_back" => [ entry.merge("sha256" => "0" * 64) ]
    )
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(bad)
    end
    assert_match(/sha256/i, error.message)
  end

  def test_write_fixture_read_before_sha256_mismatch_is_rejected
    entry = ddr_read_back_entry(VALID_DDR_READ_BACK_RAW)
    bad = fields_write_fixture("read_before" => [ entry.merge("sha256" => "0" * 64) ])
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(bad)
    end
    assert_match(/read_before/i, error.message)
  end

  def test_write_fixture_read_before_accepts_sealed_valid_ddr_entries
    entry = ddr_read_back_entry(VALID_DDR_READ_BACK_RAW)
    assert RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("read_before" => [ entry ]))
  end

  def test_write_fixture_signed_on_as_realuser_is_rejected
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("signed_on_as" => "REALUSER1"))
    end
    assert_match(/signed_on_as/i, error.message)
  end

  def test_write_fixture_persona_probe_bad_sha256_is_rejected
    probe = {
      "signed_on_as" => "PROV123",
      "inputs" => [ "x" ],
      "raw_return" => "6\x00T00020ERRORID#{RS}0^BSDX07 Error: No file room printer#{RS}",
      "sha256" => "0" * 64
    }
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("persona_probe" => probe))
    end
    assert_match(/persona_probe/i, error.message)
  end

  def test_write_fixture_persona_probe_non_synthetic_signed_on_as_is_rejected
    probe = {
      "signed_on_as" => "REALUSER1",
      "inputs" => [ "x" ],
      "raw_return" => "6\x00T00020ERRORID#{RS}0^BSDX07 Error: No file room printer#{RS}",
      "sha256" => Digest::SHA256.hexdigest("6\x00T00020ERRORID#{RS}0^BSDX07 Error: No file room printer#{RS}")
    }
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("persona_probe" => probe))
    end
    assert_match(/persona_probe/i, error.message)
  end

  def test_write_fixture_persona_probe_success_reply_is_rejected
    raw = PERSONA_PROBE_SUCCESS_RAW
    probe = persona_probe_entry(raw)
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("persona_probe" => probe))
    end
    assert_match(/persona_probe/i, error.message)
  end

  def test_write_fixture_persona_probe_broker_error_reply_is_rejected
    raw = "8\x01-1^Access denied#{RS}#{RS}".b
    probe = persona_probe_entry(raw)
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("persona_probe" => probe))
    end
    assert_match(/persona_probe/i, error.message)
  end

  def test_write_fixture_persona_probe_booking_refusal_is_accepted
    raw = PERSONA_PROBE_REFUSAL_RAW
    probe = persona_probe_entry(raw)
    assert RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("persona_probe" => probe))
  end

  def test_write_fixture_read_back_error_reply_is_rejected
    raw = "5\x00[ERROR]\r\n-1^bad iens\r\n".b
    entry = ddr_read_back_entry(raw)
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("read_back" => [ entry ]))
    end
    assert_match(/read_back/i, error.message)
  end

  def test_write_fixture_read_back_data_marker_only_is_rejected
    raw = "5\x00[Data]\r\n".b
    entry = ddr_read_back_entry(raw)
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("read_back" => [ entry ]))
    end
    assert_match(/read_back/i, error.message)
  end

  def test_write_fixture_read_back_accepts_cia_framed_valid_ddr_reply
    entry = ddr_read_back_entry(VALID_DDR_READ_BACK_RAW)
    assert RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("read_back" => [ entry ]))
  end

  def test_ddr_read_back_validation_accepts_cia_framed_valid_reply
    assert RpmsRpc::WireCapture.valid_ddr_read_back_raw?(VALID_DDR_READ_BACK_RAW)
  end

  def test_ddr_read_back_validation_rejects_error_marker
    refute RpmsRpc::WireCapture.valid_ddr_read_back_raw?("5\x00[ERROR]\r\n-1^bad\r\n")
  end

  def test_ddr_read_back_validation_rejects_data_marker_without_field_rows
    refute RpmsRpc::WireCapture.valid_ddr_read_back_raw?("5\x00[Data]\r\n")
  end

  def test_non_write_fixture_without_read_back_still_loads
    path = File.join(FIXTURES_DIR, "orqqvi-vitals.yml")
    assert RpmsRpc::WireCapture::Fixture.load_file(path)
  end

  # -- RecordingClient --------------------------------------------------------

  def test_recording_client_wraps_delegate_records_rpc_and_returns_delegate_value
    inner = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def call_rpc_raw(rpc, params)
        @calls << [ :raw, rpc, params ]
        "ok-raw"
      end

      def call_rpc_global_array(rpc, params)
        @calls << [ :global, rpc, params ]
        "ok-global"
      end
    end.new

    recorder = RpmsRpc::WireCapture::RecordingClient.new(inner)
    assert_equal "ok-raw", recorder.call_rpc_raw("RPC A", [ "1" ])
    assert_equal "ok-global", recorder.call_rpc_global_array("RPC B", [ "2" ])

    assert_equal(
      { kind: :raw, rpc: "RPC A", inputs: [ "1" ], raw: "ok-raw" },
      recorder.rpc_calls[0]
    )
    assert_equal(
      { kind: :global_array, rpc: "RPC B", inputs: [ "2" ], raw: "ok-global" },
      recorder.rpc_calls[1]
    )
  end

  def test_recording_client_with_context_is_not_an_rpc_call
    inner = Class.new do
      def with_context(_name) = yield

      def call_rpc_raw(*) = "ok"
    end.new

    recorder = RpmsRpc::WireCapture::RecordingClient.new(inner)
    recorder.with_context("CIAV VUECENTRIC") { recorder.call_rpc_raw("DDR GETS ENTRY DATA", { "FILE" => "2" }) }
    assert_equal 1, recorder.rpc_calls.size
    assert_equal :raw, recorder.rpc_calls.first[:kind]
    context_calls = recorder.calls.select { |c| c[:kind] == :context }
    assert_empty context_calls,
                 "context binds must not appear as RPC calls (or must use :kind :context — not mixed with RPC)"
  end

  # -- rake wire:capture_writes guardrails ------------------------------------

  def test_capture_writes_aborts_when_live_disposable_unset
    assert_capture_writes_refuses(env: base_capture_writes_env.merge("LIVE_DISPOSABLE" => ""))
  end

  def test_capture_writes_aborts_when_broker_host_not_loopback
    assert_capture_writes_refuses(
      env: base_capture_writes_env.merge("LIVE_DISPOSABLE" => "1", "BROKER_HOST" => "10.0.0.5")
    )
  end

  def test_capture_writes_aborts_when_rpms_access_not_synthetic_persona
    assert_capture_writes_refuses(
      env: base_capture_writes_env.merge("LIVE_DISPOSABLE" => "1", "RPMS_ACCESS" => "REALUSER1")
    )
  end

  def test_capture_writes_aborts_when_release_unset
    env = base_capture_writes_env.merge("LIVE_DISPOSABLE" => "1")
    env.delete("RELEASE")
    assert_capture_writes_refuses(env: env)
  end

  def test_capture_writes_aborts_when_release_blank
    assert_capture_writes_refuses(
      env: base_capture_writes_env.merge("LIVE_DISPOSABLE" => "1", "RELEASE" => "  ")
    )
  end

  def test_capture_writes_task_source_never_interpolates_rpms_verify_into_fixtures
    src = File.read(WIRE_RAKE_PATH, encoding: Encoding::UTF_8)
    task_body = src[/task\s+:capture_writes\b.*?^\s*end/m]
    skip "wire:capture_writes task not defined yet" unless task_body

    refute_match(/RPMS_VERIFY/, task_body,
                 "wire:capture_writes must not interpolate RPMS_VERIFY into fixture output")
  end

  def test_wire_capture_read_catalog_never_lists_scheduling_write_rpcs_as_live
    live = RpmsRpc::WireCapture::CATALOG.select(&:live?).map(&:rpc)
    overlaps = SCHEDULING_WRITE_RPCS & live
    assert_empty overlaps,
                 "wire:capture read catalog must not :live-call scheduling writes: #{overlaps.join(", ")}"
  end

  def test_capture_writes_exits_nonzero_when_driver_capture_reports_error
    dir = Dir.mktmpdir("wire_capture_writes")
    fake_document = {
      "captures" => {
        "BSDX CHECKIN APPOINTMENT" => {
          "signed_on_as" => "PROV123",
          "error" => "synthetic driver failure"
        }
      },
      "setup" => {
        "resource_ien" => 1,
        "hospital_location_id" => 3
      }
    }
    driver_status = Struct.new(:success?, :exitstatus).new(true, 0)
    begin
      load_wire_rake!
      Open3.singleton_class.prepend(Module.new do
        define_method(:capture2) do |_env, *_argv|
          [ JSON.generate(fake_document), driver_status ]
        end
      end)
      exit = assert_raises(SystemExit) do
        with_env(base_capture_writes_env.merge("WIRE_FIXTURES_DIR" => dir)) do
          Rake::Task["wire:capture_writes"].invoke
        end
      end
      refute_equal 0, exit.status
      refute File.file?(File.join(dir, "bsdx-checkin-appointment.yml"))
    ensure
      Rake::Task["wire:capture_writes"].reenable if Rake::Task.task_defined?("wire:capture_writes")
      FileUtils.remove_entry(dir)
    end
  end

  private

  def ddr_read_back_entry(raw)
    {
      "rpc" => "DDR GETS ENTRY DATA",
      "inputs" => { "FILE" => "2.98", "IENS" => "3270107.09,3,", "FIELDS" => "16", "FLAGS" => "I" },
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw)
    }
  end

  def persona_probe_entry(raw)
    {
      "signed_on_as" => "PROV123",
      "inputs" => [ "3261126.1115", "3261126.1145", "3", "ZZ PILOT SCHED CAPTURE", "30", "", "", "" ],
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw)
    }
  end

  WIRE_WRITE_REFUSAL = "wire:capture_writes: refusing to run."

  def base_capture_writes_env
    {
      "WIRE_FIXTURES_DIR" => Dir.mktmpdir("wire_capture_writes"),
      "LIVE_DISPOSABLE" => "1",
      "BROKER_HOST" => "127.0.0.1",
      "RPMS_ACCESS" => "PROV123",
      "RELEASE" => "bcer-9.0-20261012-e7923a4-ydb"
    }
  end

  def assert_capture_writes_refuses(env:)
    dir = env.fetch("WIRE_FIXTURES_DIR")
    begin
      load_wire_rake!
      assert Rake::Task.task_defined?("wire:capture_writes"),
             "missing rake wire:capture_writes task (write capture pipeline not implemented)"
      # The rake guard itself must refuse: the message is its own (the
      # driver's guard words its refusal differently), so a rake guard that
      # lets the run through and a driver that then refuses cannot pass.
      status = nil
      _out, err = capture_io do
        status = assert_raises(SystemExit) { with_env(env) { Rake::Task["wire:capture_writes"].invoke } }.status
      end
      assert_equal 1, status
      assert_includes err, WIRE_WRITE_REFUSAL
      assert_empty Dir.glob(File.join(dir, "*.yml"))
    ensure
      Rake::Task["wire:capture_writes"].reenable if Rake::Task.task_defined?("wire:capture_writes")
      FileUtils.remove_entry(dir)
    end
  end

  def load_wire_rake!
    Rake.application.rake_require("tasks/wire", [ File.join(ROOT, "lib") ])
  end

  def with_env(env)
    prior = env.keys.to_h { |k| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    prior.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
