# frozen_string_literal: true

require "rpms_rpc/api/notifications"

# Notifications: BEHOXQ ALRLIST (the inbox), BEHOXQ ALRPP (remove), BEHOXQ
# FORWARD and BEHOXQ ALRMSG, as the gem's Notifications calls them.
#
# Setup sends five alerts through Kernel's GUI alert API, XQAL GUI ALERTS with
# LOC=SEND (SETUP^XQALERT), as notifications_live_test.rb does: to the
# clinician PROVIDER,TEST (DUZ 200) a BEHOXQ alert for demo patient DFN 3, a
# removable one (XQACNDEL=1), one with no patient, and a removable TIU alert,
# whose handler in #90460.021 has no post-processing; to PROFILE,SCHED
# (DUZ 208) a BEHOXQ alert for DFN 3, which that user forwards to
# PROFILE,REG (DUZ 207). Run on a fresh throwaway container: each run sends
# five more alerts. rpms-rpc#620.
Notifications = RpmsRpc::Notifications
ALERTS = {} # the completed alert IDs setup reads back, for the flows

# A refusal the gem raises is the outcome the flow records.
def refused
  yield
rescue Notifications::RefusedError
  nil
end

send_alert = lambda do |client, xqaid, message, to:, dfn: 3, removable: false|
  data = { "LOC" => "SEND", "XQAID" => xqaid, "XQAMSG" => message,
           "XQADATA" => (dfn ? "DFN=#{dfn}^PRI=1^INF=0" : "PRI=1^INF=0"), "XQA,#{to}" => "" }
  data["XQACNDEL"] = "1" if removable
  client.with_context("XQAL GUI ALERTS") { client.call_rpc("XQAL GUI ALERTS", data) }
  xqaid
end

CAPTURE = {
  rpc: "BEHOXQ ALRLIST", entry_point: "ALRLIST^BEHOXQ",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  personas: {
    sched: { access: "PSCH123", verify: "PSCH123!!", signed_on_as: "PROFILE,SCHED (PSCH123, a published demo pair; DUZ 208)" },
    reg: { access: "PREG123", verify: "PREG123!!", signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)" }
  },
  note: "Setup sends five alerts through XQAL GUI ALERTS (LOC=SEND) as PROVIDER,TEST: four to DUZ 200 " \
        "(BEHOXQ for DFN 3, BEHOXQ removable for DFN 3, BEHOXQ with no patient, TIU removable) and one " \
        "to DUZ 208 (BEHOXQ for DFN 3). The image also carries one OR consult alert for DUZ 200.",
  setup: lambda { |client|
    send_alert.call(client, "BEHOXQ,CAPKEEP", "Review the visit.", to: 200)
    send_alert.call(client, "BEHOXQ,CAPDEL", "Lab result to review.", to: 200, removable: true)
    send_alert.call(client, "BEHOXQ,CAPNOPT", "Staff meeting moved to 3 PM.", to: 200, dfn: nil)
    send_alert.call(client, "TIU,CAPTIU", "Note to cosign.", to: 200, removable: true)
    send_alert.call(client, "BEHOXQ,CAPFWD", "Please see this patient.", to: 208)
    # Kernel completes each ID (XQAID;sender;time): read them back, so a flow
    # sends only the calls the gem makes.
    ids = client.call_rpc_lines("BEHOXQ ALRLIST").map { |row| row.split("^")[9] }
    sched = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    sched.connect
    sched.authenticate("PSCH123", "PSCH123!!")
    ids += sched.call_rpc_lines("BEHOXQ ALRLIST").map { |row| row.split("^")[9] }
    sched.disconnect
    { keep: "BEHOXQ,CAPKEEP;", removable: "BEHOXQ,CAPDEL;", tiu: "TIU,CAPTIU;", forward: "BEHOXQ,CAPFWD;" }.each do |key, prefix|
      ALERTS[key] = ids.find { |id| id.to_s.start_with?(prefix) } || abort("setup: no #{prefix} alert was listed")
    end
    {}
  },
  flows: {
    "inbox_empty" => { as: :reg, about: "inbox of PROFILE,REG before anything is forwarded to it: no alerts",
                       run: -> { Notifications.inbox } },
    "inbox" => { about: "inbox of PROVIDER,TEST", run: -> { Notifications.inbox } },
    "inbox_patient" => { about: "inbox of PROVIDER,TEST with DFN 4 in context: only the alert with no patient",
                         run: -> { Notifications.inbox(patient_dfn: 4) } },
    "remove_not_removable" => {
      about: "remove the BEHOXQ alert sent without XQACNDEL: refused before BEHOXQ ALRPP",
      run: lambda {
        refused do
          Notifications.remove(ALERTS.fetch(:keep))
        end
      }
    },
    "remove_not_listed" => {
      about: "remove an alert ID no alert of this user has: refused before BEHOXQ ALRPP",
      run: lambda {
        refused do
          Notifications.remove("BEHOXQ,ELSE;9;3261104.1")
        end
      }
    },
    "remove_still_listed" => {
      about: "remove the removable TIU alert: its handler (2, TIU) has no post-processing, so it stays listed",
      run: lambda {
        refused do
          Notifications.remove(ALERTS.fetch(:tiu))
        end
      }
    },
    "remove" => {
      about: "remove the removable BEHOXQ alert: listed, BEHOXQ ALRPP (handler 3, BEHOXQ), listed again without it",
      run: lambda {
        Notifications.remove(ALERTS.fetch(:removable))
      }
    },
    "forward" => {
      as: :sched, about: "PROFILE,SCHED forwards its alert to DUZ 207 with a comment",
      run: lambda {
        Notifications.forward(ALERTS.fetch(:forward), to: 207, comment: "Please review today.")
      }
    },
    "message" => { as: :reg, about: "PROFILE,REG reads the forwarded alert's message: the forwarding comment first",
                   run: -> { Notifications.message(ALERTS.fetch(:forward)) } }
  }
}.freeze
