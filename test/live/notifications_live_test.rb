# frozen_string_literal: true

require "securerandom"
require_relative "live_helper"
require "rpms_rpc/api/notifications"

# Notifications reads and acts on the signed-on user's alerts the way
# VueCentric's Notifications tab does: BEHOXQ ALRLIST to list them (rpms-ux
# S-SGN-02.1), BEHOXQ ALRPP to remove one, BEHOXQ FORWARD to forward one and
# BEHOXQ ALRMSG to read a forwarded alert's comment.
#
# The spec sends alerts through Kernel's own GUI alert API, XQAL GUI ALERTS
# with LOC=SEND (SETUP^XQALERT, XQALGUI.m:35-41): the call BEHOXQPC makes for
# its missing-POV and missing-E&M alerts. Each is an IHS EHR (BEHOXQ) alert
# for a demo patient, so the BEHOXQ handler names its patient from DFN= in
# its data. XQACNDEL=1 is Kernel's "may be deleted without processing" flag,
# the CAN DELETE piece ALRLIST answers. Whatever an alert's test leaves behind
# is deleted with LOC=DELETE (DELETE^XQALERT), for every recipient.
#
# XQAL GUI ALERTS is in no option but its own, so the persona must be one CIA
# lets call it: SYS123 on the pinned build (XUPROGMODE, CIANBACT.m:49).
# Another persona is refused at the send, and the spec says so. The second
# user is a published demo persona of the build, signed on on its own
# connection, as in scoped_client_two_identities_live_test.rb.
class NotificationsLiveTest < LiveSpec::Test
  writes!

  SEND_RPC = "XQAL GUI ALERTS"
  DFN = 3 # MOUSE,MICKEY M, a demo patient of the image
  OTHER_DFN = 4
  OTHER_PAIR = [ "PSCH123", "PSCH123!!" ].freeze

  def teardown
    Array(@sent).each { |alert_id| delete_alert(alert_id) }
    @other&.disconnect
    super
  end

  # Send an alert to +to+ (DUZs, default the persona) and answer its ID, as
  # Kernel completed it (XQAID;sender;time). +xqaid+ is unique per call, so
  # two alerts sent in the same second never share an ID.
  def send_alert(message, to: [ client.duz ], removable: false, xqaid: "BEHOXQ,LIVESPEC#{SecureRandom.hex(3).upcase}")
    data = { "LOC" => "SEND", "XQAID" => xqaid, "XQADATA" => "DFN=#{DFN}^PRI=1^INF=0", "XQAMSG" => message }
    to.each { |duz| data["XQA,#{duz}"] = "" }
    data["XQACNDEL"] = "1" if removable
    begin
      client.call_rpc(SEND_RPC, data)
    rescue RpmsRpc::Client::RpcError => e
      flunk "#{persona} may not send an alert through #{SEND_RPC} (#{e.message}): run this spec as SYS123"
    end
    reader = to.include?(client.duz) ? client : other
    alert_id = RpmsRpc.with_client(reader) { inbox_ids }.find { |id| id.start_with?("#{xqaid};") }
    refute_nil alert_id, "the alert just sent is listed for its recipient"
    (@sent ||= []) << alert_id
    alert_id
  end

  def delete_alert(alert_id)
    client.call_rpc(SEND_RPC, { "LOC" => "DELETE", "XQAID" => alert_id })
  end

  def other
    @other ||= begin
      c = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
      c.connect
      c.authenticate(*OTHER_PAIR)
      refute_equal client.duz, c.duz, "the second persona is another user"
      c
    end
  end

  def inbox_ids = RpmsRpc::Notifications.inbox.map { |row| row[:alert_id] }
  def as_other(&) = RpmsRpc.with_client(other, &)

  def test_s_sgn_02_1_an_alert_sent_to_me_is_listed_with_its_patient
    before = inbox_ids
    message = "Live spec notification #{SecureRandom.hex(4)}"

    send_alert(message, xqaid: "BEHOXQ,LIVESPEC")
    added = RpmsRpc::Notifications.inbox.reject { |row| before.include?(row[:alert_id]) }

    assert_equal 1, added.size, "exactly the alert just sent is new: #{added.inspect}"
    alert = added.first
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
  end

  def test_i_remove_a_removable_notification_and_it_leaves_my_inbox
    alert_id = send_alert("Live spec removable #{SecureRandom.hex(4)}", removable: true)
    assert RpmsRpc::Notifications.inbox.find { |r| r[:alert_id] == alert_id }[:removable], "XQACNDEL=1 is ALRLIST's CAN DELETE"

    assert_equal({ alert_id: alert_id, removed: true }, RpmsRpc::Notifications.remove(alert_id))

    refute_includes inbox_ids, alert_id, "BEHOXQ ALRPP removed it from my notifications"
    puts "\n#{persona}: alert #{alert_id} removed through BEHOXQ ALRPP"
  end

  def test_a_notification_rpms_marks_not_removable_is_refused_and_stays
    alert_id = send_alert("Live spec not removable #{SecureRandom.hex(4)}")

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(alert_id) }
    assert_match(/may not be removed/, error.message)
    assert_includes inbox_ids, alert_id, "the refused alert is still listed"
  end

  def test_i_cannot_remove_another_users_notification
    alert_id = send_alert("Live spec someone else's #{SecureRandom.hex(4)}", removable: true)

    as_other do
      refute_includes inbox_ids, alert_id, "the alert is not the second user's"
      error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(alert_id) }
      assert_match(/not in your notifications/, error.message)
      # The stock RPC itself, sent as the second user, leaves it too:
      # BEHDEL^BEHOXQ(AID,1) deletes for DUZ only (XQAKILL=1, XQALDEL.m:17-19).
      other.call_rpc("BEHOXQ ALRPP", alert_id)
    end

    assert_includes inbox_ids, alert_id, "the alert is still listed for its own recipient"
  end

  def test_i_forward_a_notification_and_it_arrives_with_my_comment
    message = "Live spec forward #{SecureRandom.hex(4)}"
    alert_id = send_alert(message)
    comment = "Please review today #{SecureRandom.hex(2)}"

    result = RpmsRpc::Notifications.forward(alert_id, to: other.duz, comment: comment)

    assert_equal({ alert_id: alert_id, forwarded_to: [ other.duz.to_i ], comment: comment }, result)
    assert_includes inbox_ids, alert_id, "forwarding leaves my own copy"
    as_other do
      row = RpmsRpc::Notifications.inbox.find { |r| r[:alert_id] == alert_id }
      refute_nil row, "the forwarded alert is in the recipient's notifications"
      assert_equal message, row[:message]
      assert_equal DFN, row[:patient_dfn]
      assert_equal client.signon_user, row[:sender], "ALRLIST names the forwarder (BEHOXQ.m:32-33)"
      assert_equal comment, RpmsRpc::Notifications.message(alert_id).first, "BEHOXQ ALRMSG answers the forwarding comment first"
    end
    puts "\n#{persona}: alert #{alert_id} forwarded to DUZ #{other.duz} with its comment"
  end
end
