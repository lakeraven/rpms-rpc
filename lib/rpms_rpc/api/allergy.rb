# frozen_string_literal: true

require_relative "../shape"

module RpmsRpc
  # Symbolic API for patient allergies (ORQQAL LIST). The RPC is
  # three-state (LIST^ORQQAL — ORQQAL.m:7): not-assessed
  # ("^No Allergy Assessment"), assessed with no known allergies
  # ("^No Known Allergies"), or assessed with allergy records. Use
  # {assessment} when the caller must distinguish NKA from unassessed
  # (FHIR AllergyIntolerance must); {for_patient} keeps the plain
  # record-array shape.
  module Allergy
    extend self
    extend Shape::Declarable

    NOT_ASSESSED_SENTINEL       = "^No Allergy Assessment" # ORQQAL.m:12
    NKA_SENTINEL                = "^No Known Allergies"    # ORQQAL.m:13
    NO_ALLERGIES_FOUND_SENTINEL = "^No allergies found."   # ORQQAL.m:15, written only when no row was
    MARKERS = [ NOT_ASSESSED_SENTINEL, NKA_SENTINEL, NO_ALLERGIES_FOUND_SENTINEL ].freeze

    # The text of each marker, for recognising one that arrived slightly mangled.
    MARKER_TEXTS = MARKERS.map { |marker| marker.delete_prefix("^").downcase }.freeze
    # Zero-width characters that are neither whitespace nor visible.
    INVISIBLE = /[\u200B\u200C\u200D\uFEFF]/

    # Allergy records only. An NKA or unassessed patient yields [] —
    # callers that need to tell those apart must use {assessment}. The rows
    # of a conflicting reply (a marker beside other data) are returned too,
    # because hiding a possible allergy is unsafe; this method cannot tell a
    # verified list from a conflicting one, so a host that must make that
    # distinction MUST use {assessment} and read :assessed and :conflict.
    def for_patient(dfn)
      assessment(dfn)[:allergies]
    end
    shape :for_patient, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies"

    # Three-state assessment result:
    #   { assessed: true,  nka: false, allergies: [...] } records on file
    #   { assessed: true,  nka: true,  allergies: [] }    assessed, NKA
    #   { assessed: false, nka: false, allergies: [] }    no assessment
    # An empty/indeterminate response (including the "^No allergies found."
    # fallback ORQQAL.m:15 emits when the classifier produced no rows) is
    # reported as not-assessed — the clinically safe reading, since claiming
    # "assessed" without evidence would suppress a real assessment prompt.
    #
    # A marker line counts only as the SOLE data line of the reply.
    # LIST^ORQQAL (ORQQAL.m:7-16) sets GMRARXN to "", 0 or 1 — mutually
    # exclusive branches — and writes the not-assessed / NKA marker to
    # ORAY(1) only in the two branches that write no allergy rows; the third
    # marker, "^No allergies found." (ORQQAL.m:15), is written only when no row
    # was written at all. A real reply is therefore ONE marker line OR rows,
    # never both. Verified absence is strictly byte-exact: only the exact NKA
    # marker as the sole data line is NKA. A marker that arrives slightly
    # mangled (whitespace, a carriage return, a no-break or zero-width
    # character, a different case, an extra field) is still counted as a marker
    # for conflict detection and never becomes an allergy row of its own; alone
    # it is simply not assessed. Lines with nothing visible in them are not
    # data, and a response that is neither text nor a list of lines is no
    # evidence (not assessed, no rows). A reply that
    # mixes a marker with other data (or repeats a marker) is the signature
    # of a broker desync or a concatenated reply: its rows may belong to
    # another call (or patient), or the list may be truncated. It is never
    # vouched for:
    #   { assessed: false, nka: false, allergies: [...], conflict: true }
    # ALWAYS assessed: false, never nka. The parsed rows are still returned
    # — hiding a possible allergy is the other unsafe direction — but this
    # method reports them as NOT assessed; whether a host shows them as an
    # incomplete list is the host's job, and a host that must do so MUST read
    # :conflict (one that reads only :nka and :assessed is safe in the absence
    # direction, but may still render the rows as an ordinary list). With no
    # rows it is the same shape with allergies: [], which keeps the method's
    # fail-safe (no evidence => not assessed). Clean replies carry no
    # :conflict key. Hosts that must tell a verified list from a conflicting
    # one MUST use {assessment} and read :assessed and :conflict;
    # {for_patient} returns the rows either way.
    def assessment(dfn)
      mapping = DataMapper[:allergy_list]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, dfn.to_s)
      data = response_lines(response).reject { |line| blank?(line) }
      markers, rows = data.partition { |line| marker?(line) }

      return contradictory(mapping, rows) if !markers.empty? && data.size > 1
      return { assessed: true, nka: true, allergies: [] } if data == [ NKA_SENTINEL ]
      return { assessed: false, nka: false, allergies: [] } unless markers.empty?

      allergies = mapping.parse_many(rows)
      { assessed: !allergies.empty?, nka: false, allergies: allergies }
    end
    shape :assessment, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies/assessment"

    private

    # A marker next to other data (or twice): see {assessment}. The rows stay
    # available, but the reply is never vouched for: assessed is always false
    # and nka is always false, whatever the rows are. `rows` already excludes
    # every marker line, so a marker never becomes a row of its own.
    def contradictory(mapping, rows)
      { assessed: false, nka: false, allergies: mapping.parse_many(rows), conflict: true }
    end

    # Verified absence is strictly byte-exact (only the exact NKA marker as the
    # sole data line); this is the wider test used for conflict detection. A
    # marker that arrived with whitespace, a carriage return, a no-break space,
    # a zero-width character, a different case or an extra field is still a
    # marker, so it must count beside data and must never become an allergy row.
    def marker?(line)
      return true if MARKERS.include?(line)

      pieces = squeeze(line).split("^", -1)
      pieces.size >= 2 && pieces[0].empty? && MARKER_TEXTS.include?(pieces[1].gsub(/[[:space:]]+/, " ").strip.downcase)
    end

    # A line with nothing visible in it is not data and never becomes a row.
    def blank?(line)
      squeeze(line).empty?
    end

    # The line as text for matching only (the original is never altered): read
    # as UTF-8 whatever the client tagged it as, invalid bytes dropped,
    # zero-width characters treated as whitespace (one may stand where the
    # space was) and surrounding whitespace stripped.
    def squeeze(line)
      line.dup.force_encoding(Encoding::UTF_8).scrub("").gsub(INVISIBLE, " ").gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
    end

    # Only text and lists of lines are replies; anything else (a Hash, a number)
    # is no evidence and must not become a row built from its string form.
    def response_lines(response)
      case response
      when String then response.split(/\r?\n/)
      when Array then response
      else []
      end.map { |line| DataMapper.strip_recordset_separators(line.to_s) }
    end
  end
end
