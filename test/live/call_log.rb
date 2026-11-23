# frozen_string_literal: true

require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"

module LiveSpec
  # Every RPC a live spec sends, and what came back, so a live run can say which
  # calls each spec made as its role (rpms-rpc#818). The harness starts the log
  # after sign-on and the XUPROGMODE check, so only the spec's own calls are in
  # it, and ends it in teardown. A call is recorded once, at the outermost wire
  # method (call_rpc reads through call_rpc_raw), with its outcome:
  #   answered  the broker replied with data or with no data
  #   refused   the broker refused it for this user or context (RpcRefusedError)
  #   error     anything else: a broker error, a timeout, a dropped session
  # Sign-on over CIA is CIANBRPC AUTH, sent by CiaClient#authenticate itself.
  module CallLog
    OUTCOMES = %w[answered refused error].freeze

    class << self
      # The calls of the spec running now, or nil between specs.
      attr_reader :calls

      def start = (@calls = [])

      # The calls since start, and the log closed.
      def stop
        calls = @calls || []
        @calls = nil
        calls
      end

      # Runs the block as one call to RPC; records it when the log is open and
      # no outer call is recording already. CIA: a raw reply's flag byte is read.
      def around(rpc, cia: false)
        return yield if @calls.nil? || @depth.to_i.positive?

        @depth = 1
        begin
          value = yield
          record(rpc, cia && value.is_a?(String) && cia_error?(value) ? "error" : "answered")
          value
        rescue RpmsRpc::Client::RpcRefusedError, RpmsRpc::Client::ContextRefusedError => e
          record(rpc, "refused", e.message)
          raise
        rescue StandardError, NotImplementedError => e
          record(rpc, "error", "#{e.class.name.split('::').last}: #{e.message}")
          raise
        ensure
          @depth = 0
        end
      end

      def record(rpc, outcome, detail = nil)
        entry = { "rpc" => rpc.to_s, "outcome" => outcome }
        entry["detail"] = detail.to_s.gsub(/[^\x20-\x7e]/, " ").strip[0, 120] if detail
        @calls << entry
      end

      # A raw CIA reply is the sequence echo, then the flag byte: \x01 is a broker error.
      def cia_error?(raw) = raw.b.getbyte(1) == 0x01

      # Wraps the wire methods KLASS defines, and no others, so respond_to? stays as it was.
      def wrap(klass, sign_on: nil, cia: false)
        names = %i[call_rpc call_rpc_raw call_rpc_global_array].select { |m| klass.method_defined?(m) }
        wrapper = Module.new do
          names.each do |m|
            define_method(m) { |rpc_name, *params, &blk| CallLog.around(rpc_name, cia: cia) { super(rpc_name, *params, &blk) } }
          end
          define_method(:authenticate) { |*args, **kw, &blk| CallLog.around(sign_on) { super(*args, **kw, &blk) } } if sign_on
        end
        klass.prepend(wrapper)
      end
    end

    wrap(RpmsRpc::CiaClient, sign_on: "CIANBRPC AUTH", cia: true)
    wrap(RpmsRpc::XwbClient)
    wrap(RpmsRpc::BmxClient)
  end
end
