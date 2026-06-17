# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for FHIR Communication-style MailMan messages and XQAL alerts.
  # Underlying RPCs (XM/XQAL family): message reads, message writes, inbox,
  # threads, alerts, and alert write acknowledgements.
  module Communication
    extend self

    DEFAULT_MESSAGE_STATUS = "NEW"
    DEFAULT_PRIORITY = "routine"
    DEFAULT_ALERT_STATUS = "NEW"

    def find(ien)
      return nil if invalid_id?(ien)

      message = DataMapper.mailman_message.fetch_one(ien.to_s)
      return nil if message.nil?

      apply_message_defaults(message)
    end

    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.mailman_messages_for_patient.fetch_many(dfn.to_s)).map do |message|
        apply_message_defaults(message)
      end
    end

    def search(criteria = {})
      messages = criteria[:patient_dfn] ? for_patient(criteria[:patient_dfn]) : []

      %i[status priority category].each do |field|
        messages = messages.select { |m| m[field] == criteria[field] } if criteria[field]
      end

      messages
    end

    def send_message(params = {})
      validate_send_params!(params)

      parsed = DataMapper.mailman_send.fetch_one(build_send_payload(params))

      {
        success: parsed && parsed[:success] == true,
        message_id: parsed&.fetch(:message_ien, nil),
        error: parsed&.fetch(:error, nil)
      }
    end

    def reply_to_message(parent_ien, params = {})
      return { success: false, error: "Parent message IEN required" } if invalid_id?(parent_ien)
      return { success: false, error: "Reply body required" } if blank?(params[:body])

      parent = find(parent_ien)
      return { success: false, error: "Parent message not found" } unless parent

      parsed = DataMapper.mailman_reply.fetch_one(build_reply_payload(parent_ien, params))

      {
        success: parsed && parsed[:success] == true,
        message_id: parsed&.fetch(:message_ien, nil),
        thread_id: parsed&.fetch(:thread_id, nil) || parent[:thread_id] || parent_ien.to_s,
        parent_id: parent_ien.to_i,
        error: parsed&.fetch(:error, nil)
      }
    end

    def get_thread(thread_id)
      return [] if blank?(thread_id)

      messages = Array(DataMapper.mailman_thread.fetch_many(thread_id.to_s)).map do |message|
        apply_message_defaults(message)
      end
      messages.sort_by { |message| message[:sent_at] || Time.at(0) }
    end

    def for_user(duz, basket: "IN")
      return [] if invalid_id?(duz)

      basket = "IN" if blank?(basket)
      key = "#{duz}^#{basket}"
      Array(DataMapper.mailman_inbox.fetch_many(key)).map { |message| apply_message_defaults(message) }
    end

    def get_alerts(duz)
      return [] if invalid_id?(duz)
      return [] unless RpmsRpc.client.supports?(:xqal_alert_actions)

      Array(DataMapper.xqal_alert.fetch_many(duz.to_s)).map { |alert| apply_alert_defaults(alert) }
    end

    def alert_count(duz)
      get_alerts(duz).size
    end

    def mark_alert_read(alert_ien, duz)
      return { success: false, error: "Alert IEN required" } if invalid_id?(alert_ien)
      return { success: false, error: "User DUZ required" } if invalid_id?(duz)
      return { success: false, error: "XQAL alert actions not available on this server" } unless RpmsRpc.client.supports?(:xqal_alert_actions)

      parsed = DataMapper.xqal_mark_read.fetch_one("#{alert_ien}^#{duz}")

      {
        success: parsed && parsed[:success] == true,
        error: parsed&.fetch(:error, nil)
      }
    end

    def forward_alert(alert_ien, from_duz:, to_duz:, comment: nil)
      return { success: false, error: "Alert IEN required" } if invalid_id?(alert_ien)
      return { success: false, error: "From DUZ required" } if invalid_id?(from_duz)
      return { success: false, error: "To DUZ required" } if invalid_id?(to_duz)
      return { success: false, error: "XQAL alert actions not available on this server" } unless RpmsRpc.client.supports?(:xqal_alert_actions)

      parsed = DataMapper.xqal_forward.fetch_one(
        [ alert_ien, from_duz, to_duz, escape_multiline(comment) ].join("^")
      )

      {
        success: parsed && parsed[:success] == true,
        new_alert_ien: parsed&.fetch(:new_alert_ien, nil),
        error: parsed&.fetch(:error, nil)
      }
    end

    private

    def build_send_payload(params)
      [
        params[:subject],
        escape_multiline(params[:body]),
        Array(params[:recipients]).join(","),
        params[:patient_dfn],
        params[:priority] || DEFAULT_PRIORITY,
        params[:category]
      ].join("^")
    end

    def build_reply_payload(parent_ien, params)
      [
        parent_ien,
        escape_multiline(params[:body]),
        params[:reply_all] ? "1" : "0"
      ].join("^")
    end

    def apply_message_defaults(message)
      message.merge(
        status: blank?(message[:status]) ? DEFAULT_MESSAGE_STATUS : message[:status],
        priority: blank?(message[:priority]) ? DEFAULT_PRIORITY : message[:priority]
      )
    end

    def apply_alert_defaults(alert)
      alert.merge(status: blank?(alert[:status]) ? DEFAULT_ALERT_STATUS : alert[:status])
    end

    def validate_send_params!(params)
      raise ArgumentError, "Subject required" if blank?(params[:subject])
      raise ArgumentError, "Body required" if blank?(params[:body])

      recipients = Array(params[:recipients]).reject { |r| blank?(r) }.map { |r| r.to_s.strip }
      raise ArgumentError, "Recipients required" if recipients.empty?

      params[:recipients] = recipients
    end

    def escape_multiline(value)
      value.to_s.gsub(/\r?\n/, "\\n")
    end

    def invalid_id?(value)
      blank?(value) || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
