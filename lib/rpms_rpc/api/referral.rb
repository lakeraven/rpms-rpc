# frozen_string_literal: true

require_relative "../mappings"
require_relative "../context_scope"
require_relative "../rcis_wire"
require_relative "../shape"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for referral records. Read via referral_search /
  # referral_detail; write via the BMC RCIS RPCs (see {add}).
  #
  # ## Context — this module binds it, callers do not (rpms-rpc#258)
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope): the broker
  # answers "may this session run this RPC?" from the RPC multiple of the
  # option bound right now. On a built 9.0 image the BMC* RPCs are listed in
  # the RPC multiple of ONE file-19 option, BMCRPC ("the broker context for
  # RCIS component in the EHR GUI"; 22 entries: the 21 BMC names below plus
  # ORWDXIHS CLININD), and in no other — not the option a CIA sign-on binds
  # (CIAV VUECENTRIC) and not OR CPRS GUI CHART. A user without XUPROGMODE
  # calling them under the sign-on option is simply denied.
  #
  # So every method that reaches the wire scopes itself to BMCRPC via
  # ContextScope.scoped (bind, run, restore the caller's option), the way
  # RpmsRpc::Agg does for AGGRPC. A client that cannot scope contexts runs
  # as-is. A programmer-key session bypasses the check either way, so only a
  # non-programmer run is evidence of this bind.
  #
  # The BMC methods call their RPC unconditionally. A broker that does not
  # serve it raises Client::RpcNotAvailableError; one that serves it but not
  # to this user raises Client::RpcRefusedError (#363).
  module Referral
    extend self
    extend Shape::Declarable

    # The context option the BMC* RPCs are registered under — see the module
    # doc. Every method here binds it.
    CONTEXT = "BMCRPC"

    # STATUS OF REFERRAL (file 90001, field .15) code for a cancelled
    # referral: X, CLOSED-NOT COMPLETED. RCIS's own reports skip X as
    # "cancelled" (BMCRR121.m:39, BMCRR41.m:38).
    CANCELLED_STATUS = "X"

    # STATUS OF REFERRAL (.15) set of codes on the pinned build:
    # A:ACTIVE;A1:APPROVED;C1:CLOSED-COMPLETED;X:CLOSED-NOT COMPLETED.
    STATUS_CODES = %w[A A1 C1 X].freeze

    # Every referral on file for one patient: BMC SEARCH REFERRAL, which is
    # SRCHREF^BMCRPC1(RSLT,PATIENT,REFPRVDR,STRTDATE,ENDDATE,RECNMBR,STATUS)
    # (BMCRPC1.m:9). All six formals are sent, because the routine reads
    # RECNMBR and REFPRVDR without $G (BMCRPC1.m:32,34) and a formal the
    # broker is not sent is undefined: a DFN-only frame died with LVUNDEF
    # RECNMBR at SRCHREF+23 (#210). The five after the patient mean "no filter":
    #   REFPRVDR ""  no referring-provider screen (BMCRPC1.m:34)
    #   STRTDATE ""  no start date (BMCRPC1.m:40)
    #   ENDDATE  ""  no end date (BMCRPC1.m:41)
    #   RECNMBR  ""  +"" is not > 0, so "*": every record (BMCRPC1.m:32)
    #   STATUS   ""  no status screen (BMCRPC1.m:25,35)
    SEARCH_NO_FILTERS = [ "", "", "", "", "" ].freeze

    def for_patient(dfn)
      in_context { DataMapper.referral_search.fetch_many(dfn.to_s, *SEARCH_NO_FILTERS) }
    end

    # The status screen SRCHREF^BMCRPC1 builds for "Active/Approved": STATUS
    # OF REFERRAL (.15) A (ACTIVE) or A1 (APPROVED), the two codes of a
    # referral not yet closed either way (BMCRPC1.m:40-41).
    PENDING_STATUS = "Active/Approved"

    # The most entries one cross-patient BMC SEARCH REFERRAL returns: with no
    # patient and no provider, the routine lists at most 100 (BMCRPC1.m:47).
    SEARCH_PAGE = 100

    # The referrals still open, ACTIVE or APPROVED, for every patient, whose
    # DATE INITIATED (.01) is in from..to (Dates, both ends included).
    #
    # BMC SEARCH REFERRAL with no PATIENT and no REFPRVDR takes its third
    # path: LIST^DIC on the B index of .01 from the start date, screened to
    # .01 >= from, .01 <= to and the PENDING_STATUS codes, at most
    # SEARCH_PAGE entries (BMCRPC1.m:42-47). A full page is followed by
    # another from the last date it reached, and entries already read are
    # kept once, so the answer is every match, oldest first. A single date
    # with more than SEARCH_PAGE pending referrals cannot be paged past, and
    # raises Client::RpcError rather than answer short.
    #
    # Rows are referral_search's: :ien (the #90001 IEN), :date, :patient_dfn,
    # :patient_name, :status ("ACTIVE" or "APPROVED"), :referral_number, and
    # the rest of that mapping.
    def pending(from:, to:)
      raise ArgumentError, "from and to must be Dates" unless from.is_a?(Date) && to.is_a?(Date)
      raise ArgumentError, "from (#{from}) is after to (#{to})" if from > to

      in_context do
        rows = {}
        start = from
        loop do
          page = DataMapper.referral_search.fetch_many("", "", external_date(start), external_date(to), "", PENDING_STATUS)
          fresh = page.reject { |row| rows.key?(row[:ien]) }
          fresh.each { |row| rows[row[:ien]] = row }
          break if page.size < SEARCH_PAGE

          last = page.filter_map { |row| row[:date] }.max
          if fresh.empty? || last.nil?
            raise Client::RpcError, "BMC SEARCH REFERRAL: more than #{SEARCH_PAGE} pending referrals initiated on " \
                                    "#{external_date(start)}; one call returns at most #{SEARCH_PAGE}, so they cannot all be read"
          end

          start = last
        end
        rows.values
      end
    end
    shape :pending, resource: "referrals", verb: "GET", path: "/referrals/pending"

    # One referral by RCIS REFERRAL (#90001) IEN, with its diagnoses and
    # notes named from the sections GTRFBYID^BMCRPC1 appends (#210).
    def find(ien)
      return nil if ien.nil?

      record = in_context { DataMapper.referral_detail.fetch_one(ien.to_s) }
      record && name_sections(record)
    end

    def add(*params)
      bmc_scalar_result(:bmc_add_referral, *params)
    end
    shape :add, resource: "referrals", verb: "POST", path: "/referrals"

    # BMC UPDATE REFERRAL is UPDREFRL^BMCRPC2 (BMCRPC2.m:158), 36 formals with
    # RSLT. All of them as actuals is more than YottaDB takes (32 actual
    # arguments; the broker answers %YDB-E-MAXACTARG, as for BMC ADD REFERRAL).
    # A call with fewer is fine as long as the routine never reads the
    # missing formals unguarded: see record_follow_up, which sends 30.
    # Every call on an open referral also sets DATE LAST UPDATED (.27) to
    # today and sends a MailMan notice through SENDXM^BMCRPC3 (BMCRPC2.m:227,245).
    def update(ien, *params)
      bmc_scalar_result(:bmc_update_referral, ien, *params)
    end
    shape :update, resource: "referrals", verb: "PUT", path: "/referrals/{ien}"

    # The STANDARD IHS REFERRAL LETTER as text (PRINT^BMCRPC5, BMCRPC5.m:50-64).
    def print(ien, *params)
      bmc_text(:bmc_print_referral, ien.to_s, *params)
    end
    shape :print, resource: "referrals", verb: "POST", path: "/referrals/{ien}/print"

    def update_status(ien, status, *params)
      bmc_scalar_result(:bmc_referral_status_update, ien.to_s, status.to_s, *params)
    end
    shape :update_status, resource: "referrals", verb: "PUT", path: "/referrals/{ien}/status"

    # Cancel a referral: file its status as CANCELLED_STATUS through BMC
    # REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3(RSLT,REFIEN,STATUS),
    # BMCRPC3.m:176-187), under CONTEXT. RCIS has no delete; this replaces
    # the removed `delete`. The routine files field .15 and nothing else, so
    # there is no reason argument: a cancellation reason is not filed by it.
    #
    # Returns { success:, message:, raw: }. The routine answers "1" when it
    # filed and "~`0^message" when it refused. On builds without
    # openrpms#702 its refusal path QUITs with a value under a broker that
    # DOes the tag, and the call raises Client::RpcError instead.
    def cancel(ien)
      return failure if invalid_id?(ien)

      in_context do
        result = bmc_scalar_result(:bmc_referral_status_update, ien.to_s.strip, CANCELLED_STATUS)
        refusal = result[:raw].to_s.match(/\A~`0\^?(.*)\z/m)
        refusal ? result.merge(success: false, message: refusal[1].strip) : result
      end
    end
    shape :cancel, resource: "referrals", verb: "POST", path: "/referrals/{ien}/cancel"

    # File a checked STATUS OF REFERRAL (.15) through BMC REFERRAL STATUS
    # UPDATE, UPDTSTRF^BMCRPC3(RSLT,REFIEN,STATUS) (BMCRPC3.m:176-187), under
    # CONTEXT, and decide success by reading .15 back (rpms-rpc#722). Observed
    # live on the pinned build:
    # 1. FILE^DIE is called without the E flag, so the routine files any
    #   string ("H" was filed): status must be one of STATUS_CODES, checked here.
    # 2. The routine NEWs neither FDA nor ERR1, and FILE^DIE kills the FDA only
    #   when it files without error (DIEF.m:24). After one failed update in a
    #   broker session the failed write stays queued: every later update in
    #   that session re-files every queued entry (on any referral) and answers
    #   the stale "~`0^...". So a "~`0" reply is :session_poisoned whatever .15
    #   reads back, and the session must be closed; a "1" reply is decided by
    #   the read-back.
    # 3. In an option without the RPC the broker refuses it, and
    #   Client::RpcRefusedError propagates.
    #
    # .15 is read before and after with DDR GETS ENTRY DATA in the caller's
    # option. Returns { success: true, status:, previous_status:, raw: };
    # { success: false, error: :session_poisoned, status: <read back or nil>,
    # previous_status:, message:, raw: } for a "~`0" reply; { success: false,
    # error: :not_filed, ... } when .15 does not read back as sent; or a
    # refusal (:invalid_ien, :invalid_status, :unread, :not_found) before
    # anything is sent.
    def record_status(ien, status)
      id = referral_ien(ien)
      return refusal(:invalid_ien, "not a referral IEN: #{ien.inspect}") unless id
      unless status.is_a?(String) && STATUS_CODES.include?(status)
        return refusal(:invalid_status, "not a STATUS OF REFERRAL code (#{STATUS_CODES.join(', ')}): #{status.inspect}")
      end

      entry = status_entry(id)
      return refusal(:unread, "DDR GETS ENTRY DATA gave no reply for referral #{id}") if entry.nil?
      return refusal(:not_found, "referral #{id} is not on file") if entry[:error] || entry[:fields].empty?

      previous = filed_status(entry).to_s
      result = bmc_scalar_result(:bmc_referral_status_update, id, status)
      filed = filed_status(status_entry(id))
      outcome = { status: filed, previous_status: previous, raw: result[:raw] }
      if result[:code] == "0"
        message = "BMC REFERRAL STATUS UPDATE answered #{result[:raw].to_s.strip.inspect}: this broker session holds an " \
                  "earlier failed FileMan write (UPDTSTRF^BMCRPC3 keeps it queued) that every status update re-files, " \
                  "on any referral; close the session before filing again"
        return { success: false, error: :session_poisoned, message: message }.merge(outcome)
      end
      return { success: true }.merge(outcome) if filed == status

      message = result[:error] || "referral #{id} .15 reads #{filed.inspect} after the update, not #{status.inspect}"
      { success: false, error: :not_filed, message: message }.merge(outcome)
    end
    shape :record_status, resource: "referrals", verb: "POST", path: "/referrals/status"

    # The most actual arguments a YottaDB M call takes, RSLT included.
    YDB_MAX_ACTUALS = 32

    # STATUS OF REFERRAL (.15) codes of a closed referral. UPDREFRL^BMCRPC2
    # files only notes on one of these and silently drops every other field
    # (BMCRPC2.m:165-175).
    CLOSED_STATUSES = %w[C1 X].freeze

    # INCLUDE ... flags, fields 401-412, in UPDREFRL's formal order ICSRP
    # through IXRYF (BMCRPC2.m:158; filed at :215-226). Each one is filed
    # whenever "YN" contains it, and "YN" contains "", so a flag not resent
    # with its current value is deleted: they are read first and resent.
    INCLUDE_FLAG_FIELDS = %w[411 405 406 408 407 412 401 403 404 402 409 410].freeze

    # The range DD 1106's input transform accepts, 2950101 up to 4000101
    # (exclusive); UPDREFRL files without it (no E flag), so it is checked here.
    APPOINTMENT_RANGE = (Date.new(1995, 1, 1)...Date.new(2100, 1, 1)).freeze

    # What record_follow_up compares before and after the write, by name.
    FOLLOW_UP_FIELDS = { appointment: "1106", schedule_within_days: "1302", include_flags: "INCLUDE flags 401-412",
                         snomed_terms: "the SNOMED CT term", case_notes: "the CASE notes" }.freeze

    # A confirmed follow-up on an open referral: the scheduled date of service
    # (1106, ACTUAL APPT/BEGIN DOS) and a case note, filed through BMC UPDATE
    # REFERRAL (UPDREFRL^BMCRPC2, BMCRPC2.m:158-252) under CONTEXT, and
    # decided by reading the referral back. Part of rpms-rpc#722.
    #
    # The routine rewrites the record rather than patching it, so this:
    # - reads the current state first with DDR GETS ENTRY DATA and DDR LISTER
    #   (stock FileMan, in the caller's option, not BMCRPC): .15, 1106, 1302,
    #   1303, the INCLUDE flags 401-412, the SNOMED CT multiple (#90001.22) and
    #   the CASE notes;
    # - sends exactly 30 parameters, REFIEN through CN (31 actuals with
    #   RSLT, under YDB_MAX_ACTUALS). The five formals left off (RDCODE,
    #   RDN, RDT, RQPR, DUPREF) are read with $G, read only when RDCODE and
    #   RDN are set, or not read at all (BMCRPC2.m:190,240);
    # - sends TYPE, INOROUT, ICDCAT, CPTCAT, PURPOSE, PRIORITY, TYPEEXT,
    #   VISITS and NOTESCHD empty, which the routine skips (:189-211);
    # - always sends SCHWIDAY: the routine deletes 1106 when SCHWIDAY carries
    #   no date (:182-188,216-217), so a note-only call resends the date on
    #   file as "<1302>^MM/DD/YYYY@<its time digits exactly>";
    # - resends the INCLUDE flags as read, and the one SNOMED CT term, since
    #   the routine kills ^BMCREF(REFIEN,22) and refiles only SNMDST (:232-233).
    # Every call also sets DATE LAST UPDATED (.27) to today and ADDITIONAL
    # INFO (.34) from the flags, and sends a MailMan notice through
    # SENDXM^BMCRPC3 (:227-229,245); filing 1106 also fires its trigger on
    # 1110 (INP ACTUAL LOS) for an inpatient referral.
    #
    # It refuses, before anything is written: a non-IEN (:invalid_ien), a
    # referral not on file (:not_found) or one it cannot read (:unread, also
    # when the CASE notes cannot be listed), a closed one (:closed, where the
    # routine would file the note and drop the date), one with more than one
    # SNOMED CT term (:several_snomed_terms; all but one would be lost), one
    # linked to an EHR referral (:linked_ehr_referral; field 1303, which the
    # routine also rewrites through UPENVREF^BMCRPC5 with fields this does not
    # read), and a note-only call on a 1106 with no time
    # (:date_only_appointment; the routine would file "3261204." with a
    # trailing dot).
    #
    # appointment_on is a Date in APPOINTMENT_RANGE (:invalid_date otherwise,
    # before anything is read) and needs time: "HH:MM", 00:01 to 23:59, with
    # no default; time without appointment_on raises ArgumentError. FILE^DIE runs without the E flag and the routine files
    # "date.digits" as built, so the time goes out as FileMan's canonical
    # digits: no colon, trailing zeros dropped ("09:30" -> "093", "12:00" ->
    # "12"); 00:00 has none and raises ArgumentError. case_note is one line of
    # text, filed as a CASE note (type C, #90001.03) by SETMEDHX^BMCRPC3.
    #
    # The reply is not evidence: success is 1106 reading back as expected,
    # exactly one new CASE note with the sent text when a note was sent
    # (other new notes, someone else's, are ignored), and 1302, 401-412 and
    # the SNOMED CT term reading as before. Returns
    # { success: true, appointment: <1106 internal>, case_note_ien:, raw: }, or
    # { success: false, error:, message:, raw: } (message with the routine's
    # refusal text when it gave one) where error is :unverified (the
    # read-back cannot be read: the write may have landed, do not resend),
    # :partially_filed (it reads changed, but not as sent) or :not_filed
    # (nothing reads changed); or a refusal above.
    def record_follow_up(ien, appointment_on: nil, time: nil, case_note: nil)
      id = referral_ien(ien)
      return refusal(:invalid_ien, "not a referral IEN: #{ien.inspect}") unless id

      note = one_line(case_note)
      return refusal(:nothing_to_file, "give an appointment date, a case note, or both") if appointment_on.nil? && note.empty?
      raise ArgumentError, "time needs appointment_on" if appointment_on.nil? && !time.nil?
      raise ArgumentError, "appointment_on must be a Date" if appointment_on && !appointment_on.is_a?(Date)

      sent = appointment_on && "#{FilemanDateParser.format_date(appointment_on)}.#{time_digits(time)}"
      if appointment_on && !APPOINTMENT_RANGE.cover?(appointment_on)
        return refusal(:invalid_date, "appointment_on #{appointment_on} is outside 1106's range, 1995-01-01 to 2099-12-31")
      end

      before = follow_up_record(id)
      refused = before[:error] ? before : follow_up_refusal(id, before)
      return refused if refused

      expected = sent || before[:appointment]
      unless expected.empty? || schwiday_date(expected)
        return refusal(:date_only_appointment, "referral #{id} 1106 reads #{expected.inspect}, a date with no time; " \
                                               "resent, BMC UPDATE REFERRAL would file it with a trailing dot")
      end

      result = bmc_scalar_result(:bmc_update_referral, *follow_up_params(id, before, expected, note))
      outcome = follow_up_outcome(before, follow_up_record(id), expected, note)
      return outcome.merge(raw: result[:raw]) if outcome[:success]

      outcome.merge(message: [ result[:message] || result[:error], outcome[:message] ].compact.join("; "), raw: result[:raw])
    end
    shape :record_follow_up, resource: "referrals", verb: "POST", path: "/referrals/follow-up"

    # The 30 positional parameters record_follow_up sends, REFIEN through CN.
    # SCHWIDAY carries the 1106 the call expects to read back.
    def follow_up_params(ien, state, appointment, note)
      schwiday = appointment.empty? ? "" : "#{state[:schedule_within_days]}^#{schwiday_date(appointment)}"
      flags = INCLUDE_FLAG_FIELDS.map { |field| state[:include_flags][field] }
      params = [ ien ] + Array.new(9, "") + [ "", schwiday ] + flags +
               [ "", "", "", "", state[:snomed_terms].first.to_s, note ]
      raise ArgumentError, "BMC UPDATE REFERRAL would get #{params.size + 1} actuals" if params.size + 1 > YDB_MAX_ACTUALS

      params
    end
    private :follow_up_params

    # What record_follow_up reads back: STATUS OF REFERRAL (.15, internal),
    # the date of service it files (1106, FileMan internal, e.g.
    # "3261204.093"), and the referral's CASE notes (#90001.03, type C),
    # oldest first, as { ien:, date:, text: }, or nil when DDR LISTER cannot
    # list them all. Read with DDR GETS ENTRY DATA and DDR LISTER, in the
    # caller's option. Nil, with nothing sent, for a non-IEN; nil when the
    # referral is not on file.
    def follow_up_state(ien)
      id = referral_ien(ien)
      return nil unless id

      entry = DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{id},", fields: ".15;1106", flags: "I")
      return nil if entry.nil? || entry[:error]

      fields = entry[:fields]
      {
        status: fields.dig(".15", :internal).to_s,
        appointment: fields.dig("1106", :internal).to_s,
        case_notes: case_notes(id)
      }
    end
    shape :follow_up_state, resource: "referrals", verb: "GET", path: "/referrals/{ien}/follow-up-state"

    def update_consultation_status(consultation_ien, status, *params)
      bmc_scalar_result(:bmc_consultation_status_update, consultation_ien.to_s, status.to_s, *params)
    end
    shape :update_consultation_status, resource: "referrals", verb: "PUT", path: "/referrals/consultations/{consultation_ien}/status"

    def purposes(*params)
      bmc_many(:bmc_purpose_of_referral_list, *params)
    end

    def reference_data(*params)
      bmc_many(:bmc_reference_data, *params)
    end

    # PROV^BMCRPC4 answers one node, "-1^All~IEN^NAME~...": the "All"
    # entry is a picker option, not a user, so it is dropped (#210).
    def users_providers(*params)
      RcisWire.records(bmc_text(:bmc_users_providers, *params)).filter_map do |rec|
        ien, name = rec.split("^", 2)
        { ien: ien, name: name } if ien.to_i.positive?
      end
    end

    # Active holders of the PROVIDER key, { duz:, name: } each (PROV^ORQPTQ2,
    # ORQPTQ2.m:95-101). PROV(Y) takes no parameter: one sent anyway is "more
    # actual than formal parameters" (#364).
    def providers
      bmc_many(:bmc_providers)
    end

    def search_referred_to(*params)
      bmc_many(:bmc_search_referred_to, *params)
    end

    def rcis_templates(*params)
      bmc_many(:bmc_rcis_template_list, *params)
    end

    def rcis_template_detail(template_ien, *params)
      bmc_text(:bmc_rcis_template_detail, template_ien.to_s, *params)
    end

    def patient_eligibility_status(dfn, *params)
      in_context do
        DataMapper.bmc_patient_eligibility_status.fetch_one(dfn.to_s, *params)
      end
    end

    def patient_face_sheet(dfn, *params)
      bmc_text(:bmc_patient_face_sheet, dfn.to_s, *params)
    end

    # BMC PATIENT HEALTH SUMMARY runs EN^BQIRHS(DATA,DFN,SUMMTYP) and reads
    # SUMMTYP with no $G (BQIRHS+38), so the HEALTH SUMMARY TYPE (#9001015)
    # IEN is required: a DFN-only call dies LVUNDEF/<UNDEFINED> on either
    # engine before it builds anything (#448). health_summary_types lists
    # the IENs.
    def patient_health_summary(dfn, type_ien)
      bmc_text(:bmc_patient_health_summary, dfn.to_s, type_ien.to_s)
    end

    def health_summary_types(*params)
      bmc_many(:bmc_health_summary_type, *params)
    end

    def check_year_site_param(*params)
      bmc_scalar_result(:bmc_check_year_site_param, *params)
    end

    def add_c32_print_log(*params)
      bmc_scalar_result(:bmc_add_c32_print_log, *params)
    end
    shape :add_c32_print_log, resource: "referrals", verb: "POST", path: "/referrals/c32-print-log"

    # NOT IMPLEMENTED — and honestly so (#217). The former binding,
    # BGOREF SET, is the personal REFUSALS writer (SET^BGOREF files
    # ^AUPNPREF via $$REFSET2^BGOUTL2 — BGOREF.m:8,29): "creating a
    # referral" was filing a refusal record. The real referral writer is
    # BMC ADD REFERRAL (SETREFRL^BMCRPC2), whose 39 positional formals
    # (referral date, type, IO/RO, ICD/CPT categories, purpose, priority,
    # …) cannot be honestly derived from this method's small params hash —
    # use {add} with the full BMC parameter list instead.
    def create(dfn, params)
      raise ArgumentError, "params must be a Hash" unless params.is_a?(Hash)
      return failure if invalid_id?(dfn)

      {
        success: false,
        error: :not_implemented,
        message: "Referral.create has no faithful RPC binding: BGOREF SET writes " \
                 "refusals, not referrals. Use Referral.add (BMC ADD REFERRAL = " \
                 "SETREFRL^BMCRPC2) with the full RCIS parameter list.",
        raw: nil
      }
    end

    private

    REFERRAL_FILE = "90001"
    COMMENTS_FILE = "90001.03"
    SNOMED_FILE = "90001.22"

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def refusal(error, message)
      { success: false, error: error, message: message, raw: nil }
    end

    # The referral IEN as sent (stripped), or nil. invalid_id? alone passes
    # "1,2" and "+7" (to_i is 1 and 7), and the IEN goes into an IENS.
    def referral_ien(ien)
      id = ien.to_s.strip
      id unless invalid_id?(ien) || !id.match?(/\A[1-9]\d*\z/)
    end

    # FileMan's canonical time digits for "HH:MM": no colon, trailing zeros
    # dropped. 00:00 leaves none and is refused like a malformed time.
    def time_digits(time)
      hhmm = time.match(/\A([01]\d|2[0-3]):([0-5]\d)\z/) if time.is_a?(String)
      digits = hhmm ? hhmm.captures.join.sub(/0+\z/, "") : ""
      raise ArgumentError, "time must be HH:MM, 00:01 through 23:59: #{time.inspect}" if digits.empty?

      digits
    end

    # SCHWIDAY's "MM/DD/YYYY@digits" for a FileMan date/time, with the time
    # digits exactly as given; nil when it has no time part.
    def schwiday_date(internal)
      date, digits = internal.match(/\A(\d{7})\.(\d+)\z/)&.captures
      day = date && FilemanDateParser.parse_date(date)
      day && "#{day.strftime('%m/%d/%Y')}@#{digits}"
    end

    # The fields record_follow_up reads and resends, internal: .15, 1106,
    # 1302, 1303, 401-412, the SNOMED CT terms and the CASE notes (each nil
    # when its list cannot be read); or a refusal hash (with :error) when
    # the referral cannot be read or is not on file.
    def follow_up_record(ien)
      entry = DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},",
                                    fields: ".15;1106;1302;1303;#{INCLUDE_FLAG_FIELDS.sort.join(';')}", flags: "I")
      return refusal(:unread, "DDR GETS ENTRY DATA gave no reply for referral #{ien}") if entry.nil?
      return refusal(:not_found, "referral #{ien} is not on file") if entry[:error] || entry[:fields].empty?

      internal = ->(field) { entry[:fields].dig(field, :internal).to_s }
      {
        status: internal.call(".15"),
        appointment: internal.call("1106"),
        schedule_within_days: internal.call("1302"),
        ehr_referral: internal.call("1303"),
        include_flags: INCLUDE_FLAG_FIELDS.to_h { |field| [ field, internal.call(field) ] },
        snomed_terms: snomed_terms(ien),
        case_notes: case_notes(ien)
      }
    end

    # Why record_follow_up must not send the update for this record, or nil.
    def follow_up_refusal(ien, state)
      status, linked, terms = state.values_at(:status, :ehr_referral, :snomed_terms)
      return refusal(:closed, "referral #{ien} is closed (status #{status}); BMC UPDATE REFERRAL would drop the date") if CLOSED_STATUSES.include?(status)
      return refusal(:linked_ehr_referral, "referral #{ien} is linked to EHR referral #{linked}; not supported") unless linked.empty?
      return refusal(:unread, "DDR LISTER could not list referral #{ien}'s SNOMED CT terms") if terms.nil?
      return refusal(:several_snomed_terms, "referral #{ien} has #{terms.size} SNOMED CT terms; only one would be kept") if terms.size > 1

      refusal(:unread, "DDR LISTER could not list referral #{ien}'s CASE notes") if state[:case_notes].nil?
    end

    # What the read-back after the write says: { success: true, appointment:,
    # case_note_ien: } when it all filed as sent, else { success: false,
    # error: :unverified | :partially_filed | :not_filed, message: }. Any new
    # CASE note counts as a change, so a write that may have landed is never
    # reported :not_filed.
    def follow_up_outcome(before, after, appointment, note)
      unread = after[:error] ? after[:message] : %i[snomed_terms case_notes].find { |key| after[key].nil? }
      if unread
        return { success: false, error: :unverified,
                 message: "sent, but the read-back could not be read (#{FOLLOW_UP_FIELDS.fetch(unread, unread)}); do not resend" }
      end

      known = before[:case_notes].map { |n| n[:ien] }
      added = after[:case_notes].reject { |n| known.include?(n[:ien]) }
      sent = added.select { |n| n[:text].strip == note }
      changed = FOLLOW_UP_FIELDS.keys.reject { |key| key == :case_notes ? added.empty? : after[key] == before[key] }
      wrong = (changed & %i[schedule_within_days include_flags snomed_terms]).map { |key| "#{FOLLOW_UP_FIELDS[key]} changed" }
      wrong.unshift("1106 reads #{after[:appointment].inspect}, not #{appointment.inspect}") unless after[:appointment] == appointment
      wrong << "#{sent.size} new CASE notes with the sent text, expected 1" unless note.empty? || sent.size == 1
      return { success: true, appointment: after[:appointment], case_note_ien: (sent.first[:ien] unless note.empty?) } if wrong.empty?
      return { success: false, error: :not_filed, message: "nothing reads changed: #{wrong.join('; ')}" } if changed.empty?

      { success: false, error: :partially_filed,
        message: "#{changed.map { |key| FOLLOW_UP_FIELDS[key] }.join(', ')} changed, but #{wrong.join('; ')}" }
    end

    # STATUS OF REFERRAL (.15) internal, for record_status.
    def status_entry(ien)
      DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".15", flags: "I")
    end

    # The .15 code a status_entry reply holds, or nil when it holds none.
    def filed_status(entry)
      return nil if entry.nil? || entry[:error]

      entry[:fields].dig(".15", :internal)&.to_s
    end

    # The referral's SNOMED CT terms (#90001.22 .01), or nil when DDR LISTER
    # fails, stops short (MORE) or sends no data section: [] means none.
    def snomed_terms(ien)
      listed = complete_list(DdrFileman.lister(file: SNOMED_FILE, iens: ",#{ien},", fields: "@;.01", flags: "IP"))
      listed && listed.map { |e| e[:pieces].first.to_s }.reject(&:empty?)
    end

    # CASE notes for one referral from RCIS COMMENTS (#90001.03): .01 date,
    # .03 referral, .05 type, text in field 1 (SETMEDHX^BMCRPC3, BMCRPC3.m:132-153).
    # Listed on the "AD" index of .03, as the routine's own reader does
    # (BMCRPC1.m:133); PART "7" also matches referral 70, so the screen stays.
    # Nil when DDR LISTER fails, stops short (MORE) or sends no data section,
    # or a note's text cannot be read: [] means the referral has none.
    def case_notes(ien)
      listed = complete_list(DdrFileman.lister(file: COMMENTS_FILE, fields: "@;.01;.03;.05", flags: "IP",
                                               xref: "AD", part: ien,
                                               screen: "I $P(^(0),U,3)=#{ien.to_i},$P(^(0),U,5)=\"C\""))
      return nil unless listed

      listed.map do |e|
        text = DdrFileman.gets_entry(file: COMMENTS_FILE, iens: "#{e[:ien]},", fields: "1", flags: "I")
        return nil if text.nil? || text[:error]

        { ien: e[:ien], date: e[:pieces][0], text: Array(text.dig(:fields, "1", :text)).join("\n") }
      end
    end

    # A DDR LISTER result's entries, or nil unless it is a whole list.
    def complete_list(listed)
      listed[:entries] unless listed.nil? || listed[:error] || listed[:more] || !listed[:data]
    end

    # One line, without the "~" the RCIS word-processing writer splits on.
    def one_line(text)
      text.to_s.gsub(/[\r\n]+/, " ").tr("~", "-").strip
    end

    # RCIS DIAGNOSIS (#90001.01) entry pieces, BMCRPC4.m:104-114.
    DIAGNOSIS_FIELDS = %i[ien icd_ien patient_dfn referral_ien type primary_secondary
                          narrative_ien icd_code narrative].freeze

    # Note sections by GETMEDHX tag (BMCRPC1.m:124-128): S (secondary
    # referral notes) is sent under B.
    NOTE_SECTIONS = { medical_history: "M", business_office: "B", case: "C" }.freeze

    def name_sections(record)
      sections = record.delete(:sections) || {}
      diagnoses = (sections["D"] || []).map { |pieces| DIAGNOSIS_FIELDS.zip(pieces).to_h }
      notes = NOTE_SECTIONS.transform_values do |tag|
        (sections[tag] || []).map { |pieces| note(pieces) }
      end
      record.merge(diagnoses: diagnoses, notes: notes)
    end

    # RFCMTIEN^CMDATE^REVIEWER^text, word-processing lines joined by "~"
    # (BMCRPC1.m:136-143).
    def note(pieces)
      ien, date, reviewer, *text = pieces
      { ien: ien, date: date, reviewer: reviewer, text: text.join("^").tr("~", "\n") }
    end

    # "JAN 10, 2001": SRCHREF converts its dates with DT^DILF (BMCRPC1.m:42-43).
    def external_date(date)
      FilemanDateParser.format_external_date(date)
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    # Bind BMCRPC for the duration of the block and restore the caller's
    # option afterward (a no-op round-trip-wise when BMCRPC is already bound).
    # Every wire-reaching path below goes through here.
    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def bmc_many(mapping_name, *params)
      in_context { DataMapper[mapping_name].fetch_many(*params.map(&:to_s)) }
    end

    def bmc_text(mapping_name, *params)
      in_context { DataMapper[mapping_name].fetch_text(*params.map(&:to_s)) }
    end

    def bmc_scalar_result(mapping_name, *params)
      in_context do
        raw = DataMapper[mapping_name].fetch_scalar(*params.map(&:to_s))
        result_from_raw(raw)
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A parameter the wire would mis-frame is refused before the write is sent
      # (#472; on a real session the context bind still goes out around it);
      # the writers answer { success:, raw: }, so say why in :error. This hash
      # carries :error, where a broker-side failure from result_from_raw
      # carries :message and :raw only (#480).
      { success: false, raw: nil, error: e.message }
    end

    def result_from_raw(raw)
      rcis = RcisWire.result(raw)
      return rcis.merge(raw: raw) if rcis

      line = raw.to_s.strip
      return { success: false, raw: raw } if line.empty?

      # Non-sigil success is exactly "1", "1^..." (a 1 followed by a caret), or a
      # bare positive integer (/\A[1-9]\d*\z/). Anything else fails closed (#210).
      success = line.start_with?("1^") || line.match?(/\A[1-9]\d*\z/)
      message = line.sub(/\A[01]\^/, "").strip
      { success: success, message: message.empty? ? nil : message, raw: raw }
    end
  end
end
