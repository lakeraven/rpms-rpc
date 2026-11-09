# frozen_string_literal: true

require "yaml"
require "digest"
require "rpms_rpc/cia_client"
require "rpms_rpc/bmx_client"

# Replies captured from a throwaway container of a pinned build, replayed
# through the real CiaClient reply parser (ADR 0009: a test reads what RPMS
# sent, not a reply we wrote). Evidence is in test/fixtures/captured_replies/,
# one YAML file per RPC, written by tools/capture_replies.rb; each capture's
# raw_return is sealed by its sha256, and load fails on a broken seal.
module CapturedReplies
  DIR = File.expand_path("../fixtures/captured_replies", __dir__)

  module_function

  # The parsed capture file for an RPC slug, e.g. "orwu-validsig".
  def file(slug)
    doc = YAML.safe_load_file(File.join(DIR, "#{slug}.yml"))
    doc.fetch("captures").each do |capture|
      raw = capture.fetch("raw_return").b
      next if Digest::SHA256.hexdigest(raw) == capture.fetch("sha256")

      raise "#{slug}.yml capture #{capture['name']}: raw_return does not match its sha256; re-capture, do not edit"
    end
    doc
  end

  # One capture's raw bytes, exactly as CiaClient#call_rpc_raw returned them.
  def raw(slug, name)
    capture = file(slug).fetch("captures").find { |c| c["name"] == name }
    raise KeyError, "#{slug}.yml has no capture named #{name.inspect}" unless capture

    capture.fetch("raw_return").b
  end

  # The captures of one recorded flow ("<flow>/<n>", tools/capture_replies.rb
  # `flows`), in the order the gem made the calls.
  def flow(slug, name)
    captures = file(slug).fetch("captures").select { |c| c["name"].start_with?("#{name}/") }
    raise KeyError, "#{slug}.yml has no flow named #{name.inspect}" if captures.empty?

    captures.sort_by { |c| c["name"].split("/").last.to_i }
  end

  # A ReplayCiaClient script that answers a flow's calls with its replies.
  def flow_script(slug, name)
    flow(slug, name).group_by { |c| c.fetch("rpc") }.transform_values { |cs| cs.map { |c| c.fetch("raw_return").b } }
  end

  # The [rpc, params] the gem sent in a recorded flow.
  def flow_calls(slug, name) = flow(slug, name).map { |c| [ c.fetch("rpc"), c.fetch("inputs") ] }

  # A CiaClient whose wire is a script of raw replies: each call_rpc_raw
  # answers the next scripted reply for that RPC, and every call is recorded.
  # call_rpc, call_rpc_lines and the reply grammar are CiaClient's own, so a
  # captured reply is read exactly as a live one is. An RPC with no scripted
  # reply left fails the test rather than inventing one. The session starts
  # bound to CIAV VUECENTRIC, as a CIA sign-on binds it.
  class ReplayCiaClient < RpmsRpc::CiaClient
    attr_reader :calls

    def initialize(script)
      super(host: "127.0.0.1", port: 9100)
      @script = script.transform_values { |replies| Array(replies).dup }
      @calls = []
      @connected = true
      @authenticated = true
      @current_context = SIGNON_CONTEXT
    end

    def connected? = true
    def authenticated? = true

    def call_rpc_raw(rpc_name, *params) = next_reply(rpc_name, params)

    # A GLOBAL ARRAY reply (the AGG registration RPCs) runs through
    # CiaClient's own call_rpc_global_array, so its refusal check and decoding
    # are the real ones; only the wire exchange is the script. Capture it with
    # global_array: true, which reads to the same $C(31) end sentinel.
    def call_rpc_global_array(rpc_name, *params)
      @scripted = next_reply(rpc_name, params)
      super
    ensure
      @scripted = nil
    end

    # A GLOBAL ARRAY read: the next scripted reply for that RPC, read as
    # CiaClient#call_rpc_global_array reads the frame it receives.
    def call_rpc_global_array(rpc_name, *params) = global_array_reply(call_rpc_raw(rpc_name, *params))

    def create_context(option_name = SIGNON_CONTEXT)
      @calls << { rpc: :create_context, params: [ option_name ] }
      @current_context = option_name
      true
    end

    def rpcs_called = @calls.map { |c| c[:rpc] }

    # The signed-on user the capture was taken as, for code that reads
    # Client#duz (a filer row naming who entered it).
    def signed_on_as(duz)
      @duz = duz.to_s
      self
    end

    private

    def next_reply(rpc_name, params)
      @calls << { rpc: rpc_name, params: params }
      replies = @script[rpc_name]
      raise "ReplayCiaClient: no scripted reply left for #{rpc_name}" if replies.nil? || replies.empty?

      replies.shift.b
    end

    # The wire, for a call_rpc_global_array in flight: its scripted reply.
    def exchange(*, **)
      @scripted || raise("ReplayCiaClient: a wire exchange outside a scripted call")
    end
  end

  # A BmxClient whose socket answers a script of whole BMX reply frames
  # (security packet, application packet, data, EOT), as a BMX flow recorded
  # them (tools/capture_replies.rb, broker: :bmx). The frame each call sends is
  # built by BmxClient itself and dropped; the reply is read by BmxClient's own
  # read_response, so a refusal in the security packet raises as it does live.
  # The client starts connected and not signed on, as a BMX session does.
  class ReplayBmxClient < RpmsRpc::BmxClient
    attr_reader :calls

    # Answers recv from the next scripted frame of the RPC in flight.
    class ScriptedSocket
      def initialize(client) = @client = client
      def write(_bytes) = nil
      def flush = nil
      def closed? = false
      def close = nil
      def recv(_max) = @client.send(:next_frame)
    end

    def initialize(script)
      super(host: "127.0.0.1", port: 9101)
      @script = script.transform_values { |replies| Array(replies).dup }
      @calls = []
      @socket = ScriptedSocket.new(self)
      @connected = true
    end

    def build_bmx_message(rpc_name, params = [])
      @calls << { rpc: rpc_name, params: params }
      @in_flight = rpc_name
      super
    end

    def rpcs_called = @calls.map { |c| c[:rpc] }

    private

    def next_frame
      replies = @script[@in_flight]
      raise "ReplayBmxClient: no scripted reply left for #{@in_flight}" if replies.nil? || replies.empty?

      replies.shift.b
    end
  end
end
