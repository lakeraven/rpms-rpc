# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the clinician alert inbox. Fires at login and on
  # patient open.
  # Underlying RPC: BQI GET COMM ALERTS SPLASH. (`mark_read` once sent
  # BQI MARK ALERT READ, a name no built 9.0 image registers; it was
  # removed, #207. The registered acknowledgement verbs are BQI SET COMM
  # ALERTS * and BQI UPDATE NOTIFICATION STATUS — model one from its
  # routine before adding a write back, ADR 0003.)
  module Notifications
    extend self

    # `unread: nil` returns everything; `unread: true` returns only items
    # without a read_at timestamp; `unread: false` returns only items that
    # have been read. Any other value raises ArgumentError so a truthy
    # surprise ("false" string, 0, etc.) can't silently flip the filter.
    def inbox(user_duz, unread: nil)
      return [] if invalid_id?(user_duz)

      unless unread.nil? || unread == true || unread == false
        raise ArgumentError, "unread must be nil, true, or false (got #{unread.inspect})"
      end

      rows = Array(DataMapper.notifications_inbox.fetch_many(user_duz.to_s))
      return rows if unread.nil?

      rows.select { |row| row[:read_at].nil? == unread }
    end

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
