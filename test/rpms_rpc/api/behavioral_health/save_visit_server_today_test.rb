# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health"
require_relative "../../captured_replies"

# rpms-rpc#644: BehavioralHealth.save_visit refuses an encounter date after
# today, and "today" is the RPMS server's (ORWU DT "T"), never the
# workstation's. In a US evening a UTC server is already on the next day, so
# comparing with Date.today refused every save dated the server's today.
#
# Evidence: test/fixtures/captured_replies/orwu-dt.yml, captured live at
# 18:3x America/Los_Angeles on 2026-11-08 from a UTC container whose ORWU DT
# "T" was 3261109. The guard reads no client clock: each test runs with the
# process in the latest evening zone (Etc/GMT+12), and the after-today
# answers follow the captured server date alone.
class BehavioralHealthSaveVisitServerTodayTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "orwu-dt"
  SERVER_TODAY = "3261109" # the captured ORWU DT "T"
  EVENING_ZONE = "Etc/GMT+12" # UTC-12: the furthest behind a UTC server's date

  KWARGS = {
    provider: "412", patient: "990536", program: "MENTAL HEALTH", clinic: "17",
    type_of_contact: "3", encounter_location: "55", community_of_service: "42"
  }.freeze

  def teardown
    RpmsRpc.reset!
  end

  # Runs save_visit against the captured ORWU DT reply, in the evening zone.
  # Returns [error, rpcs called]. Only ORWU DT is
  # scripted, so a save that passes the date guard stops at its next RPC.
  def save_with(orwu_reply, encounter_date)
    client = CapturedReplies::ReplayCiaClient.new("ORWU DT" => [ orwu_reply ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    zone = ENV.fetch("TZ", nil)
    ENV["TZ"] = EVENING_ZONE
    error = begin
      BH.save_visit(**KWARGS, encounter_date: encounter_date)
      nil
    rescue StandardError => e
      e
    ensure
      ENV["TZ"] = zone
    end
    [ error, client.rpcs_called ]
  end

  def today_reply = CapturedReplies.raw(SLUG, "today")

  def test_the_server_today_passes_the_guard_in_a_client_evening
    error, called = save_with(today_reply, SERVER_TODAY)

    refute_kind_of BH::SaveError, error, "the server's today is not after today: #{error&.message}"
    assert_equal "ORWU DT", called.first
    assert_operator called.size, :>, 1, "the save went on past the date guard to its next RPC"
  end

  def test_the_day_after_the_server_today_is_refused_before_any_write
    error, called = save_with(today_reply, "3261110")

    assert_kind_of BH::SaveError, error
    assert_equal "encounter date is after today", error.message
    assert_equal [ "ORWU DT" ], called, "only the server date was read"
  end

  def test_a_server_date_of_minus_one_refuses_the_save
    error, called = save_with(CapturedReplies.raw(SLUG, "not_a_date"), SERVER_TODAY)

    assert_kind_of BH::SaveError, error
    assert_equal "the server date could not be read", error.message
    assert_equal [ "ORWU DT" ], called
  end

  def test_an_empty_server_date_refuses_the_save
    empty = today_reply.byteslice(0, 2) # the captured sequence echo and data ack, no value
    error, = save_with(empty, SERVER_TODAY)

    assert_kind_of BH::SaveError, error
    assert_equal "the server date could not be read", error.message
  end

  def test_a_refused_orwu_dt_refuses_the_save
    error, called = save_with(CapturedReplies.raw(SLUG, "refused"), SERVER_TODAY)

    assert_kind_of BH::SaveError, error
    assert_equal "the server date could not be read", error.message
    assert_kind_of RpmsRpc::Client::RpcError, error.cause
    assert_equal [ "ORWU DT" ], called
  end
end
