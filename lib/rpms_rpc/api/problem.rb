# frozen_string_literal: true

require "date"
require_relative "../shape"
require_relative "../mappings"
require_relative "../context_scope"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for the problem list. Read via ORQQPL LIST and the other
  # ORQQPL reads below; write through IHS's BGOPROB SET / BGOPROB DEL, the
  # writes VueCentric uses on RPMS (rpms-rpc#527). Stock ORQQPL stays
  # read-only here: its writes carry none of SNOMED CT, laterality or the
  # location-scoped problem number.
  module Problem
    extend self
    extend Shape::Declarable

    # "P"-line pieces after the "P" marker for SET^BGOPROB's ARRAY param
    # (BGOPROB.m:229-233 on the pinned build; parsed in PROB^BGOPROB3:
    # SNOMED CT [2], Descriptive CT [3], Provider text [4], Mapped ICD [5],
    # Location [6], Onset [7], Status [8], Class [9], Problem # [10],
    # Priority [11]). The list locks the order so a caller's Hash key
    # insertion order can't reshuffle the payload mid-flight.
    PROB_FIELDS = %i[snomed_ct descriptive_ct description icd_code location_ien
                     onset_date status problem_class problem_number priority].freeze

    # The pieces of an integrated-list "P" row after its letter, in order
    # (GET^BGOPROB's header, BGOPROB.m:40-42; built at GET2^BGOPROB).
    INTEGRATED_FIELDS = %i[ien snomed_concept snomed_description number status onset narrative
                           icd_code priority problem_class pip additional_icd inpatient_dx outpatient_dx
                           used_as_pov asthma_dx needs_normal_abnormal laterality_flag laterality
                           default_status last_modified nonredisclosure diagnosed_on recorded_on
                           resolved_on diagnosis_date_source].freeze
    INTEGRATED_DATES = %i[onset diagnosed_on recorded_on resolved_on].freeze
    # 1/0 pieces: $$USED^BGOPROB1 (ever a purpose of visit) and the laterality flag.
    INTEGRATED_FLAGS = %i[used_as_pov laterality_flag].freeze

    # The option that carries BGOPROB SET / DEL and DDR GETS ENTRY DATA on
    # the pinned build (the context CIA sign-on binds).
    CONTEXT = "CIAV VUECENTRIC"
    PROBLEM_FILE = "9000011"

    # List a patient's problems. Underlying RPC: ORQQPL LIST — verified row
    # shape IEN^NARRATIVE^STATUS^ICD^ONSET^LAST MODIFIED^SC^SPEXP^... (see
    # the :problem_list mapping). An inactive-ICD row (ORQQPL.m:15-16:
    # piece 13 "#", whatever piece 4 holds) yields inactive_icd true and
    # transcribed nil; a retired code there is kept as icd_code, flagged by
    # inactive_icd (#532). On every row icd_code keeps piece 4 only when it is
    # code-shaped after surrounding whitespace is stripped (ICD-10-CM or
    # ICD-9-CM, PROBLEM_LIST_ICD_CODE_SHAPE). Anything else — any
    # $$ICDDX/^ICDCODE failure text, "-1", empty — is nil, and a code-shaped
    # value is the stripped token. Every other
    # row has inactive_icd false. "No
    # problems" comes back as the sentinel row "^No problems found."
    # (LIST^ORQQPL: ORQQPL.m:17) — no IEN, so it
    # is dropped rather than surfaced as a phantom problem. Invalid DFNs
    # short-circuit to [] without dispatching an RPC.
    #
    # Formals: LIST(ORPY,DFN,STATUS) (ORQQPL.m:3-5) — STATUS "A" active,
    # "I" inactive, "" all. STATUS is read unconditionally, so it goes over
    # the wire even when empty; a DFN-only frame died in M on it (#259).
    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.problem_list.fetch_many(dfn.to_s, "").reject { |r| r[:ien].to_s.empty? }
    end
    shape :for_patient, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems"

    # Add a problem: SET^BGOPROB with PRIEN empty. The gem sends SPEC=1, so
    # the routine files the caller's ICD (:icd_code) rather than deriving one
    # from SNOMED CT (PROB^BGOPROB3, BGOPROB3.m:94-95), and needs a location
    # (:location_ien, the INSTITUTION the problem is numbered under; -1049
    # without one, BGOPROB3.m:125). The reply is the new problem's IEN
    # (BGOPROB3.m:183) or -CODE^text.
    #
    # The new entry is read back with DDR. The build answers an IEN for an
    # ICD code it cannot resolve and files the problem with .01 = -1
    # ($$ICDDX^ICDEX answers "-1^..." and `I 'DIEN` does not catch it,
    # BGOPROB3.m:121-122), so a read-back whose .01 is not a positive
    # pointer, or whose .02 is not the patient, is a failure (:not_filed),
    # with the IEN the build gave.
    #
    # status: (add and update) is one of the names BGOPROB SET files --
    # Chronic, Inactive, Sub-acute, Episodic, Social/Environmental,
    # Routine/Admin, Admin -- or the .12 letter it files as (A, I, S, E, O,
    # R), in any case; the exact name is what is sent. Any other value,
    # including D or Deleted (Problem.delete deletes), is refused before
    # anything is sent, because BGOPROB would file it as EPISODIC (#923).
    # Omitted, nil or "" leaves the build's own default (BGOPROB3.m:113-114).
    #
    # Returns { success:, ien:, raw: }, plus error: on a refusal.
    def add(dfn, problem)
      raise ArgumentError, "problem must be a Hash" unless problem.is_a?(Hash)
      return failure if invalid_id?(dfn)

      problem, refused = with_status_name(problem)
      return refused if refused

      in_context { write(dfn, nil, problem) }
    end
    shape :add, resource: "problems", verb: "POST", path: "/patients/{dfn}/problems"

    # Edit a problem: SET^BGOPROB with PRIEN set. SET does not check that
    # the problem is the patient's (it only checks the patient exists,
    # BGOPROB3.m:117, and leaves .02 alone on an edit), so the gem reads the
    # problem first and sends nothing unless its .02 is this patient
    # (:not_found, :wrong_patient). The edit is read back as add's is.
    def update(dfn, ien, changes)
      raise ArgumentError, "changes must be a Hash" unless changes.is_a?(Hash)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      changes, refused = with_status_name(changes)
      return refused if refused

      in_context do
        refused = refuse_unless_patients(dfn, ien)
        refused || write(dfn, ien, changes)
      end
    end
    shape :update, resource: "problems", verb: "PUT", path: "/patients/{dfn}/problems/{ien}"

    # Logical delete via DEL^BGOPROB -> DEL^BGOPROB3: .12 STATUS "D" plus
    # 2.01-2.04 (who, when, reason, comment). Param: IEN ^ TYPE ^ REASON ^
    # COMMENT ^ PROB ID. DEL answers "" on success, and also "" for a
    # problem IEN not on file (BGOPROB3.m:18), so the gem reads the problem
    # first (:not_found, :wrong_patient; nothing sent) and reads .12 back
    # after: anything but "D" is :not_filed. A problem a visit, care plan,
    # visit instruction or OB note uses is refused by the build as -1^text
    # (CHK^BGOPROB2).
    def delete(dfn, ien, reason:)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      in_context do
        refused = refuse_unless_patients(dfn, ien)
        next refused if refused

        # Client called directly: DEL returns "" on success, which
        # fetch_scalar would collapse into nil (indistinguishable from
        # broker silence — and silence must never read as a delete).
        raw = RpmsRpc.client.call_rpc(DataMapper.problem_remove.rpc_name, "#{ien}^^#{reason}")
        next { success: false, ien: nil, raw: raw } unless DataMapper.write_accepted?(raw)

        filed = problem_fields(ien)
        next { success: true, ien: ien.to_i, raw: raw } if filed.is_a?(Hash) && filed[".12"] == "D"

        { success: false, ien: ien.to_i, raw: raw, error: :not_filed }
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: e.message)
    end
    shape :delete, resource: "problems", verb: "DELETE", path: "/patients/{dfn}/problems/{ien}"

    # IHS's integrated problem list, as VueCentric's Problem List component
    # reads it: BGOPROB GET (GET^BGOPROB). Where ORQQPL LIST (for_patient)
    # answers the stock row, this carries what IHS files beside it: the
    # SNOMED CT concept and description IDs, the facility-scoped problem
    # number ("DIC-1"), the IHS status, priority, laterality, date of
    # diagnosis, and each problem's qualifiers and notes.
    #
    #   integrated(dfn, statuses: nil) => [problem, ...]
    #
    # statuses: letters of the IHS statuses wanted (A chronic, S sub-acute,
    # E episodic, O social/environmental, R routine/admin, I inactive, P
    # personal history); nil sends none, and GET^BGOPROB takes "ASEOR",
    # every active status. Deleted problems are never listed.
    #
    # A problem is a Hash of INTEGRATED_FIELDS read from its "P" row
    # (BGOPROB.m:40-42), plus qualifiers: from its "Q" rows ({ kind: S
    # severity, F finding or C clinical course, ien:, snomed_ct:, text:,
    # provider:, recorded_on: }), notes: from its "N" rows (the row's
    # pieces, BGOPROB.m:44), and other: every other row that followed it,
    # as sent (care plan entries, "P1", "A", "F"), so nothing the build
    # answered is dropped. used_as_pov and laterality_flag are booleans.
    # Dates the routine formats as MM/DD/YYYY
    # (FMTDATE^BGOUTL) are Dates; last_modified is the FileMan datetime as
    # sent. A -n^text reply raises Client::RpcError: a failed read is not
    # "no problems".
    def integrated(dfn, statuses: nil)
      return [] if invalid_id?(dfn)

      wanted = integrated_statuses(statuses)
      lines = integrated_lines(DataMapper.problem_integrated, dfn.to_s, wanted, "", "", "")
      integrated_problems(lines)
    end
    shape :integrated, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems/integrated"

    # One problem of the integrated list, any status, by PROBLEM (#9000011)
    # IEN: BGOPROB1 GETONE (GETONE^BGOPROB1), the read VueCentric opens a
    # problem with. The same Hash integrated answers, or nil for a problem
    # not on file or deleted.
    def integrated_entry(ien)
      return nil if invalid_id?(ien)

      integrated_problems(integrated_lines(DataMapper.problem_integrated_one, ien.to_s, "")).first
    end
    shape :integrated_entry, resource: "problems", verb: "GET", path: "/problems/{ien}/integrated-entry"

    # The patient's active problems that carry a SNOMED CT concept: BGOPROB1
    # EDPROB (EDPROB^BGOPROB1, EXT=1), the list VueCentric offers when a
    # problem is chosen for patient education or a care plan.
    #
    #   coded_active(dfn) => [{ ien:, narrative:, snomed_ct:, icd_code:,
    #                           status:, eye_dx:, diagnosed_on:,
    #                           recorded_on:, resolved_on:,
    #                           diagnosis_date_source: }, ...]
    #
    # status is the external IHS status (CHRONIC, EPISODIC, ...); eye_dx is
    # true when the site's BGO IPL EYE DX filter marks the concept; the
    # three dates are Dates or nil. A problem without a SNOMED CT concept is
    # not listed (EDPROB+19).
    def coded_active(dfn)
      return [] if invalid_id?(dfn)

      lines = integrated_lines(DataMapper.problem_coded_active, dfn.to_s, "1")
      DataMapper.problem_coded_active.parse_many(lines).map do |row|
        row.merge(eye_dx: row[:eye_dx] == "1",
                  diagnosed_on: external_date(row[:diagnosed_on]),
                  recorded_on: external_date(row[:recorded_on]),
                  resolved_on: external_date(row[:resolved_on]))
      end
    end
    shape :coded_active, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems/coded-active"

    # ORQQPL stock-VistA reads. Use these when the engine wants the
    # stock-VistA lookup/audit surface rather than the IHS BGOPROB writes
    # above. Returns nil / [] for invalid identifiers without raising; a
    # broker that does not serve the RPC raises RpcNotAvailableError, and one
    # that serves it but not to this user raises RpcRefusedError (#363).

    # Candidate problems from the Lexicon: LEXSRCH^ORQQPL1 answers one
    # "lexicon IEN^text^ICD code^ICD IEN^coding system" row per match
    # (ORQQPL1.m: ien^.01^icd^icdifn^system), then a last line with the
    # match count ("669 matches found"), which is not a row. A piece the
    # build leaves empty is nil. LEXSRCH fills the ICD pieces only for a
    # Lexicon entry whose text names an ICD-9-CM, DSM-IV or Title 38 code;
    # on the pinned build no "diabetes" entry does.
    #
    #   lex_search(text) => [{ ien:, description:, code:, code_ien:, coding_system: }, ...]
    def lex_search(text)
      return [] if text.to_s.strip.empty?

      mapper = DataMapper.problem_lex_search
      mapper.lines!(text.to_s).select { |line| line.include?("^") }.map { |line| mapper.parse_one(line) }
    end
    shape :lex_search, resource: "problems", verb: "GET", path: "/problems/lex-search"

    def clinic_search(clinic_ien)
      return [] if invalid_id?(clinic_ien)

      Array(DataMapper.problem_clinic_search.fetch_many(clinic_ien.to_s))
    end
    shape :clinic_search, resource: "problems", verb: "GET", path: "/problems/clinics/{clinic_ien}/search"

    # The problem's detail report: the display text DETAIL^ORQQPL builds,
    # one line per Y(I), joined with newlines; nil for an invalid id or when
    # nothing came back.
    #
    # Formals: DETAIL(Y,DFN,PROBIEN,ID) (ORQQPL.m:21) — the problem IEN is
    # the third formal, after the patient; DFN and ID are declared but never
    # read, so the report is the problem's whatever DFN is sent. An IEN-only
    # frame put the IEN in DFN and died in M on PROBIEN (#259).
    #
    # The lines (ORQQPL.m:26-59): "NARRATIVE (DIAGNOSIS)", an inactive-code
    # notice when the ICD code is inactive, then labelled lines ("   Onset: ",
    # "  Status: " with /ACUTE or /CHRONIC, " SC Cond: ", "Exposure: ",
    # "Provider: ", "  Clinic: ", "Recorded: ", " Entered: ", " Updated: "),
    # comments and audit history when there are any, and " " spacer lines.
    # They are text, not a caret row (#821). A problem not on file dies in M
    # (DETAIL^GMPLUTL2 leaves ORGMPL("NARRATIVE") undefined), and that raises.
    def details(dfn, ien)
      return nil if invalid_id?(dfn) || invalid_id?(ien)

      text = DataMapper.problem_detail.fetch_text(dfn.to_s, ien.to_s)
      return nil if text.nil? || text.strip.empty?

      text
    end
    shape :details, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems/{ien}"

    # The problem's change history: HIST^ORQQPL2 answers a count line, then
    # one "date^text" row per change, the date as the build prints it
    # ("11/20/26"); or the single line NONE when the problem has none
    # (ORQQPL2.m:10-11). Neither the count nor NONE is a row.
    #
    #   audit_history(ien) => [{ date: "11/20/26", text: "PROBLEM removed by ..." }, ...]
    def audit_history(ien)
      return [] if invalid_id?(ien)

      mapper = DataMapper.problem_audit_history
      mapper.lines!(ien.to_s).select { |line| line.include?("^") }.map { |line| mapper.parse_one(line) }
    end
    shape :audit_history, resource: "problems", verb: "GET", path: "/problems/{ien}/audit-history"

    # The problem's active notes: GETCOMM^ORQQPL2 answers one line per note,
    # the note's text alone (ORQQPL2.m:131-139), across every facility.
    #
    #   comments(ien) => [{ comment: "..." }, ...]
    def comments(ien)
      return [] if invalid_id?(ien)

      DataMapper.problem_comments.lines!(ien.to_s).map { |line| { comment: line } }
    end
    shape :comments, resource: "problems", verb: "GET", path: "/problems/{ien}/comments"

    def init_patient(dfn)
      return nil if invalid_id?(dfn)

      DataMapper.problem_init_patient.fetch_one(dfn.to_s)
    end
    shape :init_patient, resource: "problems", verb: "POST", path: "/patients/{dfn}/problems/init"

    def provider_list(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.problem_provider_list.fetch_many(dfn.to_s))
    end
    shape :provider_list, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems/provider-list"

    # Formals: EDLOAD(RETURN,DA,GMPROV,GMPVAMC) (ORQQPL1.m:83) — the problem
    # IEN, then the provider DUZ, then the facility: an INSTITUTION (#4) IEN,
    # DUZ(2) in the roll-and-scroll Problem List (GMPLUTL.m:89). The pinned
    # registry names them IFN, provider, vamc. GETFLDS^GMPLEDT3 reads
    # GMPVAMC unconditionally to find the facility's note multiple
    # (GMPLEDT3.m:55) and GMPROV to keep only that provider's notes
    # (GMPLEDT3.m:57); an IEN-only frame died in M on GMPVAMC (#364).
    def edit_load(ien, provider_duz:, institution_ien:)
      raise ArgumentError, "provider_duz is required (got nil)" if provider_duz.nil?
      raise ArgumentError, "institution_ien is required (got nil)" if institution_ien.nil?
      return nil if invalid_id?(ien)

      DataMapper.problem_edit_load.fetch_one(ien.to_s, provider_duz.to_s, institution_ien.to_s)
    end

    private

    # SET^BGOPROB formals after RET: DFN, PRIEN, VIEN, ARRAY, SPEC, PIP
    # (BGOPROB.m:242). SPEC=1 takes the caller's mapped ICD.
    def write(dfn, ien, fields)
      raw = DataMapper.problem_set.fetch_scalar(
        dfn.to_s, ien.to_s, "", [ build_p_line(fields) ], "1"
      )

      saved_ien = raw.to_s.match(/\A[1-9]\d*\z/)&.to_s&.to_i
      return { success: false, ien: nil, raw: raw } unless saved_ien

      filed = problem_fields(saved_ien)
      if filed.is_a?(Hash) && filed[".02"] == dfn.to_s && filed[".01"].to_s.match?(/\A[1-9]\d*\z/)
        { success: true, ien: saved_ien, raw: raw }
      else
        { success: false, ien: saved_ien, raw: raw, error: :not_filed }
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: e.message)
    end

    # nil when problem `ien` is on file for patient `dfn`; else the refusal:
    # :not_found, :unreadable (see problem_fields) or :wrong_patient.
    def refuse_unless_patients(dfn, ien)
      filed = problem_fields(ien)
      return failure.merge(error: filed) if filed.is_a?(Symbol)
      return failure.merge(error: :wrong_patient) unless filed[".02"] == dfn.to_s

      nil
    end

    # PROBLEM (#9000011) .01, .02 and .12, internal. :not_found when
    # GETS^DIQ answers an error for the entry; :unreadable when the read
    # cannot be trusted: no reply, or one DdrFileman marks malformed, stray
    # (a field may have been read twice, the later value kept) or altered.
    def problem_fields(ien)
      entry = DdrFileman.gets_entry(file: PROBLEM_FILE, iens: "#{ien},", fields: ".01;.02;.12", flags: "I")
      return :unreadable if entry.nil? || entry[:malformed] || entry[:stray] || entry[:altered]
      return :not_found if entry[:error] || entry[:fields].empty?

      entry[:fields].transform_values { |f| f[:internal].to_s }
    end

    # The status letters GET^BGOPROB takes (BGOPROB.m:33-34, :65, GET2+33).
    INTEGRATED_STATUS_LETTERS = /\A[ASEORIP]+\z/

    def integrated_statuses(statuses)
      return "" if statuses.nil?

      letters = Array(statuses).join.upcase
      raise ArgumentError, "statuses must be letters of ASEORIP, got #{statuses.inspect}" unless letters.match?(INTEGRATED_STATUS_LETTERS)

      letters
    end

    # The reply's rows, one String per row, under the mapping's context. A
    # -n^text first row raises.
    def integrated_lines(mapping, *params)
      client = RpmsRpc.client
      reply = mapping.in_context(client) do
        client.respond_to?(:call_rpc_lines) ? client.call_rpc_lines(mapping.rpc_name, *params) : client.call_rpc(mapping.rpc_name, *params)
      end
      reply = reply.split(/\r\n|\r|\n/) if reply.is_a?(String)
      lines = Array(reply).map { |line| DataMapper.strip_recordset_separators(line.to_s) }.reject(&:empty?)
      raise Client::RpcError, "#{mapping.rpc_name} refused: #{lines.first}" if lines.first && DataMapper.error_row?(lines.first)

      lines
    end

    def integrated_problems(lines)
      problems = []
      lines.each do |line|
        type, *pieces = line.split("^", -1)
        if type == "P"
          problems << integrated_problem(pieces)
        elsif (current = problems.last)
          case type
          when "Q" then current[:qualifiers] << integrated_qualifier(pieces)
          when "N" then current[:notes] << pieces
          else current[:other] << line
          end
        end
      end
      problems
    end

    def integrated_problem(pieces)
      row = INTEGRATED_FIELDS.each_with_index.to_h { |field, i| [ field, pieces[i].to_s ] }
      row[:ien] = row[:ien].to_i
      INTEGRATED_DATES.each { |field| row[field] = external_date(row[field]) }
      row.transform_values! { |v| v == "" ? nil : v }
      INTEGRATED_FLAGS.each { |field| row[field] = row[field] == "1" }
      row.merge(qualifiers: [], notes: [], other: [])
    end

    def integrated_qualifier(pieces)
      kind, ien, snomed, text, provider, date = pieces
      { kind: kind, ien: ien.to_i, snomed_ct: snomed, text: text, provider: provider.to_s.empty? ? nil : provider,
        recorded_on: external_date(date) }
    end

    # MM/DD/YYYY, as FMTDATE^BGOUTL writes a date (FMTE^XLFDT "5ZD"); nil
    # for anything else.
    def external_date(value)
      md = value.to_s.match(%r{\A(\d{2})/(\d{2})/(\d{4})\z})
      md && Date.new(md[3].to_i, md[1].to_i, md[2].to_i)
    rescue ArgumentError
      nil
    end

    def in_context(&) = ContextScope.scoped(RpmsRpc.client, CONTEXT, &)

    # The status names PROB^BGOPROB3 files (BGOPROB3.m:115), keyed by the
    # lower-cased name and by the .12 internal letter each files as. Any other
    # value BGOPROB would file as E (EPISODIC) without saying so (#923), so it
    # is refused here. D (deleted) is not among them: Problem.delete deletes.
    STATUS_NAMES = {
      "chronic" => "Chronic", "a" => "Chronic",
      "inactive" => "Inactive", "i" => "Inactive",
      "sub-acute" => "Sub-acute", "s" => "Sub-acute",
      "episodic" => "Episodic", "e" => "Episodic",
      "social/environmental" => "Social/Environmental", "o" => "Social/Environmental",
      "routine/admin" => "Routine/Admin", "r" => "Routine/Admin",
      "admin" => "Admin"
    }.freeze
    private_constant :STATUS_NAMES

    # [fields with status: as the exact name BGOPROB matches, nil], or
    # [fields, refusal] for a status it does not take. An omitted, nil or
    # empty status is left for the build's own default (BGOPROB3.m:113-114).
    def with_status_name(fields)
      status = fields[:status]
      return [ fields, nil ] if status.nil? || status == ""

      name = status.is_a?(String) && !status.include?("^") && STATUS_NAMES[status.downcase]
      return [ fields.merge(status: name), nil ] if name

      [ fields, failure.merge(error: "status \"#{status}\" is not one BGOPROB SET files " \
                                     "(#{STATUS_NAMES.values.uniq.join(', ')}, or A, I, S, E, O, R)") ]
    end

    def build_p_line(fields)
      ([ "P" ] + PROB_FIELDS.map { |k| fields[k].to_s }).join("^")
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
