# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../fileman_date_parser"

module RpmsRpc
  # A patient's goals (PATIENT GOALS, #9000093), as VueCentric's Patient
  # Goals component lists them.
  # Underlying RPC: BEHOPGAP GETGOAL (GETGOAL^BEHOPGAP — BEHOPGAP.m:91).
  module PatientGoal
    extend self
    extend Shape::Declarable

    HEADER = /\A[1-9]\d*\^/

    # The patient's goals, by goal number.
    #
    #   for_patient(dfn) => [{ ien:, goal_number:, setting:, status:, status_name:,
    #                          created_on:, created_by:, last_modified:, facility:,
    #                          provider:, start_date:, follow_up_date:, types: [],
    #                          name:, reason:, reviews: [{ date:, note: }] }, ...]
    #
    # setting is GOAL SET or GOAL NOT SET; status the internal code (A, ME,
    # MA, S, D) and status_name its name; the dates are Dates and
    # last_modified a Time, read from FileMan values. GETGOAL means to skip a
    # deleted goal (BEHOPGAP.m:118) but compares the code joined to its name
    # ("D;DELETED/...") with "D", so the build lists deleted goals too; check
    # status. A -N^text reply raises Client::RpcError, and so does a reply
    # whose lines do not follow the layout above.
    def for_patient(dfn)
      return [] unless dfn.to_s.match?(/\A[1-9]\d*\z/)

      mapping = DataMapper.patient_goals
      client = RpmsRpc.client
      reply = mapping.in_context(client) { client.call_rpc(mapping.rpc_name, dfn.to_s) }
      lines = Array(reply.is_a?(String) ? reply.split(/\r\n|\r|\n/, -1) : reply).map(&:to_s)
      lines.pop while lines.last == ""
      raise Client::RpcError, RpmsRpc.sanitize_error("BEHOPGAP GETGOAL refused: #{lines.first}") if lines.first && DataMapper.error_row?(lines.first)

      goals(lines)
    end
    shape :for_patient, resource: "patient-goals", verb: "GET", path: "/patients/{dfn}/patient-goals"

    private

    def goals(lines)
      found = []
      until lines.empty?
        header = lines.shift
        raise Client::RpcError, "BEHOPGAP GETGOAL answered #{header.inspect} where a goal header belongs" unless header.match?(HEADER) && lines.size >= 3

        types, name, reason = lines.shift(3)
        reviews = []
        reviews << review(lines.shift) while lines.first&.start_with?("REVIEW^")
        found << goal(header.split("^", -1), types, name, reason, reviews)
      end
      found
    end

    def goal(pieces, types, name, reason, reviews)
      ien, setting, created, by, modified, facility, provider, start, follow_up, status, number = pieces
      code, status_name = status.to_s.split(";", 2)
      { ien: ien.to_i, goal_number: number.to_s.empty? ? nil : number.to_i, setting: presence(setting),
        status: presence(code), status_name: presence(status_name),
        created_on: FilemanDateParser.parse_date(created.to_s), created_by: presence(by),
        last_modified: FilemanDateParser.parse_datetime_or_date(modified.to_s), facility: presence(facility),
        provider: presence(provider), start_date: FilemanDateParser.parse_date(start.to_s),
        follow_up_date: FilemanDateParser.parse_date(follow_up.to_s),
        types: types.to_s.split("^").reject(&:empty?), name: presence(name), reason: presence(reason), reviews: reviews }
    end

    def review(line)
      _, date, note = line.split("^", 3)
      { date: FilemanDateParser.parse_date(date.to_s), note: presence(note) }
    end

    def presence(value)
      value.to_s.empty? ? nil : value
    end
  end
end
