# frozen_string_literal: true

# Utilities for parsing RPMS RPC responses.
#
# RPMS returns data in various formats with inconsistent column naming.
# This module provides helpers for robust response parsing.
#
# Patterns handled:
# - Column name variations (DFN, dfn, PatientDfn, PatientDFN)
# - Caret-delimited piece data ("1^Success message")
# - Pipe-delimited parameters (AMH module: "begin|end|dfn")
# - Success/failure detection ("-1^Error" vs "1^OK")
module RpmsRpc
  class ResponseParser
    # Result of an RPC operation that may succeed or fail.
    RpcResult = Struct.new(:success, :message, :id, keyword_init: true) do
      def success?
        success
      end

      def failure?
        !success
      end
    end

    # Pick first non-empty value from hash using multiple key variations.
    # RPMS returns inconsistent column casing across sites/versions.
    def self.pick_string(row, *keys)
      return "" if row.nil?

      keys.each do |key|
        found_key = row.keys.find { |k| k.to_s.casecmp?(key.to_s) }
        next unless found_key

        value = row[found_key]
        return value.to_s unless value.nil? || value.to_s.empty?
      end
      ""
    end

    # Get value from hash with multiple key variations (raw value, not string).
    def self.pick_value(row, *keys)
      return nil if row.nil?

      keys.each do |key|
        found_key = row.keys.find { |k| k.to_s.casecmp?(key.to_s) }
        next unless found_key

        value = row[found_key]
        return value unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
      nil
    end

    # Parse caret-delimited piece string (1-based, FileMan convention).
    def self.piece(str, piece_num)
      return "" if str.nil? || str.empty?
      return "" if piece_num < 1

      pieces = str.split("^", -1) # -1 preserves trailing empty strings
      pieces[piece_num - 1] || ""
    end

    # Parse pipe-delimited parameter string (used by AMH module).
    def self.pipe_piece(str, piece_num)
      return "" if str.nil? || str.empty?
      return "" if piece_num < 1

      pieces = str.split("|", -1)
      pieces[piece_num - 1] || ""
    end

    # Build pipe-delimited parameter string for AMH-style RPCs.
    def self.pipe_param(*args)
      args.map(&:to_s).join("|")
    end

    # Parse RPC result for success/failure.
    def self.parse_result(response, empty_is_success: true)
      if response.nil? || (response.respond_to?(:empty?) && response.empty?)
        return RpcResult.new(
          success: empty_is_success,
          message: empty_is_success ? nil : "No response from server"
        )
      end

      if response.is_a?(Array)
        return parse_result(response.first, empty_is_success: empty_is_success) if response.any?

        return RpcResult.new(success: empty_is_success)
      end

      return parse_row_result(response) if response.is_a?(Hash)

      parse_string_result(response.to_s)
    end

    def self.parse_row_result(row)
      error_msg = pick_string(row, "ERROR", "Error", "ERRORMSG", "ErrorMessage", "ErrorMsg")
      return RpcResult.new(success: false, message: error_msg) unless error_msg.empty?

      status = pick_string(row, "STATUS", "Status", "RESULT", "Result")
      unless status.empty?
        status_lower = status.downcase
        if status_lower == "-1" || status_lower.include?("error") || status_lower.include?("fail")
          msg = pick_string(row, "MESSAGE", "Message", "MSG", "Msg", "DESCRIPTION", "Description")
          return RpcResult.new(success: false, message: msg.empty? ? status : msg)
        end
      end

      first_val = row.values.first.to_s
      return parse_string_result(first_val, row: row) if first_val.include?("^")

      message = pick_string(row, "MESSAGE", "Message", "MSG")
      unless message.empty?
        msg_lower = message.downcase
        if %w[error fail invalid denied].any? { |word| msg_lower.include?(word) }
          return RpcResult.new(success: false, message: message)
        end
      end

      id = pick_string(row, "ID", "Id", "IEN", "ien", "BMXIEN", "ApptID", "WaitListItemId")
      RpcResult.new(success: true, id: id.empty? ? nil : id)
    end

    def self.parse_string_result(str, row: nil)
      if str.include?("^")
        pieces = str.split("^")
        code = pieces[0].strip
        message = pieces[1..].join("^")

        if code == "-1" || code.casecmp?("error")
          return RpcResult.new(
            success: false,
            message: message.empty? ? "Operation failed" : message
          )
        end

        if %w[1 0 ok].any? { |ok| code.casecmp?(ok) }
          id = row ? pick_string(row, "ID", "Id", "IEN", "ien", "BMXIEN") : nil
          id = nil if id.nil? || id.empty?
          return RpcResult.new(
            success: true,
            message: message.empty? ? nil : message,
            id: id
          )
        end
      end

      RpcResult.new(success: true)
    end

    # Convert array of caret-delimited strings to array of hashes.
    def self.rows_from_delimited(lines, header_row: 0, delimiter: "^")
      return [] if lines.nil? || lines.empty?
      return [] if lines.length <= header_row

      headers = lines[header_row].split(delimiter).map(&:strip)
      data_lines = lines[(header_row + 1)..]

      data_lines.map do |line|
        values = line.split(delimiter, -1)
        headers.each_with_index.each_with_object({}) do |(header, idx), row|
          row[header] = values[idx]&.strip || ""
        end
      end
    end

    # Common column name variations for reference.
    COLUMN_VARIANTS = {
      id: %w[ID Id IEN ien BMXIEN],
      patient_dfn: %w[DFN dfn PatientDfn PatientDFN Patient_DFN],
      patient_name: %w[PatientName Patient_Name Patient patient Name name],
      clinic: %w[Clinic clinic ClinicName Clinic_Name],
      clinic_id: %w[ClinicId Clinic_ID ClinicIEN],
      date: %w[Date date DateTime AppointmentDateTime ApptDate DateAdded AddedDate],
      status: %w[Status status STATUS],
      error: %w[ERROR Error ERRORMSG ErrorMessage ErrorMsg],
      message: %w[MESSAGE Message MSG Msg DESCRIPTION Description],
      hrn: %w[Hrn HRN HealthRecordNumber Health_Record_Number],
      provider: %w[Provider provider ProviderName Provider_Name],
      priority: %w[Priority priority]
    }.freeze
  end
end
