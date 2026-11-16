# frozen_string_literal: true

require "date"
require_relative "client"
require_relative "fileman_date_parser"
require_relative "api/orwu"

module RpmsRpc
  # The RPMS server's clock: "now" and "today" as the site counts them, read
  # with ORWU DT "NOW" (RpmsRpc::Orwu, FileMan's %DT on the server). RPMS
  # keeps the site's time and FileMan judges a date against its own DT, so a
  # write path that defaults a date to today, stamps one, or refuses a date
  # "in the future" asks the server, not this process. This process's clock is
  # not the site's: an app host runs in UTC, which is already tomorrow during
  # a US site's evening (rpms-rpc#741).
  #
  # now is a wall-clock Time built as every FileMan time is
  # (FilemanDateParser.parse_datetime: Time.new in this process's zone), so
  # its fields are the server's date and time. today is its Date.
  #
  # One ORWU DT call per read; a write path reads once and passes the value
  # on. When ORWU DT gives no FileMan date/time (an empty reply or "-1"), a
  # Client::RpcError is raised: a write is never dated by a guess. A broker
  # error from ORWU DT is not rescued.
  module ServerClock
    extend self

    def now(client: RpmsRpc.client)
      raw = Orwu.fileman_datetime("NOW", client: client)
      FilemanDateParser.parse_datetime(raw) ||
        raise(Client::RpcError, "ORWU DT \"NOW\" gave no FileMan date/time (#{raw.inspect}): the server's clock is unknown")
    end

    def today(client: RpmsRpc.client) = now(client: client).to_date
  end
end
