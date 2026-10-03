# frozen_string_literal: true

# rpc:live's record of every wire call the API makes, with the reply's CIA flag (rpms-rpc#270).
# Prepended to RpmsRpc::CiaClient by live_runner.rb.
#
# Verdicts come from the WIRE, not from the API's return value. CiaClient#call_rpc flattens a
# broker error reply ($C(1)+text) to printable text instead of raising (#195), so an API method
# can return a non-nil "result" that is really an error. Each raw reply is classified by its
# CIA flag byte: \x00 -> data, \x01 -> broker error, no flag -> no data (SNDEOD).
#
# A transport error (a timeout, a dropped connection) is logged on BOTH call paths and re-raised.
# The global-array path (AMHG, AGG, BSDX) did not log one before #335, so a read that timed out
# left no evidence at all, and a programmer run could not show it was a permission gap.
module RpcCoverage
  module WireTrace
    TRANSPORT_ERRORS = [ IOError, SystemCallError ].freeze

    def self.log = (@log ||= [])

    def self.classify(raw)
      rest = raw.to_s.b.byteslice(1..) || "".b
      case rest.getbyte(0)
      when 0x00 then [ :data, (rest.bytesize - 1) ]
      when 0x01 then [ :error, rest.byteslice(1..).to_s.gsub(/[^\x20-\x7e]/, " ").strip[0, 160] ]
      else [ :no_data, 0 ]
      end
    end

    def self.transport_error?(error)
      error.is_a?(RpmsRpc::Client::ConnectionError) || TRANSPORT_ERRORS.any? { |k| error.is_a?(k) }
    end

    def self.record(rpc_name, raw)
      kind, detail = classify(raw)
      log << { rpc: rpc_name, reply: kind, detail: detail }
      raw
    end

    def self.record_transport_error(rpc_name, error)
      log << { rpc: rpc_name, reply: :transport_error, detail: "#{error.class}: #{error.message}"[0, 160] }
    end

    def call_rpc_raw(rpc_name, *params)
      WireTrace.record(rpc_name, super)
    rescue StandardError => e
      WireTrace.record_transport_error(rpc_name, e) if WireTrace.transport_error?(e)
      raise
    end

    def call_rpc_global_array(rpc_name, *params)
      WireTrace.record(rpc_name, super)
    rescue StandardError => e
      WireTrace.record_transport_error(rpc_name, e) if WireTrace.transport_error?(e)
      raise
    end
  end
end
