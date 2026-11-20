# frozen_string_literal: true

require_relative "../../captured_replies"

# Replays of the Behavioral Health save conversations recorded on the pinned
# build (tools/captured_replies/amhg-save-*.rb). Every reply is one the build
# sent. What no reply can carry, a lost wire or a frame too long to send, is
# raised at the wire by the client, around the recorded replies. rpms-rpc#622.
module AmhgReplay
  FILEMAN_CONTEXT = "CIAV VUECENTRIC"

  # A ReplayCiaClient that notes the option each RPC ran under, can lose the
  # wire on one RPC, and can refuse to bind one option.
  class Client < CapturedReplies::ReplayCiaClient
    attr_reader :binds

    # context: the option the session holds at the start (nil: never bound).
    def initialize(script, context: SIGNON_CONTEXT)
      super(script)
      @current_context = context
      @binds = []
    end

    # Raise error on the next call of rpc. sent: true records the call
    # first (the frame went out and the wire was lost); false raises before
    # it (nothing was sent).
    def fail_on(rpc, error, sent: true)
      @failure = { rpc: rpc, error: error, sent: sent }
      self
    end

    # Binding option is refused as Client#create_context refuses it: the
    # session is left with no known context.
    def refuse_bind(option)
      @refused_bind = option
      self
    end

    def call_rpc_raw(rpc_name, *params)
      failure = @failure if @failure && @failure[:rpc] == rpc_name
      if failure
        @failure = nil
        @calls << { rpc: rpc_name, params: params, context: current_context } if failure[:sent]
        raise failure[:error]
      end
      super.tap { @calls.last[:context] = current_context }
    end

    def create_context(option_name = SIGNON_CONTEXT)
      if option_name == @refused_bind
        @current_context = nil
        raise RpmsRpc::Client::ContextBindRefusedError.new("Failed to create context '#{option_name}'",
                                                           option: option_name)
      end
      @binds << option_name
      super
    end
  end

  module_function

  # A replay client answering the named flow's replies, configured as the
  # gem's client.
  def flow(slug, name, context: CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT)
    use(Client.new(CapturedReplies.flow_script(slug, name), context: context))
  end

  # A replay client with no replies at all: any RPC fails the test.
  def silent = use(Client.new({}))

  def use(client)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end
end
