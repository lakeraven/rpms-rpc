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
  # One call is not a BMC RPC: find first reads the entry with DDR GETS
  # ENTRY DATA, which BMCRPC does not list, under the caller's option (#767).
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

    # RCIS REFERRAL, the file BMC GET REFERRAL reads.
    REFERRAL_FILE = "90001"

    # One referral by RCIS REFERRAL (#90001) IEN, with its diagnoses and
    # notes named from the sections GTRFBYID^BMCRPC1 appends (#210).
    #
    # Nil for a referral not on file, and for one with no REFERRAL # (.02).
    # The routine cannot answer either: for an IEN not on file it answers
    # "Not a valid Referral Ien" as a scalar under a GLOBAL ARRAY RPC
    # (BMCRPC1.m:57), which the broker reads as a global name and raises an
    # M error on; and it finds the record by .02 on the C index
    # (BMCRPC1.m:62-65), so a referral without a number dies with GVUNDEF
    # ^TMP($J,"PRNRC",1) (#767). RCIS always files a number, so the second is
    # a data problem, not a referral a user made. find checks both with DDR
    # GETS ENTRY DATA (.01, .02) under the caller's context first, and does
    # not call BMC GET REFERRAL when the entry is missing or has no number.
    # When that check gets no reply at all, find reads as it did before it.
    def find(ien)
      return nil if ien.nil?
      return nil if numbered?(ien) == false

      record = in_context { DataMapper.referral_detail.fetch_one(ien.to_s) }
      record && name_sections(record)
    end

    # SETREFRL^BMCRPC2's formals after RSLT, RFDT through RDDX (BMCRPC2.m:8).
    ADD_PARAMETERS = 40

    # File a new referral through BMC ADD REFERRAL (SETREFRL^BMCRPC2) with
    # all ADD_PARAMETERS of its parameters, in its order, "" for one not
    # given. Any other count is refused before anything is sent (#877): on
    # YottaDB the broker packs a frame into the routine's one array formal
    # only past 31 parameters, so a shorter one dies "More actual parameters
    # than formal parameters" (as captured), and the broker takes at most 40.
    def add(*params)
      unless params.size == ADD_PARAMETERS
        raise ArgumentError, "BMC ADD REFERRAL takes all #{ADD_PARAMETERS} of SETREFRL^BMCRPC2's parameters " \
                             "(\"\" for one not given); got #{params.size}"
      end

      bmc_scalar_result(:bmc_add_referral, *params)
    end
    shape :add, resource: "referrals", verb: "POST", path: "/referrals"

    # UPDREFRL^BMCRPC2's formals after RSLT, REFIEN through DUPREF
    # (BMCRPC2.m:168-174; on IRIS they are the routine's own 35 formals).
    UPDATE_PARAMETERS = 35

    # The fields update takes, by the 1-based position of their formal in
    # UPDREFRL. Each name is the one find reads the same field back as,
    # where it reads it.
    UPDATE_FIELDS = {
      type: 2,                          # TYPE, .04: C, I, O or N
      visit_type: 3,                    # INOROUT, .14: I or O
      icd_category_ien: 4,              # ICDCAT, .12
      cpt_category_ien: 5,              # CPTCAT, .13
      purpose: 6,                       # PURPOSE, 1201
      priority_ien: 7,                  # PRIORITY, .32 (RCIS MEDICAL PRIORITIES)
      referred_to_ien: 8,               # TYPEEXT: .07, .08 or .23 by type
      visit_number: 9,                  # VISITS, 1111
      scheduling_notes: 10,             # NOTESCHD, 1301
      medical_history: 11,              # HXCMNTS, "~" between lines
      include_consultation_report: 13,  # ICSRP, 411
      include_face_sheet: 14,           # IFSHT, 405
      include_health_summary: 15,       # IHLSM, 406
      include_history_and_physical: 16, # IHSPH, 408
      include_ekg: 17,                  # IEKG, 407
      include_lab_report: 18,           # ILBRP, 412
      include_pcc_visit_form: 19,       # IPCC, 401
      include_prenatal_record: 20,      # IPRNL, 403
      include_tubal_consent: 21,        # ITUBL, 404
      include_clinic_notes: 22,         # ICLNT, 402
      include_xray_report: 23,          # IXRYR, 409
      include_xray_film: 24,            # IXRYF, 410
      business_office_notes: 25,        # BCMNTS
      other_type_ien: 26,               # OTHRTYP, .09
      snomed_ct: 27,                    # SNMDCT, to the V REFERRAL
      problem_ien: 28,                  # PROB, to the V REFERRAL
      snomed_code: 29,                  # SNMDST, the 2200 multiple
      case_notes: 30,                   # CN
      diagnosis_code: 31,               # RDCODE, an ICD DIAGNOSIS (#80) code
      diagnosis_narrative: 32,          # RDN, its provider narrative
      provider_ien: 34                  # RQPR, .06
    }.freeze

    # The SCHED WI DAY formal (12): "DAYS^MM/DD/YYYY@HH:MM", the second piece
    # the expected begin date of service (1106).
    SCHEDULE_PARAMETER = 12

    # The twelve INCLUDE flags, Y or N.
    INCLUDE_FIELDS = UPDATE_FIELDS.keys.select { |name| name.start_with?("include_") }.freeze

    # Save a referral through BMC UPDATE REFERRAL (UPDREFRL^BMCRPC2), the
    # whole-form save of the RCIS referral screen. It sends all
    # UPDATE_PARAMETERS of the routine's parameters, "" for a field not
    # given (#877).
    #
    # A field not given is left as it is, except for these, which the
    # routine files whatever it is sent:
    # - each INCLUDE flag (include_*): true files Y, false files N, and one
    #   not given is cleared ("YN"[""] is true in M);
    # - the expected begin date (1106): filed from expected_begin, a Time,
    #   and deleted when it is not given;
    # - ADDITIONAL INFO (.34), set from the flags, and DATE LAST UPDATED (.27).
    #
    # A CLOSED referral (C1 or X) takes only its notes (medical_history,
    # business_office_notes, case_notes).
    #
    # diagnosis_code and diagnosis_narrative go together: given both,
    # UPDREFRL calls EDITRD^BMCRPC5 (BMCRPC2.m:260; BMCRPC5.m:111-128), which
    # deletes the referral's RCIS DIAGNOSIS (#90001.01) entries and files
    # this one, as provisional and primary, its narrative added to PROVIDER
    # NARRATIVE (#9999999.27) when new. The code must be an ICD DIAGNOSIS
    # (#80) code ("E11.9"). For one not on file EDITRD deletes the
    # referral's diagnoses, files nothing, and UPDREFRL still answers "~`1",
    # so the code is looked up first (DDR LISTER on #80's B index, in the
    # caller's option) and one not on file is refused with nothing sent:
    # { success: false, message: }. The list of other diagnoses to keep
    # (33, DXS) is sent empty,
    # so the given one is the referral's only diagnosis afterwards. One
    # without the other raises ArgumentError: the routine would skip both.
    # Reading it back needs openrpms#1271's fix, first released in
    # bcer-9.0-20261124-60d39b6-ydb (rpms-rpc#915). DUPREF (35) is sent
    # empty: UPDREFRL does not read it.
    #
    # Returns { success:, message:, raw: }: "~`1" when filed, "~`0^message"
    # when refused. An unknown field, or a flag that is not true or false,
    # raises ArgumentError before anything is sent.
    def update(ien, expected_begin: nil, schedule_within_days: nil, **fields)
      unknown = fields.keys - UPDATE_FIELDS.keys
      raise ArgumentError, "Referral.update: unknown field(s) #{unknown.join(', ')}" unless unknown.empty?
      if fields.key?(:diagnosis_code) ^ fields.key?(:diagnosis_narrative)
        raise ArgumentError, "Referral.update: diagnosis_code and diagnosis_narrative go together"
      end
      if fields.key?(:diagnosis_code) && !icd_code_on_file?(fields[:diagnosis_code])
        return { success: false, message: "ICD DIAGNOSIS #{fields[:diagnosis_code]} is not on file; nothing was sent", raw: nil }
      end

      params = [ ien.to_s ] + ([ "" ] * (UPDATE_PARAMETERS - 1))
      fields.each { |name, value| params[UPDATE_FIELDS.fetch(name) - 1] = update_value(name, value) }
      params[SCHEDULE_PARAMETER - 1] = schedule(schedule_within_days, expected_begin)
      bmc_scalar_result(:bmc_update_referral, *params)
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

    # CONSULTATION STATUS (1306) codes.
    CONSULTATION_STATUSES = { "P" => "PENDING", "R" => "REVIEWED" }.freeze

    # File who reviewed a referral's consultation, when, and its status
    # (CONSULTATION_STATUSES), through BMC CONSULTATION STATUS UPDATE:
    # UPCNRINF^BMCRPC3(RSLT,REFIEN,CONSULTBY,CONSULTDT,CONSULTSTATUS), which
    # files 1308, 1307 and 1306 of the referral (BMCRPC3.m:190-217).
    # reviewed_by is a NEW PERSON (#200) IEN; reviewed_at is a Time, sent as
    # MM/DD/YYYY@HH:MM because the routine requires a time (DT^DILF "RT").
    #
    # Returns { success:, message:, raw: }. A referral already reviewed with
    # that status is not filed again: the routine answers success with a
    # message naming who reviewed it and when. A status that is not a code,
    # or a reviewed_at that is not a Time, raises ArgumentError before
    # anything is sent (#877).
    def update_consultation_status(referral_ien, status:, reviewed_by:, reviewed_at:)
      raise ArgumentError, "status must be one of #{CONSULTATION_STATUSES.keys.join(', ')}; got #{status.inspect}" unless CONSULTATION_STATUSES.key?(status.to_s)

      result = bmc_scalar_result(:bmc_consultation_status_update, referral_ien.to_s, reviewed_by.to_s,
                                 fileman_time(reviewed_at, "%m/%d/%Y@%H:%M"), status.to_s)
      # "~`1^<patient> has already been reviewed by ..." is a message, not an IEN.
      result[:success] && result[:ien] ? result.merge(ien: nil, message: result[:ien]) : result
    end
    shape :update_consultation_status, resource: "referrals", verb: "PUT", path: "/referrals/{referral_ien}/consultation-status"

    # The referral purposes, sorted by term: GTREFTYP^BMCRPC3 lists the EHR
    # REFERRAL TYPE subset as CONCEPT^DESCRIPTION^TERM records in one node
    # (BMCRPC3.m:155-174). A purpose is a SNOMED CT concept, so its key is the
    # concept id, not an IEN: add files the concept and the term (SNMDCT,
    # SNMDPT). Rows are { concept_id:, description_id:, name: } (#877).
    PURPOSE_FIELDS = %i[concept_id description_id name].freeze

    def purposes
      rcis_rows(bmc_text(:bmc_purpose_of_referral_list), PURPOSE_FIELDS)
    end

    # The RCIS pick lists GTREFDT^BMCRPC5 sends in five nodes, in this order
    # (BMCRPC5.m:211-259), each opening "~`" (#877):
    #   icd_categories  RCIS ICD DIAGNOSTIC CATEGORY (#90001.51): IEN, DX
    #                   CATEGORY, ACTIVE DATE, INACTIVE DATE (external dates)
    #   cpt_categories  RCIS HCPCS/CPT CATEGORY (#90001.52): IEN, name
    #   purpose_texts   RCIS PURPOSE (#90001.58): IEN, text
    #   statuses        STATUS OF REFERRAL (.15) set of codes: code, name
    #   priorities      RCIS MEDICAL PRIORITIES (#90001.84): IEN, PRIORITY
    #                   CODE and DESCRIPTION joined by a space
    REFERENCE_SECTIONS = {
      icd_categories: %i[ien name active_date inactive_date],
      cpt_categories: %i[ien name],
      purpose_texts: %i[ien name],
      statuses: %i[code name],
      priorities: %i[ien name]
    }.freeze

    # The REFERENCE_SECTIONS as a Hash of row arrays, a section the build
    # sent empty as [].
    def reference_data
      sections = bmc_text(:bmc_reference_data).to_s.delete("\r\n").split(RcisWire::SIGIL, -1).drop(1)
      REFERENCE_SECTIONS.each_with_index.to_h do |(name, fields), i|
        [ name, rcis_rows(sections[i], fields) ]
      end
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

    # The pieces SRRFRDTO^BMCRPC1 sends for each referral type
    # (BMCRPC1.m:154-221). It searches a different file per type:
    #   C (CHS)                 VENDOR (#9999999.11): IEN, name, UEI, EIN,
    #                           EIN suffix, mail-to and remit-to (comma-joined)
    #   I (another IHS facility) LOCATION (#9999999.06): IEN, name, area,
    #                           service unit, code, inactive ("1" or "")
    #   O (other)               RCIS SPECIFIC PROVIDER (#90001.53): IEN, name
    #   N (in-house)            CLINIC STOP (#40.7): IEN, name, code
    REFERRED_TO_FIELDS = {
      "C" => %i[ien name uei ein ein_suffix mail_to remit_to],
      "I" => %i[ien name area service_unit code inactive],
      "O" => %i[ien name],
      "N" => %i[ien name code]
    }.freeze

    # Who a referral of +type+ (a REFERRED_TO_FIELDS key) can go to, matched
    # on +search+ from the start of the name. A type the routine has no
    # search for is refused before anything is sent (#877).
    def search_referred_to(search, type)
      fields = REFERRED_TO_FIELDS.fetch(type.to_s) do
        raise ArgumentError, "referral type must be one of #{REFERRED_TO_FIELDS.keys.join(', ')} (got #{type.inspect})"
      end
      rcis_rows(bmc_text(:bmc_search_referred_to, search.to_s, type.to_s), fields)
    end

    # The RCIS ROUTINE REFERRAL DEF (#90001.32) templates, { ien:, name: }
    # each (GTTMPLST^BMCRPC3, BMCRPC3.m:10-19); rcis_template_detail reads one.
    def rcis_templates
      rcis_rows(bmc_text(:bmc_rcis_template_list), %i[ien name])
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

    # Log a C32 print of a referral in its C32 PRINTED (#90001.6) multiple
    # through BMC ADD C32 PRINT LOG: ADDC32LG^BMCRPC3(RSLT,REFIEN,USERIEN,
    # RRINTDT) (BMCRPC3.m:58-71). user_ien defaults on the server to the
    # signed-on user (DUZ). printed_at is a Time, sent as MM/DD/YYYY@HHMM;
    # when it is not given the parameter is left off and the routine logs
    # the print as now (an empty date is refused: BMCRPC3.m:64). A time in
    # the future is logged as now too.
    #
    # Returns { success:, ien:, message:, raw: }; :ien is the new entry in
    # the multiple (#877).
    def add_c32_print_log(referral_ien, user_ien: nil, printed_at: nil)
      params = [ referral_ien.to_s, user_ien.to_s ]
      params << fileman_time(printed_at, "%m/%d/%Y@%H%M") if printed_at
      params.pop while params.size > 1 && params.last.empty?
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

    # An update field as UPDREFRL takes it: an INCLUDE flag as Y or N.
    def update_value(name, value)
      return value.to_s unless INCLUDE_FIELDS.include?(name)
      return "" if value.nil?
      return value ? "Y" : "N" if [ true, false ].include?(value)

      raise ArgumentError, "Referral.update: #{name} is true or false; got #{value.inspect}"
    end

    # SCHED WI DAY: the days, then the expected begin date with its time.
    def schedule(days, expected_begin)
      return days.to_s if expected_begin.nil?

      "#{days}^#{fileman_time(expected_begin, '%m/%d/%Y@%H:%M')}"
    end

    # A Time in the external form a BMC routine parses with DT^DILF.
    def fileman_time(value, format)
      raise ArgumentError, "expected a Time; got #{value.inspect}" unless value.is_a?(Time) || value.is_a?(DateTime)

      value.strftime(format)
    end

    def failure
      { success: false, ien: nil, raw: nil }
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
    # True when the referral is on file with a REFERRAL # (.02), false when it
    # is not on file or has none, nil when DDR GETS ENTRY DATA gave no reply.
    def numbered?(ien)
      entry = DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".01;.02", flags: "I")
      return nil if entry.nil?
      return false if entry[:error]

      !entry[:fields].dig(".01", :internal).to_s.empty? && !entry[:fields].dig(".02", :internal).to_s.empty?
    end

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    # RCIS records ("~"-joined, "~`" sigils stripped; RcisWire.records) from
    # every line of +text+, each record's "^" pieces named by +fields+.
    def rcis_rows(text, fields)
      text.to_s.split(/\r\n|\r|\n/).flat_map { |line| RcisWire.records(line) }.map do |record|
        fields.zip(record.split("^", -1)).to_h
      end
    end

    # Whether +code+ is an ICD DIAGNOSIS (#80) .01, exactly. It reads the BA
    # index (the code and a blank), which answers at once; the B index that
    # SAVERD^BMCRPC5 walks (BMCRPC5.m:102) took 7 to 26 seconds a lookup on
    # the demo image. A read that fails raises.
    def icd_code_on_file?(code)
      code = code.to_s.strip
      return false if code.empty? || code.match?(/[\^|~`]/)

      listed = DdrFileman.lister(file: "80", fields: "@;.01", flags: "IP", xref: "BA", part: "#{code} ", max: "5")
      raise Client::RpcError, "DDR LISTER could not read ICD DIAGNOSIS (#80) for #{code}" if listed.nil? || listed[:error]

      listed[:entries].any? { |e| e[:pieces].first.to_s.strip == code }
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
