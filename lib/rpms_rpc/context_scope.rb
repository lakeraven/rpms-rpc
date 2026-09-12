# frozen_string_literal: true

module RpmsRpc
  # Tracks the broker CONTEXT OPTION bound to a session, and scopes a block to
  # a different one.
  #
  # RPC registration is OPTION-scoped: both broker lines answer "may this
  # session run this RPC?" from the RPC multiple of the option bound RIGHT NOW,
  # and deny anything absent from it —
  #
  #   CIA — $$CANRUN^CIANBACT answers $D(^XTMP("CIA",UID,"C",CTX,RPC)) from a
  #         table merged out of ^DIC(19,OPT,"RPC","B") (CIANBACT.m:148,155),
  #         and ACTR applies it to every non-CIANB* routine (CIANBACT.m:55).
  #   XWB — CHKPRMIT^XWBSEC -> $$CHK^XQCS(DUZ,option,RPC), whose cache is
  #         built from ^DIC(19,XQOPT,"RPC",…) (XWBSEC.m:3-27, XQCS.m:64-76).
  #
  # So an API whose RPCs live under their OWN option (RpmsRpc::Agg / AGGRPC)
  # must bind that option before probing or calling. Skip the bind and the
  # broker answers a truthful "not runnable HERE" — which is indistinguishable
  # from "not installed" unless the caller knows which context was bound.
  #
  # Both lines bypass the check for holders of XUPROGMODE (CIANBACT.m:147,
  # XWBSEC.m:5), so a programmer session cannot detect a missing bind: it is
  # answered 1 either way. Only a NON-privileged session is evidence.
  module ContextScope
    # The context option this client believes is bound, or nil when unknown
    # (never bound through this client — e.g. before sign-on).
    attr_reader :current_context

    # Run the block with `option_name` bound, restoring the previously known
    # context afterward. Costs nothing when it is already bound, so a caller
    # may wrap a whole workflow and let the individual APIs re-assert their
    # own context freely.
    #
    # Restoration needs a NAME to go back to, and there is no "unbind": the
    # CIA line persists the last context it was given (SETVAR^CIANBUTL,
    # CIANBACT.m:50) and reuses it for any frame that omits one (:49). So a
    # client that never declared a context cannot be returned to it — the
    # scope still happens (refusing would guarantee the scoped API is dead),
    # but it warns, because the next API to run on this session will run under
    # `option_name` rather than wherever the caller thought it was.
    #
    # Either way `current_context` keeps naming the option actually bound, so
    # the next scope re-binds from a truthful starting point rather than
    # assuming.
    # Held under the client's wire lock for its WHOLE duration, bind through
    # restore. The bound option is per-session state that the broker consults
    # on every frame, so a scope that only locked its individual calls let
    # another thread re-bind between this one's bind and its call: the RPC —
    # or a capability probe inside it — then ran under the wrong option, and
    # the broker's truthful "not runnable here" is indistinguishable from
    # "not installed".
    #
    # This serializes scoped workflows against each other. That is the honest
    # cost of one session holding one context; per-session clients (#234) are
    # what removes it.
    def with_context(option_name, &block)
      synchronize_context do
        next block.call if current_context == option_name

        previous = current_context
        if previous.nil?
          warn "[rpms_rpc] binding context #{option_name.inspect} on a session " \
               "with no declared context — it cannot be restored afterward"
        end
        create_context(option_name)
        begin
          block.call
        ensure
          restore_context(previous, option_name)
        end
      end
    end

    private

    # Clients carry the wire lock; anything else that mixes in ContextScope
    # (or a stand-in in a test) simply runs the block.
    def synchronize_context(&block)
      respond_to?(:synchronize_wire) ? synchronize_wire(&block) : block.call
    end

    def restore_context(previous, scoped)
      return if previous.nil? || previous == scoped

      create_context(previous)
    rescue StandardError => e
      warn "[rpms_rpc] could not restore context #{previous.inspect} " \
           "(#{e.class}); session remains on #{current_context.inspect}"
    end
  end
end
