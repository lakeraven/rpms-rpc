# frozen_string_literal: true

require_relative "behavioral_health/wire"
require_relative "ddr_fileman"
require_relative "../shape"

module RpmsRpc
  # Symbolic API for IHS Behavioral Health (AMHG) — rpms-rpc#227.
  #
  # Every AMHG RPC takes a SINGLE pipe-delimited parameter. YottaDB rejects
  # multi-actual calls to these entry points with YDB-E-ACTLSTTOOLONG (#198),
  # so the packing is not a style choice.
  #
  # Wire quirks this module exists to absorb, each read from the M source the
  # #8994 registry names:
  #
  #   * "Signed" is inverted. AMHGD.m:47 sets AMHESIG to "*" when field 1112
  #     is FALSE — the star means NOT signed.
  #   * The visit-list header declares an 18th column (DOBI) that no row ever
  #     carries (AMHGD.m:53 computes it, :55 omits it).
  #   * Visit-information columns mix "IEN~external" pairs with external-only
  #     values (AMHGDVF.m:12, :27, :45).
  #   * arrival_time is permanently blank (AMHGDVF.m:40).
  #
  # Context: every AMHG call runs under AMHGRPC (BehavioralHealth::CONTEXT,
  # bound and restored by Wire#call_amhg — rpms-rpc#258); callers do not
  # bind it.
  module BehavioralHealth
    extend self
    extend Wire
    extend Shape::Declarable

    # Raised when a visit is refused before any AMHG call, or when the
    # reply does not prove the record was filed. A post-call message says
    # the outcome is unknown and that the visit may have been filed. It
    # names a record IEN when one is known, and never a value the caller
    # passed or the broker's text. A {Client::ConnectionError} (including
    # a timeout) or a {Client::RpcMError} from the AMHG call, and an
    # {RpmsRpc::Error} from a post-call DDR read, are this class with that
    # exception kept as the cause.
    class SaveError < RpmsRpc::Error; end

    # External values of BH VISIT (#9002011) field .02, piece 3 of
    # ^DD(9002011,.02,0) on the pinned image (M:MENTAL HEALTH;S:SOCIAL
    # SERVICES;O:OTHER;C:CHEMICAL DEPENDENCY). $$SCI^AMHGT returns "" for
    # any other external value (AMHGT.m:183-196) and VISIT files that
    # blank (AMHGSVF.m:22). Read-back compares the internal letter.
    PROGRAM_INTERNAL = {
      "MENTAL HEALTH" => "M",
      "SOCIAL SERVICES" => "S",
      "OTHER" => "O",
      "CHEMICAL DEPENDENCY" => "C"
    }.freeze
    PROGRAM_CODES = PROGRAM_INTERNAL.keys.freeze

    # #9002011 field .11: A:APPOINTMENT;W:WALK-IN;U:UNSPECIFIED. Same SCI
    # collapse (AMHGSVF.m:31). Read-back compares the internal letter.
    APPOINTMENT_INTERNAL = {
      "APPOINTMENT" => "A",
      "WALK-IN" => "W",
      "UNSPECIFIED" => "U"
    }.freeze
    APPOINTMENT_WITH_CODES = APPOINTMENT_INTERNAL.keys.freeze

    # BH VISIT. DDR GETS ENTRY DATA field lists are the ones save_visit
    # sends: .08 and 1112 before an edit, the patient .01 before an add,
    # pointer .01 before the AMHG call, and the filed visit fields after
    # the reply. Group fields are in the read-back only when a group name
    # was sent, because MODV files them only then.
    BH_VISIT_FILE = "9002011"
    PRE_EDIT_VISIT_FIELDS = ".08;1112"
    PRE_EDIT_VISIT_FLAGS = "I"
    READBACK_FIELDS = ".01;.02;.04;.05;.07;.08;.11;.25"
    READBACK_FIELDS_GROUP = ".01;.02;.04;.05;.07;.08;.11;.25;.12;.34;1104;1109"
    READBACK_FLAGS = "IE"
    # PATIENT (#9000001) .01 before an add. Flags "I": internal only.
    PATIENT_FILE = "9000001"
    PRE_ADD_PATIENT_FIELDS = ".01"
    PRE_ADD_PATIENT_FLAGS = "I"
    # Pointer .01 (flags "I") before AMHG SAVE VISIT. A missing row is
    # refused; the call would otherwise file the dangling pointer.
    CLINIC_FILE = "40.7"
    TYPE_OF_CONTACT_FILE = "9002012.1"
    ENCOUNTER_LOCATION_FILE = "9999999.06"
    COMMUNITY_FILE = "9999999.05"
    PROVIDER_DUZ_FILE = "200"
    PRE_POINTER_FIELDS = ".01"
    PRE_POINTER_FLAGS = "I"
    # MHSS RECORD PROVIDERS (#9002011.02). AD is the record xref
    # (^AMHRPROV("AD", visit IEN)). PART is a prefix, so FROM 0 and
    # SCREEN "I $P(^(0),U,3)=<visit>" keep the page to that visit.
    # FLAGS "IP" is internal, packed.
    # A row is "<row ien>^<duz>^<dfn>^<visit ien>^P".
    PROVIDER_FILE = "9002011.02"
    PROVIDER_XREF = "AD"
    PROVIDER_FROM = "0"
    PROVIDER_FIELDS = ".01;.02;.03;.04"
    PROVIDER_FLAGS = "IP"
    PROVIDER_MAX = "25"

    POSITIVE_IEN = /\A[1-9]\d*\z/
    # Pipe splits AMHSTR. A caret is FileMan's piece delimiter inside the
    # routines that re-parse a value. $C(30)/$C(31) frame the reply. The
    # other C0 controls and DEL are not field text.
    UNSAFE_WIRE = /[|\x00-\x1f\x7f^]/
    # 1109 GROUP NAME is free text, at most 30 bytes (ydb_chset=M $L).
    # Empty means "do not file the group fields", not a zero-length name.
    GROUP_NAME_MAX = 30
    # 1104 TIME SPENT IN GROUP is 0 through 9999. .12 ACTIVITY TIME's input
    # transform rejects anything under 1, so 1 through 9999. MODV files both
    # raw through the FDA (AMHGEVF.m:91-95), which does not run that
    # transform; the limits are enforced here.
    GROUP_TIME_MINUTES = /\A(?:0|[1-9]\d{0,3})\z/
    ACTIVITY_TIME_MINUTES = /\A[1-9]\d{0,3}\z/
    # Unary + of a leading zero drops it (AMHGSVF.m:26). A FileMan year in
    # 1800-2099 is 100-399, so the date must begin with 1, 2, or 3.
    # .01's DD minimum is 2000101 (1 Jan 1900). A later check refuses a
    # date after Date.today; that one uses the local clock.
    FILEMAN_CENTURY = /\A[1-3]/
    ENCOUNTER_DATE_MIN = 20_001_01
    # Omitted keyword, distinct from an explicit nil. On an edit both are
    # refused for every field MODV files from a piece. "" clears
    # appointment/walk-in. It does not clear program, clinic, type of
    # contact, encounter location, or community of service. group name ""
    # leaves the group fields alone.
    OMITTED = Object.new.freeze
    private_constant :PROGRAM_INTERNAL, :APPOINTMENT_INTERNAL, :BH_VISIT_FILE,
                     :PRE_EDIT_VISIT_FIELDS, :PRE_EDIT_VISIT_FLAGS,
                     :READBACK_FIELDS, :READBACK_FIELDS_GROUP, :READBACK_FLAGS,
                     :PATIENT_FILE, :PRE_ADD_PATIENT_FIELDS, :PRE_ADD_PATIENT_FLAGS,
                     :CLINIC_FILE, :TYPE_OF_CONTACT_FILE, :ENCOUNTER_LOCATION_FILE,
                     :COMMUNITY_FILE, :PROVIDER_DUZ_FILE, :PRE_POINTER_FIELDS,
                     :PRE_POINTER_FLAGS, :PROVIDER_FILE, :PROVIDER_XREF, :PROVIDER_FROM,
                     :PROVIDER_FIELDS, :PROVIDER_FLAGS, :PROVIDER_MAX, :POSITIVE_IEN,
                     :UNSAFE_WIRE, :GROUP_NAME_MAX, :GROUP_TIME_MINUTES,
                     :ACTIVITY_TIME_MINUTES, :FILEMAN_CENTURY, :ENCOUNTER_DATE_MIN,
                     :OMITTED

    # Visit list for a patient over a FileMan date range, newest first.
    #
    # Rows are screened per-user by $$ALLOWVI^AMHUTIL(DUZ,AMHIEN)
    # (AMHGD.m:33). An empty result means "no visits VISIBLE TO THIS USER in
    # this range", never "this patient has no visits" — callers must not
    # render it as the latter.
    #
    # CiaClient#call_rpc_global_array returns the raw GLOBAL ARRAY frame:
    # a sequence echo, a \x00 ack, then $C(30)-separated records ending at
    # $C(31). parse_many splits only on newlines, so the echo stays on the
    # header and that header is parsed as a visit whose IEN is
    # "<seq>\x00T00010BMXIEN" — a different value on every call, even when
    # the visit set did not change. The frame is split before parsing.
    def visits(dfn, from:, to:)
      mapping = DataMapper[:amhg_visit_list]
      response = call_amhg(mapping, from, to, dfn)

      mapping.parse_many(save_visit_rows(response)).map { |row| decorate_visit(row) }
    end

    # Detail for one visit, or nil when the IEN yields no row.
    def visit_information(visit_ien)
      mapping = DataMapper[:amhg_visit_information]
      response = call_amhg(mapping, visit_ien)
      row = mapping.parse_many(response).first
      return nil if row.nil?

      {
        ien: row[:ien],
        primary_provider:     split_ien_name(row[:primary_provider_raw]),
        program:              presence(row[:program]),
        clinic:               split_ien_name(row[:clinic_raw]),
        type_of_contact:      split_ien_name(row[:type_of_contact_raw]),
        # AMHGDVF.m:40 blanks this unconditionally. nil, not "", so a caller
        # cannot mistake a dead column for an observed empty value.
        arrival_time:         nil,
        encounter_date:       presence(row[:encounter_date]),
        encounter_location:   split_ien_name(row[:encounter_location_raw]),
        appointment_with:     presence(row[:appointment_with]),
        community_of_service: split_ien_name(row[:community_of_service_raw]),
        visit:                presence(row[:visit]),
        ehr:                  flag?(row[:ehr_flag])
      }
    end

    # Add or edit one BH VISIT (#9002011) through AMHG SAVE VISIT
    # (VISIT^AMHGSVF, AMHGSVF.m:11-45). One pipe-delimited AMHSTR. The
    # AMHG call runs under AMHGRPC via {Wire#call_amhg}. Every DDR call
    # runs in the caller's context, outside that scope: DDR GETS ENTRY
    # DATA and DDR LISTER are registered under CIAV VUECENTRIC.
    #
    # Pieces, in order: mode A/E, record IEN, primary provider (files
    # #9002011.02), program external (.02, $$SCI^AMHGT at AMHGSVF.m:22;
    # an unknown external becomes "" and is filed blank), clinic (.25 ->
    # 40.7), type of contact (.07 -> 9002012.1), arrival, encounter date
    # (.01, taken with unary + at AMHGSVF.m:26), location (.04 ->
    # 9999999.06), appointment/walk-in external (.11, set
    # A:APPOINTMENT;W:WALK-IN;U:UNSPECIFIED, SCI at AMHGSVF.m:31),
    # community of service (.05 -> AUTTCOM; a pointer, not a comment),
    # patient DFN (.08), group name (1109), group time (1104), e-sign
    # flag, activity time (.12).
    #
    # Arrival is piece 7 and is always blank. VISIT $TR's colons out of
    # it and passes it to MODV as ARR, and MODV never files ARR
    # (AMHGEVF.m:77-88). The date of service is piece 8. Unary + drops a
    # leading zero, so "0251031" would file 251031; a date that does not
    # begin with 1, 2, or 3 is refused before any RPC. A date before
    # 2000101, the DD minimum for .01, is refused. A date after today is
    # refused. That comparison uses Date.today, the process local clock,
    # not the RPMS server date. Every call sends exactly these 16 pieces,
    # blanks included. Omitting the arrival piece would put the date in
    # piece 7.
    #
    # Piece 15 is always blank. There is no +esign+ argument. A truthy
    # piece calls UPDREC^AMHGESIG (AMHGSVF.m:38-40), which stamps the
    # signature for the session DUZ and does not check an electronic
    # signature code.
    #
    # MODV^AMHGEVF (AMHGEVF.m:77-121) puts .01, .02, .25, .07, .04, .11
    # and .05 in the FDA on both add and edit. Mode "E" with a blank
    # record IEN becomes "A" (line 79), so a blank record_ien is refused
    # here and never sent. .02, .04, .05, .07 and .25 are required by the
    # DD, so program, clinic, type of contact, encounter location and
    # community of service must be non-blank on add and on edit. Nil, an
    # omitted keyword, and "" are refused for those five; "" is not a
    # clear. appointment/walk-in may be blank. On an edit, nil and an
    # omitted keyword are refused for it, and "" clears .11. group name
    # is required on an edit the same way (nil and omitted refused); ""
    # does not clear the group fields. They are filed only when the name
    # is non-empty (lines 91-95: .12, .34 = 1, 1109, 1104), and a blank
    # piece then clears .12 and 1104, so a non-empty name also requires
    # group time and activity time. The name is at most 30 bytes
    # (String#bytesize), which is $L when ydb_chset=M, not 30 characters.
    # Activity time is an integer from 1 through 9999. Group time is an
    # integer from 0 through 9999. Field .08 is filed only on add
    # (line 99).
    #
    # Before the AMHG call, each non-blank pointer is read with DDR GETS
    # ENTRY DATA, field .01, flags "I": clinic on 40.7, type of contact
    # on 9002012.1, encounter location on 9999999.06, community of
    # service on 9999999.05, and provider on 200. Nil (broker silence),
    # an error, an empty body, or a blank .01 is SaveError naming that
    # field and not the IEN, and AMHG SAVE VISIT is not called. A missing
    # clinic would otherwise file a dangling .25.
    #
    # Before an add, the same RPC reads PATIENT (#9000001) .01 (flags
    # "I") for the DFN. Nil, an error, an empty body, or a blank .01 is
    # SaveError and AMHG SAVE VISIT is not called. A read that raises is
    # the same refusal. Before an edit, the same RPC reads the stored
    # .08 and 1112 (DATE/TIME NOTE SIGNED), flags "I". The call is
    # refused, with no AMHG RPC, when that read errors, is empty, names
    # another patient, or 1112 is non-blank (the visit is signed). DDR
    # LISTER on #9002011.02 (xref AD, part the visit IEN, FROM 0, SCREEN
    # "I $P(^(0),U,3)=<visit>", fields .01;.02;.03;.04, flags IP, max 25)
    # must show exactly one primary (.04 "P" and .03 the visit) whose
    # .01 equals +provider+. The SCREEN is built only from that visit
    # IEN after it has matched a positive integer. A row whose .03 is a
    # different visit is ignored. An error marker or a MORE line is
    # SaveError, and so is any other result that is not that one
    # primary. FNDPRV^AMHGU calls CHNGPP (AMHGU.m:336-349), which
    # rewrites the existing primary's .01 to the new provider. It does
    # not add a second primary. The pre-edit refusal stands for that
    # reason.
    #
    # The reply is "T00010BMXIEN" $C(30) <+AMHIEN> $C(30) $C(31)
    # (AMHGSVF.m:41-44). MERR^AMHGU writes one row "M ERROR|<text>"
    # $C(30) and no $C(31) (AMHGU.m:108-120), so the CIA read can time
    # out. A {Client::ConnectionError} from the AMHG call, including
    # {Client::TimeoutError}, or a {Client::RpcMError}, is SaveError,
    # and that exception is its cause. The message says the outcome is
    # unknown and that the visit may have been filed.
    # {Client::RpcNotAvailableError} and {Client::RpcRefusedError} are
    # not those classes (they are {Client::RpcError}); they propagate
    # unchanged. An M error row or a reply that does not name this
    # record says the same. An add that fails leaves AMHIEN 0
    # (AMHGEVF.m:106-108). An edit that fails still returns REC
    # (lines 116-118).
    #
    # A reply that names the record is not success until DDR GETS ENTRY
    # DATA reads back .01, .02, .04, .05, .07, .08, .11 and .25, and,
    # when a group name was sent, .12, .34, 1104 and 1109. Each internal
    # equals what was sent: the normalised FileMan date (trailing zeros
    # dropped from the time fraction, the same shape unary + stores),
    # the program and appointment letters, the pointer IENs, the
    # patient, and for a group the activity time, "1", the group time
    # and the name. The same DDR LISTER must then show exactly one
    # primary equal to +provider+. A miss says the outcome is unknown
    # and that the visit may have been filed. A post-call DDR read that
    # raises {RpmsRpc::Error} is that same SaveError, naming the record
    # IEN, with the error kept as the cause.
    #
    # MODV also stores values this call does not take and does not read
    # back, because the routine sets them itself: .19 is the session
    # DUZ, .33 is "R", and 1117 is the hospital location $$HL^AMHUTIL2
    # derives from the program letter (the letter is read back as .02).
    # On add it also sets .03 to DT, .22 to "A", 1111 to 1, and a
    # #9002011.5101 audit row (.01 now, .02 the session DUZ). On edit it
    # sets .21 to DT, .22 to "M" and .28 to the session DUZ, and
    # VAUD^AMHGEVF writes .21, .28 and another audit row. Arrival is
    # not filed.
    #
    # Limits this method does not close: DD screens on the pointers are
    # not replicated. An inactive location of encounter (.04), or a
    # screen such as $$ALLOWV, can still be on file with a non-blank
    # .01 and is not rejected here. .06 ACTIVITY TYPE is required by the
    # DD (^DD(9002011,.06,0)) and AMHG SAVE VISIT has no piece for it,
    # so this call does not file it. The future-date check uses the
    # local clock.
    #
    # Returns the record IEN as a string.
    def save_visit(provider:, patient:, encounter_date:, record_ien: nil, program: OMITTED,
                   clinic: OMITTED, type_of_contact: OMITTED, encounter_location: OMITTED,
                   community_of_service: OMITTED, appointment_with: OMITTED, group_name: OMITTED,
                   group_time: nil, activity_time: nil)
      wire, requested, expected, provider_ien = save_visit_wire(
        provider: provider, patient: patient, encounter_date: encounter_date,
        record_ien: record_ien, program: program, clinic: clinic,
        type_of_contact: type_of_contact, encounter_location: encounter_location,
        community_of_service: community_of_service, appointment_with: appointment_with,
        group_name: group_name, group_time: group_time, activity_time: activity_time
      )
      patient_ien = expected.fetch(".08")
      if requested.empty?
        save_visit_confirm_pointers!(expected, provider_ien)
        save_visit_confirm_patient_exists!(patient_ien)
      else
        save_visit_confirm_patient!(requested, patient_ien)
        save_visit_require_primary!(requested, provider_ien)
        save_visit_confirm_pointers!(expected, provider_ien)
      end
      mapping = DataMapper[:amhg_save_visit]
      response = save_visit_amhg(mapping, wire, requested)
      ien = save_visit_ien(response, requested)
      save_visit_confirm_filed!(ien, expected)
      save_visit_confirm_primary!(ien, provider_ien)
      ien
    end
    shape :save_visit, resource: "behavioral-health", verb: "POST", path: "/behavioral-health/visit"

    # -- visit detail tabs ---------------------------------------------------

    # Activity tab. One row (AMHGDVF.m:291).
    def visit_activity(visit_ien)
      row = first_row(:amhg_visit_activity, visit_ien)
      return nil if row.nil?

      {
        ien: row[:ien],
        activity_type:        split_ien_name(row[:activity_type_raw]),
        activity_time:        presence(row[:activity_time]),
        flag:                 presence(row[:flag]),
        local_service_site:   split_ien_name(row[:local_service_site_raw]),
        number_served:        presence(row[:number_served]),
        # AMHGDVF.m:311 blanks this when falsy, so "" means not utilised.
        interpreter_utilized: flag?(row[:interpreter_utilized])
      }
    end

    # POV / diagnosis list. :code_pointer is a pointer into the POV code file,
    # NOT a record address — the subfile IEN is never emitted (AMHGDVF.m:64).
    def visit_axis_ii(visit_ien)
      code_rows(:amhg_visit_axis_ii, visit_ien)
    end

    # Psychosocial stressors. Same pointer caveat as {visit_axis_ii}.
    def visit_axis_iv(visit_ien)
      code_rows(:amhg_visit_axis_iv, visit_ien)
    end

    # Free-text Axis III lines. Carets were translated to spaces upstream
    # (AMHGDVF.m:88), so nothing here can contain one.
    def visit_axis_iii(visit_ien)
      text_lines(:amhg_visit_axis_iii, visit_ien)
    end

    # Axis V and GAF. Always one row on the wire, even when both are empty
    # (AMHGDVF.m:123) — we return the pair with nils rather than nil, because
    # "asked and both blank" is a real answer here.
    def visit_axis_v(visit_ien)
      row = first_row(:amhg_visit_axis_v, visit_ien)
      return { axis_v: nil, gaf: nil } if row.nil?

      { axis_v: presence(row[:axis_v]), gaf: presence(row[:gaf]) }
    end

    # Chief complaint. The wire sends the raw node with no caret sanitisation
    # (AMHGDVF.m:140), so this is read as a whole line — caret-splitting it
    # would invent columns out of the clinician's punctuation.
    def visit_chief_complaint(visit_ien)
      text_lines(:amhg_visit_chief_complaint, visit_ien).first
    end

    # SOAP text. Two sources, one shape: a TIU-backed note is served by
    # TIU^AMHGDVF2 (AMHGDVF.m:153) with the same header and row layout.
    def visit_soap(visit_ien)
      text_lines(:amhg_visit_soap, visit_ien)
    end

    def visit_comment_appointment(visit_ien)
      text_lines(:amhg_visit_comment_appointment, visit_ien)
    end

    # Assessment text. Keyed by INTAKE IEN, not visit IEN, despite the RPC
    # name — AMHGDINT.m:114 walks ^AMHRINTK. The keyword argument exists so a
    # caller cannot pass a visit IEN by habit and silently get [].
    def visit_assessment(intake_ien:)
      text_lines(:amhg_visit_assessment, intake_ien)
    end

    # Screenings recorded on a visit.
    #
    # AT MOST ONE ROW EVER ARRIVES. AMHGDVF3.m:157 increments the subscript
    # once before the screening loop at :161, so each matching screening
    # overwrites the previous one and only the last in the fixed list order
    # survives. A visit with both a Depression and a Suicide Risk screen
    # reports Suicide Risk alone.
    #
    # This returns a collection because the wire says it is one, and because
    # the defect is upstream and may be patched. Callers MUST NOT present the
    # result as a complete screening list.
    def visit_screenings(visit_ien)
      mapping = DataMapper[:amhg_visit_screening]
      mapping.parse_many(call(mapping, visit_ien)).map do |row|
        {
          visit_ien: row[:visit_ien], # BMXIEN is the visit IEN repeated
          screening_type: presence(row[:screening_type]),
          result:         presence(row[:result]),
          provider:       split_ien_name([ row[:provider_ien], row[:provider] ].join(Wire::IEN_NAME_SEPARATOR)),
          comment:        presence(row[:comment])
        }
      end
    end

    # -- treatment plans -----------------------------------------------------

    # Treatment plans for a patient over a FileMan date range, newest first.
    #
    # Screened per-user by $$ALLOWTP^AMHLETP (AMHGD.m:174) — an empty list
    # means "none visible to this DUZ", not "this patient has no plans".
    #
    # The range boundaries are NOT interchangeable with {visits}: AMHGD.m:167
    # applies the inverse-date adjustments in the opposite order to
    # VISITL^AMHGD, so the same from/to can include an edge date in one and
    # exclude it in the other.
    #
    # :review_date, :date_established and :closed_date arrive $$LVDT-formatted
    # for display. {treatment_plan} returns the same fields as raw internal
    # FileMan dates. Both are passed through as received rather than
    # normalised, because guessing which one a caller wants would hide the
    # discrepancy instead of exposing it.
    def treatment_plans(dfn, from:, to:)
      mapping = DataMapper[:amhg_treatment_plan_list]
      response = call_amhg(mapping, from, to, dfn)

      mapping.parse_many(response).map do |row|
        {
          ien: row[:ien],
          sort_date:        presence(row[:sort_date]),
          date_established: presence(row[:date_established]),
          program:          presence(row[:program]),
          status:           presence(row[:status]),
          # Falls back to the diagnosis node when field 1101 is empty
          # (AMHGD.m:178) — this column mixes problem and diagnosis text.
          problem:          presence(row[:problem]),
          provider:         presence(row[:provider]),
          review_date:      presence(row[:review_date]),
          review_count:     presence(row[:review_count]),
          closed_date:      presence(row[:closed_date])
        }
      end
    end

    # One treatment plan, or nil. Dates are INTERNAL FileMan here — see the
    # note on {treatment_plans}.
    def treatment_plan(plan_ien)
      row = first_row(:amhg_treatment_plan, plan_ien)
      return nil if row.nil?

      {
        ien: row[:ien],
        date_established:    presence(row[:date_established]),
        program:             presence(row[:program]),
        target_date:         presence(row[:target_date]),
        review_date:         presence(row[:review_date]),
        date_closed:         presence(row[:date_closed]),
        designated_provider: split_ien_name(row[:designated_provider_raw]),
        problem_list:        presence(row[:problem_list]),
        case_admit:          presence(row[:case_admit]),
        concurred_date:      presence(row[:concurred_date]),
        concur_supervisor:   split_ien_name(row[:concur_supervisor_raw]),
        dsm4:                flag?(row[:dsm4])
      }
    end

    # Reviews recorded against a plan.
    #
    # :ien is the review subfile IEN (the wire's BMXIEN2) — the addressable
    # one. :plan_ien is the plan IEN repeated on every row.
    #
    # The wire's ReviewProviderComplete / ReviewSupervisorComplete columns are
    # IEN~name pairs, not completion status (AMHGDTP.m:193-194). We surface
    # them as :review_provider / :review_supervisor identities and expose no
    # "complete" key at all, so the misnomer cannot propagate.
    def treatment_plan_reviews(plan_ien)
      mapping = DataMapper[:amhg_treatment_plan_reviews]
      mapping.parse_many(call(mapping, plan_ien)).map do |row|
        {
          ien: row[:ien],
          plan_ien:           row[:plan_ien],
          review_date:        presence(row[:review_date]),
          next_review_date:   presence(row[:next_review_date]),
          review_provider:    split_ien_name(row[:review_provider_raw]),
          review_supervisor:  split_ien_name(row[:review_supervisor_raw])
        }
      end
    end

    # Plan participants. No per-row identifier: AMHGDTP.m:215 emits the plan
    # IEN and never the subfile IEN, so these cannot be addressed for edit.
    def treatment_plan_participants(plan_ien)
      mapping = DataMapper[:amhg_treatment_plan_participants]
      mapping.parse_many(call(mapping, plan_ien)).map do |row|
        { plan_ien: row[:plan_ien],
          participant: presence(row[:participant]),
          relationship: presence(row[:relationship]) }
      end
    end

    # Plan narrative. Raw nodes, no caret sanitisation (AMHGDTP.m:168).
    def treatment_plan_narrative(plan_ien)
      text_lines(:amhg_treatment_plan_narrative, plan_ien)
    end

    # -- suicide risk --------------------------------------------------------

    # Suicide risk forms for a patient over a FileMan date range.
    #
    # Screened per-user by $$ALLOW^AMHSFR (AMHGD.m:252): an empty list means
    # "none visible to this DUZ", never "this patient has no forms". For this
    # cluster in particular, rendering absence as "no risk history" would be a
    # clinical misstatement.
    #
    # :complete inverts the wire's "I" marker (AMHGD.m:256), which is present
    # when the form is INCOMPLETE.
    def suicide_forms(dfn, from:, to:)
      mapping = DataMapper[:amhg_suicide_form_list]
      response = call_amhg(mapping, from, to, dfn)

      mapping.parse_many(response).map do |row|
        {
          ien: row[:ien],
          sort_date:         presence(row[:sort_date]),
          date:              presence(row[:date]),
          local_case_number: presence(row[:local_case_number]),
          provider:          presence(row[:provider]),
          suicidal_behavior: presence(row[:suicidal_behavior]),
          complete:          row[:incomplete_marker].to_s.strip != "I"
        }
      end
    end

    # One suicide risk form, or nil. All sixteen columns — the header is built
    # across two SETs (AMHGDSF.m:19-20) and a reader that stops at the first
    # loses Lethality, LocationofAct, LocationOther, Disposition and
    # DispositionText.
    def suicide_form(form_ien)
      row = first_row(:amhg_suicide_form, form_ien)
      return nil if row.nil?

      {
        ien: row[:ien],
        local_case_number:        presence(row[:local_case_number]),
        provider:                 split_ien_name(row[:provider_raw]),
        date_of_act:              presence(row[:date_of_act]), # internal FileMan
        community_where_occurred: split_ien_name(row[:community_where_occurred_raw]),
        relationship_status:      presence(row[:relationship_status]),
        employment_status:        presence(row[:employment_status]),
        education:                presence(row[:education]),
        highest_grade:            presence(row[:highest_grade]),
        suicidal_behavior:        presence(row[:suicidal_behavior]),
        previous_attempts:        presence(row[:previous_attempts]),
        lethality:                presence(row[:lethality]),
        location_of_act:          presence(row[:location_of_act]),
        location_other:           presence(row[:location_other]),
        disposition:              split_ien_name(row[:disposition_raw]),
        disposition_text:         presence(row[:disposition_text])
      }
    end

    # Methods recorded on a form.
    #
    # ROWS ARE NOT METHODS. An overdose (method 7) with recorded drugs emits
    # one row per drug (AMHGDSF.m:73), so the same method repeats; any other
    # method emits a single row with no drug (:75-78). The method subfile IEN
    # is never sent, so rows cannot be grouped back into distinct methods —
    # callers counting rows are counting method-drug pairs.
    def suicide_form_methods(form_ien)
      mapping = DataMapper[:amhg_suicide_form_methods]
      mapping.parse_many(call(mapping, form_ien)).map do |row|
        { form_ien: row[:form_ien],
          method: presence(row[:method]),
          method_if_other: presence(row[:method_if_other]),
          drug: split_ien_name(row[:drug_raw]),
          drug_if_other: presence(row[:drug_if_other]) }
      end
    end

    # Substance use recorded on a form. Always at least one row — a "not 2"
    # answer still emits the substance value with blank drug columns
    # (AMHGDSF.m:106-108), so an empty array means the RPC returned nothing at
    # all, not that the question went unasked.
    def suicide_form_substances(form_ien)
      mapping = DataMapper[:amhg_suicide_form_substances]
      mapping.parse_many(call(mapping, form_ien)).map do |row|
        { form_ien: row[:form_ien],
          substance: presence(row[:substance]),
          drug: split_ien_name(row[:drug_raw]),
          drug_if_other: presence(row[:drug_if_other]) }
      end
    end

    # Contributing factors recorded on a form.
    def suicide_form_contributing_factors(form_ien)
      mapping = DataMapper[:amhg_suicide_form_contributing_factors]
      mapping.parse_many(call(mapping, form_ien)).map do |row|
        { form_ien: row[:form_ien],
          contributing_factor: presence(row[:contributing_factor]),
          if_other: presence(row[:if_other]) }
      end
    end

    private

    def call(mapping, param)
      call_amhg(mapping, param)
    end

    def save_visit_wire(provider:, patient:, encounter_date:, record_ien:, program:, clinic:,
                        type_of_contact:, encounter_location:, community_of_service:,
                        appointment_with:, group_name:, group_time:, activity_time:)
      requested = save_visit_record_ien(record_ien)
      editing = !requested.empty?
      program_piece = save_visit_code(
        save_visit_required_text(program, "program", editing), PROGRAM_CODES, "program"
      )
      clinic_piece = save_visit_required_ien(save_visit_required_text(clinic, "clinic", editing), "clinic")
      contact_piece = save_visit_required_ien(
        save_visit_required_text(type_of_contact, "type of contact", editing), "type of contact"
      )
      location_piece = save_visit_required_ien(
        save_visit_required_text(encounter_location, "encounter location", editing), "encounter location"
      )
      community_piece = save_visit_required_ien(
        save_visit_required_text(community_of_service, "community of service", editing),
        "community of service"
      )
      appointment_piece = save_visit_code(
        save_visit_explicit(appointment_with, "appointment/walk-in", editing),
        APPOINTMENT_WITH_CODES, "appointment/walk-in"
      )

      name = save_visit_group_name(group_name, editing)
      gtime = save_visit_group_minutes(group_time, "group time", name, GROUP_TIME_MINUTES, "0 through 9999")
      atime = save_visit_group_minutes(activity_time, "activity time", name, ACTIVITY_TIME_MINUTES, "1 through 9999")
      encounter_piece = save_visit_encounter(encounter_date)
      patient_piece = save_visit_required_ien(patient, "patient")
      provider_piece = save_visit_required_ien(provider, "provider")
      pieces = [
        editing ? "E" : "A",
        requested,
        provider_piece,
        program_piece,
        clinic_piece,
        contact_piece,
        "",
        encounter_piece,
        location_piece,
        appointment_piece,
        community_piece,
        patient_piece,
        name,
        gtime,
        "",
        atime
      ]
      wire = pieces.join("|")
      # Internal invariant: VISIT^AMHGSVF is 16 pieces, date in piece 8,
      # e-sign piece 15 blank.
      count = wire.split("|", -1).length
      raise Error, "AMHG SAVE VISIT wire has #{count} pieces, not 16" unless count == 16

      expected = {
        ".01" => save_visit_filed_date(encounter_piece),
        ".02" => save_visit_set_internal(program_piece, PROGRAM_INTERNAL),
        ".04" => location_piece,
        ".05" => community_piece,
        ".07" => contact_piece,
        ".08" => patient_piece,
        ".11" => save_visit_set_internal(appointment_piece, APPOINTMENT_INTERNAL),
        ".25" => clinic_piece
      }
      unless name.empty?
        expected[".12"] = atime
        expected[".34"] = "1"
        expected["1104"] = gtime
        expected["1109"] = name
      end
      [ wire, requested, expected, provider_piece ]
    end

    # nil is an add. A blank string is mode E with no IEN, which MODV turns
    # into an add (AMHGEVF.m:79). Refuse that before the RPC.
    def save_visit_record_ien(value)
      return "" if value.nil?

      text = save_visit_text(value)
      save_visit_refuse!("record IEN is blank") if text.empty?
      save_visit_refuse!("record IEN must be a positive integer") unless text.match?(POSITIVE_IEN)
      text
    end

    # On an edit, an omitted keyword and an explicit nil are the same
    # refusal. "" is left for the caller: appointment/walk-in sends it,
    # and the DD-required pieces refuse it.
    def save_visit_explicit(value, label, editing)
      if editing && (value.equal?(OMITTED) || value.nil?)
        save_visit_refuse!("#{label} is required when editing a visit")
      end
      value.equal?(OMITTED) ? nil : value
    end

    # .02, .04, .05, .07 and .25 are required by the DD on add and on
    # edit. "" is not a clear for those pieces.
    def save_visit_required_text(value, label, editing)
      text = save_visit_text(save_visit_explicit(value, label, editing))
      save_visit_refuse!("#{label} is required") if text.empty?
      text
    end

    def save_visit_required_ien(value, label)
      text = save_visit_text(value)
      save_visit_refuse!("#{label} is required") if text.empty?
      save_visit_refuse!("#{label} must be a positive integer") unless text.match?(POSITIVE_IEN)
      text
    end

    def save_visit_code(value, allowed, label)
      text = save_visit_text(value)
      return "" if text.empty?
      save_visit_refuse!("#{label} is not a filed code") unless allowed.include?(text)

      text
    end

    # On an edit the keyword is required. nil and an omitted keyword are
    # the same refusal; "" means "do not touch the group fields". A
    # non-empty name is 1109, at most 30 bytes.
    def save_visit_group_name(value, editing)
      if editing && (value.equal?(OMITTED) || value.nil?)
        save_visit_refuse!("group name is required when editing a visit")
      end
      text = save_visit_text(value.equal?(OMITTED) ? nil : value)
      save_visit_refuse!("group name is longer than 30 bytes") if text.bytesize > GROUP_NAME_MAX
      text
    end

    # A non-empty group name files .12 and 1104 even when the piece is
    # blank, and FILE^DIE then clears them (AMHGEVF.m:91-95,116). Both
    # times are required in that case. Either time without a name is
    # refused. Blank stays blank, and "0" is sent as "0".
    def save_visit_group_minutes(value, label, name, pattern, range)
      text = save_visit_text(value)
      if name.empty?
        save_visit_refuse!("#{label} requires a group name") unless text.empty?
        return ""
      end
      save_visit_refuse!("#{label} is required when a group name is sent") if text.empty?
      save_visit_refuse!("#{label} must be an integer from #{range}") unless text.match?(pattern)
      text
    end

    def save_visit_encounter(value)
      text = save_visit_text(value)
      save_visit_refuse!("encounter date is required") if text.empty?
      # "0251031" parses as a date (year 1725) and unary + files 251031.
      unless text.match?(FILEMAN_CENTURY) && FilemanDateParser.parse_datetime_or_date(text)
        save_visit_refuse!("encounter date is not a FileMan date")
      end
      date_fm = text.split(".", 2).first.to_i
      save_visit_refuse!("encounter date is before 2000101") if date_fm < ENCOUNTER_DATE_MIN
      save_visit_refuse!("encounter date is after today") if date_fm > save_visit_today_fm
      text
    end

    # Local calendar date as a FileMan integer. Not the RPMS server's DT.
    def save_visit_today_fm
      FilemanDateParser.format_date(Date.today).to_i
    end

    def save_visit_text(value)
      return "" if value.nil?

      text = value.to_s
      save_visit_refuse!("a value contains a separator or control character") if text.match?(UNSAFE_WIRE)
      text.strip
    end

    def save_visit_set_internal(external, table)
      return "" if external.empty?

      table.fetch(external)
    end

    # Unary + drops trailing zeros in the time fraction (AMHGSVF.m:26).
    # "3251031.0930" is stored as "3251031.093"; a fraction of only zeros
    # is stored as the date.
    def save_visit_filed_date(text)
      return text unless text.include?(".")

      date, fraction = text.split(".", 2)
      fraction = fraction.sub(/0+\z/, "")
      fraction.empty? ? date : "#{date}.#{fraction}"
    end

    # .08 is filed only on add. An edit that names another patient still
    # files the other pieces (AMHGEVF.m:99,116).
    #
    # Before an add the patient must already be on file. Nil (broker
    # silence), an error, an empty body, a blank .01, or a read that
    # raises is a refusal, and AMHG SAVE VISIT is not called. The
    # :failed marker keeps a broker exception from being rescued again
    # as this method's own SaveError.
    def save_visit_confirm_patient_exists!(dfn)
      got = begin
        DdrFileman.gets_entry(
          file: PATIENT_FILE, iens: "#{dfn},",
          fields: PRE_ADD_PATIENT_FIELDS, flags: PRE_ADD_PATIENT_FLAGS
        )
      rescue Error
        :failed
      end
      save_visit_refuse!("the patient could not be read") if save_visit_dot01_missing?(got)
    end

    def save_visit_dot01_missing?(got)
      return true if got.nil? || got == :failed
      return true if got[:error]

      got[:fields].dig(".01", :internal).to_s.strip.empty?
    end

    # Non-blank pointers only. The message names the field and not the IEN.
    def save_visit_confirm_pointers!(expected, provider_ien)
      [
        [ "clinic", CLINIC_FILE, expected.fetch(".25") ],
        [ "type of contact", TYPE_OF_CONTACT_FILE, expected.fetch(".07") ],
        [ "encounter location", ENCOUNTER_LOCATION_FILE, expected.fetch(".04") ],
        [ "community of service", COMMUNITY_FILE, expected.fetch(".05") ],
        [ "provider", PROVIDER_DUZ_FILE, provider_ien ]
      ].each do |label, file, ien|
        next if ien.to_s.empty?

        save_visit_confirm_pointer!(label, file, ien)
      end
    end

    def save_visit_confirm_pointer!(label, file, ien)
      got = begin
        DdrFileman.gets_entry(
          file: file, iens: "#{ien},",
          fields: PRE_POINTER_FIELDS, flags: PRE_POINTER_FLAGS
        )
      rescue Error
        nil
      end
      save_visit_refuse!("#{label} is not on file") if save_visit_dot01_missing?(got)
    end

    def save_visit_confirm_patient!(record_ien, patient)
      got = save_visit_ddr(
        file: BH_VISIT_FILE, iens: "#{record_ien},",
        fields: PRE_EDIT_VISIT_FIELDS, flags: PRE_EDIT_VISIT_FLAGS
      )
      stored = save_visit_stored_patient(got)
      save_visit_refuse!("the stored patient could not be read") if stored.nil?
      save_visit_refuse!("the visit is signed") if save_visit_signed?(got)
      save_visit_refuse!("the stored patient does not match this visit") unless stored == patient
    rescue Error => e
      raise if e.is_a?(SaveError)

      save_visit_refuse!("the stored patient could not be read")
    end

    def save_visit_signed?(got)
      !got[:fields].dig("1112", :internal).to_s.strip.empty?
    end

    def save_visit_stored_patient(got)
      return nil if got.nil? || got[:error] || got[:fields].empty?

      raw = got[:fields].dig(".08", :internal)
      return nil if raw.nil?

      ien = raw.to_s.split(";", 2).first.to_s.strip
      ien.empty? ? nil : ien
    end

    # The reply IEN is success only when the stored fields equal what was
    # sent. A miss says the visit may have been filed. Group fields are
    # part of that list only when a group name was sent. A DDR read that
    # raises keeps that error as the cause.
    def save_visit_confirm_filed!(ien, expected)
      got = save_visit_ddr(
        file: BH_VISIT_FILE, iens: "#{ien},",
        fields: save_visit_readback_fields(expected), flags: READBACK_FLAGS
      )
      save_visit_unconfirmed!(ien) unless save_visit_filed?(got, expected)
    rescue Error => e
      raise if e.is_a?(SaveError)

      save_visit_ambiguous!(ien, cause: e)
    end

    def save_visit_readback_fields(expected)
      expected.key?("1109") ? READBACK_FIELDS_GROUP : READBACK_FIELDS
    end

    # Exactly one primary (.04 P, .03 this visit) whose .01 is provider.
    # Anything else is refused. FNDPRV^AMHGU calls CHNGPP
    # (AMHGU.m:336-349), which rewrites the existing primary's .01 to
    # the new provider. It does not add a second primary.
    def save_visit_require_primary!(visit_ien, provider)
      rows = save_visit_primaries(visit_ien)
      save_visit_refuse!("the primary provider could not be read") if rows.nil?
      return if save_visit_primary?(rows, provider)

      save_visit_refuse!("changing the primary provider is not supported")
    rescue Error => e
      raise if e.is_a?(SaveError)

      save_visit_refuse!("the primary provider could not be read")
    end

    # After the reply the same lookup must still show that one primary.
    # A miss may mean the row was filed.
    def save_visit_confirm_primary!(visit_ien, provider)
      rows = save_visit_primaries(visit_ien)
      save_visit_ambiguous!(visit_ien) unless save_visit_primary?(rows, provider)
    rescue Error => e
      raise if e.is_a?(SaveError)

      save_visit_ambiguous!(visit_ien, cause: e)
    end

    def save_visit_primary?(rows, provider)
      rows&.size == 1 && rows.first[:pieces][0].to_s.strip == provider
    end

    # nil when the list cannot be trusted: no body, an error marker, or a
    # MORE line (the page is not the whole xref). Otherwise the P rows
    # for this visit.
    def save_visit_primaries(visit_ien)
      got = save_visit_lister(visit_ien)
      return nil if got.nil? || got[:error] || got[:more]

      visit = visit_ien.to_s
      got[:entries].select do |entry|
        pieces = entry[:pieces]
        pieces.is_a?(Array) && pieces.length >= 4 &&
          pieces[2].to_s.strip == visit && pieces[3].to_s.strip == "P"
      end
    end

    # Outside call_amhg. The SCREEN is only the validated visit IEN, so a
    # caller value cannot become M code. FROM 0 with that screen is the
    # page that is this visit, not the PART prefix (1 also matches 10).
    def save_visit_lister(visit_ien)
      ien = visit_ien.to_s
      return nil unless ien.match?(POSITIVE_IEN)

      DdrFileman.lister(
        file: PROVIDER_FILE, xref: PROVIDER_XREF, part: ien, from: PROVIDER_FROM,
        screen: "I $P(^(0),U,3)=#{ien}",
        fields: PROVIDER_FIELDS, flags: PROVIDER_FLAGS, max: PROVIDER_MAX
      )
    end

    # MERR writes no $C(31) (AMHGU.m:116-119), so the CIA read of this
    # call can time out after the routine has filed. ConnectionError
    # covers that timeout. RpcMError means the routine ran and the
    # outcome is still unknown. RpcNotAvailableError and RpcRefusedError
    # are RpcError, not these two, so they are not wrapped.
    def save_visit_amhg(mapping, wire, requested)
      call_amhg(mapping, wire)
    rescue Client::ConnectionError, Client::RpcMError => e
      known = requested.empty? ? nil : requested
      save_visit_ambiguous!(known, cause: e)
    end

    def save_visit_filed?(got, expected)
      return false if got.nil? || got[:error] || got[:fields].empty?

      expected.all? { |field, want| save_visit_readback(field, got[:fields]) == want }
    end

    def save_visit_readback(field, fields)
      raw = fields.dig(field, :internal)
      return nil if raw.nil?

      text = raw.to_s.strip
      return text.split(";", 2).first.to_s.strip if field == ".08"

      text
    end

    # Outside call_amhg. A direct DdrFileman.gets_entry call is what the
    # required-RPC list attributes to this module. DDR GETS ENTRY DATA is
    # an ARRAY (return type 2): a broker {Client} reads it with call_rpc,
    # which stops at EOD. call_rpc_global_array waits for $C(31) and would
    # time out on that RPC. A stand-in that is not a Client (the post-call
    # double, and MockClient) raises or answers from call_rpc_global_array,
    # so a visit-file read goes through that entry point there.
    def save_visit_ddr(file:, iens:, fields:, flags:)
      client = RpmsRpc.client
      broker = defined?(Client) && client.is_a?(Client)
      if file == BH_VISIT_FILE && !broker && client.respond_to?(:call_rpc_global_array)
        param = DdrFileman.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags)
        return save_visit_parse_gets(client.call_rpc_global_array("DDR GETS ENTRY DATA", param))
      end

      DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: flags)
    end

    # Same field rows as {DdrFileman.gets_entry}. Word-processing bodies
    # are not in the visit read, so a "[WORD PROCESSING]" row is skipped.
    def save_visit_parse_gets(response)
      return nil if response.nil?

      lines = response.is_a?(Array) ? response.map(&:to_s) : response.to_s.split(/\r?\n/)
      return nil if lines.empty?

      fields = {}
      lines.each do |line|
        next if line.start_with?("[")

        pieces = line.split("^", -1)
        next if pieces.length < 4 || pieces[3] == "[WORD PROCESSING]"

        fields[pieces[2]] = { internal: pieces[3], external: pieces[4..].join("^") }
      end
      error = lines.include?("[ERROR]") || (fields.empty? && !lines.include?("[Data]"))
      { fields: fields, error: error }
    end

    # GLOBAL ARRAY reply: optional "<seq>\x00" ack, rows split on $C(30),
    # cut at $C(31). A newline-only body (a client that already split, or
    # a line seed) is used as rows. Shared with {visits}: a header left
    # glued to the sequence echo parses as a visit. The IEN field is a
    # string so an "M ERROR|..." row is not coerced to 0. The broker text
    # stays out of the message: the outcome is unknown either way.
    def save_visit_ien(response, requested)
      rows = save_visit_rows(response)
      known = requested.empty? ? nil : requested
      save_visit_ambiguous!(known) if rows.any? { |row| row.start_with?("M ERROR|") }

      data = rows.reject { |row| DataMapper.recordset_header_row?(row) }
      ien = data.empty? ? "" : DataMapper[:amhg_save_visit].parse_one(data.first)&.dig(:ien).to_s
      save_visit_ambiguous!(known) unless ien.match?(POSITIVE_IEN)
      save_visit_ambiguous!(known) if known && ien != known
      ien
    end

    def save_visit_rows(response)
      body = response.is_a?(Array) ? response.join("\n") : response.to_s
      body = body.split("\x00", 2).last if body.include?("\x00")
      body = body.split("\x1f", 2).first.to_s
      parts = body.include?("\x1e") ? body.split("\x1e") : body.split(/\r?\n/)
      parts.filter_map do |row|
        row = row.delete_prefix("\r\n").delete_prefix("\n").delete_prefix("\r")
        stripped = DataMapper.strip_recordset_separators(row)
        stripped.empty? ? nil : stripped
      end
    end

    def save_visit_refuse!(message)
      raise SaveError, message
    end

    def save_visit_ambiguous!(record_ien, cause: nil)
      where = record_ien.nil? ? "the visit" : "record #{record_ien}"
      message = "AMHG SAVE VISIT outcome unknown; #{where} may have been filed"
      raise SaveError, message, cause: cause if cause

      raise SaveError, message
    end

    def save_visit_unconfirmed!(record_ien)
      raise SaveError, "AMHG SAVE VISIT outcome unknown; record #{record_ien} may have been filed but was not confirmed"
    end

    # The wire's Signed column is a NEGATIVE marker, and the EHR path clears
    # it regardless of the underlying field (AMHGD.m:47-49). We report the
    # boolean the column actually means and surface :ehr alongside, so a
    # caller that needs to distinguish "signed" from "EHR-sourced, marker
    # suppressed" can.
    def decorate_visit(row)
      {
        ien: row[:ien],
        visit_date:    presence(row[:visit_date]),
        display_date:  presence(row[:display_date]),
        pov:           presence(row[:pov]),
        axis_v:        presence(row[:axis_v]),
        clinic:        presence(row[:clinic]),
        activity:      presence(row[:activity]),
        visit_type:    presence(row[:visit_type]),
        contact_type:  presence(row[:contact_type]),
        provider:      presence(row[:provider]),
        signed:        row[:signed_marker].to_s.strip != "*",
        ehr:           flag?(row[:ehr_flag]),
        delete_intakes: flag?(row[:delete_intakes]),
        location:      presence(row[:location]),
        group:         flag?(row[:group_flag]),
        program:       presence(row[:program]),
        activity_time: presence(row[:activity_time])
      }
    end


    def flag?(value)
      v = value.to_s.strip
      !v.empty? && v != "0"
    end



    def code_rows(mapping_name, param)
      mapping = DataMapper[mapping_name]
      mapping.parse_many(call(mapping, param)).map do |row|
        { code_pointer: presence(row[:code_pointer]),
          code: presence(row[:code]),
          narrative: presence(row[:narrative]) }
      end
    end
  end
end
