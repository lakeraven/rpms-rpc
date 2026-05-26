# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for state IIS immunization exchange.
  # Underlying RPCs (BYIMRT family): VXU, VXQ, RSP, STATUS.
  module ImmunizationExchange
    extend self

    DEFAULT_STATUS = "completed"

    def send_immunizations(dfn)
      return invalid_patient_response unless positive_integer?(dfn)

      response = RpmsRpc.client.call_rpc(DataMapper.immunization_exchange_vxu.rpc_name, dfn.to_s)
      parse_status_line(DataMapper.immunization_exchange_vxu, response, default_error: "VXU send failed")
    end

    def submit_query(dfn)
      return invalid_patient_response unless positive_integer?(dfn)

      response = RpmsRpc.client.call_rpc(DataMapper.immunization_exchange_vxq.rpc_name, dfn.to_s)
      parse_status_line(DataMapper.immunization_exchange_vxq, response, default_error: "VXQ query failed")
    end

    def for_patient(dfn)
      return [] unless positive_integer?(dfn)

      retrieve_response(dfn)
    end

    def retrieve_response(dfn = nil)
      return [] if !dfn.nil? && !positive_integer?(dfn)

      params = dfn.nil? ? [] : [ dfn.to_s ]
      rows = DataMapper.immunization_exchange_rsp.fetch_many(*params)
      Array(rows).map { |row| apply_defaults(row) }
    end

    def process_responses
      response = RpmsRpc.client.call_rpc(DataMapper.immunization_exchange_rsp.rpc_name)
      return { success: true, count: 0 } if empty_response?(response)

      parsed = parse_status_line(DataMapper.immunization_exchange_process_result, response,
        default_error: "Response processing failed")
      return parsed unless parsed[:success]

      { success: true, count: parsed[:message].to_s.scan(/\d+/).first.to_i }
    end

    def check_status
      response = RpmsRpc.client.call_rpc(DataMapper.immunization_exchange_status.rpc_name)
      status = parse_status_line(DataMapper.immunization_exchange_status, response,
        default_error: "IIS status check failed")

      status[:success] ? { available: true } : { available: false, error: status[:message] }
    rescue StandardError => e
      { available: false, error: e.message.to_s }
    end

    private

    def parse_status_line(mapping, response, default_error:)
      return { success: false, message: "Empty response from RPMS" } if empty_response?(response)

      row = mapping.parse_one(response)
      status_code = row[:status_code].to_i
      message = row[:message]

      if status_code.positive?
        { success: true, message: message }
      else
        { success: false, message: blank?(message) ? default_error : message }
      end
    end

    def apply_defaults(row)
      row.merge(status: blank?(row[:status]) ? DEFAULT_STATUS : row[:status])
    end

    def invalid_patient_response
      { success: false, message: "Invalid patient DFN" }
    end

    def empty_response?(response)
      response.nil? || (response.respond_to?(:empty?) && response.empty?)
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end

    def positive_integer?(val)
      !blank?(val) && val.to_s.match?(/\A\d+\z/) && val.to_i.positive?
    end
  end
end
