# frozen_string_literal: true

require "securerandom"
require_relative "live_helper"
require "rpms_rpc/api/notifications"

# Notifications.inbox reads the signed-on user's alerts the way VueCentric's
# Notifications tab does, BEHOXQ ALRLIST (rpms-ux S-SGN-02.1).
#
# The spec sends the persona an alert through Kernel's own GUI alert API,
# XQAL GUI ALERTS with LOC=SEND (SETUP^XQALERT, XQALGUI.m:35-41): the call
# BEHOXQPC makes for its missing-POV and missing-E&M alerts. The alert is an
# IHS EHR (BEHOXQ) alert for a demo patient, so the BEHOXQ handler names its
# patient from DFN= in its data. It reads the alert back, then deletes it
# (LOC=DELETE, DELETE^XQALERT for the persona).
#
# XQAL GUI ALERTS is in no option but its own, so the persona must be one CIA
# lets call it: SYS123 on the pinned build (XUPROGMODE, CIANBACT.m:49).
# Another persona is refused at the send, and the spec says so.
class NotificationsLiveTest < LiveSpec::Test
  writes!

  SEND_RPC = "XQAL GUI ALERTS"
  DFN = 3 # MOUSE,MICKEY M, a demo patient of the image
  OTHER_DFN = 4

  def send_alert(message)
    client.call_rpc(SEND_RPC, {
      "LOC" => "SEND",
      "XQA,#{client.duz}" => "",
      "XQAID" => "BEHOXQ,LIVESPEC",
      "XQADATA" => "DFN=#{DFN}^PRI=1^INF=0",
      "XQAMSG" => message
    })
  rescue RpmsRpc::Client::RpcError => e
    flunk "#{persona} may not send itself an alert through #{SEND_RPC} (#{e.message}): run this spec as SYS123"
  end

  def delete_alert(alert_id)
    client.call_rpc(SEND_RPC, { "LOC" => "DELETE", "XQAID" => alert_id })
  end

  def test_s_sgn_02_1_an_alert_sent_to_me_is_listed_with_its_patient
    before = RpmsRpc::Notifications.inbox.map { |row| row[:alert_id] }
    message = "Live spec notification #{SecureRandom.hex(4)}"

    send_alert(message)
    added = RpmsRpc::Notifications.inbox.reject { |row| before.include?(row[:alert_id]) }

    assert_equal 1, added.size, "exactly the alert just sent is new: #{added.inspect}"
    @sent = alert = added.first
    assert_match(/\ABEHOXQ,LIVESPEC;#{client.duz};\d{7}\.\d+\z/, alert[:alert_id], "Kernel appends the sender and the time")
    assert_equal message, alert[:message]
    assert_equal DFN, alert[:patient_dfn]
    assert_equal "MOUSE,MICKEY M", alert[:patient_name]
    assert_equal client.signon_user, alert[:sender]
    assert_equal :high, alert[:priority]
    assert_equal false, alert[:info_only]
    assert_equal "BEHOXQ", alert[:type]
    # A FileMan time carries no zone: it is the server's wall clock, read as local here.
    assert_in_delta Time.now, alert[:delivered_at], 86_400, "delivered today, on the server's wall clock"

    assert_includes RpmsRpc::Notifications.inbox(patient_dfn: DFN).map { |r| r[:alert_id] }, alert[:alert_id]
    refute_includes RpmsRpc::Notifications.inbox(patient_dfn: OTHER_DFN).map { |r| r[:alert_id] }, alert[:alert_id],
                    "with another patient in context, this patient's alert is not listed"
    puts "\n#{persona}: alert #{alert[:alert_id]} for DFN #{DFN} listed by BEHOXQ ALRLIST"
  ensure
    if @sent
      delete_alert(@sent[:alert_id])
      refute_includes RpmsRpc::Notifications.inbox.map { |r| r[:alert_id] }, @sent[:alert_id], "the spec's alert is deleted"
    end
  end
end
