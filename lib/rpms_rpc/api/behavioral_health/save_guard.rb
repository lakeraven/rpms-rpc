# frozen_string_literal: true

require_relative "../../context_scope"
require_relative "../ddr_fileman"

module RpmsRpc
  module BehavioralHealth
    # The one exclusion and visit lock every save on a BH visit record takes:
    # save_health_factors, Wellness.save_screening and
    # Wellness.save_measurements (rpms-rpc#629). Each extends this module and
    # defines save_guard_refuse!(message, cause), which raises its SaveError.
    #
    # M LOCK is incremental per broker job, so a second save on the same
    # client is granted ^AMHREC(ien) at once; the DDR lock alone does not keep
    # two saves of one visit apart. The in-process set is the exclusion the
    # broker will not give, and it is shared, so a health-factor save and a
    # Wellness save of one visit on one client exclude each other. The mutex
    # guards the set only and is never held across a save, so a re-entrant
    # call refuses instead of deadlocking. The key is [:session, id] or
    # [:object, object_id] plus the record IEN. No client this gem ships
    # defines session_id, so stock clients key on object_id; a host that wraps
    # one session in several objects shares the exclusion only by exposing
    # session_id on each wrapper.
    #
    # The visit lock is polled: DDR LOCK with a zero timeout, then a pause
    # with the wire free, up to LOCK_ATTEMPTS times (about five seconds). A
    # server-side wait would hold the client's wire for the whole wait, and
    # every other caller on that client would block behind it.
    module SaveGuard
      GUARD = Mutex.new
      IN_PROGRESS = {}
      LOCK_ATTEMPTS = 10
      LOCK_PAUSE = 0.5
      private_constant :GUARD, :IN_PROGRESS

      private

      # One save at a time per client identity and record, refused before
      # any RPC.
      def save_exclusive(client, record)
        key = [ save_guard_identity(client), record.to_s ]
        GUARD.synchronize do
          save_guard_refuse!("a save for this record is in progress", nil) if IN_PROGRESS[key]

          IN_PROGRESS[key] = true
        end
        begin
          yield
        ensure
          GUARD.synchronize { IN_PROGRESS.delete(key) }
        end
      end

      # [:session, id] or [:object, object_id], so a string session id and an
      # integer object id cannot collide. session_id is read once: nil, false
      # or an empty String is no id. A raise is a refusal before any RPC.
      def save_guard_identity(client)
        session = client.respond_to?(:session_id) ? client.session_id : nil
        session = nil if session == false || (session.is_a?(String) && session.empty?)
        return [ :object, client.object_id ] if session.nil?

        [ :session, session.is_a?(String) ? session.dup.freeze : session ]
      rescue StandardError, NotImplementedError => e
        save_guard_refuse!("the client session could not be read", e)
      end

      # Hold node from the yield's first RPC to its last; unlocked on every
      # exit once acquired.
      def with_record_lock(node)
        record_lock!(node)
        begin
          yield
        ensure
          record_unlock(node)
        end
      end

      # A false reply is a lock another job holds, polled again after a pause
      # outside the wire lock. nil, any other reply, StandardError or
      # NotImplementedError ends the wait. Once a poll was sent and the lock
      # was not taken, the node is unlocked before the refusal (L - on a node
      # not held is harmless). When the FileMan context could not be bound no
      # poll was sent, so no unlock is.
      def record_lock!(node)
        sent = false
        cause = nil
        LOCK_ATTEMPTS.times do |attempt|
          save_guard_pause if attempt.positive?
          got = begin
            save_guard_fileman do
              sent = true
              DdrFileman.lock(node: node, timeout: 0)
            end
          rescue StandardError, NotImplementedError => e
            cause = e
            nil
          end
          return true if got == true
          break unless got == false
        end
        record_unlock(node) if sent
        save_guard_refuse!("the lock #{node} was not acquired", cause)
      end

      # Best-effort. A false reply, StandardError or NotImplementedError must
      # not replace a result or an exception the save already produced. A
      # lock this call does not release expires with the broker job.
      def record_unlock(node)
        save_guard_fileman { DdrFileman.unlock(node: node) }
      rescue StandardError, NotImplementedError
        nil
      end

      # Never called inside the wire lock: the point of polling.
      def save_guard_pause = sleep(LOCK_PAUSE)

      # AMHGRPC does not list the DDR lock RPC; the FileMan context does.
      # Patient is loaded on first use so requiring this file does not pull
      # Patient's dependency chain into the process before a save needs it.
      def save_guard_fileman(&block)
        require_relative "../patient"
        ContextScope.scoped(RpmsRpc.client, RpmsRpc::Patient::FILEMAN_CONTEXT, &block)
      end
    end
  end
end
