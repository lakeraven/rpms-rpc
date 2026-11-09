# frozen_string_literal: true

require "yaml"
require "digest"
require "rpms_rpc/cia_client"

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

  # A CiaClient whose wire is a script of raw replies: each call_rpc_raw
  # answers the next scripted reply for that RPC, and every call is recorded.
  # call_rpc, call_rpc_lines and the reply grammar are CiaClient's own, so a
  # captured reply is read exactly as a live one is. An RPC with no scripted
  # reply left fails the test rather than inventing one.
  class ReplayCiaClient < RpmsRpc::CiaClient
    attr_reader :calls

    def initialize(script)
      super(host: "127.0.0.1", port: 9100)
      @script = script.transform_values { |replies| Array(replies).dup }
      @calls = []
      @connected = true
      @authenticated = true
    end

    def connected? = true
    def authenticated? = true

    def call_rpc_raw(rpc_name, *params)
      @calls << { rpc: rpc_name, params: params }
      replies = @script[rpc_name]
      raise "ReplayCiaClient: no scripted reply left for #{rpc_name}" if replies.nil? || replies.empty?

      replies.shift.b
    end

    def create_context(option_name = SIGNON_CONTEXT)
      @calls << { rpc: :create_context, params: [ option_name ] }
      @current_context = option_name
      true
    end

    def rpcs_called = @calls.map { |c| c[:rpc] }
  end
end
