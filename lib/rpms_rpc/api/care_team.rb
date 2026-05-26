# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for FHIR CareTeam data.
  # Underlying RPCs (ORQQCT family): LIST, GET.
  #
  # Each team: { ien:, team_name:, status:, category:, start_date:,
  #              end_date:, participants:, reason_code:, reason_display:,
  #              organization:, patient_dfn: (find only) }
  #
  # Participants are parsed from the sub-encoded RPMS string
  #   DUZ~NAME~ROLE~START~END;DUZ~NAME~ROLE~START~END
  # into [{ duz:, name:, role:, start_date:, end_date: }, ...].
  module CareTeam
    extend self

    DEFAULT_STATUS = "active"

    def for_patient(dfn)
      return [] if blank?(dfn) || dfn.to_i <= 0

      raw = DataMapper.care_team_list.fetch_many(dfn.to_s)
      Array(raw).map { |row| decorate(row) }
    end

    def find(ien)
      return nil if blank?(ien) || ien.to_i <= 0

      parsed = DataMapper.care_team_detail.fetch_one(ien.to_s, extras: { ien: ien })
      return nil if parsed.nil?

      decorate(parsed)
    end

    private

    def decorate(row)
      row.merge(
        status:       blank?(row[:status]) ? DEFAULT_STATUS : row[:status],
        participants: parse_participants(row[:participants_raw])
      ).tap { |h| h.delete(:participants_raw) }
    end

    def parse_participants(raw)
      return [] if blank?(raw)

      raw.to_s.split(";").filter_map do |chunk|
        parts = chunk.split("~", -1)
        next if parts.empty? || parts.first.to_s.empty?

        {
          duz:        presence(parts[0]),
          name:       presence(parts[1]),
          role:       presence(parts[2]),
          start_date: presence(parts[3]),
          end_date:   presence(parts[4])
        }
      end
    end

    def presence(val)
      return nil if val.nil?

      s = val.to_s
      s.empty? ? nil : s
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
