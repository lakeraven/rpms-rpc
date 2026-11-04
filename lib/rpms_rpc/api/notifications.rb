# frozen_string_literal: true

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
  # No write is modelled. Removing or forwarding an alert (ORB DELETE ALERT,
  # BEHOXQ FORWARD) is a write the gem does not yet send.
  module Notifications
    extend self

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

    private

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
