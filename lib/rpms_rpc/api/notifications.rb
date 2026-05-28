# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the clinician alert inbox. Fires at login and on
  # patient open.
  # Underlying RPCs: BQI GET COMM ALERTS SPLASH, BQI MARK ALERT READ.
  module Notifications
    extend self

    # `unread: nil` returns everything; `unread: true` returns only items
    # without a read_at timestamp; `unread: false` returns only items that
    # have been read.
    def inbox(user_duz, unread: nil)
      return [] if invalid_id?(user_duz)

      rows = Array(DataMapper.notifications_inbox.fetch_many(user_duz.to_s))
      return rows if unread.nil?

      rows.select { |row| row[:read_at].nil? == unread }
    end

    def mark_read(notification_ien, user_duz)
      return failure if invalid_id?(notification_ien) || invalid_id?(user_duz)

      raw = DataMapper.notification_mark_read.fetch_scalar(notification_ien.to_s, user_duz.to_s)
      {
        success: raw.to_s == "0" || raw.to_s.match?(/\A\d+\z/),
        raw: raw
      }
    end

    private

    def failure
      { success: false, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
