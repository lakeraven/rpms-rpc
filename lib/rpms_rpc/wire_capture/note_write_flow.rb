# frozen_string_literal: true

module RpmsRpc
  module WireCapture
    # One TIU note on the seed patient: create, lock, set text, read it back,
    # unlock, and sign only when a signature code was actually supplied.
    #
    # The code is never logged and never returned. The broker still receives
    # the XWB ciphertext; the structure this returns puts WITHHELD in its place.
    class NoteWriteFlow
      DFN = "4"
      VISIT_IEN = "4"
      TITLE_IEN = "248"
      WITHHELD = "[signature code withheld]"
      # Clinical-neutral. The second line is longer than ProgressNote::WRAP_WIDTH
      # so SETTEXT's list is wrapped. No patient or staff names.
      NOTE_TEXT = [
        "Synthetic pilot note for wire capture.",
        "This synthetic clinical-neutral sentence exists so wire capture wraps a progress-note line."
      ].join("\n").freeze

      # Any positive id. ESignature.add requires user_duz and does not send it:
      # the signer is the broker session DUZ (see ESignature).
      SESSION_DUZ = "1"

      CREATE_RPC = "TIU CREATE RECORD"
      LOCK_RPC = "TIU LOCK RECORD"
      SET_RPC = "TIU SET DOCUMENT TEXT"
      GET_RPC = "TIU GET RECORD TEXT"
      UNLOCK_RPC = "TIU UNLOCK RECORD"
      SIGN_RPC = "TIU SIGN RECORD"

      class << self
        # { rpc => {"inputs" => ..., "raw" => verbatim} } in call order.
        # A step that raises is {"error" => ...} with the code removed, and
        # the flow stops: a later write would file against an unknown note.
        def run(client, esig: nil)
          captures = {}
          secrets = []
          secrets << esig if esig.is_a?(String) && !esig.empty?
          with_recorder(client, captures, secrets) do
            RpmsRpc.with_client(client) { perform(captures, secrets, esig) }
          end
          redact(captures, secrets)
        end

        # Drop every secret from a returned structure. Fail closed: if a secret
        # cannot be searched in the encoding, replace the whole string.
        def redact(value, secrets)
          list = Array(secrets).flatten.compact.map(&:to_s).reject(&:empty?).uniq
          return value if list.empty?

          scrub(value, list.sort_by { |secret| -secret.bytesize })
        end

        def redacted_error(error, secrets)
          "#{error.class}: #{redact(error.message.to_s, secrets)}"
        end

        def remember_sign_cipher(rpc, params, secrets)
          return unless rpc == SIGN_RPC

          cipher = params[1]
          secrets << cipher if cipher.is_a?(String) && !cipher.empty?
        end

        def recorded_inputs(rpc, params)
          inputs = params.map { |param| copy_input(param) }
          # The client's own param list keeps the ciphertext. This copy does not.
          inputs[1] = WITHHELD if rpc == SIGN_RPC && inputs.size > 1
          inputs
        end

        private

        def perform(captures, secrets, esig)
          require_api
          ok, created = guarded(captures, CREATE_RPC, secrets) do
            ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
          end
          return unless ok && created.is_a?(Hash) && created[:success] == true

          note_ien = created[:ien].to_s
          ok, held = guarded(captures, LOCK_RPC, secrets) { ProgressNote.lock(note_ien) }
          return unless ok && held == true

          # Lock is held. Set the text, read it back, then unlock, even when
          # update_text reports failure: the lock is still ours. A raise stops
          # instead; the failed step is the last capture.
          ok, = guarded(captures, SET_RPC, secrets) { ProgressNote.update_text(note_ien, NOTE_TEXT) }
          return unless ok

          ok, = guarded(captures, GET_RPC, secrets) { ProgressNote.fetch_text(note_ien) }
          return unless ok

          ok, = guarded(captures, UNLOCK_RPC, secrets) { ProgressNote.unlock(note_ien) }
          return unless ok
          return unless sign?(esig)

          guarded(captures, SIGN_RPC, secrets) { ESignature.add(note_ien, SESSION_DUZ, esig) }
          nil
        end

        def sign?(esig)
          esig.is_a?(String) && !esig.strip.empty?
        end

        def guarded(captures, rpc, secrets)
          [ true, yield ]
        rescue StandardError => e
          captures[rpc] = { "error" => redacted_error(e, secrets) }
          [ false, nil ]
        end

        def require_api
          require_relative "../api/progress_note"
          require_relative "../api/e_signature"
        end

        # Per-instance wrapper, removed in ensure. Not a global CiaClient patch:
        # Ruby has no unprepend, so the singleton methods we add are removed
        # rather than left on the ancestor chain. A client that already defined
        # call_rpc_raw on its singleton is refused — we could not put that
        # method back.
        def with_recorder(client, captures, secrets)
          singleton = client.singleton_class
          if singleton.instance_methods(false).include?(:call_rpc_raw) ||
             singleton.instance_methods(false).include?(:__note_write_flow_call_rpc_raw)
            raise ArgumentError, "refusing to wrap a client that already defines singleton call_rpc_raw"
          end

          singleton.send(:alias_method, :__note_write_flow_call_rpc_raw, :call_rpc_raw)
          begin
            install_recorder(singleton, captures, secrets)
            yield
          ensure
            remove_recorder(singleton)
          end
        end

        def install_recorder(singleton, captures, secrets)
          singleton.define_method(:call_rpc_raw) do |rpc, *params|
            NoteWriteFlow.remember_sign_cipher(rpc, params, secrets)
            raw = __note_write_flow_call_rpc_raw(rpc, *params)
            raw = raw.join("\n") if raw.is_a?(Array)
            captures[rpc] = {
              "inputs" => NoteWriteFlow.recorded_inputs(rpc, params),
              "raw" => raw.to_s.dup
            }
            raw
          end
        end

        def remove_recorder(singleton)
          if singleton.instance_methods(false).include?(:call_rpc_raw)
            singleton.send(:remove_method, :call_rpc_raw)
          end
          return unless singleton.instance_methods(false).include?(:__note_write_flow_call_rpc_raw)

          singleton.send(:remove_method, :__note_write_flow_call_rpc_raw)
        end

        def copy_input(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), copy|
              copy[input_key(key)] = copy_input(item)
            end
          when Array
            value.map { |item| copy_input(item) }
          when String
            value.dup
          else
            value.to_s
          end
        end

        # TEXT list keys are ["TEXT", n, 0]. YAML and JSON need String keys.
        def input_key(key)
          case key
          when Array
            key.map { |part| part.is_a?(String) ? part : part.to_s }.join(",")
          when String
            key.dup
          else
            key.to_s
          end
        end

        def scrub(value, secrets)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), copy|
              copy[scrub(key, secrets)] = scrub(item, secrets)
            end
          when Array
            value.map { |item| scrub(item, secrets) }
          when String
            apply_secrets(value, secrets)
          else
            value
          end
        end

        def apply_secrets(text, secrets)
          secrets.reduce(text) { |current, secret| current.gsub(secret, WITHHELD) }
        rescue Encoding::CompatibilityError, ArgumentError
          WITHHELD
        end
      end
    end

    # Loopback broker and the owned dev container. A read capture (writes
    # false or nil) is not refused. Anything else, including a missing host
    # or any other CONTAINER, is a reason and must abort before a socket.
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    OWNED_WRITE_CONTAINER = "rpms-ydb-9.0"

    def self.write_refusal(writes:, host:, container:)
      return nil if writes == false || writes.nil?
      unless writes == true
        return "WRITES=1 is refused"
      end

      unless LOOPBACK_HOSTS.include?(host.to_s.strip.downcase)
        return "WRITES=1 is refused unless the broker host is loopback " \
               "(127.0.0.1, localhost, or ::1)"
      end

      if container.to_s.strip != OWNED_WRITE_CONTAINER
        return "WRITES=1 is refused unless CONTAINER=#{OWNED_WRITE_CONTAINER} (the owned rung)"
      end

      nil
    end

    # True only when the public API accepts the reply. Odd input is false.
    # error_reply? and a reply with no data rows are false before the API runs.
    def self.write_evidence?(entry, raw, note_body: nil)
      return false unless raw.is_a?(String)
      return false unless entry.respond_to?(:rpc)
      return false if error_reply?(raw)
      return false if data_rows(raw).empty?

      rows = payload_rows(raw)
      return false if rows.empty?

      require_write_api
      case entry.rpc
      when NoteWriteFlow::CREATE_RPC then create_evidence?(rows)
      when NoteWriteFlow::LOCK_RPC then replay(entry.rpc, rows) { ProgressNote.lock("1") } == true
      when NoteWriteFlow::UNLOCK_RPC then replay(entry.rpc, rows) { ProgressNote.unlock("1") } == true
      when NoteWriteFlow::SET_RPC then set_evidence?(rows)
      when NoteWriteFlow::SIGN_RPC then sign_evidence?(rows)
      when NoteWriteFlow::GET_RPC then read_back_evidence?(rows, raw, note_body)
      else false
      end
    rescue StandardError
      # Fail closed. A shape we cannot judge is not evidence, and it must not
      # escape into the capture task.
      false
    end

    def self.write_capture_source(entry, raw, note_body: nil)
      return "live-capture" if write_evidence?(entry, raw, note_body: note_body)

      nil
    rescue StandardError
      nil
    end

    class WriteReplay
      def initialize(rpc, rows)
        @rpc = rpc.to_s
        @rows = rows
        @used = false
      end

      # One call, and only the RPC under test. Fixture#rows is the payload:
      # CIA frame stripped, empty lines dropped. A second call is nil.
      def call_rpc(name, *)
        return nil if @used || name.to_s != @rpc

        @used = true
        @rows
      end
    end
    private_constant :WriteReplay

    class << self
      private

      def require_write_api
        require_relative "../api/progress_note"
        require_relative "../api/e_signature"
      end

      def replay(rpc, rows)
        RpmsRpc.with_client(WriteReplay.new(rpc, rows)) { yield }
      end

      def create_evidence?(rows)
        result = replay(NoteWriteFlow::CREATE_RPC, rows) do
          ProgressNote.create(NoteWriteFlow::DFN, NoteWriteFlow::VISIT_IEN, NoteWriteFlow::TITLE_IEN)
        end
        result.is_a?(Hash) && result[:success] == true
      end

      # Pass the reply's own IEN when it is a positive integer so update_text
      # can accept TIUDA^PAGE^PAGES. Otherwise pass "1": invalid_id? would
      # return before the API read the reply, and a "0^..." failure would
      # never be judged.
      def set_evidence?(rows)
        result = replay(NoteWriteFlow::SET_RPC, rows) do
          ProgressNote.update_text(reply_ien(rows), "x")
        end
        result.is_a?(Hash) && result[:success] == true
      end

      # "x" is not a signature and is not recorded. The replay ignores params;
      # ESignature.add accepts the reply only when it is an all-digit ERR.
      def sign_evidence?(rows)
        result = replay(NoteWriteFlow::SIGN_RPC, rows) { ESignature.add("1", "1", "x") }
        result.is_a?(Hash) && result[:success] == true
      end

      def read_back_evidence?(rows, raw, note_body)
        text = replay(NoteWriteFlow::GET_RPC, rows) { ProgressNote.fetch_text("1") }
        return false if text.nil? || text.to_s.empty?

        first = note_body.to_s.split(/\r?\n/, 2).first.to_s.strip
        return false if first.empty?

        lines = frame_payload(raw).split(/\r?\n/, -1)
        blank = lines.index("")
        return false if blank.nil?

        lines[(blank + 1)..].to_a.any? { |line| line.include?(first) }
      end

      def reply_ien(rows)
        piece = rows.first.to_s.split("^", 2).first.to_s
        piece.match?(/\A[1-9]\d*\z/) ? piece : "1"
      end

      # Same frame strip as Fixture#rows, including the blank lines rows drops.
      def frame_payload(raw)
        raw.sub(/\A\d+[\x00\x01]/, "")
      end

      def payload_rows(raw)
        frame_payload(raw).split(/\r\n|\r|\n/).reject(&:empty?)
      end
    end
  end
end
