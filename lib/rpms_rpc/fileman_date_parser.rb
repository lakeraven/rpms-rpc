# frozen_string_literal: true

require "date"

# Converts between Ruby Date/Time and VistA FileMan date format.
#
# FileMan format: YYYMMDD.HHMM where YYY = year - 1700
#
# Examples:
#   2800101 = 1980-01-01     (280 + 1700 = 1980)
#   3250101.0915 = 2025-01-01 09:15
module RpmsRpc
  class FilemanDateParser
    # Parse FileMan date string to Ruby Date.
    def self.parse_date(fileman_date)
      return nil if fileman_date.nil? || fileman_date.to_s.empty?

      fileman_str = fileman_date.to_s.split(".").first
      return nil unless fileman_str.match?(/\A\d{7}\z/)

      yyy = fileman_str[0..2].to_i
      mm = fileman_str[3..4].to_i
      dd = fileman_str[5..6].to_i

      year = yyy + 1700

      return nil if mm < 1 || mm > 12
      return nil if dd < 1 || dd > 31

      Date.new(year, mm, dd)
    rescue ArgumentError
      nil
    end

    # Parse FileMan datetime string to Ruby Time.
    def self.parse_datetime(fileman_datetime)
      return nil if fileman_datetime.nil? || fileman_datetime.to_s.empty?

      parts = fileman_datetime.to_s.split(".")
      return nil unless parts.length == 2
      return nil unless parts[0].match?(/\A\d{7}\z/)

      time_part = parts[1]
      # Accept HH, HHMM, or HHMMSS — keeps round-trip symmetry with
      # format_datetime(..., seconds: true).
      return nil unless time_part.match?(/\A\d{2}(\d{2}(\d{2})?)?\z/)

      time_part = time_part.ljust(4, "0") if time_part.length == 2
      time_part = time_part.ljust(6, "0") if time_part.length == 4

      date = parse_date(parts[0])
      return nil if date.nil?

      hh = time_part[0..1].to_i
      mm = time_part[2..3].to_i
      ss = time_part[4..5].to_i

      return nil if hh > 23 || mm > 59 || ss > 59

      Time.new(date.year, date.month, date.day, hh, mm, ss)
    rescue ArgumentError
      nil
    end

    # Format Ruby Date to FileMan date string (YYYMMDD).
    def self.format_date(date)
      return nil if date.nil?

      yyy = date.year - 1700
      mm = date.month.to_s.rjust(2, "0")
      dd = date.day.to_s.rjust(2, "0")

      "#{yyy}#{mm}#{dd}"
    end

    # -- EXTERNAL (DD^%DT) format ---------------------------------------------
    #
    # Some recordset RPCs emit dates already run through FileMan's external
    # writer DD^%DT — "SEP 04, 2026", optionally "@HH:MM[:SS]" (DIDT.m DD tag);
    # e.g. SEARCH^BSDX24 (BSDX24.m:116-117) and APBLKALL^BSDX05, which also
    # translates the "@" to a space (BSDX05.m:100-101). Both separators are
    # accepted, as is a missing space after the comma.

    EXTERNAL_MONTHS = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC].freeze
    EXTERNAL_FORMAT =
      /\A([A-Z]{3})\s+(\d{1,2}),\s*(\d{4})(?:[@\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?\z/i

    # Parse an external-format date ("SEP 04, 2026[@09:00]") to a Date.
    # Any time portion is ignored. Returns nil for anything unparseable.
    def self.parse_external_date(value)
      parts = match_external(value)
      parts && Date.new(parts[:year], parts[:month], parts[:day])
    rescue ArgumentError
      nil
    end

    # Parse an external-format datetime ("SEP 04, 2026 09:00" or "@09:00[:SS]")
    # to a Time. A missing time portion reads as midnight. Returns nil for
    # anything unparseable.
    def self.parse_external_datetime(value)
      parts = match_external(value)
      return nil if parts.nil?
      return nil if parts[:hour] > 23 || parts[:min] > 59 || parts[:sec] > 59

      Time.new(parts[:year], parts[:month], parts[:day],
               parts[:hour], parts[:min], parts[:sec])
    rescue ArgumentError
      nil
    end

    # Format a Date/Time as an external-format date ("SEP 04, 2026").
    def self.format_external_date(date)
      return nil if date.nil?

      date.strftime("%b %d, %Y").upcase
    end

    # Format a Time as an external-format datetime in the space-separated form
    # BSDX05 puts on the wire ("SEP 04, 2026 09:00"; seconds when nonzero).
    def self.format_external_datetime(datetime)
      return nil if datetime.nil?

      time = format("%02d:%02d", datetime.hour, datetime.min)
      time += format(":%02d", datetime.sec) if datetime.sec.positive?
      "#{format_external_date(datetime)} #{time}"
    end

    def self.match_external(value)
      md = EXTERNAL_FORMAT.match(value.to_s.strip)
      return nil if md.nil?

      month = EXTERNAL_MONTHS.index(md[1].upcase)
      return nil if month.nil?

      { year: md[3].to_i, month: month + 1, day: md[2].to_i,
        hour: md[4].to_i, min: md[5].to_i, sec: md[6].to_i }
    end
    private_class_method :match_external

    # Format an outgoing RPC date/time parameter. Time and DateTime carry a
    # time of day, so they must be matched BEFORE Date — DateTime < Date in
    # Ruby, and a bare `when Date` branch silently dropped DateTime times
    # (date-only bookings). Seconds are included only when nonzero, matching
    # FileMan's trailing-zero-trimmed storage so values parsed from the wire
    # round-trip exactly. Anything else (preformatted strings, nil) passes
    # through as a string.
    def self.to_fileman(value)
      case value
      when Time, DateTime then format_datetime(value, seconds: value.sec.positive?)
      when Date then format_date(value)
      else value.to_s
      end
    end

    # Format Ruby Time to FileMan datetime string. Default precision is
    # minutes (YYYMMDD.HHMM); pass `seconds: true` for YYYMMDD.HHMMSS
    # (the precision BEHOVM SAVE accepts in VIT+ rows).
    def self.format_datetime(datetime, seconds: false)
      return nil if datetime.nil?

      yyy = datetime.year - 1700
      mm = datetime.month.to_s.rjust(2, "0")
      dd = datetime.day.to_s.rjust(2, "0")
      hh = datetime.hour.to_s.rjust(2, "0")
      min = datetime.min.to_s.rjust(2, "0")
      base = "#{yyy}#{mm}#{dd}.#{hh}#{min}"
      return base unless seconds

      sec = datetime.sec.to_s.rjust(2, "0")
      "#{base}#{sec}"
    end
  end
end
