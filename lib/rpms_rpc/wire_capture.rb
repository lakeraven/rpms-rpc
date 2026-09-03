# frozen_string_literal: true

require "digest"
require "yaml"
require_relative "fileman_date_parser"

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
  #   fixtures to test/fixtures/wire_captures/.
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

    SOURCES = [ "live-capture", "routine-cite" ].freeze
    KINDS = [ "fields", "scalar", "text_blob", "lines" ].freeze

    class InvalidFixture < StandardError; end

    Piece = Struct.new(:position, :attributes, :fileman_type, keyword_init: true)

    # One curated capture target: which RPC, which mapping gates it, how to
    # call it live (or why we can't), and the cited piece semantics.
    CatalogEntry = Struct.new(:rpc, :mapping, :kind, :mode, :inputs, :cite, :pieces, :note,
                              keyword_init: true) do
      def live? = mode == :live
    end

    # A committed wire capture. Validates provenance on load — an invalid
    # fixture raises InvalidFixture rather than silently entering the gate.
    class Fixture
      attr_reader :path, :rpc, :mapping_name, :kind, :source, :cite, :inputs,
                  :raw_return, :example_return, :sha256, :release_tag, :captured_at,
                  :pieces, :note

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
        @pieces = (data["pieces"] || []).map do |p|
          Piece.new(position: p["position"],
                    attributes: Array(p["attribute"] || p["attributes"]).map(&:to_s),
                    fileman_type: p["fileman_type"])
        end
        validate!
      end

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

        text.sub(/\A\d+\x00/, "").split(/\r\n|\r|\n/).reject(&:empty?)
      end

      # Only live-captured rows are evidence; example rows illustrate a cite.
      def captured_rows
        @raw_return.nil? ? [] : rows
      end

      private

      def validate!
        fail!("missing rpc") if blank?(@rpc)
        fail!("missing mapping") if @mapping_name.nil?
        fail!("kind must be one of #{KINDS.join("/")}") unless KINDS.include?(@kind)
        fail!("source must be live-capture or routine-cite — a hand-written wire " \
              "fixture without capture provenance is rejected") unless SOURCES.include?(@source)
        fail!("missing cite — piece semantics must cite the M routine that " \
              "builds the return") if blank?(@cite)
        fail!("fields kind requires pieces annotations") if @kind == "fields" && @pieces.empty?
        validate_pieces!
        @source == "live-capture" ? validate_live! : validate_routine_cite!
      end

      def validate_live!
        fail!("live-capture requires verbatim raw_return") if blank?(@raw_return)
        fail!("live-capture requires release_tag") if blank?(@release_tag)
        fail!("live-capture requires captured_at") if blank?(@captured_at)
        fail!("live-capture requires sha256 of raw_return") if blank?(@sha256)
        actual = Digest::SHA256.hexdigest(@raw_return)
        fail!("sha256 does not match raw_return (#{actual}) — raw was edited " \
              "after capture") unless actual == @sha256
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

        return [] unless fixture.kind == "fields"

        mapping.fields.flat_map { |field| field_violations(field, fixture) }
      end

      def mapping_kind(mapping)
        return "scalar" if mapping.scalar?
        return "text_blob" if mapping.text_blob?

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
        fixture.captured_rows.filter_map do |row|
          raw = row.split("^", -1)[field.position]
          next if raw.nil? || raw.empty? || raw_conforms?(raw, field.type)

          Violation.new(kind: :type_mismatch, position: field.position,
                        declared: field.attribute, expected: field.type, detail: raw)
        end
      end

      def raw_conforms?(raw, type)
        case type
        when :integer then raw.match?(/\A-?\d+\z/)
        when :float then Float(raw, exception: false) ? true : false
        when :boolean then [ "0", "1" ].include?(raw) || raw.match?(/\A(yes|no)\z/i)
        when :fileman_date then !FilemanDateParser.parse_date(raw).nil?
        when :fileman_datetime
          # FileMan datetime values may legitimately omit the time part.
          !FilemanDateParser.parse_datetime(raw).nil? || !FilemanDateParser.parse_date(raw).nil?
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
    # Inputs use only synthetic build-time data (DFN 8 DEMOPATIENT,REG2244 —
    # registered on the rung by prior evidence work). Public repo: never a
    # real patient, partner, or tribe.
    CATALOG = [
      CatalogEntry.new(
        rpc: "ORQQVI VITALS", mapping: :vitals, kind: "fields", mode: :live,
        inputs: [ "8", "2900101", "3991231" ],
        cite: "VITALS^ORQQVI (ORQQVI.m:4-24): header line 6 'vital measurement " \
              "ien^vital type^date/time taken^rate'; row construction line 23; " \
              "'^No vitals found.' sentinel line 24",
        pieces: [
          Piece.new(position: 0, attributes: [ "measurement_ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "type" ]),
          Piece.new(position: 2, attributes: [ "recorded_date", "recorded_datetime" ],
                    fileman_type: "fileman_datetime"),
          Piece.new(position: 3, attributes: [ "value", "rate" ])
        ],
        note: "The mapping this gate exists for: shipped as TYPE^VALUE^UNITS^DATE " \
              "with green mock tests; the real wire is IEN^TYPE^DATETIME^value."
      ),
      CatalogEntry.new(
        rpc: "ORQQPL LIST", mapping: :problem_list, kind: "fields", mode: :live,
        inputs: [ "8", "" ],
        cite: "LIST^ORQQPL (ORQQPL.m:3-18) reorders LIST^GMPLUTL3 rows " \
              "(GMPLUTL3.m:76-99: IEN^STATUS^NARRATIVE^ICD^ONSET^MODIFIED^SC^SP^" \
              "PRIORITY^TRANSCRIBED^SCT-C^SCT-D) as in1^in3^in2^in4^in5^in6^in7^" \
              "in8^in10^in9^''^DETAIL; '^No problems found.' sentinel line 16",
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
          Piece.new(position: 11, attributes: [ "detail_flag" ])
        ]
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
      CatalogEntry.new(
        rpc: "ORWPT ID INFO", mapping: :patient_id_info, kind: "fields", mode: :live,
        inputs: [ "8" ],
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
      CatalogEntry.new(
        rpc: "BEHOENCX GETVISIT", mapping: :encounter_visit, kind: "fields", mode: :live,
        inputs: [ "1" ],
        cite: "GETVISIT^BEHOENCX (BEHOENCX.m:4-16): header 'Returns hosp loc^" \
              "visit date^service category^dfn^visit id^locked'; service category " \
              "= VISIT #9000010 field .07 (VIS2VSTR^BEHOENCX)",
        pieces: [
          Piece.new(position: 0, attributes: [ "location_ien" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "datetime_raw" ]),
          Piece.new(position: 2, attributes: [ "service_category", "status" ]),
          Piece.new(position: 3, attributes: [ "patient_dfn" ], fileman_type: "integer"),
          Piece.new(position: 4, attributes: [ "visit_id", "ward" ]),
          Piece.new(position: 5, attributes: [ "locked" ], fileman_type: "boolean")
        ]
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
      # VAFC VOA ADD PATIENT is a WRITE RPC — never called by the capture
      # task (read-only discipline; conformance SPEC non-negotiable). Its
      # reply shape is routine-cited instead.
      CatalogEntry.new(
        rpc: "VAFC VOA ADD PATIENT", mapping: :voa_add_patient, kind: "fields", mode: :routine_cite,
        inputs: nil,
        cite: "ADD^VAFCPTAD (VAFCPTAD.m:28-29,55,140,145,178): RETURN(1) is " \
              "'-1^error text' | '1^DFN' | '1^DFN^ALIAS warning...'",
        pieces: [
          Piece.new(position: 0, attributes: [ "status" ], fileman_type: "integer"),
          Piece.new(position: 1, attributes: [ "dfn_or_error" ]),
          Piece.new(position: 2, attributes: [ "warning" ])
        ],
        note: "Write RPC: shape verified from routine source only; " \
              "example rows are illustrative, not captured."
      )
    ].freeze
  end
end
