# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
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
  CHECKIN_SUCCESS_RAW = "8\x00T00020ERRORID^T00150MESSAGE#{RS}0^#{RS}".b
  CANCEL_SUCCESS_RAW = "8\x00T00020ERRORID#{RS}#{RS}".b
  NOSHOW_SUCCESS_RAW = "8\x00I00020ERRORID^T00030ERRORTEXT#{RS}1^#{RS}".b

  SCHEDULING_WRITE_RPCS = [
    "BSDX ADD NEW APPOINTMENT",
    "BSDX CHECKIN APPOINTMENT",
    "BSDX CANCEL APPOINTMENT",
    "BSDX NOSHOW"
  ].freeze

  def fields_write_fixture(overrides = {})
    raw = ADD_SUCCESS_RAW
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
          "raw_return" => "[Data]\n9002018.4^1^1^.01^3270107.09\n",
          "sha256" => Digest::SHA256.hexdigest("[Data]\n9002018.4^1^1^.01^3270107.09\n")
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
    fx = RpmsRpc::WireCapture::Fixture.new(
      fields_write_fixture(
        "rpc" => "BSDX CANCEL APPOINTMENT",
        "mapping" => "scheduling_cancel_appointment",
        "raw_return" => CANCEL_SUCCESS_RAW,
        "sha256" => Digest::SHA256.hexdigest(CANCEL_SUCCESS_RAW),
        "pieces" => [ { "position" => 0, "attribute" => "error" } ]
      )
    )
    assert_empty fx.captured_data_rows
  end

  def test_wire_capture_data_rows_split_bsdx_cancel_empty_recordset
    assert_empty RpmsRpc::WireCapture.data_rows(CANCEL_SUCCESS_RAW)
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

  def test_write_fixture_read_back_with_no_data_rows_is_rejected
    raw = "[ERROR]\n-1^bad iens\n"
    entry = {
      "rpc" => "DDR GETS ENTRY DATA",
      "inputs" => { "FILE" => "2", "IENS" => "bad,", "FIELDS" => ".01", "FLAGS" => "I" },
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw)
    }
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      RpmsRpc::WireCapture::Fixture.new(fields_write_fixture("read_back" => [ entry ]))
    end
    assert_match(/read_back/i, error.message)
  end

  def test_non_write_fixture_without_read_back_still_loads
    path = File.join(FIXTURES_DIR, "orqqvi-vitals.yml")
    assert RpmsRpc::WireCapture::Fixture.load_file(path)
  end

  # -- RecordingClient --------------------------------------------------------

  def test_recording_client_wraps_delegate_and_records_rpc_calls
    inner = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def call_rpc_raw(rpc, params) = @calls << [ :raw, rpc, params ] and "ok-raw"

      def call_rpc_global_array(rpc, params) = @calls << [ :global, rpc, params ] and "ok-global"
    end.new

    recorder = RpmsRpc::WireCapture::RecordingClient.new(inner)
    assert_equal "ok-raw", recorder.call_rpc_raw("RPC A", [ "1" ])
    assert_equal "ok-global", recorder.call_rpc_global_array("RPC B", [ "2" ])

    assert_equal [ [ :raw, "RPC A", [ "1" ] ], [ :global, "RPC B", [ "2" ] ] ], recorder.calls
    assert_empty inner.calls.select { |c| c[0] == :context }
  end

  # -- rake wire:capture_writes guardrails ------------------------------------

  def test_capture_writes_aborts_without_live_disposable_loopback_synthetic_persona
    dir = Dir.mktmpdir("wire_capture_writes")
    begin
      load_wire_rake!
      env = {
        "WIRE_FIXTURES_DIR" => dir,
        "LIVE_DISPOSABLE" => "",
        "BROKER_HOST" => "127.0.0.1",
        "RPMS_ACCESS" => "PROV123"
      }
      load_wire_rake!
      assert Rake::Task.task_defined?("wire:capture_writes"),
             "missing rake wire:capture_writes task (write capture pipeline not implemented)"
      assert_raises(SystemExit) { with_env(env) { Rake::Task["wire:capture_writes"].invoke } }
      assert_empty Dir.glob(File.join(dir, "*.yml"))
    ensure
      Rake::Task["wire:capture_writes"].reenable if Rake::Task.task_defined?("wire:capture_writes")
      FileUtils.remove_entry(dir)
    end
  end

  def test_wire_capture_read_catalog_never_lists_scheduling_write_rpcs_as_live
    live = RpmsRpc::WireCapture::CATALOG.select(&:live?).map(&:rpc)
    overlaps = SCHEDULING_WRITE_RPCS & live
    assert_empty overlaps,
                 "wire:capture read catalog must not :live-call scheduling writes: #{overlaps.join(", ")}"
  end

  private

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
