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
      return nil unless time_part.match?(/\A\d{2,4}\z/)

      time_part = time_part.ljust(4, "0") if time_part.length == 2

      date = parse_date(parts[0])
      return nil if date.nil?

      hh = time_part[0..1].to_i
      mm = time_part[2..3].to_i

      return nil if hh > 23 || mm > 59

      Time.new(date.year, date.month, date.day, hh, mm, 0)
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

    # Format Ruby Time to FileMan datetime string (YYYMMDD.HHMM).
    def self.format_datetime(datetime)
      return nil if datetime.nil?

      yyy = datetime.year - 1700
      mm = datetime.month.to_s.rjust(2, "0")
      dd = datetime.day.to_s.rjust(2, "0")
      hh = datetime.hour.to_s.rjust(2, "0")
      min = datetime.min.to_s.rjust(2, "0")

      "#{yyy}#{mm}#{dd}.#{hh}#{min}"
    end
  end
end
