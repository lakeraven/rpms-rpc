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

    # Raised when a visit or purpose of visit is refused before any AMHG
    # call, or when the reply does not prove the record was filed. A
    # post-call message says the outcome is unknown and that the record
    # may have been filed. It names a record IEN when one is known, and
    # never a value the caller passed or the broker's text. A
    # {Client::ConnectionError} (including a timeout) or a
    # {Client::RpcMError} from the AMHG call, and an {RpmsRpc::Error}
    # from a post-call DDR read, are this class with that exception kept
    # as the cause. {Client::FrameTooLongError} from the AMHG call is
    # this class too, cause kept, but the message says nothing was sent:
    # the frame is rejected before the RPC goes out, so the outcome is
    # not unknown. That is save_visit and save_pov.
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

    # POV rows (#9002011.01, ^AMHRPRO). AD is the record xref. PART is a
    # prefix, so FROM 0 and SCREEN "I $P(^(0),U,3)=<record>" keep the page
    # to that record. FLAGS "IP" with .04E: FLAGS "IE" returns [Errors]
    # on this file. .01, .02 and .03 are internal; .04E is the narrative's
    # external text, because FNDNARR can partial-match (AMHGU.m:320-325).
    # A row whose .03 is not this record is ignored.
    POV_FILE = "9002011.01"
    POV_XREF = "AD"
    POV_FROM = "0"
    POV_FIELDS = ".01;.02;.03;.04E"
    POV_FLAGS = "IP"
    POV_MAX = "25"
    # Axis IV multiple (#9002011.06101). Mode "E" clears ^AMHREC(record,61)
    # before the adds (CLNA4^AMHGEVF, AMHGEVF.m:71-75). Listed by IENS
    # ",record,". No xref, part, from or screen: ADDAXIS4 stores only .01,
    # and a piece-3 screen errors. FLAGS "IP": .01 is the stressor IEN.
    AXIS_IV_SUBFILE = "9002011.06101"
    AXIS_IV_FIELDS = ".01"
    AXIS_IV_FLAGS = "IP"
    AXIS_IV_MAX = "25"
    # .01 of each problem, before AMHG SAVE POV. A missing row would
    # otherwise be filed as a dangling pointer (ADDPOV, AMHGEVF.m:12).
    MHSS_PROBLEM_FILE = "9002012.2"
    # .01 of each Axis IV stressor (subfile 9002011.06101 points here).
    PSYCHOSOCIAL_FILE = "9002012.9"
    # .14 AXIS V and 1115 GAF SCALE TYPE after the reply, flags "IE".
    # 5301 is a separate read, flags "E", only when a line was sent.
    # A blank piece leaves the WP unchanged (AXIS3, AMHGSVF.m:109).
    POV_VISIT_FIELDS = ".14;1115"
    POV_VISIT_FLAGS = "IE"
    AXIS_III_FIELD = "5301"
    AXIS_III_FLAGS = "E"
    # 5301 is a word-processing line. 245 bytes is the FileMan WP width.
    # 1115 is free text, 1 through 20 bytes. .14 is an integer 0 through 100.
    AXIS_III_MAX_BYTES = 245
    GAF_MAX_BYTES = 20
    AXIS_V_MAX = 100
    AXIS_V_INTEGER = /\A(?:0|[1-9]\d*)\z/
    # #9999999.27 field .01, the narrative FNDNARR lays go. The pinned
    # input transform is
    # K:$L(X)>160!($L(X)<2)!'((X'?1P.E)!(X?1"|".E))!(X'?.ANP) X.
    # $L is bytes when ydb_chset=M. Printable ASCII is 0x20 through
    # 0x7E, the set this call accepts, including the space a narrative
    # is filed with. Leading punctuation is MUMPS patcode P. A leading
    # "|" is the transform's exemption and is refused earlier as a wire
    # separator. More than POV_MAX diagnoses, or AXIS_IV_MAX stressors,
    # is refused before any RPC: the lister cannot verify a longer page,
    # and CLNPOV or CLNA4 has already deleted the stored rows.
    NARRATIVE_MIN_BYTES = 2
    NARRATIVE_MAX_BYTES = 160
    PRINTABLE_ASCII = /\A[\x20-\x7E]*\z/
    NARRATIVE_LEADING_PUNCT = /\A[!"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~]/
    # "*" splits a list (ARRAY^AMHGU) and "~" splits an item. "|" , "^",
    # the C0 controls and DEL are refused by WIRE_SEPARATOR. C1 controls
    # are in UNSAFE_WIRE for every free-text value except a POV
    # narrative, which refuses them as non-ASCII under the .01 transform.
    POV_LIST_MARK = /[~*]/
    private_constant :POV_FILE, :POV_XREF, :POV_FROM, :POV_FIELDS, :POV_FLAGS, :POV_MAX,
                     :AXIS_IV_SUBFILE, :AXIS_IV_FIELDS, :AXIS_IV_FLAGS, :AXIS_IV_MAX,
                     :MHSS_PROBLEM_FILE, :PSYCHOSOCIAL_FILE,
                     :POV_VISIT_FIELDS, :POV_VISIT_FLAGS, :AXIS_III_FIELD, :AXIS_III_FLAGS,
                     :AXIS_III_MAX_BYTES, :GAF_MAX_BYTES, :AXIS_V_MAX, :AXIS_V_INTEGER,
                     :NARRATIVE_MIN_BYTES, :NARRATIVE_MAX_BYTES, :PRINTABLE_ASCII,
                     :NARRATIVE_LEADING_PUNCT, :POV_LIST_MARK

    POSITIVE_IEN = /\A[1-9]\d*\z/
    # Pipe splits AMHSTR. A caret is FileMan's piece delimiter inside the
    # routines that re-parse a value. $C(30)/$C(31) frame the reply. The
    # other C0 controls and DEL are not field text (WIRE_SEPARATOR).
    # UNSAFE_WIRE adds the C1 controls, U+0080 through U+009F. A POV
    # narrative does not use that wider class: the #9999999.27 .01
    # transform refuses every byte outside printable ASCII, and that
    # refusal names the transform.
    WIRE_SEPARATOR = /[|\x00-\x1f\x7f^]/
    UNSAFE_WIRE = /[|\x00-\x1f\x7f\u0080-\u009f^]/
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
                     :WIRE_SEPARATOR, :UNSAFE_WIRE, :GROUP_NAME_MAX, :GROUP_TIME_MINUTES,
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
    # runs outside that scope, in the caller's context: DDR GETS ENTRY
    # DATA and DDR LISTER are registered under CIAV VUECENTRIC. A session
    # that declared no context cannot be restored by the scope and would
    # stay bound to AMHGRPC, so only in that case the post-call reads
    # re-bind DDR_CONTEXT first (binds: AMHGRPC, then DDR_CONTEXT).
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
    # A value equal to "@" after strip is FileMan's delete-field marker.
    # It is refused before the wire is built, and no RPC is sent. A
    # longer value that contains "@" is not that marker.
    #
    # Every value is coerced with to_s. It must be a String whose
    # encoding is UTF-8, US-ASCII, or ASCII-8BIT and whose bytes are
    # valid UTF-8. Any other encoding, an invalid byte sequence, or a
    # to_s that is not a String is SaveError, and nothing is sent. The
    # tag is checked before the bytes are re-read: Latin-1,
    # Windows-1252, UTF-16, and UTF-32 are refused even when those
    # bytes would be valid UTF-8. "|", "^", the C0 controls, DEL, and
    # the C1 controls (U+0080 through U+009F) are refused in every
    # free-text value, including the group name, before any RPC.
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
    # another patient, omits the 1112 row, or 1112 is non-blank (the
    # visit is signed). A reply with .08 and no 1112 row is not treated
    # as unsigned: the signature date could not be read. DDR
    # LISTER on #9002011.02 (xref AD, part the visit IEN, FROM 0, SCREEN
    # "I $P(^(0),U,3)=<visit>", fields .01;.02;.03;.04, flags IP, max 25)
    # must show exactly one primary (.04 "P" and .03 the visit) whose
    # .01 equals +provider+. The SCREEN is built only from that visit
    # IEN after it has matched a positive integer. A row whose .03 is a
    # different visit is ignored. An error marker, a MORE line, or a
    # reply with no data section (V0 "[Data]", or V1 "[BEGIN_diDATA]")
    # is SaveError, and so is any other
    # result that is not that one primary. FNDPRV^AMHGU calls CHNGPP (AMHGU.m:336-349), which
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
    # {Client::FrameTooLongError} from the AMHG call is SaveError with
    # that exception as the cause, and the message says nothing was
    # sent: the frame is rejected before the RPC goes out, so this is
    # not an unknown outcome. {Client::RpcNotAvailableError} and
    # {Client::RpcRefusedError} are not those classes (they are
    # {Client::RpcError}); they propagate unchanged. An M error row or a
    # reply that does not name this record says the same. An add that
    # fails leaves AMHIEN 0 (AMHGEVF.m:106-108). An edit that fails
    # still returns REC (lines 116-118).
    #
    # A reply that names the record is not success until DDR GETS ENTRY
    # DATA reads back .01, .02, .04, .05, .07, .08, .11 and .25, and,
    # when a group name was sent, .12, .34, 1104 and 1109. Each internal
    # equals what was sent: the normalised FileMan date (trailing zeros
    # dropped from the time fraction, the same shape unary + stores),
    # the program and appointment letters, the pointer IENs, the
    # patient, and for a group the activity time, "1", the group time
    # and the name. The same DDR LISTER must then show exactly one
    # primary equal to +provider+. A reply with no data section (V0
    # "[Data]", or V1 "[BEGIN_diDATA]") is a miss. A miss says the
    # outcome is unknown and that the visit may have been filed. A
    # post-call DDR read that raises {RpmsRpc::Error} is that same
    # SaveError, naming the record IEN, with the error kept as the cause.
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
    # Signature and primary provider are checked before the call only.
    # MODV files an edit unconditionally (AMHGEVF.m:110-120) and the
    # read-back fields omit 1112, so a visit signed by another session
    # between the pre-check and VISIT^AMHGSVF is overwritten and still
    # reported as success. On a failed add, MODV still calls MODPRV with
    # visit 0 (AMHGEVF.m:108-109, 123-135); FNDPRV finds nothing for 0, so
    # stock M files a #9002011.02 row with .03=0 (FNDPRV rewrites it
    # later). That is stock behaviour and is not prevented here.
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
      declared = save_visit_declared_context
      response = save_visit_amhg(mapping, wire, requested)
      ien = save_visit_reply_ien(response, requested, declared)
      save_visit_rebind_ddr_context(declared, ien)
      save_visit_confirm_filed!(ien, expected)
      save_visit_confirm_primary!(ien, provider_ien)
      ien
    end
    shape :save_visit, resource: "behavioral-health", verb: "POST", path: "/behavioral-health/visit"

    # Replace the purpose-of-visit rows on one BH VISIT (#9002011) through
    # AMHG SAVE POV (POV^AMHGSVF, AMHGSVF.m:47-75). One pipe-delimited
    # AMHSTR. The AMHG call runs under AMHGRPC via {Wire#call_amhg}. Every
    # DDR call runs outside that scope, in the caller's context: DDR GETS
    # ENTRY DATA and DDR LISTER are registered under CIAV VUECENTRIC. A
    # session that declared no context cannot be restored by the scope and
    # would stay bound to AMHGRPC, so only in that case the post-call reads
    # re-bind DDR_CONTEXT first (binds: AMHGRPC, then DDR_CONTEXT).
    #
    # Pieces, in order, always eight, blanks included: mode, record IEN,
    # axis II list, axis III, axis IV list, axis V, patient DFN, GAF scale
    # type. The mode piece is always "E". Omitting a blank piece would
    # shift the ones after it.
    #
    # Piece 3 is the axis II list. ARRAY^AMHGU (AMHGU.m:22-32) splits it
    # on "*" and stops at the first empty item, and turns "^" into a
    # space. Each item is "PIEN~PCODE~PNARR" (R="~", AMHGSVF.m:84-86).
    # PCODE is unused; this call sends it blank. PNARR is the narrative.
    # AXIS2 (AMHGSVF.m:77-90) news AMHN once for the whole list, not once
    # per item (line 78). An item with a blank narrative therefore reuses
    # the previous item's narrative IEN. A blank narrative is refused,
    # and so is one that is non-empty but blank after strip. The text
    # that is sent must pass the #9999999.27 .01 input transform, or
    # FNDNARR's LAYGO fails and ADDPOV files a blank .04 after CLNPOV
    # has already deleted every diagnosis. Refused before any RPC:
    # shorter than 2 bytes, longer than 160 bytes, a leading punctuation
    # character (MUMPS patcode P, so "-SYNTH" and ".SYNTH"), or any byte
    # outside printable ASCII 0x20-0x7E. That last rule covers a C1
    # control and a non-ASCII letter. Space is printable ASCII and is
    # allowed. An empty list is refused too: CLNPOV has already deleted
    # every POV, so an empty piece 3 would remove them and file nothing.
    # Duplicate problem IENs would file twice; the loop does not
    # collapse them. They are refused. More than 25 diagnoses are
    # refused before any RPC. The POV lister reads at most 25 rows, so
    # a longer list can never be verified, and CLNPOV has already wiped
    # the record. 25 is accepted.
    #
    # CLNPOV (AMHGSVF.m:102-106) deletes every ^AMHRPRO("AD", record) row
    # before the adds, in both modes. The call is a full replacement, not
    # a patch. The add-versus-edit branch below the Q at line 90 is
    # unreachable. ADDPOV^AMHGEVF (AMHGEVF.m:8-19) files #9002011.01 .01
    # the problem IEN, .02 the piece-7 patient, .03 the record and .04
    # the narrative IEN, through UPDATE^DIE with no flags (internal
    # values). That call does not run the .03 screen, so a POV whose
    # patient differs from the visit's .08 can still be filed. The
    # patient is checked here, before the RPC. FNDNARR^AMHGU
    # (AMHGU.m:320-325) looks the narrative up in #9999999.27 with
    # DIC(0)="L" and LAYGO. A partial match can select a different
    # narrative than the text sent, so the read-back compares .04's
    # external text to the sent narrative, not the IEN.
    #
    # Piece 4 is axis III, free text filed into WP field 5301 only when
    # it is non-blank (AXIS3, AMHGSVF.m:108-115). A blank piece leaves
    # the stored text unchanged and is not read back. ARRAYT^AMHGU
    # (AMHGU.m:78-106) splits on $C(10) and, once a line is past 65
    # characters, after a space. No character is dropped. This call
    # sends one line of 1 through 245 bytes and no control character.
    # 245 is the FileMan word-processing width, so a line with no space
    # is filed as one line.
    #
    # Piece 5 is the axis IV list, items "PIEN~~" (PCODE and PNARR
    # blank). AXIS4 (AMHGSVF.m:117-129) calls CLNA4^AMHGEVF only when
    # the mode is "E" (AMHGEVF.m:71-75), which deletes ^AMHREC(record,61)
    # before the adds. Mode "A" would append, duplicates included. This
    # call always sends "E", so the list is a full replacement. An empty
    # list clears the multiple. ADDAXIS4^AMHGEVF (AMHGEVF.m:46-53) files
    # subfile #9002011.06101 .01. Duplicate stressor IENs are refused.
    # More than 25 are refused before any RPC, for the same reason as
    # the diagnoses: the lister's max is 25, and CLNA4 has already
    # cleared the multiple. 25 is accepted.
    #
    # Piece 6 is axis V (.14) and piece 8 is GAF SCALE TYPE (1115).
    # AXIS5 (AMHGSVF.m:130-137) files both through FILE^DIE("K") on every
    # call and swallows a filing error (line 135). A blank piece clears
    # the field. Only exactly "" clears. A value that is non-empty but
    # blank after strip is refused, for axis V, GAF, axis III and the
    # narrative; it is not a clear. Axis V is an integer from 0 through
    # 100, or "" to clear; nil is refused. GAF is 1 through 20 bytes,
    # or "" to clear; nil is refused. The read-back is what catches a
    # swallowed error. A cleared .14 or 1115 must come back as a present
    # row whose internal is blank. GETS^DIQ returns blank fields as
    # rows. A missing row, a nil internal, or a body with no field rows
    # is a miss: absence is not a verified clear.
    #
    # Piece 2 must already be a BH VISIT. Piece 7 is the patient. Both
    # are positive integers. Each problem IEN points at MHSS PROBLEM
    # (#9002012.2). Each axis IV IEN points at #9002012.9.
    #
    # A value equal to "@" after strip is FileMan's delete-field marker.
    # It is refused before the wire is built, and no RPC is sent. A
    # longer value that contains "@" is not that marker.
    #
    # Every value is coerced with to_s. It must be a String whose
    # encoding is UTF-8, US-ASCII or ASCII-8BIT, and whose bytes are
    # valid UTF-8. Any other encoding, an invalid byte sequence, or a
    # to_s that is not a String is SaveError, and nothing is sent. The
    # tag is checked before the bytes are re-read. "|", "~", "*", "^",
    # the C0 controls, DEL, and the C1 controls (U+0080 through U+009F)
    # are refused in every free-text value. The same C1 refusal applies
    # to save_visit. "|" splits AMHSTR, "~" splits an item, "*" splits
    # a list, and "^" is turned into a space by ARRAY and ARRAYT. Every
    # one of these input checks runs before any RPC, including the DDR
    # pre-reads.
    #
    # Before the AMHG call, DDR GETS ENTRY DATA reads the visit's .08
    # and 1112, flags "I". Nil, an error, an empty body, a missing 1112
    # row, a non-blank 1112 (the visit is signed), or a .08 that is not
    # this patient is SaveError, and AMHG SAVE POV is not called. A read
    # that raises is the same refusal. The same RPC then reads .01,
    # flags "I", of each problem on #9002012.2 and each axis IV IEN on
    # #9002012.9. Nil, an error, an empty body or a blank .01 is
    # SaveError naming that field and not the IEN.
    #
    # The reply is "T00030Result" $C(30), then either the echoed piece 2
    # or AMHER, $C(30) $C(31) (AMHGSVF.m:71-74). AMHER is "0~Add POV"
    # (AMHGEVF.m:17) or "0~Add Axis IV" (AMHGEVF.m:51). The echo is the
    # record IEN that was sent. It does not mean the rows were filed.
    # Only the last failure is visible: CLNPOV has already deleted the
    # previous rows, and a later ADDPOV or ADDAXIS4 can still fail.
    # MERR^AMHGU writes one row "M ERROR|<text>" $C(30) and no $C(31)
    # (AMHGU.m:108-120), so the CIA read can time out. A
    # {Client::ConnectionError} from the AMHG call, including
    # {Client::TimeoutError}, or a {Client::RpcMError}, is SaveError,
    # and that exception is its cause. The message says the outcome is
    # unknown and that the record's diagnoses may have been changed, and
    # it names the record IEN. {Client::FrameTooLongError} from the AMHG
    # call is SaveError with that exception as the cause, and the
    # message says nothing was sent: the frame is rejected before the
    # RPC goes out, so this is not an unknown outcome.
    # {Client::RpcNotAvailableError} and {Client::RpcRefusedError}
    # propagate. An M error row, or a reply that is not this record
    # IEN, says the same.
    #
    # A reply that names the record is not success until the read-back
    # matches. DDR LISTER on #9002011.01 (xref AD, part the record IEN,
    # FROM 0, SCREEN "I $P(^(0),U,3)=<record>", fields .01;.02;.03;.04E,
    # flags IP, max 25) must show exactly the sent diagnoses: the same
    # multiset of problem IEN and .04 external narrative, each row's .02
    # equal to the patient, and .03 equal to this record. A row whose
    # .03 is another record is ignored. A row that is not the row IEN
    # plus exactly those four pieces, or whose problem is not a positive
    # integer, is a miss, not a row to ignore. The SCREEN is built only
    # from the record IEN after it has matched a positive integer. An
    # error marker, a MORE line, or a reply with no data section is a
    # miss: absence is not an empty list. A data section is V0 "[Data]"
    # or V1 "[BEGIN_diDATA]" through "[END_diDATA]", so an XwbClient
    # read-back of the sent rows is success. DDR LISTER on #9002011.06101
    # (IENS ",record,", field .01, flags IP, max 25, no xref, part, from
    # or screen) must show exactly the sent axis IV multiset. Each row
    # is a row IEN plus a non-blank positive-integer .01. A row that is
    # not that shape is a miss, not dropped. A reply with no data
    # section is a miss, including a clear: an empty multiple is a
    # data section with no rows. DDR GETS ENTRY
    # DATA then reads .14 and 1115 (flags "IE"). Each internal equals
    # what was sent. A cleared field must be a present row whose
    # internal is blank. A missing row, a nil internal, or a body with
    # no field rows is a miss. When an axis III line was sent, a second
    # read asks for 5301 with flags "E". That field is word processing:
    # its text lines joined with "" equal the line.
    # A miss says the outcome is unknown and names the record. A
    # post-call DDR read that raises {RpmsRpc::Error} is that same
    # SaveError, with the error kept as the cause.
    #
    # Signature is checked before the call only. POV^AMHGSVF does not
    # look at field 1112, so a visit signed by another session between
    # the pre-check and the RPC is overwritten and, if the read-back
    # matches, still reported as success.
    #
    # Returns the record IEN as a string.
    def save_pov(record_ien:, patient:, diagnoses:, axis_iv:, axis_v:, gaf:, axis_iii: nil)
      wire, record, patient_ien, rows, stressors, axis_v_piece, gaf_piece, axis_iii_piece =
        save_pov_wire(
          record_ien: record_ien, patient: patient, diagnoses: diagnoses, axis_iv: axis_iv,
          axis_v: axis_v, gaf: gaf, axis_iii: axis_iii
        )
      save_visit_confirm_patient!(record, patient_ien)
      save_pov_confirm_pointers!(rows, stressors)
      mapping = DataMapper[:amhg_save_pov]
      declared = save_visit_declared_context
      response = save_pov_amhg(mapping, wire, record)
      ien = save_pov_reply_ien(response, record, declared)
      save_pov_rebind_ddr_context(declared, ien)
      save_pov_confirm_filed!(ien, patient_ien, rows, stressors, axis_v_piece, gaf_piece, axis_iii_piece)
      ien
    end
    shape :save_pov, resource: "behavioral-health", verb: "POST", path: "/behavioral-health/pov"

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

      text = save_visit_utf8(value)
      save_visit_refuse!("a value contains a separator or control character") if text.match?(UNSAFE_WIRE)
      text = text.strip
      save_visit_refuse!("a value is the FileMan delete marker") if text == "@"
      text
    rescue EncodingError
      save_visit_refuse!("a value is not valid UTF-8")
    end

    # to_s first. The tag must be UTF-8, US-ASCII, or ASCII-8BIT, and the
    # bytes must be valid UTF-8. Any other tag is refused before the bytes
    # are re-read: UTF-16 of an ASCII character force-tagged UTF-8 is valid
    # UTF-8 with embedded NULs, and a Latin-1 or Windows-1252 tag whose
    # bytes happen to be valid UTF-8 would file as different characters.
    # Accepted text is returned tagged UTF-8. The value stays out of the
    # message.
    def save_visit_utf8(value)
      text = value.to_s
      utf8 = nil
      if text.is_a?(String) && [ Encoding::UTF_8, Encoding::US_ASCII, Encoding::ASCII_8BIT ].include?(text.encoding)
        utf8 = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
      end
      save_visit_refuse!("a value is not valid UTF-8") unless utf8&.valid_encoding?
      utf8
    rescue EncodingError
      save_visit_refuse!("a value is not valid UTF-8")
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
        :failed
      end
      save_visit_refuse!("#{label} could not be read") if got == :failed
      save_visit_refuse!("#{label} is not on file") if save_visit_dot01_missing?(got)
    end

    def save_visit_confirm_patient!(record_ien, patient)
      got = save_visit_ddr(
        file: BH_VISIT_FILE, iens: "#{record_ien},",
        fields: PRE_EDIT_VISIT_FIELDS, flags: PRE_EDIT_VISIT_FLAGS
      )
      stored = save_visit_stored_patient(got)
      save_visit_refuse!("the stored patient could not be read") if stored.nil?
      # A missing 1112 row is not a blank signature. Fail closed before AMHG.
      save_visit_refuse!("the stored signature date could not be read") unless got[:fields].key?("1112")
      save_visit_refuse!("the visit is signed") if save_visit_signed?(got)
      save_visit_refuse!("the stored patient does not match this visit") unless stored == patient
    rescue Error => e
      raise if e.is_a?(SaveError)

      save_visit_refuse!("the stored patient could not be read")
    end

    # Non-blank 1112 means the visit is signed. The caller has already
    # refused a reply that has no 1112 row; a missing row is not blank.
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

    # nil when the list cannot be trusted: no body, an error marker, a
    # MORE line (the page is not the whole xref), or no data section
    # (V0 "[Data]", or V1 "[BEGIN_diDATA]").
    # Otherwise the P rows for this visit. A missing data section is
    # a miss on its own, not merely an empty list of primaries.
    def save_visit_primaries(visit_ien)
      got = save_visit_lister(visit_ien)
      return nil if got.nil? || got[:error] || got[:more] || !got[:data]

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

    # The DDR context the post-call reads need. Equal to CiaClient::SIGNON_CONTEXT,
    # which cannot be referenced here: api/ files load before cia_client.
    DDR_CONTEXT = "CIAV VUECENTRIC"
    private_constant :DDR_CONTEXT

    def save_visit_declared_context
      client = RpmsRpc.client
      client.respond_to?(:current_context) ? client.current_context : :unscoped
    end

    # ContextScope restores only a context that existed. With none declared
    # the session is left on AMHGRPC, which the DDR reads must not rely on.
    # +record_ien+ is the record the reply already named, or nil.
    def save_visit_rebind_ddr_context(declared, record_ien)
      return unless declared.nil?

      client = RpmsRpc.client
      return unless client.respond_to?(:create_context)

      client.create_context(DDR_CONTEXT) if client.current_context != DDR_CONTEXT
    rescue Error => e
      save_visit_ambiguous!(record_ien, cause: e)
    end

    # MERR writes no $C(31) (AMHGU.m:116-119), so the CIA read of this
    # call can time out after the routine has filed. ConnectionError
    # covers that timeout. RpcMError means the routine ran and the
    # outcome is still unknown. RpcNotAvailableError and RpcRefusedError
    # are RpcError, not these two, so they are not wrapped.
    # FrameTooLongError is raised before the frame is written: nothing
    # was sent, and the message does not say the outcome is unknown.
    def save_visit_amhg(mapping, wire, requested)
      call_amhg(mapping, wire)
    rescue Client::FrameTooLongError => e
      save_visit_not_sent!(e)
    rescue Client::ConnectionError, Client::RpcMError => e
      known = requested.empty? ? nil : requested
      save_visit_ambiguous!(known, cause: e)
    end

    def save_visit_not_sent!(cause)
      raise SaveError, "AMHG SAVE VISIT could not be framed; nothing was sent", cause: cause
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

    # Outside call_amhg. Always {DdrFileman.gets_entry}, which reads with
    # #call_rpc. DDR GETS ENTRY DATA is an ARRAY (return type 2): that
    # read stops at EOD. #call_rpc_global_array waits for $C(31) and would
    # time out on this RPC, so the client class is not consulted.
    def save_visit_ddr(file:, iens:, fields:, flags:)
      DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: flags)
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

    # Parses the reply. A bad reply must not skip the re-bind, so the DDR
    # context is restored before the error propagates.
    def save_visit_reply_ien(response, requested, declared)
      save_visit_ien(response, requested)
    rescue SaveError
      save_visit_rebind_ddr_context(declared, requested.empty? ? nil : requested)
      raise
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

    def save_pov_wire(record_ien:, patient:, diagnoses:, axis_iv:, axis_v:, gaf:, axis_iii:)
      record = save_pov_record_ien(record_ien)
      patient_piece = save_visit_required_ien(patient, "patient")
      rows = save_pov_diagnoses(diagnoses)
      stressors = save_pov_axis_iv(axis_iv)
      axis_v_piece = save_pov_axis_v(axis_v)
      gaf_piece = save_pov_gaf(gaf)
      axis_iii_piece = save_pov_axis_iii(axis_iii)
      pieces = [
        "E",
        record,
        rows.map { |row| "#{row[:problem]}~~#{row[:narrative]}" }.join("*"),
        axis_iii_piece,
        stressors.map { |ien| "#{ien}~~" }.join("*"),
        axis_v_piece,
        patient_piece,
        gaf_piece
      ]
      wire = pieces.join("|")
      count = wire.split("|", -1).length
      raise Error, "AMHG SAVE POV wire has #{count} pieces, not 8" unless count == 8

      [ wire, record, patient_piece, rows, stressors, axis_v_piece, gaf_piece, axis_iii_piece ]
    end

    def save_pov_record_ien(value)
      save_visit_refuse!("record IEN is required") if value.nil?

      save_visit_required_ien(value, "record IEN")
    end

    # nil is refused. "" is the clear, and is sent as a blank piece.
    # A value that is non-empty but blank after strip is refused: only
    # exactly "" clears axis V and GAF.
    def save_pov_required_text(value, label)
      save_visit_refuse!("#{label} is required") if value.nil?
      save_pov_refuse_padded_blank!(value, label)

      save_pov_text(value)
    end

    # Spaces around a real value are stripped later. A value with no
    # non-space character would be sent as a clear, which the caller
    # did not ask for. A separator or control character is left for
    # the text check so that refusal names it.
    def save_pov_refuse_padded_blank!(value, label)
      return if value.nil?

      text = save_visit_utf8(value)
      return if text.empty?
      return if text.match?(UNSAFE_WIRE) || text.match?(POV_LIST_MARK)

      save_visit_refuse!("#{label} is blank") if text.strip.empty?
    end

    def save_pov_diagnoses(value)
      save_visit_refuse!("diagnoses are required") if value.nil? || !value.is_a?(Array) || value.empty?
      save_visit_refuse!("diagnoses are limited to #{POV_MAX}") if value.length > POV_MAX.to_i

      seen = {}
      value.map do |row|
        save_visit_refuse!("a diagnosis is required") unless row.is_a?(Hash)

        problem = save_visit_required_ien(save_pov_entry(row, :problem), "problem")
        narrative = save_pov_narrative(save_pov_entry(row, :narrative))
        save_visit_refuse!("a problem is listed more than once") if seen[problem]

        seen[problem] = true
        { problem: problem, narrative: narrative }
      end
    end

    # Separators and C0 controls keep the separator message. C1 and any
    # other byte outside printable ASCII fail the .01 transform, whose
    # message names the narrative. Checked on the stripped text, which
    # is what the wire sends and what FNDNARR lays go.
    def save_pov_narrative(value)
      save_visit_refuse!("narrative is required") if value.nil?

      text = save_visit_utf8(value)
      if text.match?(WIRE_SEPARATOR) || text.match?(POV_LIST_MARK)
        save_visit_refuse!("a value contains a separator or control character")
      end
      save_visit_refuse!("narrative is blank") if !text.empty? && text.strip.empty?

      text = text.strip
      save_visit_refuse!("a value is the FileMan delete marker") if text == "@"
      save_visit_refuse!("narrative is required") if text.empty?
      save_pov_narrative_transform!(text)
      text
    end

    def save_pov_narrative_transform!(text)
      return if text.bytesize.between?(NARRATIVE_MIN_BYTES, NARRATIVE_MAX_BYTES) &&
                text.match?(PRINTABLE_ASCII) &&
                !text.match?(NARRATIVE_LEADING_PUNCT)

      save_visit_refuse!(
        "narrative must be 2 to 160 bytes of printable ASCII and must not start with punctuation"
      )
    end

    def save_pov_axis_iv(value)
      save_visit_refuse!("axis IV is required") if value.nil? || !value.is_a?(Array)
      save_visit_refuse!("axis IV is limited to #{AXIS_IV_MAX}") if value.length > AXIS_IV_MAX.to_i

      seen = {}
      value.map do |item|
        ien = save_visit_required_ien(item, "axis IV")
        save_visit_refuse!("an axis IV entry is listed more than once") if seen[ien]

        seen[ien] = true
        ien
      end
    end

    def save_pov_axis_v(value)
      text = save_pov_required_text(value, "axis V")
      return "" if text.empty?
      unless text.match?(AXIS_V_INTEGER) && text.to_i.between?(0, AXIS_V_MAX)
        save_visit_refuse!("axis V must be an integer from 0 through 100")
      end

      text
    end

    def save_pov_gaf(value)
      text = save_pov_required_text(value, "GAF")
      save_visit_refuse!("GAF is longer than 20 bytes") if text.bytesize > GAF_MAX_BYTES

      text
    end

    # nil and "" both send a blank piece. AXIS3 then leaves 5301 alone.
    # A non-empty blank is refused; it is not "leave the field alone".
    def save_pov_axis_iii(value)
      save_pov_refuse_padded_blank!(value, "axis III")
      text = save_pov_text(value)
      save_visit_refuse!("axis III is longer than 245 bytes") if text.bytesize > AXIS_III_MAX_BYTES

      text
    end

    def save_pov_entry(row, key)
      return row[key] if row.key?(key)

      row[key.to_s]
    end

    # save_visit_text refuses "|" , "^" , controls and a stripped "@".
    # "~" and "*" are the list marks ARRAY and the item split use.
    def save_pov_text(value)
      text = save_visit_text(value)
      save_visit_refuse!("a value contains a separator or control character") if text.match?(POV_LIST_MARK)

      text
    end

    def save_pov_confirm_pointers!(diagnoses, axis_iv)
      diagnoses.each do |row|
        save_visit_confirm_pointer!("problem", MHSS_PROBLEM_FILE, row[:problem])
      end
      axis_iv.each do |ien|
        save_visit_confirm_pointer!("axis IV", PSYCHOSOCIAL_FILE, ien)
      end
    end

    # The reply IEN is the record that was sent, or it is not success.
    # CLNPOV has already run by the time AMHER is set, so a bad reply
    # still may have changed the diagnoses.
    def save_pov_ien(response, record_ien)
      rows = save_visit_rows(response)
      save_pov_ambiguous!(record_ien) if rows.any? { |row| row.start_with?("M ERROR|") }

      data = rows.reject { |row| DataMapper.recordset_header_row?(row) }
      ien = data.empty? ? "" : DataMapper[:amhg_save_pov].parse_one(data.first)&.dig(:ien).to_s
      save_pov_ambiguous!(record_ien) unless ien == record_ien && ien.match?(POSITIVE_IEN)
      ien
    end

    def save_pov_reply_ien(response, record_ien, declared)
      save_pov_ien(response, record_ien)
    rescue SaveError
      save_pov_rebind_ddr_context(declared, record_ien)
      raise
    end

    def save_pov_amhg(mapping, wire, record_ien)
      call_amhg(mapping, wire)
    rescue Client::FrameTooLongError => e
      save_pov_not_sent!(e)
    rescue Client::ConnectionError, Client::RpcMError => e
      save_pov_ambiguous!(record_ien, cause: e)
    end

    def save_pov_not_sent!(cause)
      raise SaveError, "AMHG SAVE POV could not be framed; nothing was sent", cause: cause
    end

    # Same restore as save_visit. The message names this RPC.
    def save_pov_rebind_ddr_context(declared, record_ien)
      return unless declared.nil?

      client = RpmsRpc.client
      return unless client.respond_to?(:create_context)

      client.create_context(DDR_CONTEXT) if client.current_context != DDR_CONTEXT
    rescue Error => e
      save_pov_ambiguous!(record_ien, cause: e)
    end

    def save_pov_confirm_filed!(record_ien, patient, diagnoses, axis_iv, axis_v, gaf, axis_iii)
      pov = save_pov_lister(record_ien)
      save_pov_ambiguous!(record_ien) unless save_pov_diagnoses_match?(pov, patient, record_ien, diagnoses)

      listed = save_pov_axis_iv_lister(record_ien)
      save_pov_ambiguous!(record_ien) unless save_pov_axis_iv_match?(listed, axis_iv)
      save_pov_confirm_visit_fields!(record_ien, axis_v, gaf, axis_iii)
    rescue Error => e
      raise if e.is_a?(SaveError)

      save_pov_ambiguous!(record_ien, cause: e)
    end

    # No data section (V0 "[Data]" or V1 "[BEGIN_diDATA]") is a miss,
    # even when nothing parsed as a row.
    # A row that does not fit the POV shape is a miss, not dropped.
    # A row that fits and names another record is ignored.
    def save_pov_diagnoses_match?(got, patient, record_ien, diagnoses)
      return false if got.nil? || got[:error] || got[:more] || !got[:data]

      rows = []
      got[:entries].each do |entry|
        row = save_pov_diagnosis_row(entry)
        return false if row.nil?

        rows << row
      end
      rows.select! { |row| row[:record] == record_ien }
      return false unless rows.all? { |row| row[:patient] == patient }

      rows.map { |row| [ row[:problem], row[:narrative] ] }.tally ==
        diagnoses.map { |row| [ row[:problem], row[:narrative] ] }.tally
    end

    # Packed row, flags IP, fields .01;.02;.03;.04E: problem, patient,
    # record, narrative external. Exactly those four pieces. The problem
    # is a positive integer; a pointer's internal value may be
    # "IEN;name", and the IEN is what is compared. .04E is the narrative
    # text and is not split. Nil means the row does not fit, and the
    # read-back is a miss rather than a row to drop.
    def save_pov_diagnosis_row(entry)
      pieces = entry[:pieces]
      return nil unless pieces.is_a?(Array) && pieces.length == 4

      problem = pieces[0].to_s.split(";", 2).first.to_s.strip
      return nil unless problem.match?(POSITIVE_IEN)

      {
        problem: problem,
        patient: pieces[1].to_s.split(";", 2).first.to_s.strip,
        record: pieces[2].to_s.split(";", 2).first.to_s.strip,
        narrative: pieces[3].to_s.strip
      }
    end

    # No data section (V0 "[Data]" or V1 "[BEGIN_diDATA]") is a miss,
    # including a clear. A row whose .01
    # is not a non-blank positive integer is a miss, not dropped.
    def save_pov_axis_iv_match?(got, axis_iv)
      return false if got.nil? || got[:error] || got[:more] || !got[:data]

      found = []
      got[:entries].each do |entry|
        ien = save_pov_axis_iv_ien(entry)
        return false if ien.nil?

        found << ien
      end
      found.tally == axis_iv.tally
    end

    def save_pov_axis_iv_ien(entry)
      pieces = entry[:pieces]
      return nil unless pieces.is_a?(Array) && !pieces.empty?

      ien = pieces[0].to_s.split(";", 2).first.to_s.strip
      ien.match?(POSITIVE_IEN) ? ien : nil
    end

    def save_pov_confirm_visit_fields!(record_ien, axis_v, gaf, axis_iii)
      got = save_visit_ddr(
        file: BH_VISIT_FILE, iens: "#{record_ien},", fields: POV_VISIT_FIELDS, flags: POV_VISIT_FLAGS
      )
      save_pov_ambiguous!(record_ien) if got.nil? || got[:error]
      save_pov_ambiguous!(record_ien) unless save_pov_scalar_match?(got[:fields], ".14", axis_v)
      save_pov_ambiguous!(record_ien) unless save_pov_scalar_match?(got[:fields], "1115", gaf)
      return if axis_iii.empty?

      wp = save_visit_ddr(
        file: BH_VISIT_FILE, iens: "#{record_ien},", fields: AXIS_III_FIELD, flags: AXIS_III_FLAGS
      )
      save_pov_ambiguous!(record_ien) if wp.nil? || wp[:error]
      save_pov_ambiguous!(record_ien) unless save_pov_axis_iii_match?(wp[:fields][AXIS_III_FIELD], axis_iii)
    end

    # A cleared field is a present row whose internal is blank.
    # GETS^DIQ returns that row. A missing row, a nil internal, or a
    # body with no field rows is a miss: absence is not a clear.
    def save_pov_scalar_match?(fields, field, want)
      entry = fields.is_a?(Hash) ? fields[field] : nil
      return false unless entry.is_a?(Hash) && entry.key?(:internal)
      return false if entry[:internal].nil?

      entry[:internal].to_s.strip == want
    end

    # 5301 is word processing (GETS^DIQ "[WORD PROCESSING]"). ARRAYT
    # keeps a splitting space on the earlier line, so the lines joined
    # with "" are the line that was sent.
    def save_pov_axis_iii_match?(field, sent)
      return false unless field.is_a?(Hash) && field[:text].is_a?(Array)

      field[:text].join("") == sent
    end

    # Outside call_amhg. The SCREEN is only the validated record IEN, so a
    # caller value cannot become M code. FROM 0 with that screen is the
    # page that is this record, not the PART prefix (1 also matches 10).
    def save_pov_lister(record_ien)
      ien = record_ien.to_s
      return nil unless ien.match?(POSITIVE_IEN)

      DdrFileman.lister(
        file: POV_FILE, xref: POV_XREF, part: ien, from: POV_FROM,
        screen: "I $P(^(0),U,3)=#{ien}",
        fields: POV_FIELDS, flags: POV_FLAGS, max: POV_MAX
      )
    end

    # Subfile by IENS. No xref and no screen: a piece-3 screen errors,
    # and ADDAXIS4 stores only .01.
    def save_pov_axis_iv_lister(record_ien)
      ien = record_ien.to_s
      return nil unless ien.match?(POSITIVE_IEN)

      DdrFileman.lister(
        file: AXIS_IV_SUBFILE, iens: ",#{ien},",
        fields: AXIS_IV_FIELDS, flags: AXIS_IV_FLAGS, max: AXIS_IV_MAX
      )
    end

    def save_pov_ambiguous!(record_ien, cause: nil)
      message = "AMHG SAVE POV outcome unknown; record #{record_ien}'s diagnoses may have been changed"
      raise SaveError, message, cause: cause if cause

      raise SaveError, message
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
