# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # The signed-on user's notifications, read the way VueCentric's
  # Notifications tab reads them (rpms-ux S-SGN-02.1).
  #
  # Underlying RPC: BEHOXQ ALRLIST -> ALRLIST^BEHOXQ, the IHS EHR
  # notification component. It reads the Kernel ALERT file (#8992) for DUZ,
  # so it always answers for the user the session signed on as; there is no
  # user parameter to pass. The reply layout is documented on the
  # :notifications_inbox mapping (mappings/ihs.rb).
  #
  # This module once read BQI GET COMM ALERTS SPLASH, iCare's community
  # alerts (notifiable-disease and suicide counts per community,
  # BQICASPL.m:4-15): not a user's notifications, and it carries no patient
  # per row.
  #
  # Read only as far as the alerts go: ALRLIST does not mark an alert seen
  # (ORWORB FASTUSER does, through GETUSER1^XQALDATA). It does set CIA
  # session variables (SETVAR^CIANBUTL, BEHOXQ.m:11, :41-42), which is why
  # retry_safety.yml does not call it a read.
  #
  # Acting on one is done through the RPCs the same component sends (read
  # from BEHNotifications.ocx: its Delete, after its own CAN DELETE check, calls
  # BEHOXQ ALRPP with the alert ID, and its forward calls BEHOXQ FORWARD
  # with the alert IDs, the recipients and the comment). All three sit in
  # CIAV VUECENTRIC, the option sign-on binds, so they run as the
  # signed-on user under that user's own option:
  #
  #   remove   BEHOXQ ALRPP    DELETE /notifications/{alert_id}
  #   forward  BEHOXQ FORWARD  POST   /notifications/{alert_id}/forward
  #   message  BEHOXQ ALRMSG   GET    /notifications/{alert_id}/message
  #
  # Neither write answers whether it did anything (ALRPP answers its alert
  # handler, FORWARD answers 0), so the gem checks what it can, the way
  # VueCentric does: the alert must be one of the user's (ALRLIST), and a
  # remove must be of an alert RPMS marks CAN DELETE ("You cannot delete
  # the following alert", the tab's own refusal). A remove is then
  # confirmed by reading the list again. Anything else raises RefusedError.
  module Notifications
    extend self
    extend Shape::Declarable

    # RPMS did not, or would not, do what was asked. The message says why.
    class RefusedError < RpmsRpc::Error; end

    # The forwarding comment's limits: 1 to 245 characters at the Kernel's
    # own prompt (XQALFWD.m:22), and stored as a caret piece of the
    # recipient's alert (XQALSET.m:62), so it may hold no caret.
    COMMENT_MAX = 245

    # ORB URGENCY's codes, which ORPARSE^BEHOXQ passes through (BEHOXQ.m:90-96;
    # ORQORB.m:20-24). A BEH alert's own PRI= is on the same scale, and
    # ALRLIST answers 2 when a handler sets none (BEHOXQ.m:40).
    PRIORITY = { 1 => :high, 2 => :moderate, 3 => :low }.freeze

    # The signed-on user's alerts, one hash per alert, as RPMS orders them.
    # +patient_dfn+ limits it to that patient's alerts and those with no
    # patient, as VueCentric does with a patient in context.
    #
    #   { alert_id: "OR,3,19;4;3261104.175206", patient_dfn: 3,
    #     patient_name: "MOUSE,MICKEY M", hrn: "1001", location: nil,
    #     message: "Unscheduled visit.", delivered_at: Time, sender: "MANAGER,SYSTEM",
    #     priority: :moderate, info_only: true, removable: true, type: "OR.19" }
    #
    # A refusal raises (the client's RpcError, as CIA reports one); an empty
    # list means RPMS holds no alert for the user.
    def inbox(patient_dfn: nil)
      params = patient_dfn.nil? ? [] : [ patient_dfn.to_s ]
      Array(DataMapper.notifications_inbox.fetch_many(*params)).map { |row| decorate(row) }
    end

    # Remove one of the signed-on user's notifications, as the Notifications
    # tab's Delete does: BEHOXQ ALRPP, which runs the alert handler's PROCESS
    # code (for a BEH alert, DELETE^XQALERT for DUZ only: BEHDEL^BEHOXQ with
    # XQAKILL=1, XQALDEL.m:17-19). Only an alert ALRLIST lists for the user
    # with CAN DELETE set is sent; afterwards it must be gone from the list.
    # Answers { alert_id:, removed: true }; raises RefusedError otherwise.
    def remove(alert_id)
      id = alert_id!(alert_id)
      alert = listed!(id)
      unless alert[:removable]
        raise RefusedError, "#{id} may not be removed: RPMS lists it with CAN DELETE 0, so it is processed, not deleted"
      end

      handler = DataMapper.notifications_remove.fetch_scalar(id).to_i
      raise RefusedError, "BEHOXQ ALRPP found no alert handler for #{id}: nothing was removed" unless handler.positive?
      raise RefusedError, "#{id} is still listed after BEHOXQ ALRPP: RPMS did not remove it" if listed?(id)

      { alert_id: id, removed: true }
    end
    shape :remove, resource: "notifications", verb: "DELETE", path: "/notifications/{alert_id}"

    # Forward one of the signed-on user's notifications to other users, by
    # DUZ, with an optional comment, as the tab's Forward does: BEHOXQ
    # FORWARD, FORWARD^XQALFWD(alert, users, "A", comment). Each recipient
    # gets their own copy, naming the forwarder and carrying the comment
    # (read back with #message); the user keeps theirs. Only an alert
    # ALRLIST lists for the user is sent, since Kernel forwards nothing else
    # (RESETUP^XQALFWD, XQALFWD.m:99) and answers 0 either way.
    # Answers { alert_id:, forwarded_to: [DUZ], comment: }.
    def forward(alert_id, to:, comment: nil)
      id = alert_id!(alert_id)
      recipients = Array(to).map { |duz| duz!(duz) }
      raise ArgumentError, "forward needs at least one recipient DUZ" if recipients.empty?

      text = comment.to_s
      raise ArgumentError, "a forwarding comment is at most #{COMMENT_MAX} characters" if text.length > COMMENT_MAX
      raise ArgumentError, "a forwarding comment may not contain a caret" if text.include?("^")

      listed!(id)
      list = recipients.each_with_index.to_h { |duz, i| [ (i + 1).to_s, duz.to_s ] }
      reply = DataMapper.notifications_forward.fetch_scalar(id, list, text)
      raise RefusedError, "BEHOXQ FORWARD answered #{reply.inspect} for #{id}, not 0" unless reply == 0

      { alert_id: id, forwarded_to: recipients, comment: text.empty? ? nil : text }
    end
    shape :forward, resource: "notifications", verb: "POST", path: "/notifications/{alert_id}/forward"

    # The text of one of the signed-on user's notifications, as BEHOXQ ALRMSG
    # answers it: a forwarded alert's comment first, then the alert's long
    # text. [] when the user holds no such alert or it has neither.
    def message(alert_id)
      DataMapper.notifications_message.fetch_text(alert_id!(alert_id)).to_s.split("\n")
    end
    shape :message, resource: "notifications", verb: "GET", path: "/notifications/{alert_id}/message"

    private

    def alert_id!(alert_id)
      id = alert_id.to_s.strip
      raise ArgumentError, "an alert ID is required" if id.empty?

      id
    end

    def duz!(value)
      duz = value.is_a?(Integer) ? value : (Integer(value.to_s, 10) if value.to_s.match?(/\A\d+\z/))
      raise ArgumentError, "a recipient is a DUZ, a positive integer (got #{value.inspect})" unless duz&.positive?

      duz
    end

    def listed?(id) = inbox.any? { |row| row[:alert_id] == id }

    def listed!(id)
      inbox.find { |row| row[:alert_id] == id } ||
        raise(RefusedError, "#{id} is not in your notifications (BEHOXQ ALRLIST does not list it)")
    end

    # "NAME    (HRN)" (BEHOXQ.m:36, :39): the HRN only when the patient has
    # one at the user's facility.
    NAME_HRN = /\A(?<name>.*?)\s{4}\((?<hrn>[^)]*)\)\z/
    private_constant :NAME_HRN

    def decorate(row)
      name = row[:patient].to_s.strip
      hrn = nil
      if (match = NAME_HRN.match(name))
        name = match[:name].strip
        hrn = match[:hrn]
      end
      dfn = row[:patient_dfn].to_i
      {
        alert_id: row[:alert_id],
        patient_dfn: dfn.positive? ? dfn : nil,
        patient_name: name.empty? ? nil : name,
        hrn: hrn,
        location: blank_to_nil(row[:location]),
        message: row[:message],
        delivered_at: row[:delivered_at],
        sender: blank_to_nil(row[:sender]),
        priority: PRIORITY[row[:priority]],
        info_only: row[:info_only] == true,
        removable: row[:removable] == true,
        type: row[:type]
      }
    end

    def blank_to_nil(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
