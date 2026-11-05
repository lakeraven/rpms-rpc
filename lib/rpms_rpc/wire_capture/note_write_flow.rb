# frozen_string_literal: true

require "ipaddr"
require "socket"

module RpmsRpc
  module WireCapture
    # One TIU note on the seed patient: create, lock, set text, read it back,
    # unlock, and sign only when a signature code was actually supplied.
    #
    # The code is never logged and never returned. A capture whose reply or
    # inputs contain it is dropped, not rewritten. The broker still receives
    # the XWB ciphertext; the structure this returns puts WITHHELD in its
    # place before that check, so the marker itself is not a hit.
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
        # A step that raises is {"error" => ...} with the message dropped when
        # it holds the code. A held lock is unlocked before this returns.
        def run(client, esig: nil)
          captures = {}
          secrets = []
          secrets << esig if esig.is_a?(String) && !esig.empty?
          with_recorder(client, captures, secrets) do
            RpmsRpc.with_client(client) { perform(captures, secrets, esig) }
          end
          quarantine_secrets(captures, secrets)
        end

        # A capture whose raw or inputs contain a secret becomes an error.
        # Every other capture is the same object, bytes unchanged.
        def quarantine_secrets(captures, secrets)
          needles = secret_needles(secrets)
          return captures if needles.empty?

          captures.each_with_object({}) do |(rpc, capture), clean|
            clean[rpc] = if secret_in_capture?(capture, needles)
              { "error" => quarantine_error(rpc) }
            else
              capture
            end
          end
        end

        # An exception message that contains a secret is replaced wholesale.
        # Substituting inside it would leave the rest of the text.
        def redacted_error(error, secrets)
          message = error.message.to_s
          needles = secret_needles(secrets)
          return "#{error.class}: #{WITHHELD}" if tainted_string?(message, needles)

          "#{error.class}: #{message}"
        rescue Encoding::CompatibilityError, ArgumentError
          # Fail closed: an unreadable message may hold the code, so none of it is kept.
          "#{error.class}: #{WITHHELD}"
        end

        def remember_sign_cipher(rpc, params, secrets)
          return unless rpc == SIGN_RPC

          cipher = params[1]
          secrets << cipher if cipher.is_a?(String) && !cipher.empty?
        end

        def recorded_inputs(rpc, params)
          inputs = params.map { |param| copy_input(param) }
          # The client's own param list keeps the ciphertext. This copy does not.
          # Quarantine runs after this replacement, so WITHHELD is not a hit.
          inputs[1] = WITHHELD if rpc == SIGN_RPC && inputs.size > 1
          inputs
        end

        private

        def perform(captures, secrets, esig)
          require_api
          note_ien = nil
          locked = false
          ready = false
          begin
            ok, created = guarded(captures, CREATE_RPC, secrets) do
              ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
            end
            return unless ok && created.is_a?(Hash) && created[:success] == true

            note_ien = created[:ien].to_s
            ok, held = guarded(captures, LOCK_RPC, secrets) { ProgressNote.lock(note_ien) }
            return unless ok && held == true

            locked = true
            ready = write_and_read(captures, secrets, note_ien)
          ensure
            # lock returned true: unlock even when set-text or the read-back raised.
            if locked
              ready = false unless unlock_note(captures, secrets, note_ien)
              sign_note(captures, secrets, esig, note_ien) if ready
            end
          end
        end

        def write_and_read(captures, secrets, note_ien)
          ok, updated = guarded(captures, SET_RPC, secrets) do
            ProgressNote.update_text(note_ien, NOTE_TEXT)
          end
          wrote = ok && updated.is_a?(Hash) && updated[:success] == true
          return false unless ok

          ok_read, = guarded(captures, GET_RPC, secrets) { ProgressNote.fetch_text(note_ien) }
          wrote && ok_read
        end

        def unlock_note(captures, secrets, note_ien)
          ok, unlocked = guarded(captures, UNLOCK_RPC, secrets) { ProgressNote.unlock(note_ien) }
          ok && unlocked == true
        end

        # Sign only after create, set-text, read-back, and unlock all succeeded.
        def sign_note(captures, secrets, esig, note_ien)
          return unless sign?(esig)

          guarded(captures, SIGN_RPC, secrets) { ESignature.add(note_ien, SESSION_DUZ, esig) }
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

        def secret_needles(secrets)
          Array(secrets).flatten.compact.map { |secret| secret.to_s.b }.reject(&:empty?).uniq
        end

        def secret_in_capture?(capture, needles)
          # Fail closed: a capture that is not a hash may still hold the code.
          return true unless capture.is_a?(Hash)

          secret_in_value?(capture["raw"], needles) || secret_in_value?(capture["inputs"], needles)
        end

        def secret_in_value?(value, needles)
          case value
          when nil
            false
          when String
            tainted_string?(value, needles)
          when Array
            value.any? { |item| secret_in_value?(item, needles) }
          when Hash
            value.any? { |key, item| secret_in_value?(key, needles) || secret_in_value?(item, needles) }
          else
            tainted_string?(value.to_s, needles)
          end
        end

        def tainted_string?(text, needles)
          return false if needles.empty?

          bytes = text.to_s.b
          needles.any? { |needle| bytes.include?(needle) }
        end

        def quarantine_error(rpc)
          "#{rpc}: reply contains the signature code; not recorded"
        end
      end
    end

    # README.md synthetic dev personas. A write may sign on as one of these
    # and nothing else. The access code is never copied into a refusal or a fixture.
    SYNTHETIC_PERSONAS = %w[SYS123 PROV123].freeze

    # Host mode only. A read capture (writes false or nil) is not refused.
    # WRITES=1 is allowed only when the broker host resolves and every
    # address is loopback, CONTAINER is nil or "", and the access code is a
    # synthetic persona. A container run goes through `docker exec`, which
    # would put the signature code on a command line. Anything else is a
    # reason and must abort before a socket.
    def self.write_refusal(writes:, host:, container:, access: nil, resolver: nil)
      return nil if writes == false || writes.nil?
      return "WRITES=1 is refused" unless writes == true
      return "WRITES=1 is refused when CONTAINER is set" unless container.to_s.strip.empty?
      return loopback_refusal unless resolved_loopback?(host, resolver)
      return persona_refusal unless SYNTHETIC_PERSONAS.include?(access)

      nil
    end

    # True only when the public API accepts the reply. Odd input is false.
    # error_reply? and a reply with no data rows are false before the API runs.
    # note_ien is the captured note. SET fails closed when it is nil; lock,
    # unlock, and the read-back are called with it when it was supplied.
    def self.write_evidence?(entry, raw, note_body: nil, note_ien: nil)
      return false unless raw.is_a?(String)
      return false unless entry.respond_to?(:rpc)
      return false if error_reply?(raw)
      return false if data_rows(raw).empty?

      rows = payload_rows(raw)
      return false if rows.empty?

      require_write_api
      case entry.rpc
      when NoteWriteFlow::CREATE_RPC then create_evidence?(rows)
      when NoteWriteFlow::LOCK_RPC then lock_evidence?(rows, note_ien)
      when NoteWriteFlow::UNLOCK_RPC then unlock_evidence?(rows, note_ien)
      when NoteWriteFlow::SET_RPC then set_evidence?(rows, note_ien)
      when NoteWriteFlow::SIGN_RPC then sign_evidence?(rows)
      when NoteWriteFlow::GET_RPC then read_back_evidence?(rows, raw, note_body, note_ien)
      else false
      end
    rescue StandardError
      # Fail closed. A shape we cannot judge is not evidence, and it must not
      # escape into the capture task.
      false
    end

    def self.write_capture_source(entry, raw, note_body: nil, note_ien: nil)
      return "live-capture" if write_evidence?(entry, raw, note_body: note_body, note_ien: note_ien)

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

      def loopback_refusal
        "WRITES=1 is refused unless the broker host resolves to loopback addresses only"
      end

      def persona_refusal
        "WRITES=1 is refused unless the sign-on is a synthetic persona"
      end

      def resolved_loopback?(host, resolver)
        name = host.to_s.strip
        return false if name.empty?

        addresses = resolver ? resolver.call(name) : resolve_host_addresses(name)
        list = addresses.is_a?(Array) ? addresses : Array(addresses)
        return false if list.empty?

        list.all? { |address| ip_loopback?(address) }
      rescue StandardError
        # Fail closed: an unresolved host is not a loopback broker.
        false
      end

      def resolve_host_addresses(host)
        Addrinfo.getaddrinfo(host.to_s, nil).map(&:ip_address)
      end

      def ip_loopback?(address)
        IPAddr.new(address.to_s).loopback?
      rescue IPAddr::InvalidAddressError, ArgumentError
        false
      end

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

      def lock_evidence?(rows, note_ien)
        replay(NoteWriteFlow::LOCK_RPC, rows) { ProgressNote.lock(evidence_id(note_ien)) } == true
      end

      def unlock_evidence?(rows, note_ien)
        replay(NoteWriteFlow::UNLOCK_RPC, rows) { ProgressNote.unlock(evidence_id(note_ien)) } == true
      end

      # The API refuses a blank id before it reads the reply. SET must not
      # use this placeholder: a nil note IEN has nothing to match against TIUDA.
      def evidence_id(note_ien)
        note_ien.nil? ? "1" : note_ien
      end

      def set_evidence?(rows, note_ien)
        # Fail closed: a missing note IEN must not be treated as the reply's TIUDA.
        return false if note_ien.nil?

        result = replay(NoteWriteFlow::SET_RPC, rows) do
          ProgressNote.update_text(note_ien, "x")
        end
        result.is_a?(Hash) && result[:success] == true
      end

      # "x" is not a signature and is not recorded. The replay ignores params;
      # ESignature.add accepts the reply only when it is an all-digit ERR.
      def sign_evidence?(rows)
        result = replay(NoteWriteFlow::SIGN_RPC, rows) { ESignature.add("1", "1", "x") }
        result.is_a?(Hash) && result[:success] == true
      end

      def read_back_evidence?(rows, raw, note_body, note_ien)
        text = replay(NoteWriteFlow::GET_RPC, rows) do
          ProgressNote.fetch_text(evidence_id(note_ien))
        end
        return false if text.nil? || text.to_s.empty?

        body_lines = body_after_blank(raw)
        return false if body_lines.nil?
        return false if body_lines.any? { |line| line.bytesize > ProgressNote::WRAP_WIDTH }

        note_lines_in_order?(body_lines, note_body)
      end

      # CIA row grammar: rows separate on \r\n, a bare \r, or \n. -1 keeps blanks.
      def body_after_blank(raw)
        lines = frame_payload(raw).split(/\r\n|\r|\n/, -1)
        blank = lines.index("")
        return nil if blank.nil?

        lines[(blank + 1)..] || []
      end

      # Body lines are joined with a space. Whitespace is then removed so a
      # soft break (one space dropped) and a hard cut (a space inserted inside
      # a token) both still show the note. Each NOTE_TEXT line must occur, in
      # order. Every body line is also at most WRAP_WIDTH bytes.
      def note_lines_in_order?(body_lines, note_body)
        body = without_space(body_lines.join(" "))
        cursor = 0
        found = false
        note_body.to_s.split(/\r\n|\r|\n/, -1).each do |line|
          needle = without_space(line)
          next if needle.empty?

          at = body.index(needle, cursor)
          return false if at.nil?

          cursor = at + needle.length
          found = true
        end
        found
      end

      def without_space(text)
        text.to_s.gsub(/\s+/, "")
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
