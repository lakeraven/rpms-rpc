# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/scheduling"
require_relative "../captured_replies"

# rpms-rpc#481: failed BSDX list reads must raise RpcError, not masquerade as
# "nothing on file". A header-only recordset reply is [].
#
# Replies are the pinned build's, captured as the scheduler persona
# (test/fixtures/captured_replies/bsdx-scheduling.yml), replayed through
# CiaClient. Each read is pinned on its captured rows and on a captured
# header-only reply. The guard cases keep a captured frame (its sequence echo
# and header) and change its rows, because the build answered these reads
# without an error; each says what it changes.
class SchedulingBsdxListReadTest < Minitest::Test
  SLUG = "bsdx-scheduling"
  RS = "\x1E"
  US = "\x1F"
  DAY = Date.new(2026, 11, 16)

  # Each list read: its RPC, the call, the capture with rows, and the
  # header-only capture (nil when the build had no empty case to capture; the
  # rows are then dropped from the captured frame).
  READS = {
    availability: {
      rpc: "BSDX SEARCH AVAILABILITY", rows: "availability", empty: "availability_unknown_resource",
      call: -> { RpmsRpc::Scheduling.availability(resources: "DEMO IHS CLINIC", start_date: DAY, end_date: DAY) }
    },
    all_appointments: {
      rpc: "BSDX ALL APPOINTMENTS", rows: "all_appointments", empty: "all_appointments_none",
      call: -> { RpmsRpc::Scheduling.all_appointments(start_date: DAY, end_date: DAY) }
    },
    hospital_locations: {
      rpc: "BSDX HOSPITAL LOCATION", rows: "hospital_locations", empty: nil,
      call: -> { RpmsRpc::Scheduling.hospital_locations }
    },
    clinic_setup: {
      rpc: "BSDX CLINIC SETUP", rows: "clinic_setup", empty: nil,
      call: -> { RpmsRpc::Scheduling.clinic_setup }
    },
    resources: {
      rpc: "BSDX RESOURCES", rows: "resources", empty: nil,
      call: -> { RpmsRpc::Scheduling.resources }
    },
    slot_schedule: {
      rpc: "BSDX CREATE ASGND SLOT SCHED", rows: "slot_schedule", empty: "slot_schedule_unknown_resource",
      call: -> { RpmsRpc::Scheduling.slot_schedule(resource: "DEMO IHS CLINIC", start_date: DAY, end_date: DAY) }
    },
    appointments: {
      rpc: "BSDX CREATE APPT SCHEDULE", rows: "appointments", empty: "appointments_none",
      call: -> { RpmsRpc::Scheduling.appointments(resource: "DEMO IHS CLINIC", start_date: DAY, end_date: DAY) }
    }
  }.freeze

  # Broker text that must never reach an RpcError message: it can hold a
  # patient's name.
  LEAKY_ROW = "-1^Patient DEMO,PATIENT ONE has a conflict"

  def teardown
    RpmsRpc.reset!
  end

  def raw(name) = CapturedReplies.raw(SLUG, name)

  def replay(rpc, reply)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = CapturedReplies::ReplayCiaClient.new(rpc => [ reply ]) }
  end

  # The captured frame's echo and \x00 ack, its header line, and its rows.
  def parts(cfg)
    reply = raw(cfg[:rows])
    head = reply.byteslice(0, 2)
    header, *rows = reply.byteslice(2..).delete_suffix(US.b).split(RS.b).reject(&:empty?)
    [ head, header, rows ]
  end

  # A captured frame with its rows replaced by the given lines.
  def frame_with(cfg, *lines, header: nil)
    head, captured_header, = parts(cfg)
    body = [ header || captured_header, *lines ].map { |l| l.b + RS.b }.join
    head + body + US.b
  end

  def assert_rpc_error(method, cfg, phrase = nil)
    err = assert_raises(RpmsRpc::Client::RpcError, "#{method}: failed read must raise RpcError") { cfg[:call].call }
    assert_includes err.message, cfg[:rpc], "#{method}: RpcError must name the RPC"
    assert_includes err.message, phrase, "#{method}: #{err.message.inspect}" if phrase
    err
  end

  READS.each do |method, cfg|
    define_method("test_#{method}_reads_the_captured_rows") do
      replay(cfg[:rpc], raw(cfg[:rows]))
      rows = cfg[:call].call

      refute_empty rows, "#{method}: the captured reply has rows"
      refute(rows.any? { |r| r.values.compact.any? { |v| v.to_s.match?(/\A[ITDF]\d{5}/) } },
             "#{method}: the typed header is not a record")
    end

    define_method("test_#{method}_header_only_is_empty") do
      reply = cfg[:empty] ? raw(cfg[:empty]) : frame_with(cfg)
      replay(cfg[:rpc], reply)

      assert_equal [], cfg[:call].call, "#{method}: a header-only reply is a genuine empty list"
    end

    # Guard: the frame with no header and no rows (the ack alone).
    define_method("test_#{method}_raises_on_an_empty_reply") do
      replay(cfg[:rpc], parts(cfg).first)

      assert_rpc_error(method, cfg)
    end

    # Guard: an error row in place of the rows. The code is kept; the text is not.
    define_method("test_#{method}_raises_on_an_error_row_without_echoing_it") do
      replay(cfg[:rpc], frame_with(cfg, LEAKY_ROW))

      err = assert_rpc_error(method, cfg, "-1")
      refute_match(/DEMO|PATIENT|conflict/i, err.message, "#{method}: broker text leaked")
    end

    # Guard: an ERRORID recordset (what BSDX writes for a refusal) in place of
    # the read's own header.
    define_method("test_#{method}_raises_on_an_errorid_recordset") do
      replay(cfg[:rpc], frame_with(cfg, "Resource not found", header: "T00030ERRORID"))

      err = assert_rpc_error(method, cfg, "ERRORID recordset")
      refute_match(/not found/i, err.message)
    end

    # Guard: a second header line among the rows.
    define_method("test_#{method}_raises_on_a_second_header") do
      _, header, rows = parts(cfg)
      replay(cfg[:rpc], frame_with(cfg, *rows, header))

      assert_rpc_error(method, cfg, "unexpected second header")
    end

    # Guard: a captured row with a byte that is not UTF-8. CiaClient replaces it
    # and marks the reply altered; the read fails rather than return the row.
    define_method("test_#{method}_raises_on_a_row_with_a_byte_that_is_not_utf8") do
      _, _, rows = parts(cfg)
      bad = rows.first.b.sub(/[A-Z]/n) { "\xC9".b }
      replay(cfg[:rpc], frame_with(cfg, bad, *rows.drop(1)))

      assert_rpc_error(method, cfg, "not valid UTF-8")
    end
  end
end
