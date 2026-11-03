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
    # Run the block with `option_name` bound on `client` when the client can
    # scope contexts, and as-is when it cannot (a non-broker double, a plain
    # stub) — the package APIs' entry point (RpmsRpc::Referral / BMCRPC,
    # RpmsRpc::Scheduling / BSDXRPC, RpmsRpc::BehavioralHealth / AMHGRPC, the
    # same shape RpmsRpc::Agg uses for AGGRPC). A client that cannot bind an
    # option cannot be denied by one either, so skipping the scope there
    # loses nothing.
    def self.scoped(client, option_name, &block)
      return block.call unless client.respond_to?(:with_context)

      client.with_context(option_name, &block)
    end

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
    # A refused bind (scope entry or nested) re-binds the caller's previous
    # context. That re-bind is `create_context(previous)`: on XWB/BMX a real
    # XWB CREATE CONTEXT, which is how the session recovers after
    # CRCONTXT^XWBSEC has killed the broker context. If that restore is
    # refused too, `current_context` is nil (`Client#create_context` clears
    # it on failure) and the next scope re-binds from a truthful starting
    # point rather than assuming the old name.
    #
    # The re-bind is skipped when `current_context` already equals
    # `previous`: nothing changed, so nothing is restored.
    # `Client#create_context` raises ConnectionError ("Not connected") or
    # AuthenticationError ("Not authenticated") before the wire and leaves
    # `current_context` unchanged; re-binding there fails the same way and
    # warns "could not restore context". A refused on-the-wire bind is not
    # this case. It clears `current_context` to nil, and the ensure still
    # re-binds `previous` (scope entry and nested). Do not skip a restore
    # merely because `current_context` is nil — an earlier
    # `return if current_context.nil?` broke those nested restores.
    #
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
        # The entry bind is inside the ensure so a refusal still restores.
        # create_context raises without running the block. On XWB/BMX a
        # refused CREATE CONTEXT has already killed the broker context and
        # cleared current_context, so the ensure re-binds `previous` (scope
        # entry and nested) even though current_context is nil along the
        # way. A failure before the wire leaves current_context equal to
        # previous, and restore_context does not re-bind. Do not
        # `return if current_context.nil?` — that early return broke nested
        # refused-bind restores.
        begin
          create_context(option_name)
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

      # Already the context we would re-bind: the bind never took effect.
      # create_context raises ConnectionError ("Not connected") or
      # AuthenticationError ("Not authenticated") before the wire and does
      # not clear current_context. Re-binding would fail the same way and
      # warn. A refused on-the-wire bind is different: it clears
      # current_context to nil, which is not equal to previous, so the
      # re-bind below still runs for scope entry and nested refusals. Do
      # not `return if current_context.nil?` — that skips those restores.
      return if current_context == previous

      create_context(previous)
    rescue StandardError => e
      warn "[rpms_rpc] could not restore context #{previous.inspect} " \
           "(#{e.class}); session remains on #{current_context.inspect}"
    end
  end
end
