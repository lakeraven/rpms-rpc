# frozen_string_literal: true

require "digest"
require "yaml"
require_relative "core"
require_relative "fileman_date_parser"
require_relative "wire_capture/evidence"
require_relative "wire_capture/note_write_flow"

module RpmsRpc
  # Wire-shape capture + contract checking (issue #189).
  #
  # Extends the conformance pipeline's capture -> committed fixture -> gate
  # pattern (lib/rpms_rpc/conformance/, docs/conformance/SPEC.md) from
  # "is the RPC registered / what return TYPE does it declare" down to the
  # FIELD-LEVEL layout of an actual return. The failure class this closes:
  # a DataMapper mapping authored from belief passes green against mocks
  # that mirror the same belief (MockClient formats seeds THROUGH the
  # mapping), so code and test agree with each other while proving nothing
  # about the real system. ORQQVI VITALS shipped declaring
  # TYPE^VALUE^UNITS^DATE when the real wire is IEN^TYPE^DATETIME^value
  # (VITALS^ORQQVI: ORQQVI.m:4-24). See docs/WIRE_CONTRACTS.md.
  #
  # Three pieces:
  #
  # - CATALOG: the curated RPC list with capture inputs and cited
  #   per-position semantics. `rake wire:capture` drives it against a rung
  #   we own (read-only behavioral calls, never a customer instance — the
  #   conformance SPEC's non-negotiable) and writes provenance-stamped
  #   fixtures to test/fixtures/wire_captures/. The read catalog never calls
  #   a write RPC. `rake wire:capture_writes` is the separate scheduling-write
  #   path (WRITE_CATALOG, mode :write_live): disposable loopback only, and
  #   the read-back is the proof.
  # - Fixture: loads a committed capture and REJECTS any fixture whose
  #   provenance is not `live-capture` (verbatim raw + sha256) or
  #   `routine-cite` (M source citation, no raw claimed). A hand-written
  #   wire shape with neither cannot enter the gate.
  # - Contract: checks a DataMapper mapping's declared field layout against
  #   a fixture — both the cited position->semantics annotation and, for
  #   live captures, the raw pieces themselves (a :fileman_date field whose
  #   captured piece is "120/80" fails). Runs in CI with no live container.
  module WireCapture
    FIXTURES_DIR = File.expand_path("../../test/fixtures/wire_captures", __dir__)

    # live-capture — the broker returned DATA rows; the pieces below are
    # evidence. no-data — the RPC answered but returned nothing to read
    # (empty box, or a sentinel); the bytes are kept as a record, the
    # pieces are a source cite, and it counts as coverage of nothing.
    # routine-cite — shape read from the M source, no call made.
    SOURCES = [ "live-capture", "no-data", "routine-cite" ].freeze
    KINDS = [ "fields", "scalar", "text_blob", "lines" ].freeze

    # Access codes README.md documents as synthetic dev personas. A capture
    # may record one of these as signed_on_as and nothing else.
    SYNTHETIC_PERSONAS = %w[SYS123 PROV123].freeze

    # BMX recordset column: a type letter, a 5-digit width, then the name
    # (I00020APPOINTMENTID, T00020ERRORID). A header row is one whose every
    # caret piece matches. Data rows do not.
    BMX_COLUMN = /\A[A-Za-z]\d{5}[A-Za-z][A-Za-z0-9_]*\z/
    LINE_BREAK = /\r\n|\r|\n/
    RECORDSET_BREAK = /\r\n|\r|\n|\x1e/
    RECORDSET_TRAILER = /[\x1e\x1f]+\z/

    class InvalidFixture < Error; end

    # The one rule that turns an RPC name into a fixture name.
    def self.slug(rpc) = rpc.downcase.tr(" /", "--")

    def self.fixture_path(entry) = File.join(FIXTURES_DIR, "#{entry.fixture_name}.yml")

    # A token cites an entry by its fixture name, or by its RPC name when the
    # entry's fixture is the RPC slug. An entry with its own fixture: is never
    # cited by the RPC name it shares with others.
    def self.cite_only?(entry, tokens)
      tokens.any? do |token|
        token == entry.fixture_name || (token == entry.rpc && entry.fixture_name == slug(entry.rpc))
      end
    end

    # Tokens (first occurrence order) that cite none of the entries.
    def self.unmatched_cite_only_tokens(entries, tokens)
      tokens.uniq.reject { |token| entries.any? { |entry| cite_only?(entry, [ token ]) } }
    end

    # The live entries a read run calls: ONLY narrows, CITE_ONLY removes. An
    # unmatched CITE_ONLY token is an error, judged on all live entries before
    # ONLY narrows them.
    def self.select_live_entries(catalog: CATALOG, only: "", cite_only: [])
      live = catalog.select(&:live?)
      unmatched = unmatched_cite_only_tokens(live, cite_only)
      raise ArgumentError, "CITE_ONLY names no live catalog entry: #{unmatched.map(&:inspect).join(", ")}" unless unmatched.empty?

      live = live.select { |entry| entry.named?(only) } unless only.empty?
      live.reject { |entry| cite_only?(entry, cite_only) }
    end

    Piece = Struct.new(:position, :attributes, :fileman_type, keyword_init: true)

    # One curated capture target: which RPC, which mapping gates it, how to
    # call it live (or why we can't), and the cited piece semantics.
    # context is the option to bind before the call (nil: the sign-on option).
    CatalogEntry = Struct.new(:rpc, :mapping, :kind, :mode, :inputs, :cite, :pieces, :note,
                              :context, :fixture, keyword_init: true) do
      def live? = mode == :live

      # The fixture file's base name: the entry's own fixture:, else the RPC
      # slug. Two entries calling one RPC with different inputs need distinct
      # names or they overwrite each other's file.
      def fixture_name = fixture || WireCapture.slug(rpc)

      # ONLY matches either the RPC name or the fixture name.
      def named?(name) = name == rpc || name == fixture_name

      # A patient-record write. live? stays false so the read driver never calls it.
      def write? = mode == :write
    end

    # A committed wire capture. Validates provenance on load — an invalid
    # fixture raises InvalidFixture rather than silently entering the gate.
    # Does a verbatim reply carry rows that are EVIDENCE of a field layout?
    # Exposed at module level so the capture task can label a fixture from the
    # bytes it actually received instead of assuming "live-capture" and then
    # discovering at validation time that it was wrong.
    #
    # A BMX recordset (the body contains $C(30) or $C(31)) is split on that
    # row break. Its typed column header and its end marker are not data.
    # That typed-header filter applies only to a recordset. A reply with
    # neither marker is split on newlines, and header-shaped lines stay.
    def self.data_rows(raw)
      return [] if raw.nil?

      reply_rows(raw).reject { |row| non_data_row?(row) }
    end

    # Non-empty reply lines. Blank lines stay out; a lines fixture keeps those
    # separately. The typed BMX header is dropped only when the reply is a
    # recordset (the body contains \x1e or \x1f). A non-recordset reply keeps
    # header-shaped lines.
    def self.reply_rows(raw)
      rows = payload_rows(raw).reject(&:empty?)
      return rows unless recordset_body?(raw)

      rows.reject { |row| bmx_header_row?(row) }
    end

    # An explicit broker error ("-N^message"), as opposed to a no-data
    # sentinel. The difference matters when recapturing: nothing came back
    # because the CALL failed, so the existing fixture is better evidence
    # than anything this run could write. Row breaks match #data_rows so a
    # recordset error row is not hidden behind its column header.
    def self.error_reply?(raw)
      return false if raw.nil?

      # The ACK BYTE is authoritative, not the shape of the text. CIA marks an
      # error reply with \x01 (parse_cia_reply raises RpcError on exactly that
      # byte), and such a reply can be free-form -- "Access denied for remote
      # procedure." carries no "-N^" prefix at all. Matching only the text
      # shape let a denied call be labelled live-capture and overwrite a
      # fixture with its error message as wire evidence.
      return true if raw.match?(/\A\d+\x01/)

      # Replies without CIA framing still announce failure in the row itself.
      payload_rows(raw).reject(&:empty?).any? { |row| row.match?(/\A-\d+(?:\.\d+)?\^/) }
    end

    # A PROV123 booking probe is evidence only as a refusal. A broker error
    # is not one. The first data row has to map through
    # :scheduling_add_appointment to an appointment id <= 0 and a non-empty
    # error. The mapping is loaded here, on this path only.
    def self.persona_probe_refusal?(raw)
      return false if raw.nil? || error_reply?(raw)

      rows = data_rows(raw)
      return false if rows.empty?

      require "rpms_rpc/mappings"
      mapped = DataMapper[:scheduling_add_appointment].parse_one(rows.first.to_s)
      mapped.is_a?(Hash) && mapped[:appointment_id].to_i <= 0 && !mapped[:error].to_s.empty?
    end

    # A DDR GETS ENTRY DATA body captured as a write's read-back: not a broker
    # error, and at least one FILE^IENS^FIELD^value row under the reply. A
    # bare "[Data]" marker and an "[ERROR]" body are not evidence.
    def self.valid_ddr_read_back_raw?(raw)
      return false if raw.nil? || error_reply?(raw)

      rows = payload_rows(raw).reject(&:empty?)
      return false if rows.any? { |row| row.start_with?("[ERROR]") }

      rows.any? { |row| ddr_field_row?(row) }
    end

    def self.payload_rows(raw)
      body = strip_frame(raw)
      recordset = recordset_body?(raw)
      rows = body.split(recordset ? RECORDSET_BREAK : LINE_BREAK)
      rows.map! { |row| row.sub(RECORDSET_TRAILER, "") } if recordset
      rows
    end

    # A recordset reply carries $C(30) between rows or a $C(31) end marker.
    # Anything else is split on newlines and is not run through the typed-header filter.
    def self.recordset_body?(raw)
      body = raw.to_s.sub(/\A\d+[\x00\x01]/, "")
      body.include?("\x1e") || body.include?("\x1f")
    end

    def self.bmx_header_row?(line)
      pieces = line.split("^", -1)
      return false if pieces.empty?

      pieces.all? { |piece| piece.match?(BMX_COLUMN) }
    end

    def self.ddr_field_row?(row)
      return false if row.start_with?("[")

      pieces = row.split("^", -1)
      pieces.length >= 4 && !pieces[0].empty? && !pieces[2].empty?
    end
    private_class_method :payload_rows, :recordset_body?, :bmx_header_row?, :ddr_field_row?

    # Read catalog entries the driver may call. A write run calls none of
    # them. The note flow's only read is the BEHOENCX GETVISIT linkage check
    # before create, and that call is not selected here. writes false or nil
    # is the live catalog, narrowed by ONLY, with CITE_ONLY left out.
    def self.driver_read_entries(writes:, only:, cite_only:)
      return [] if writes == true

      tokens = Array(cite_only).map { |token| token.to_s.strip }.reject(&:empty?)
      select_live_entries(only: only.to_s.strip, cite_only: tokens)
    end

    # nil, "", and whitespace are unset. Otherwise the stripped RPC name.
    # A blank ONLY must not match nothing and skip every fixture.
    def self.normalize_only(value)
      return nil if value.nil?

      text = value.to_s.strip
      return nil if text.empty?

      text
    end

    # Fixtures a run may write. WRITES=1 is only the TIU write catalog, so a
    # write run never rewrites a read or routine-cite fixture. A read run is
    # the live and routine-cite catalog, narrowed by ONLY. A blank ONLY is
    # that whole set.
    def self.fixture_entries(writes:, only:)
      entries = writes == true ? CATALOG.select(&:write?) : CATALOG.reject(&:write?)
      name = normalize_only(only)
      return entries if name.nil?

      entries.select { |entry| entry.named?(name) }
    end

    # Verdicts for a scratch capture against committed fixtures (rpms-ops#975),
    # one [fixture, verdict, committed source, captured source] row per fixture called
    # on either side. SAME: raw bytes identical. SAME-ROWS: the data rows
    # match and only the CIA frame header differs (it counts the session's
    # calls). DIFFERENT. NEW: the committed fixture has no raw return
    # (routine-cite, or none). NOT-CAPTURED: the committed fixture has a raw
    # return and the capture has none.
    COMPARE_VERDICTS = %w[SAME SAME-ROWS DIFFERENT NEW NOT-CAPTURED].freeze

    def self.compare(committed_dir, captured_dir)
      # One row per fixture file, so two entries sharing an RPC stay apart.
      load = ->(dir) { Fixture.load_all(dir).to_h { |f| [ f.fixture_name, f ] } }
      committed = load.call(committed_dir)
      captured = load.call(captured_dir)
      (committed.keys | captured.keys).sort.filter_map do |name|
        was = committed[name]&.raw_return
        now = captured[name]&.raw_return
        next if was.nil? && now.nil? # routine-cite on both sides: nothing was called

        verdict = if now.nil? then "NOT-CAPTURED"
        elsif was.nil? then "NEW"
        elsif now == was then "SAME"
        elsif data_rows(now) == data_rows(was) then "SAME-ROWS"
        else "DIFFERENT"
        end
        [ name, verdict, committed[name]&.source || "-", captured[name]&.source || "-" ]
      end
    end

    def self.non_data_row?(line)
      return true if line.match?(/\A-\d+(?:\.\d+)?\^/)

      pieces = line.split("^", -1)
      pieces.length >= 2 && pieces[0].empty? &&
        pieces[1].match?(/\A[A-Za-z]/) && pieces[2..].all?(&:empty?)
    end

    def self.strip_frame(raw)
      payload = raw.sub(/\A\d+[\x00\x01]/, "")
      return payload unless payload.encoding == Encoding::ASCII_8BIT

      text = payload.dup
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : payload
    end
    private_class_method :strip_frame

    class Fixture
      attr_reader :path, :rpc, :mapping_name, :kind, :source, :cite, :inputs,
                  :raw_return, :example_return, :sha256, :release_tag, :captured_at,
                  :pieces, :note, :signed_on_as, :write, :api_call, :read_back,
                  :read_before, :persona_probe

      def self.load_all(dir = FIXTURES_DIR)
        Dir.glob(File.join(dir, "*.yml")).sort.map { |path| load_file(path) }
      end

      def self.load_file(path)
        new(YAML.safe_load_file(path), path: path)
      end

      def initialize(data, path: nil)
        @path = path
        @rpc = data["rpc"]
        @mapping_name = data["mapping"]&.to_sym
        @kind = data["kind"]
        @source = data["source"]
        @cite = data["cite"]
        @inputs = data["inputs"]
        @raw_return = data["raw_return"]
        @example_return = data["example_return"]
        @sha256 = data["sha256"]
        @release_tag = data["release_tag"]
        @captured_at = data["captured_at"]
        @note = data["note"]
        @signed_on_as = data["signed_on_as"]
        @write = data["write"] == true
        @api_call = data["api_call"]
        @read_back = data["read_back"]
        @read_before = data["read_before"]
        @persona_probe = data["persona_probe"]
        @pieces = (data["pieces"] || []).map do |p|
          Piece.new(position: p["position"],
                    attributes: Array(p["attribute"] || p["attributes"]).map(&:to_s),
                    fileman_type: p["fileman_type"])
        end
        validate!
      end

      def fixture_name = @path && File.basename(@path, ".yml")

      def piece_at(position)
        @pieces.find { |p| p.position == position }
      end

      # Captured (or, for routine-cite, illustrative) return lines.
      #
      # raw_return is the VERBATIM broker reply — for {CIA} replies that
      # includes the protocol framing (sequence echo + ack byte, e.g.
      # "6\x00") ahead of the RPC payload (session_params in CiaClient
      # documents the same framing). Verbatim bytes are never hand-edited
      # (the sha256 seals them), so framing is stripped HERE, at parse
      # time, not in the fixture.
      def rows
        text = @raw_return || @example_return
        return [] if text.nil?

        # Strip the ack byte whatever it is: \x00 marks data, \x01 marks an
        # error, and call_rpc_raw keeps the error flag attached. Stripping
        # only \x00 left "6\x01-1^message" intact, so non_data_row?'s
        # "-N^message" test never matched and a FAILED RPC was counted as a
        # captured data row -- a valid-looking live fixture built from an error.
        # Recordset replies lose the typed header and the $C(31) end marker
        # here too, so the contract type-checks data rows.
        WireCapture.reply_rows(text)
      end

      # Only live-captured rows are evidence; example rows illustrate a cite.
      def captured_rows
        @raw_return.nil? ? [] : rows
      end

      # Rows as POSITIONS, not as evidence. For a lines reply the index IS the
      # field number, so a blank line is a field with no value and has to keep
      # its slot -- dropping it shifts every later field, and the gate then
      # compares the wrong value: it can reject a correct mapping or pass an
      # incorrect one, which is the failure this gate exists to prevent.
      # A fields reply is many records, where a blank line is just filler.
      def positional_rows
        return captured_rows unless @kind == "lines"
        return [] if @raw_return.nil?
        # A reply that is only an error row or a no-data sentinel carries no
        # field values at all. Handing that line back as position 0 made the
        # type check read "-1^message" as an integer field and fail a fixture
        # that is honestly recording an empty result.
        return [] if captured_data_rows.empty?

        @raw_return.sub(/\A\d+[\x00\x01]/, "").split(/\r\n|\r|\n/)
      end

      # The rows that are actually EVIDENCE of a wire shape. A broker error
      # ("-N^message") or a no-data sentinel ("^No problems found.") proves
      # the RPC answered and nothing about its field layout — counting
      # those as capture backing is how an empty result set comes to look
      # like a verified contract.
      def captured_data_rows
        return [] if @raw_return.nil?

        WireCapture.data_rows(@raw_return)
      end

      private

      def validate!
        fail!("missing rpc") if blank?(@rpc)
        fail!("missing mapping") if @mapping_name.nil?
        fail!("kind must be one of #{KINDS.join("/")}") unless KINDS.include?(@kind)
        fail!("source must be one of #{SOURCES.join("/")} — a hand-written wire " \
              "fixture without capture provenance is rejected") unless SOURCES.include?(@source)
        fail!("missing cite — piece semantics must cite the M routine that " \
              "builds the return") if blank?(@cite)
        fail!("fields kind requires pieces annotations") if @kind == "fields" && @pieces.empty?
        validate_pieces!
        case @source
        when "live-capture" then validate_live!
        when "no-data" then validate_no_data!
        else validate_routine_cite!
        end
        validate_write_capture! if @write
      end

      def validate_live!
        fail!("live-capture requires verbatim raw_return") if blank?(@raw_return)
        fail!("live-capture requires release_tag") if blank?(@release_tag)
        fail!("live-capture requires captured_at") if blank?(@captured_at)
        fail!("live-capture requires sha256 of raw_return") if blank?(@sha256)
        actual = Digest::SHA256.hexdigest(@raw_return)
        fail!("sha256 does not match raw_return (#{actual}) — raw was edited " \
              "after capture") unless actual == @sha256
        # The rule the corpus exists for: a reply with no data rows is not
        # evidence of a field layout, whatever the label says. A write reply
        # with none (CANCEL's empty ERRORID recordset) is no-data too; the
        # read-back is the proof, and the capture labels source from the bytes.
        fail!("live-capture captured no data rows (raw_return is framing, an " \
              "error row, or a no-data sentinel) — re-capture against a seeded " \
              "box, or declare source: no-data") if captured_data_rows.empty?
      end

      # A real call that came back empty. Worth keeping — it records what the
      # box actually said, and re-running the capture against seeded data is
      # the fix — but it backs no piece semantics.
      def validate_no_data!
        fail!("no-data requires the verbatim raw_return it observed") if blank?(@raw_return)
        fail!("no-data requires release_tag") if blank?(@release_tag)
        fail!("no-data requires captured_at") if blank?(@captured_at)
        fail!("no-data requires sha256 of raw_return") if blank?(@sha256)
        actual = Digest::SHA256.hexdigest(@raw_return)
        fail!("sha256 does not match raw_return (#{actual})") unless actual == @sha256
        fail!("no-data carries #{captured_data_rows.length} data row(s) — this is " \
              "a live-capture, label it so") if captured_data_rows.any?
      end

      def validate_write_capture!
        unless SYNTHETIC_PERSONAS.include?(@signed_on_as.to_s)
          fail!("signed_on_as must be a synthetic persona")
        end
        entries = @read_back
        fail!("write fixture requires non-empty read_back") if !entries.is_a?(Array) || entries.empty?
        entries.each { |entry| validate_sealed_ddr_entry!(entry, "read_back") }
        validate_read_before! unless @read_before.nil?
        validate_persona_probe! unless @persona_probe.nil?
      end

      # Present read_before is evidence of prior state. It has to be a
      # non-empty list of sealed, DDR-valid GETS replies. Absent means this
      # fixture was captured before that field existed.
      def validate_read_before!
        entries = @read_before
        fail!("read_before must be non-empty") if !entries.is_a?(Array) || entries.empty?
        entries.each { |entry| validate_sealed_ddr_entry!(entry, "read_before") }
      end

      def validate_sealed_ddr_entry!(entry, label)
        fail!("#{label} entry must be a map of rpc, inputs, raw_return, sha256") unless entry.is_a?(Hash)

        raw = entry["raw_return"].to_s
        actual = Digest::SHA256.hexdigest(raw)
        fail!("#{label} sha256 does not match raw_return (#{actual})") unless actual == entry["sha256"]
        fail!("#{label} has no DDR data rows") unless WireCapture.valid_ddr_read_back_raw?(raw)
      end

      def validate_persona_probe!
        probe = @persona_probe
        fail!("persona_probe must be a map of signed_on_as, inputs, raw_return, sha256") unless probe.is_a?(Hash)

        raw = probe["raw_return"].to_s
        actual = Digest::SHA256.hexdigest(raw)
        fail!("persona_probe sha256 does not match raw_return (#{actual})") unless actual == probe["sha256"]
        unless SYNTHETIC_PERSONAS.include?(probe["signed_on_as"].to_s)
          fail!("persona_probe signed_on_as must be a synthetic persona")
        end
        fail!("persona_probe must be a booking refusal") unless WireCapture.persona_probe_refusal?(raw)
      end

      def validate_routine_cite!
        # A routine-cite fixture documents shape from source; it must not
        # CLAIM captured bytes it does not have.
        fail!("routine-cite must not carry raw_return (use example_return for " \
              "an illustrative row)") unless @raw_return.nil?
      end

      def validate_pieces!
        positions = @pieces.map(&:position)
        fail!("piece positions must be unique integers") if
          positions.any? { |p| !p.is_a?(Integer) } || positions.uniq.size != positions.size
        fail!("every piece needs at least one attribute name") if
          @pieces.any? { |p| p.attributes.empty? }
      end

      def blank?(value) = value.nil? || value.to_s.empty?

      def fail!(message)
        raise InvalidFixture, "#{@path || "(fixture)"}: #{message}"
      end
    end

    # Wraps a broker client and records each `call_rpc_raw` /
    # `call_rpc_global_array` return. The hooks are prepended onto the
    # delegate's singleton class and stay there for that object's lifetime,
    # so this must wrap a client created for the capture only, never the
    # process-global RpmsRpc.client. Scheduling and DataMapper call
    # `call_rpc`, which calls `call_rpc_raw` on the same object, so the
    # hooks sit on the delegate — forwarding the wrapper's method is not
    # enough to see those bytes. Every other method, including context
    # binds, is forwarded unchanged and is not an RPC entry. A raise from
    # the delegate is not caught, retried, or rewritten.
    class RecordingClient
      RECORDED_CALLS = {
        call_rpc_raw: :raw,
        call_rpc_global_array: :global_array
      }.freeze

      attr_reader :rpc_calls

      def initialize(delegate)
        @delegate = delegate
        @rpc_calls = []
        RECORDED_CALLS.each { |method_name, kind| install_hook(delegate, method_name, kind) }
      end

      # Same log as #rpc_calls. Context binds are not entries here: a
      # filter for kind :context stays empty, and they are not RPC calls.
      def calls
        @rpc_calls
      end

      def method_missing(name, ...)
        if @delegate.respond_to?(name)
          @delegate.public_send(name, ...)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        @delegate.respond_to?(name, include_private) || super
      end

      private

      # The hook's splat wraps one argument in an extra array. One argument
      # is that argument (an inputs array, or a DDR param Hash). Several
      # arguments are the positional list.
      def install_hook(delegate, method_name, kind)
        return unless delegate.respond_to?(method_name)

        recorded = @rpc_calls
        normalize = ->(params) { params.length == 1 ? params.first : params }
        hook = Module.new do
          define_method(method_name) do |rpc, *params, &block|
            raw = super(rpc, *params, &block)
            recorded << { kind: kind, rpc: rpc, inputs: normalize.call(params), raw: raw }
            raw
          end
        end
        delegate.singleton_class.prepend(hook)
      end
    end

    # Checks one DataMapper mapping against one fixture. Returns an array of
    # Violation structs; empty means the declared layout is consistent with
    # the captured/cited wire.
    module Contract
      Violation = Struct.new(:kind, :position, :declared, :expected, :detail, keyword_init: true) do
        def to_s
          case kind
          when :rpc_mismatch then "mapping RPC #{declared.inspect} != fixture RPC #{expected.inspect}"
          when :kind_mismatch then "mapping parses as #{declared} but capture is #{expected}"
          when :unannotated_position
            "field #{declared.inspect} at position #{position} has no captured/cited piece — " \
            "the real return carries nothing verified there"
          when :attribute_mismatch
            "position #{position} declared #{declared.inspect} but the wire carries " \
            "#{expected.join("/")} (#{detail})"
          when :type_mismatch
            "position #{position} (#{declared.inspect}) typed #{expected} but captured " \
            "raw piece #{detail.inspect} does not parse as one"
          else "#{kind} at #{position}"
          end
        end
      end

      module_function

      def check(mapping, fixture)
        return [ Violation.new(kind: :rpc_mismatch, declared: mapping.rpc_name, expected: fixture.rpc) ] if
          mapping.rpc_name != fixture.rpc

        kind = mapping_kind(mapping)
        return [ Violation.new(kind: :kind_mismatch, declared: kind, expected: fixture.kind) ] if
          kind != fixture.kind

        return [] unless %w[fields lines].include?(fixture.kind)

        declared = fixture.kind == "lines" ? mapping.line_fields : mapping.fields
        declared.flat_map { |field| field_violations(field, fixture) }
      end

      def mapping_kind(mapping)
        return "scalar" if mapping.scalar?
        return "text_blob" if mapping.text_blob?
        # One field per LINE, not per caret piece (line_field). Without this
        # a line-based mapping classified as "fields" and its line numbers
        # were compared against caret positions — the wrong axis, and
        # silently, since both are small integers.
        return "lines" if mapping.line_fields?

        "fields"
      end

      def field_violations(field, fixture)
        piece = fixture.piece_at(field.position)
        unless piece
          return [ Violation.new(kind: :unannotated_position, position: field.position,
                                 declared: field.attribute) ]
        end

        violations = []
        unless piece.attributes.include?(field.attribute.to_s)
          violations << Violation.new(kind: :attribute_mismatch, position: field.position,
                                      declared: field.attribute, expected: piece.attributes,
                                      detail: fixture.cite)
        end
        violations + raw_type_violations(field, fixture)
      end

      # Validate a typed field against the live-captured raw pieces: every
      # non-empty value at that position must actually parse as the declared
      # type. This is the check that turns "98.6" under a :fileman_date
      # declaration red regardless of annotations.
      def raw_type_violations(field, fixture)
        # A lines reply is ONE record whose fields are its lines; a fields
        # reply is many records, each split on carets. Reading one as the
        # other is the whole hazard this kind exists to prevent.
        return line_type_violations(field, fixture) if fixture.kind == "lines"

        # captured_data_rows, not captured_rows: a GLOBAL ARRAY typed header
        # is not a field row, and neither is a sentinel or an error line.
        fixture.captured_data_rows.filter_map do |row|
          raw = row.split("^", -1)[field.position]
          next if raw.nil? || raw.empty? || raw_conforms?(raw, field.type)

          Violation.new(kind: :type_mismatch, position: field.position,
                        declared: field.attribute, expected: field.type, detail: raw)
        end
      end

      # The captured lines ARE the field values, indexed by line number -- so
      # index the view that preserves blank lines, not the compacted one.
      def line_type_violations(field, fixture)
        raw = fixture.positional_rows[field.position]
        return [] if raw.nil? || raw.empty? || raw_conforms?(raw, field.type)

        [ Violation.new(kind: :type_mismatch, position: field.position,
                        declared: field.attribute, expected: field.type, detail: raw) ]
      end

      def raw_conforms?(raw, type)
        case type
        when :integer then raw.match?(/\A-?\d+\z/)
        when :float then Float(raw, exception: false) ? true : false
        when :boolean then [ "0", "1" ].include?(raw) || raw.match?(/\A(yes|no)\z/i)
        when :fileman_date then !FilemanDateParser.parse_date(raw).nil?
        when :fileman_datetime
          # Ask exactly what the mapper asks. FileMan datetime values may omit
          # the time part, which parse_datetime_or_date already allows -- but
          # falling back to parse_date accepted values the mapper rejects:
          # "3260607.9" has an invalid time fraction, so parse_date returns a
          # Date while parse_datetime_or_date returns nil. The gate passed a
          # capture whose mapped datetime would be lost.
          !FilemanDateParser.parse_datetime_or_date(raw).nil?
        else true
        end
      end
    end

    # -- Curated capture targets ---------------------------------------------
    #
    # Piece semantics below are CITED to the M routines serving these RPCs in
    # the bcer-9.0-ydb corpus (rpms-ops/data/standup/bcer-9.0-ydb/r/) — the
    # same corpus the registration/DDR mappings were verified against. The
    # capture task stamps them into the fixtures; the contract test then
    # gates mappings against the committed fixtures.
    #
    # Inputs use only synthetic build-time data. Chart reads (ORWPT ID INFO,
    # BEHOPTCX PTINFO, BEHOPTPC GETBDP, ORQQPL LIST, ORQQAL LIST, ORWPS
    # ACTIVE, ORQQVI VITALS) call seed patient DFN 2, which has chart data
    # on the pinned build. ORWPT CWAD is routine-cited (inputs nil) until a
    # live capture as PROV123 lands. Other entries stay on DFN 8
    # DEMOPATIENT,REG2244. Public repo: never a real patient, partner, or tribe.
    CATALOG = [
      CatalogEntry.new(
        rpc: "ORQQVI VITALS", mapping: :vitals, kind: "fields", mode: :live,
        # Vital.for_patient sends the DFN alone: start and end are optional
        # and omitted, which FASTVIT reads as all time (ORQQVI.m:74-78).
        inputs: [ "2" ],
        # FASTVIT, not VITALS. The #8994 registry sends "ORQQVI VITALS" to
        # FASTVIT (.broker_dumps_8994_20260607.txt:565), and FASTVIT's header
        # is "ien^type^RATE^date/time taken" -- value at 2, datetime at 3.
        # VITALS^ORQQVI serves "ORQQVI VITALS FOR DATE RANGE" and swaps those
        # two, which is precisely the confusion that produced the shipped
        # mapping. Citing VITALS here would make `rake wire:capture` overwrite
        # the committed FASTVIT fixture with the other RPC's layout and
        # reintroduce the defect this gate exists to catch.
        # Pieces 5-7 are the mapping's display, metric conversion, and
        # qualifiers (ORQQVI.m:180-223, :224) — same positions the :vitals
        # mapping declares.
        cite: "FASTVIT^ORQQVI (ORQQVI.m:61-84): header 'vital measurement " \
              "ien^vital type^rate^date/time taken'; registry mapping at " \
              ".broker_dumps_8994_20260607.txt:565 \"ORQQVI VITALS^FASTVIT^ORQQVI\"; " \
              "DISPLAY^METRIC_DISPLAY^QUALIFIERS (ORQQVI.m:180-223, :224)",
        pieces: [
          Piece.new(position: 0, attributes: [ "measurement_ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "type" ]),
          Piece.new(position: 2, attributes: [ "value", "rate" ]),
          Piece.new(position: 3, attributes: [ "recorded_date", "recorded_datetime" ],
                    fileman_type: "fileman_datetime"),
          Piece.new(position: 4, attributes: [ "display" ]),
          Piece.new(position: 5, attributes: [ "metric_display" ]),
          Piece.new(position: 6, attributes: [ "qualifiers" ])
        ],
        note: "The mapping this gate exists for: shipped as TYPE^VALUE^UNITS^DATE " \
              "with green mock tests; FASTVIT's wire is IEN^TYPE^VALUE^DATETIME^" \
              "DISPLAY^METRIC_DISPLAY^QUALIFIERS."
      ),
      CatalogEntry.new(
        rpc: "ORQQPL LIST", mapping: :problem_list, kind: "fields", mode: :live,
        # Problem.for_patient sends STATUS "" (all). LIST^ORQQPL reads STATUS
        # unconditionally (ORQQPL.m:3-5): "A" active, "I" inactive, "" all.
        # DFN 2's two problems are active ("A"), so the all-status read has rows.
        inputs: [ "2", "" ],
        cite: "LIST^ORQQPL (ORQQPL.m:3-18) reorders LIST^GMPLUTL3 rows " \
              "(GMPLUTL3.m:76-99: IEN^STATUS^NARRATIVE^ICD^ONSET^MODIFIED^SC^SP^" \
              "PRIORITY^TRANSCRIBED^SCT-C^SCT-D) as in1^in3^in2^in4^in5^in6^in7^" \
              "in8^in10^in9^''^DETAIL; piece 13 '#' alone marks inactive-ICD " \
              "whatever piece 4 holds (ORQQPL.m:15-16), and $$ICDDX 'Invalid Code' " \
              "text is never a code; '^No problems found.' sentinel line 16",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "description", "narrative" ]),
          Piece.new(position: 2, attributes: [ "status" ]),
          Piece.new(position: 3, attributes: [ "icd_code" ]),
          Piece.new(position: 4, attributes: [ "onset_date" ], fileman_type: "fileman_date"),
          Piece.new(position: 5, attributes: [ "last_modified" ], fileman_type: "fileman_date"),
          Piece.new(position: 6, attributes: [ "service_connected" ]),
          Piece.new(position: 7, attributes: [ "special_exposures" ]),
          Piece.new(position: 8, attributes: [ "transcribed" ]),
          Piece.new(position: 9, attributes: [ "priority" ]),
          Piece.new(position: 10, attributes: [ "reserved" ]),
          Piece.new(position: 11, attributes: [ "detail_flag" ]),
          # Piece 13. "#" on the inactive-ICD branch (ORQQPL.m:15-16).
          Piece.new(position: 12, attributes: [ "inactive_icd" ])
        ]
      ),
      # Allergy.assessment / for_patient send the DFN only (LIST^ORQQAL).
      CatalogEntry.new(
        rpc: "ORQQAL LIST", mapping: :allergy_list, kind: "fields", mode: :live,
        inputs: [ "2" ],
        cite: "LIST^ORQQAL (ORQQAL.m:8,14 over EN1^GMRAOR1): ALLERGY_IEN^AGENT^" \
              "SEVERITY^SIGNS (\";\"-joined — ORQQAL.m:18-21); assessment sentinels " \
              "ORQQAL.m:12-15",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ]),
          Piece.new(position: 1, attributes: [ "allergen", "agent" ]),
          Piece.new(position: 2, attributes: [ "severity" ]),
          Piece.new(position: 3, attributes: [ "signs" ])
        ]
      ),
      # Medication.active_for_patient sends the DFN only. ACTIVE(LST,DFN):
      # LST is the broker return array (ORWPS.m:17). The seed has no active
      # medications, so a capture of this entry is no-data.
      CatalogEntry.new(
        rpc: "ORWPS ACTIVE", mapping: :medication_active, kind: "text_blob", mode: :live,
        inputs: [ "2" ],
        cite: "ACTIVE^ORWPS (ORWPS.m:17-51): one '~' header per medication " \
              "(~TYPE^FIELDS, ORWPS.m:45) then instruction lines and 't' comment " \
              "lines until the next '~' (ORWPS.m:45-48). Text blob — :medication_active " \
              "does not split caret pieces.",
        pieces: [],
        note: "No active medications in the seed. An empty reply is no-data, not a layout."
      ),
      CatalogEntry.new(
        rpc: "ORWPT SELECT", mapping: :patient_select, kind: "fields", mode: :live,
        inputs: [ "8" ],
        cite: "SELECT^ORWPT (ORWPT.m:42-67): header lines 43-46 NAME^SEX^DOB^SSN^" \
              "LOCIEN^LOCNM^RMBD^CWAD^SENSITIVE^ADMITTED^CONV^SC^SC%^ICN^AGE^TS",
        pieces: [
          Piece.new(position: 0, attributes: [ "name" ]),
          Piece.new(position: 1, attributes: [ "sex" ]),
          Piece.new(position: 2, attributes: [ "dob" ], fileman_type: "fileman_date"),
          Piece.new(position: 3, attributes: [ "ssn" ]),
          Piece.new(position: 4, attributes: [ "location_ien" ]),
          Piece.new(position: 5, attributes: [ "location_name" ]),
          Piece.new(position: 6, attributes: [ "room_bed" ]),
          Piece.new(position: 7, attributes: [ "cwad" ]),
          Piece.new(position: 8, attributes: [ "sensitive" ]),
          Piece.new(position: 9, attributes: [ "admitted" ]),
          Piece.new(position: 10, attributes: [ "conversion" ]),
          Piece.new(position: 11, attributes: [ "service_connected" ]),
          Piece.new(position: 12, attributes: [ "sc_percent" ]),
          Piece.new(position: 13, attributes: [ "icn" ]),
          Piece.new(position: 14, attributes: [ "age" ], fileman_type: "integer"),
          Piece.new(position: 15, attributes: [ "treating_specialty" ])
        ]
      ),
      # Patient.find sends the DFN only (IDINFO^ORWPT).
      CatalogEntry.new(
        rpc: "ORWPT ID INFO", mapping: :patient_id_info, kind: "fields", mode: :live,
        inputs: [ "2" ],
        cite: "IDINFO^ORWPT (ORWPT.m:6-11): header line 7 PID^DOB^SEX^VET^SC%^" \
              "WARD^RM-BED^NAME; REC construction line 10",
        pieces: [
          Piece.new(position: 0, attributes: [ "ssn", "pid" ]),
          Piece.new(position: 1, attributes: [ "dob" ], fileman_type: "fileman_date"),
          Piece.new(position: 2, attributes: [ "sex" ]),
          Piece.new(position: 3, attributes: [ "veteran" ]),
          Piece.new(position: 4, attributes: [ "sc_percent" ]),
          Piece.new(position: 5, attributes: [ "ward_location" ]),
          Piece.new(position: 6, attributes: [ "room_bed" ]),
          Piece.new(position: 7, attributes: [ "name" ])
        ]
      ),
      # Patient.brief_header sends the DFN to each of these three
      # (PTINFO^BEHOPTCX, GETBDP^BEHOPTPC, CWAD^ORWPT). ORWPT CWAD is
      # routine-cited below: no live capture as PROV123 on the pinned build.
      CatalogEntry.new(
        rpc: "BEHOPTCX PTINFO", mapping: :patient_ptinfo, kind: "fields", mode: :live,
        inputs: [ "2" ],
        cite: "PTINFO^BEHOPTCX (BEHOPTCX.m:7-31): NAME^SEX^DOB^SSN^...^MRN^...^" \
              "DESIGNATED_TEAM^PRIMARY_PROVIDER — 20-piece identity bundle, no .13 data",
        pieces: [
          Piece.new(position: 0, attributes: [ "name" ]),
          Piece.new(position: 1, attributes: [ "sex" ]),
          Piece.new(position: 2, attributes: [ "dob_raw" ]),
          Piece.new(position: 3, attributes: [ "ssn" ]),
          Piece.new(position: 10, attributes: [ "mrn" ]),
          Piece.new(position: 16, attributes: [ "designated_team" ]),
          Piece.new(position: 17, attributes: [ "primary_provider" ])
        ]
      ),
      CatalogEntry.new(
        rpc: "BEHOPTPC GETBDP", mapping: :patient_designated_provider, kind: "fields", mode: :live,
        inputs: [ "2" ],
        cite: "GETBDP^BEHOPTPC (BEHOPTPC.m:73): LABEL^PROVIDER_NAME^PROVIDER_IEN^TITLE^DATE",
        pieces: [
          Piece.new(position: 0, attributes: [ "label" ]),
          Piece.new(position: 1, attributes: [ "provider_name" ]),
          Piece.new(position: 2, attributes: [ "provider_ien" ], fileman_type: "integer"),
          Piece.new(position: 3, attributes: [ "title" ]),
          Piece.new(position: 4, attributes: [ "date_raw" ])
        ],
        note: "Empty designated provider in the seed. An empty reply is no-data, not a layout."
      ),
      # CWAD^ORWPT, the scalar Patient.brief_header already calls. The cite is
      # that mapping's existing citation (registry formals Y,DFN) — no routine
      # line numbers. Routine-cited until a live PROV123 capture lands.
      CatalogEntry.new(
        rpc: "ORWPT CWAD", mapping: :patient_cwad, kind: "scalar", mode: :routine_cite,
        inputs: nil,
        cite: "CWAD^ORWPT (registry formals Y,DFN; the :patient_cwad mapping's " \
              "existing citation, no routine line numbers): one scalar. Letters " \
              "present mean C=Crises, W=Warnings, A=Allergies, D=Advance Directives; " \
              "empty means none",
        pieces: [],
        note: "Routine-cited only until a live capture as PROV123 on the pinned " \
              "build lands, so its brief_header flags are not proven."
      ),
      CatalogEntry.new(
        rpc: "BGOVMSR LAST", mapping: :latest_measurements, kind: "fields", mode: :live,
        inputs: [ "8^^" ],
        cite: "LAST^BGOVMSR (BGOVMSR.m:3-35): row format line 35 " \
              "TYPE^VALUE^DATE_DISPLAY^MEASUREMENT_IEN^VISIT_IEN^LOCKED",
        pieces: [
          Piece.new(position: 0, attributes: [ "type" ]),
          Piece.new(position: 1, attributes: [ "value" ]),
          Piece.new(position: 2, attributes: [ "date_display" ]),
          Piece.new(position: 3, attributes: [ "measurement_ien" ], fileman_type: "integer"),
          Piece.new(position: 4, attributes: [ "visit_ien" ], fileman_type: "integer"),
          Piece.new(position: 5, attributes: [ "locked" ], fileman_type: "boolean")
        ]
      ),
      CatalogEntry.new(
        rpc: "BGOVMSR GET", mapping: :visit_measurements, kind: "fields", mode: :live,
        inputs: [ "1^0" ],
        cite: "GET^BGOVMSR (BGOVMSR.m:41-77): format-0 row TYPE^VALUE^DATE_DISPLAY^" \
              "MEASUREMENT_IEN^VISIT_IEN^PROVIDER_NAME^LOCKED; CDT display date " \
              "CDT^BGOVMSR:79-86",
        pieces: [
          Piece.new(position: 0, attributes: [ "type" ]),
          Piece.new(position: 1, attributes: [ "value" ]),
          Piece.new(position: 2, attributes: [ "date_display" ]),
          Piece.new(position: 3, attributes: [ "measurement_ien" ], fileman_type: "integer"),
          Piece.new(position: 4, attributes: [ "visit_ien" ], fileman_type: "integer"),
          Piece.new(position: 5, attributes: [ "provider_name" ]),
          Piece.new(position: 6, attributes: [ "locked" ], fileman_type: "boolean")
        ]
      ),
      # Pieces 1-5 are VSIT("LOC"/"VDT"/"SVC"/"PAT"/"VID") from
      # LOOKUP^VSIT(IEN,"I") — VISIT #9000010 fields .22 (HOSPITAL LOCATION),
      # .01 (VISIT/ADMIT DATE&TIME), .07 (SERVICE CATEGORY), .05 (PATIENT
      # NAME) and 15001 (VISIT ID), per FLD^VSITFLD (VSITFLD.m:15-33). None
      # of them is an encounter status or a ward: the old :status / :ward
      # labels at 2 and 4 were belief, and are no longer accepted here (#211).
      CatalogEntry.new(
        rpc: "BEHOENCX GETVISIT", mapping: :encounter_visit, kind: "fields", mode: :live,
        inputs: [ "1" ],
        cite: "GETVISIT^BEHOENCX (BEHOENCX.m:5,8-15): 'Returns hosp loc^visit date^" \
              "service category^dfn^visit id^locked' = VSIT(\"LOC\",\"VDT\",\"SVC\"," \
              "\"PAT\",\"VID\") from LOOKUP^VSIT (#9000010 fields .22/.01/.07/.05/15001, " \
              "FLD^VSITFLD: VSITFLD.m:15-33) then $$ISLOCKED (BEHOENCX.m:280-290)",
        pieces: [
          Piece.new(position: 0, attributes: [ "location_ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "datetime_raw" ], fileman_type: "fileman_datetime"),
          Piece.new(position: 2, attributes: [ "service_category" ]),
          Piece.new(position: 3, attributes: [ "patient_dfn" ], fileman_type: "integer"),
          Piece.new(position: 4, attributes: [ "visit_id" ]),
          Piece.new(position: 5, attributes: [ "locked" ], fileman_type: "boolean")
        ]
      ),
      # ORQQPXRM REMINDERS APPLICABLE (#238): live-mode, but committed as a
      # routine-cite (CITE_ONLY) until a capture runs against a rung whose
      # cover-sheet reminder parameters (ORQQPX SEARCH ITEMS / ORQQPX COVER
      # SHEET REMINDERS) are populated -- without them REMLIST yields no
      # reminders and the reply is empty. Inputs: DFN 8, no location.
      CatalogEntry.new(
        rpc: "ORQQPXRM REMINDERS APPLICABLE", mapping: :reminders_applicable, kind: "fields",
        mode: :live,
        inputs: [ "8", "" ],
        cite: "APPL^ORQQPXRM (ORQQPXRM.m:10-11) -> EVALCOVR^ORQQPX (ORQQPX.m:232-236) " \
              "-> ALIST/AVAL^PXRMRPCA (PXRMRPCA.m:42-82): rows :76 (applicable) and " \
              ":80 (not applicable) IEN^PRINT NAME^DUE DATE^LAST DONE^PRIORITY^" \
              "DUE FLAG^DIALOG^^^^DIALOG WIPE; due date is a FileMan date or " \
              "'DUE NOW'/'CNBD'/'DISABLED'/empty (PXRMDATE.m:119,129,132; PXRM.m:62)",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "print_name" ]),
          Piece.new(position: 2, attributes: [ "due_date" ]),
          Piece.new(position: 3, attributes: [ "last_done" ], fileman_type: "fileman_date"),
          Piece.new(position: 4, attributes: [ "priority" ], fileman_type: "integer"),
          Piece.new(position: 5, attributes: [ "due_flag" ], fileman_type: "integer"),
          Piece.new(position: 6, attributes: [ "dialog" ], fileman_type: "boolean"),
          Piece.new(position: 10, attributes: [ "dialog_wipe" ], fileman_type: "boolean")
        ],
        note: "Shape from routine source only: no live capture yet. ADR 0003 sections 2 " \
              "and 5 keep the mapping unverified until one lands (#238)."
      ),
      # BEHOENCX FETCH with CREATE=0 is a read: VSTR2VIS^BEHOENCX takes the
      # visit IEN from the 4th VSTR piece and never reaches FNDVIS
      # (BEHOENCX.m:107-111), and even a 3-piece VSTR runs FNDVIS with
      # IN("NEVER ADD")=1 (BEHOENCX.m:80). The inputs name the one visit the
      # rung carries at build time (visit IEN 1 of the build's test patient,
      # DFN 2, at hospital location 6) by DFN and extended VSTR. The capture
      # runs as PROV123 on the pinned build.
      CatalogEntry.new(
        rpc: "BEHOENCX FETCH", mapping: :encounter_fetch, kind: "fields", mode: :live,
        inputs: [ "2", "6;3260825.09;A;1", "", "0" ],
        cite: "FETCH^BEHOENCX (BEHOENCX.m:24-47): header lines 30-31 LOCNAME^LOCABBR^" \
              "ROOMBED^PROVIEN^PROVNAME^VISITIEN^VISITID^LOCKED^ERRORTXT; pieces 1-2 " \
              "^SC(LOC,0) (line 41), 3 ^DPT(DFN,.101) (42), 4 PRV (43), 5 ^VA(200,PRV,0) " \
              "(44), 6-8 only when IEN>0 (45), 9 only on error (46)",
        pieces: [
          Piece.new(position: 0, attributes: [ "location_name" ]),
          Piece.new(position: 1, attributes: [ "location_abbrev" ]),
          Piece.new(position: 2, attributes: [ "room_bed" ]),
          Piece.new(position: 3, attributes: [ "provider_ien" ], fileman_type: "integer"),
          Piece.new(position: 4, attributes: [ "provider_name" ]),
          Piece.new(position: 5, attributes: [ "visit_ien" ], fileman_type: "integer"),
          Piece.new(position: 6, attributes: [ "visit_id" ]),
          Piece.new(position: 7, attributes: [ "locked" ], fileman_type: "boolean"),
          Piece.new(position: 8, attributes: [ "error" ])
        ],
        note: "Params positionally FETCH(DATA,DFN,VSTR,PRV,CREATE) (registry formals " \
              "DATA,DFN,VSTR,PRV,CREATE). CREATE=0 is the read form; CREATE=1/-1 " \
              "creates a VISIT and is never sent by the capture task."
      ),
      # BEHOENCX CHKVISIT returns one COMPONENT^TEXT row per check. CV1
      # overwrites piece 1 (the status code) with the component name.
      # Visit 1 (seed DFN 2) has a POV and no note, so the capture stops
      # before SEND and files no alert.
      CatalogEntry.new(
        rpc: "BEHOENCX CHKVISIT", mapping: :encounter_chkvisit, kind: "fields", mode: :live,
        inputs: [ "1" ],
        cite: "CHKVISIT^BEHOENCX (BEHOENCX.m:329-337) and NOPOV/NOEMC^BEHOXQPC " \
              "(BEHOXQPC.m:5-14, 32-41): one COMPONENT^TEXT row per check; CV1 " \
              "overwrites piece 1 (the status code) with the component name",
        pieces: [
          Piece.new(position: 0, attributes: [ "component" ]),
          Piece.new(position: 1, attributes: [ "message" ])
        ],
        note: "Visit 1 (seed DFN 2) has a POV and no note, so NOPOV returns at " \
              "line 10 and NOEMC at line 37, before SEND — the capture files no alert."
      ),
      # BEHOVM2 VUNITS is deliberately NOT live-captured: on the
      # bcer-9.0-ydb rung the call M-faults server-side and takes the
      # single ZBROKER job down with it (observed 2026-09-02: broker
      # closed the connection mid-call and the :9100 listener died).
      # Routine-cite until the fault is understood; never point the
      # capture task at it again without fixing that first.
      CatalogEntry.new(
        rpc: "BEHOVM2 VUNITS", mapping: :vital_units, kind: "fields", mode: :routine_cite,
        inputs: nil,
        cite: "VUNITS^BEHOVM2 (BEHOVM2.m:186-196) -> UNITS^BEHOVM: " \
              "'US unit^LO^HI^Metric unit^LO^HI'; unknown type -> empty reply",
        pieces: [
          Piece.new(position: 0, attributes: [ "us_unit" ]),
          Piece.new(position: 1, attributes: [ "us_low" ]),
          Piece.new(position: 2, attributes: [ "us_high" ]),
          Piece.new(position: 3, attributes: [ "metric_unit" ]),
          Piece.new(position: 4, attributes: [ "metric_low" ]),
          Piece.new(position: 5, attributes: [ "metric_high" ])
        ],
        note: "Live call faults the bcer-9.0-ydb broker (listener dies) — " \
              "shape verified from routine source only until that is fixed."
      ),
      CatalogEntry.new(
        rpc: "DDR GETS ENTRY DATA", mapping: :ddr_gets_entry_data, kind: "text_blob", mode: :live,
        inputs: [ { "FILE" => "2", "IENS" => "8,", "FIELDS" => ".131;.132;.134;.133",
                    "FLAGS" => "IE" } ],
        cite: "GETSC^DDR2 (DDR2.m:22-43,61): '[Data]' then " \
              "FILE^IEN^FIELD^INTERNAL^EXTERNAL rows; '[ERROR]' block on failure",
        pieces: [],
        note: "text_blob mapping — the gate checks reply-kind consistency and " \
              "records the real reply grammar; row parsing lives in DdrFileman.gets_entry."
      ),
      # ORWPCE reads (#286). Inputs are the first call in each unmapped
      # capture (synthetic notes on the pinned image). A gated fixture holds
      # one reply; the other calls stay in test/fixtures/wire_captures/unmapped
      # because the spec still reads them there.
      CatalogEntry.new(
        rpc: "ORWPCE GET VISIT", mapping: :pce_get_visit, kind: "scalar", mode: :live,
        inputs: [ "3", "4", "" ],
        cite: "GETVISIT^ORWPCE2 (ORWPCE2.m:64-67): note IEN < 1 looks the visit up " \
              "with $$GETENC^PXAPI(DFN,$P(VSITSTR,\";\",2),$P(VSITSTR,\";\")); otherwise " \
              "VISIT=$P(^TIU(8925,IEN,0),U,3) and DFN is ignored. -1 is no visit",
        pieces: [],
        note: "Scalar visit IEN. -1 and an empty reply are not an IEN."
      ),
      CatalogEntry.new(
        rpc: "ORWPCE HASVISIT", mapping: :pce_has_visit, kind: "scalar", mode: :live,
        inputs: [ "3", "4", "", "" ],
        cite: "HASVISIT^ORWPCE (ORWPCE.m:118-123): ORY starts -1; a positive note " \
              "reads ^TIU(8925,IEN,0) piece 3, else $$GETENC^PXAPI(DFN,ORDTE,ORLOC). " \
              "A positive visit is $$VST2APPT^PXAPI (VST2APPT^PXUTL1, PXUTL1.m:65-78): " \
              "0 stand-alone, 1 appointment-linked, -1 no visit",
        pieces: [],
        note: "Scalar -1/0/1. Not a boolean: 0 is a visit."
      ),
      CatalogEntry.new(
        rpc: "ORWPCE NOTEVSTR", mapping: :pce_note_visit_string, kind: "scalar", mode: :live,
        inputs: [ "3" ],
        cite: "NOTEVSTR^ORWPCE (ORWPCE.m:112-116): LOC;FileMan datetime;service category " \
              "from $$VSTRBLD^TIUSRVP(VISIT) when node 12 piece 7 is set, else " \
              "$P(X12,U,11)_\";\"_$P(X0,U,7)_\";\"_$P(X0,U,13)",
        pieces: [],
        note: "One visit string, not caret fields. parse_visit_string splits on ';'."
      ),
      CatalogEntry.new(
        rpc: "ORWPCE GET IMMUNIZATION TYPE", mapping: :pce_immunization_types, kind: "fields",
        mode: :live,
        inputs: [],
        cite: "IMMTYPE^ORWPCE2 (ORWPCE2.m:17-22): IEN^NAME of active ^AUTTIMM entries " \
              "(0-node piece 7 = 0). Optional ORDT; this call sends none",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "name" ])
        ]
      ),
      CatalogEntry.new(
        rpc: "ORWPCE GET SKIN TEST TYPE", mapping: :pce_skin_test_types, kind: "fields",
        mode: :live,
        inputs: [],
        cite: "SKTYPE^ORWPCE2 (ORWPCE2.m:25-30): IEN^NAME of active ^AUTTSK entries " \
              "(0-node piece 3 = 0)",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "name" ])
        ]
      ),
      CatalogEntry.new(
        rpc: "ORWPCE GET EXAM TYPE", mapping: :pce_exam_types, kind: "fields", mode: :live,
        inputs: [],
        cite: "EXAMTYPE^ORWPCE2 (ORWPCE2.m:51-53): IEN^NAME of active ^AUTTEXAM entries " \
              "(0-node piece 4 = 0)",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "name" ])
        ]
      ),
      CatalogEntry.new(
        rpc: "ORWPCE GET EDUCATION TOPICS", mapping: :pce_education_topics, kind: "fields",
        mode: :live,
        inputs: [],
        cite: "EDTTYPE^ORWPCE2 (ORWPCE2.m:33-35): IEN^NAME of active ^AUTTEDT entries " \
              "(0-node piece 3 = 0)",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "name" ])
        ]
      ),
      CatalogEntry.new(
        rpc: "ORWPCE GET HEALTH FACTORS TY", mapping: :pce_health_factor_types, kind: "fields",
        mode: :live,
        inputs: [],
        cite: "HFTYPE^ORWPCE2 (ORWPCE2.m:38-48): IEN^NAME, and when ADDCATS " \
              "IEN^NAME^$P(0-node,U,10)^$P(0-node,U,3). This call sends no ADDCATS, " \
              "so the category pieces are empty",
        pieces: [
          Piece.new(position: 0, attributes: [ "ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "name" ]),
          Piece.new(position: 2, attributes: [ "category" ]),
          Piece.new(position: 3, attributes: [ "category_ien" ], fileman_type: "integer")
        ]
      ),
      CatalogEntry.new(
        rpc: "ORWPCE PCE4NOTE", mapping: :pce_for_note, kind: "text_blob", mode: :live,
        inputs: [ "3", "4", "" ],
        cite: "PCE4NOTE^ORWPCE3 (ORWPCE3.m:4-22): HDR^AllowEdit^CPTRequired^VStr^Author^hasCPT, " \
              "then VST/PRV/POV/CPT/IMM/SK/PED/HF/XAM/TRT/COM lines (:32-194). Note IEN < 1 " \
              "uses the visit string; otherwise the visit comes from the TIU note",
        pieces: [],
        note: "text_blob: record types do not share one caret layout. parse_note_bundle " \
              "models the lines; an unknown type is an opaque record."
      ),

      # TIU note writes (#564 / #224). mode :write, so live? is false and a read
      # capture never calls them. Cites are the lines already named in
      # ProgressNote, ESignature, and stock_vista — no line numbers beyond those.
      # CREATE inputs are the MAKE actuals. The other inputs are a note-IEN
      # placeholder; a WRITES=1 fixture stores the captured parameters instead.
      CatalogEntry.new(
        rpc: "TIU CREATE RECORD", mapping: :tiu_create_record, kind: "scalar", mode: :write,
        inputs: [ NoteWriteFlow::DFN, NoteWriteFlow::TITLE_IEN, "", "", NoteWriteFlow::VISIT_IEN ].freeze,
        cite: "MAKE^TIUSRVP (TIUSRVP.m:7, 59-63): SUCCESS is the new IEN (TIUSRVP.m:63) " \
              "or \"0^message\" (TIUSRVP.m:59, 62). Actuals DFN, TITLE, VDT, VLOC, VSIT; " \
              "VDT and VLOC empty, visit in VSIT (TIUSRVP.m:24-31). VSTRBLD is TIUSRVP.m:80-85",
        pieces: [],
        note: "Write RPC. Seed patient DFN 4, title 248, visit 4. Called only by " \
              "NoteWriteFlow when WRITES=1 is allowed."
      ),
      CatalogEntry.new(
        rpc: "TIU LOCK RECORD", mapping: :tiu_lock_record, kind: "scalar", mode: :write,
        inputs: [ "<note ien>" ].freeze,
        cite: "LOCK^TIUSRVP (TIUSRVP.m:210-212): ERR=0 when the lock is held " \
              "(TIUSRVP.m:211); \"1^ Another session has this record locked.\" when it " \
              "is not (TIUSRVP.m:212)",
        pieces: [],
        note: "Write RPC. Catalog input is a note-IEN placeholder; a live fixture " \
              "records the captured IEN."
      ),
      CatalogEntry.new(
        rpc: "TIU SET DOCUMENT TEXT", mapping: :tiu_set_document_text, kind: "scalar", mode: :write,
        inputs: [ "<note ien>" ].freeze,
        cite: "SETTEXT^TIUSRVPT (TIUSRVPT.m:7-38): TIUX(\"HDR\") is PAGE^PAGES " \
              "(TIUSRVPT.m:12), body is TIUX(\"TEXT\",n,0) (TIUSRVPT.m:18). Success is " \
              "TIUDA^PAGE^PAGES (TIUSRVPT.m:38); failure is \"0^0^0^message\" " \
              "(TIUSRVPT.m:10, 14)",
        pieces: [],
        note: "Write RPC. Catalog input is a note-IEN placeholder; a live fixture " \
              "records the captured IEN and TEXT list."
      ),
      CatalogEntry.new(
        rpc: "TIU GET RECORD TEXT", mapping: :tiu_get_record_text, kind: "text_blob", mode: :write,
        inputs: [ "<note ien>" ].freeze,
        cite: "TGET^TIUSRVR1 (REMOTE PROCEDURE registration for TIU GET RECORD TEXT: " \
              "tag TGET, routine TIUSRVR1, in " \
              "data/fingerprints/references/bcer-9.0-20261012-e7923a4-ydb.yml and " \
              "data/inventories/bcer-9.0-20261012-e7923a4-ydb/" \
              "bcer-9.0-20261012-e7923a4-ydb-broker_8994.txt). Text blob. This repo " \
              "does not cite TGET line numbers",
        pieces: [],
        note: "Read-back of the note just written. Catalog input is a note-IEN " \
              "placeholder; a live fixture records the captured IEN. Evidence requires " \
              "the note body after the header blank line."
      ),
      CatalogEntry.new(
        rpc: "TIU UNLOCK RECORD", mapping: :tiu_unlock_record, kind: "scalar", mode: :write,
        inputs: [ "<note ien>" ].freeze,
        cite: "UNLOCK^TIUSRVP (TIUSRVP.m:214-215): always ERR=0",
        pieces: [],
        note: "Write RPC. Catalog input is a note-IEN placeholder; a live fixture " \
              "records the captured IEN."
      ),
      CatalogEntry.new(
        rpc: "TIU SIGN RECORD", mapping: :tiu_sign_record, kind: "scalar", mode: :write,
        inputs: [ "<note ien>" ].freeze,
        cite: "SIGN^TIUSRVP (ESignature: TIU SIGN RECORD is SIGN(ERR,TIUDA,TIUX)^TIUSRVP; " \
              "params are the note IEN and the XWB-encrypted signature code; the signer " \
              "is the session DUZ and is not sent). This repo does not cite a SIGN line number",
        pieces: [],
        note: "Write RPC. The signature code is never stored. A live fixture's second " \
              "input is the withheld marker; the catalog input is only a note-IEN placeholder."
      ),

      # Agg.registration_candidates sends this possible-match form. The first
      # argument is Agg.encode_parms of AGGPTLNM/FNM/MNM/SFX/DOB for
      # USER / TEST / 05/05/1985 ($C(28) between pairs, empty middle and
      # suffix included). Kept as a literal so this file does not load Agg.
      CatalogEntry.new(
        rpc: "AGG LOOKUP PATIENTS", mapping: :patient_lookup_agg, kind: "fields",
        mode: :live, context: "AGGRPC",
        inputs: [
          "AGGPTLNM=USER\x1cAGGPTFNM=TEST\x1cAGGPTMNM=\x1cAGGPTSFX=\x1cAGGPTDOB=05/05/1985",
          "",
          "1",
          "1"
        ],
        cite: "FND^AGGPTLKP (AGGPTLKP.m:33-45, the $C(28) structured branch, name OR " \
              "DOB, LST2) and HDR^AGGPTLKP (AGGPTLKP.m:174): typed header " \
              "DFN^PATIENT_NAME^HRN^SSN^DOB^DOD^SENS_FLAG^ALIAS^INACTIVE, optional " \
              "COMM^MOMDN (AGGPTLKP.m:175); data rows AGGPTLKP.m:208",
        pieces: [
          Piece.new(position: 0, attributes: [ "dfn_raw" ]),
          Piece.new(position: 1, attributes: [ "name" ]),
          Piece.new(position: 2, attributes: [ "hrn" ]),
          Piece.new(position: 3, attributes: [ "ssn_raw" ]),
          Piece.new(position: 4, attributes: [ "dob" ]),
          Piece.new(position: 5, attributes: [ "dod" ]),
          Piece.new(position: 6, attributes: [ "sens_flag" ]),
          Piece.new(position: 7, attributes: [ "alias" ]),
          Piece.new(position: 8, attributes: [ "inactive_raw" ]),
          Piece.new(position: 9, attributes: [ "community" ]),
          Piece.new(position: 10, attributes: [ "mothers_maiden_name" ])
        ],
        note: "Seed patient DFN 2 (synthetic USER,TEST), the possible-match form the " \
              "registration duplicate guard sends; the free-text find form is the same " \
              "RPC and reply layout."
      )
    ].freeze

    # Scheduling writes for `rake wire:capture_writes` (issue #565). These are
    # not CATALOG entries. mode :write_live is not :live, so the read driver
    # (`CATALOG.select(&:live?)`) never calls them. A write reply is not proof;
    # the capture's read-back is. Piece layout matches the DataMapper mapping.
    WRITE_CATALOG = [
      CatalogEntry.new(
        rpc: "BSDX ADD NEW APPOINTMENT", mapping: :scheduling_add_appointment,
        kind: "fields", mode: :write_live,
        cite: "APPADD^BSDX07 (BSDX07.m:55,64) → $$MAKE^BSDAPI: data row " \
              "APPOINTMENTID^ERRORID. A positive id and an empty error is success; " \
              "piece 0 is the appointment id and piece 1 is the error text.",
        pieces: [
          Piece.new(position: 0, attributes: [ "appointment_id" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "error" ])
        ],
        note: "Booked as the setup persona. PROV123 cannot book on this seed " \
              "(DUZ(2) has no #40.8 division, so $$DIV^BSDU is 0); persona_probe is " \
              "that refusal. The read-back, not this reply, proves the appointment."
      ),
      CatalogEntry.new(
        rpc: "BSDX CHECKIN APPOINTMENT", mapping: :scheduling_checkin_appointment,
        kind: "fields", mode: :write_live,
        cite: "CHECKIN^BSDX25 (BSDX25.m:12,37,44-45,74,361-365): header " \
              "ERRORID^MESSAGE; the success row is \"0^\"_MESSAGE. A future check-in " \
              "is clamped to NOW and truncated to HHMM. Piece 0 is ERRORID.",
        pieces: [
          Piece.new(position: 0, attributes: [ "error" ])
        ],
        note: "Checked in as PROV123. The sent time is one minute before the server " \
              "minute, at minute precision, so the clamp does not rewrite it. " \
              "The read-back of #9002018.4 .03 is the proof."
      ),
      CatalogEntry.new(
        rpc: "BSDX CANCEL APPOINTMENT", mapping: :scheduling_cancel_appointment,
        kind: "fields", mode: :write_live,
        cite: "APPDEL^BSDX08 (BSDX08.m:109) → $$CANCEL^BSDAPI (BSDAPI.m:199-204): " \
              "the data row is the ERRORID column, and empty means the call was " \
              "accepted. A blank reason files 14. The ^DPT update is skipped when " \
              "the node is missing, so an empty ERRORID is not proof.",
        pieces: [
          Piece.new(position: 0, attributes: [ "error" ])
        ],
        note: "Cancelled as PROV123 with type PC and a coded #409.2 reason. The " \
              "reply is an empty ERRORID row (no-data) and proves nothing; #2.98 " \
              "field 16 is the proof, and it is unproven when the sent reason is " \
              "blank or 14."
      ),
      CatalogEntry.new(
        rpc: "BSDX NOSHOW", mapping: :scheduling_noshow_appointment,
        kind: "fields", mode: :write_live,
        cite: "NOSHOW^BSDX31 → $$CANCEL^BSDAPI: data row ERRORID^ERRORTEXT. ERRORID " \
              "is a success flag with inverted polarity (1 success, 0 failure). " \
              "Piece 0 is that flag; piece 1 is the error text.",
        pieces: [
          Piece.new(position: 0, attributes: [ "result" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "error" ])
        ],
        note: "No-show as PROV123. The read-back proves #9002018.4 .1 and #2.98 " \
              "status N; the reply's success flag is not that proof."
      )
    ].freeze
  end
end
