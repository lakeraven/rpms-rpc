# frozen_string_literal: true

require_relative "../shape"
require_relative "../reply"
require_relative "registration"
require_relative "agg"
require_relative "ddr_fileman"
require_relative "../context_scope"
require_relative "../phi_sanitizer"

module RpmsRpc
  # Symbolic API for patient data. Engine code calls these methods
  # instead of referencing DataMapper mappings directly.
  module Patient
    extend self
    extend Shape::Declarable

    # The option that lists DDR GETS ENTRY DATA on the pinned build, as in
    # Practitioner.
    FILEMAN_CONTEXT = "CIAV VUECENTRIC"

    def find(dfn)
      return nil if dfn.nil? || dfn.to_i <= 0

      attrs = DataMapper.patient_select.fetch_one(dfn.to_s, extras: { dfn: dfn.to_i })
      return nil unless attrs

      extended = DataMapper.patient_id_info.fetch_one(dfn.to_s)
      attrs.merge!(extended) if extended

      attrs
    end
    shape :find, resource: "patients", verb: "GET", path: "/patients/{dfn}"

    # ORWPT LIST ALL (LISTALL^ORWPT): ONE PAGE of the PATIENT "B" (name)
    # index, in index order, starting AT the text. It is not a filter (#352):
    #
    #   - the page is at most 44 rows and runs past the names that begin with
    #     the text: search("MOUSE") also lists NIGHTSHADE,FINLEY;
    #   - names are stored upper-case, so lower-case text collates after every
    #     name and answers [];
    #   - each row is { dfn:, name: } and nothing else.
    #
    # A caller that wants only matching names filters the page itself. For a
    # division-aware lookup use #lookup.
    def search(name_pattern)
      DataMapper.patient_list.fetch_many(page_start(name_pattern.to_s), "1")
    end
    shape :search, resource: "patients", verb: "GET", path: "/patients"

    # AGG LOOKUP PATIENTS — the IHS division-aware lookup (FND^AGGPTLKP).
    #
    # Prefer this over #search on a multi-divisional RPMS: stock
    # ORWPT LIST ALL has no division screen, so it returns patients from
    # every division to a user scoped to one.
    #
    #   all_divisions:    search beyond the caller's division (ALL)
    #   include_inactive: include patients inactive at the division (INAC)
    #   type:             search type code; "" searches all cross-references
    #
    # AGGPTLKP has NO result-limit parameter. A limit passed positionally
    # would land on ALL or INAC and silently widen the search instead of
    # narrowing it, so it is refused rather than accepted and ignored.
    #
    # SSN is masked on the wire to "XXX-XX-nnnn" when the caller lacks the
    # AGZVIEWSSN security key (AGGPTLKP.m:124). That is a redaction, not an
    # identifier — it is returned as ssn: nil with ssn_masked: true so a
    # caller cannot persist it as though it were an SSN.
    # require_response: registration needs a complete header and valid rows;
    # an unreadable reply must never look like permission to create a patient.
    def lookup(text, type: "", all_divisions: false, include_inactive: false, require_response: false, **opts)
      if opts.key?(:limit)
        raise ArgumentError,
              "AGG LOOKUP PATIENTS has no result-limit parameter; a limit " \
              "passed positionally sets ALL or INAC and widens the search"
      end
      raise ArgumentError, "search text is required" if text.to_s.strip.empty?

      rows = in_aggrpc { fetch_lookup_rows(
        DataMapper.patient_lookup_agg,
        text.to_s,
        type.to_s,
        all_divisions ? "1" : "",
        include_inactive ? "1" : "",
        require_response: require_response
      ) }

      rows.map { |row| normalize_lookup_row(row) }
    end
    shape :lookup, resource: "patients", verb: "GET", path: "/patients/lookup"

    # ORWPT FULLSSN (FULLSSN^ORWPT) reads the "SSN" index by exact value, and
    # the index holds the SSN without punctuation ("000009999", or
    # "000009999P" for a pseudo-SSN). Punctuation in the SSN given here is
    # stripped before the call, so "000-00-9999" finds the same patient (#352).
    def find_by_ssn(ssn)
      bare = ssn.to_s.gsub(/[^0-9A-Za-z]/, "")
      return nil if bare.empty?

      DataMapper.patient_ssn.fetch_one(bare)
    end
    shape :find_by_ssn, resource: "patients", verb: "GET", path: "/patients/by-ssn"

    # Register a new patient via RpmsRpc::Registration, which delegates to
    # the IHS AG package (AGG ADD NEW PATIENT / AGG UPDATE PATIENT under
    # AGGRPC). There is no stock-VistA composition fallback: VAFC VOA ADD
    # PATIENT is served by no context on RPMS (rpms-rpc#409).
    #
    # See RpmsRpc::Registration.register for the attrs contract and the HRN
    # policy (Registration.hrn_mode). Returns
    #   { success: true, dfn:, created: }           on success,
    #   { success: false, error: Symbol, message: } on rejection
    #     (:duplicate_identity with candidate_dfns; :identity_unverifiable;
    #      :agg_rejected / :hrn_file_failed), or
    #   nil when the add gives no response. A missing lookup response is
    #   :identity_unverifiable and never authorizes an add. Only literal
    #   allow_duplicate: true overrides reviewed lookup candidates.
    #
    # Raises Client::FrameTooLongError for a value the wire cannot frame
    # (see Registration.register, #480).
    def register(attrs)
      Registration.register(attrs)
    end

    # Update a patient through AG: AGG UPDATE PATIENT, one call per AG
    # window touched, under AG's edit lock (rpms-rpc#381). Takes named
    # attributes (phone_home:, email:, community_ien:, ...); see
    # RpmsRpc::Registration.update for the attribute table, value forms and
    # return shape. Attributes AG does not file raise
    # Registration::AttributeNotOfferedError before anything is sent.
    def update(dfn, **attrs)
      Registration.update(dfn, **attrs)
    end

    # Field 0 of the BEHOPTPC GETBDP row that names the designated primary
    # provider. Compared exactly after surrounding whitespace is stripped.
    DESIGNATED_PRIMARY_PROVIDER_LABEL = "DESIGNATED PRIMARY PROVIDER"

    # Chart-banner projection per issue #60 contract:
    #
    #   { name:, dob:, sex:, mrn:, age:, allergy_flag:, ad_flag:, primary_provider: }
    #
    # Composed from three RPCs:
    #   - BEHOPTCX PTINFO         (name, sex, DOB raw, MRN, primary provider name)
    #   - BEHOPTPC GETBDP         (one row per designated-provider category,
    #                              alphabetical)
    #   - BEHOCACV CWAD           (Crises/Warnings/Allergies/Directives flags)
    #
    # :primary_provider is the GETBDP row whose label (field 0), compared
    # exactly after surrounding whitespace is stripped, is
    # DESIGNATED_PRIMARY_PROVIDER_LABEL. When there is no such row, or its
    # provider name is blank, the PTINFO primary provider is used.
    #
    # Returns nil for invalid (nil / zero / negative) DFNs and for unknown DFNs
    # (PTINFO gives nothing and GETBDP has no rows). A broker that does not
    # serve one of the three RPCs raises RpcNotAvailableError, one that serves
    # it but not to this user raises RpcRefusedError, and an M error raises
    # RpcError (#363).
    def brief_header(dfn)
      return nil if dfn.nil? || dfn.to_i <= 0

      ptinfo   = DataMapper.patient_ptinfo.fetch_one(dfn.to_s)
      bdp_rows = DataMapper.patient_designated_provider.fetch_many(dfn.to_s)
      return nil if ptinfo.nil? && bdp_rows.empty?

      cwad = DataMapper.patient_cwad.fetch_scalar(dfn.to_s) || ""
      dob  = FilemanDateParser.parse_date(ptinfo && ptinfo[:dob_raw])
      designated = bdp_rows.find { |row| row[:label].to_s.strip == DESIGNATED_PRIMARY_PROVIDER_LABEL }
      name = designated && designated[:provider_name]
      name = nil if name.nil? || name.strip.empty?
      provider = name || (ptinfo && ptinfo[:primary_provider])

      {
        name:             ptinfo && ptinfo[:name],
        dob:              dob,
        sex:              ptinfo && ptinfo[:sex],
        mrn:              ptinfo && ptinfo[:mrn],
        age:              age_from(dob),
        allergy_flag:     cwad.to_s.include?("A"),
        ad_flag:          cwad.to_s.include?("D"),
        primary_provider: provider
      }
    end
    shape :brief_header, resource: "patients", verb: "GET", path: "/patients/{dfn}/brief-header"

    # Patient telecom (FHIR Patient.telecom source) — home / work / cell /
    # other phone + email, read via the registered generic FileMan read
    # (DDR GETS ENTRY DATA — GETSC^DDR2: DDR2.m:17-43): PATIENT (#2) fields
    # .131 / .132 / .134, and IHS PATIENT (#9000001) 1801 OTHER PHONE and
    # 1802 CURRENT EMAIL ADDRESS. Email is read where AG files it: AG's
    # Address window maps AGGPTEML to #9000001 1802 and keeps the previous
    # ones in 9000001.82 (EML^AGGUL1); no AG window files #2 .133, so
    # update and read use 1802 (rpms-rpc#381). Piece↔field identity for the
    # ^DPT(DFN,.13) node is cited from three independent corpus readers:
    #   piece 1 = .131 residence phone, piece 2 = .132 work phone,
    #   piece 3 = .133 email, piece 4 = .134 cellular
    #   (PTINFO1^BEHOPTCX: BEHOPTCX.m:34-41 — header
    #    "Phone(Res)^Phone(Work)^Phone(Cell)^Email" built from pieces
    #    1,2,4,3; DGRRPSAM.m:84-88 home=1/work=2; BQIPLADR.m:76).
    #
    # Why DDR and not a purpose-built RPC: the full corpus×registry sweep
    # of ^DPT(*,.13) readers found NO registered purpose-built RPC that
    # returns the phone as a structured patient read —
    #   BEHOPTCX PTINFO  — 20-piece identity bundle, no .13 data
    #                      (PTINFO^BEHOPTCX: BEHOPTCX.m:7-31)
    #   BEHOPTCX PTINFO1 — has exactly these fields but is NOT in the
    #                      #8994 registry (.broker_dumps_8994_20260607.txt
    #                      has PTINFO/PTINQ/LAST/... only)
    #   BEHOPTCX PTINQ   — report text, not structured
    #   DGRR GET PATIENT SERVICES DATA — home+work only, XML envelope
    #                      (DGRRPSAM.m:35-37), no cellular
    #   VEN ASQ GET DATA — home phone only, "|"-delimited ASQ projection
    #                      (DATA^VENPCCQ: VENPCCQ.m:180-213)
    #   BQI MAIL MERGE LIST — home/work in iCare BMX mail-merge format,
    #                      executes ^APCLVSTS print templates (BQIPLADR.m)
    #   BSDX WAITLIST    — waitlist rows, not a patient read (BSDX36.m:42)
    # The cellular phone (.134) in particular is served by NO purpose-built
    # registered RPC. DDR GETS ENTRY DATA is registered, already driven by
    # this gem (RpmsRpc::Registration), and returns all four structured.
    #
    # Returns { dfn:, phone_home:, phone_work:, phone_cell:, phone_other:,
    # email: } (missing values nil), or nil when the DFN is not a positive
    # whole number (the same guard as Practitioner#roles — a non-integer
    # never reaches the wire), the broker gives no response, or FileMan
    # errors on either read, so callers can distinguish "no phone on file"
    # from "unreachable". AG pairs every PATIENT with an IHS PATIENT entry
    # (AG71A1.m:138), so a missing #9000001 entry is a failed read too.
    # Both reads bind FILEMAN_CONTEXT and restore the caller's option.
    def contact(dfn)
      return nil unless dfn.to_s.match?(/\A\d+\z/) && dfn.to_i.positive?

      patient = nil
      ihs = nil
      ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        patient = telecom_fields("2", dfn, ".131;.132;.134")
        ihs = telecom_fields(Registration::PATIENT_FILE, dfn, "1801;1802") unless patient.nil?
      end
      return nil if patient.nil? || ihs.nil?

      {
        dfn:         dfn.to_i,
        phone_home:  external(patient, ".131"),
        phone_work:  external(patient, ".132"),
        phone_cell:  external(patient, ".134"),
        phone_other: external(ihs, "1801"),
        email:       external(ihs, "1802")
      }
    end
    shape :contact, resource: "patients", verb: "POST", path: "/patients/{dfn}/contact"

    # Mailing address on PATIENT (#2), read via the registered generic
    # FileMan read (DDR GETS ENTRY DATA — GETSC^DDR2), the same path as
    # #contact. The DD fields were read from the live data dictionary on
    # the bcer-9.0 container per issue #294, and a live spec has not yet
    # proven them (ADR 0009):
    #
    #   .111 STREET ADDRESS [LINE 1]
    #   .112 STREET ADDRESS [LINE 2]
    #   .113 STREET ADDRESS [LINE 3]
    #   .114 CITY
    #   .115 STATE (P5, pointer to STATE #5; external is the NAME)
    #   .116 ZIP CODE
    #   .1112 ZIP+4 (accepts 5 to 20 characters; ZIPOUT^VAFADDR prints
    #         12345 or 12345-6789, so the value is the WHOLE ZIP+4)
    #
    # state is the .115 external. state_ien is the .115 internal as an
    # Integer, nil when empty or not a positive whole number. The
    # abbreviation is not resolved from STATE #5.
    #
    # Returns { dfn:, line1:, line2:, line3:, city:, state:, state_ien:,
    # zip:, zip_plus4: } (missing values nil), or nil when the DFN is not a
    # positive whole number (the same guard as Practitioner#roles), the
    # broker gives no reply, FileMan errors, or the reply has no field
    # rows. The read binds FILEMAN_CONTEXT and restores the caller's option.
    def address(dfn)
      return nil unless dfn.to_s.match?(/\A\d+\z/) && dfn.to_i.positive?

      fields = ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        telecom_fields("2", dfn, ".111;.112;.113;.114;.115;.116;.1112")
      end
      return nil if fields.nil?

      {
        dfn:       dfn.to_i,
        line1:     external(fields, ".111"),
        line2:     external(fields, ".112"),
        line3:     external(fields, ".113"),
        city:      external(fields, ".114"),
        state:     external(fields, ".115"),
        state_ien: internal_ien(fields, ".115"),
        zip:       external(fields, ".116"),
        zip_plus4: external(fields, ".1112")
      }
    end
    shape :address, resource: "patients", verb: "POST", path: "/patients/{dfn}/address"

    # PATIENT (#2) field .06 RACE is P10'X. Its input transform is
    # historical-only ("ENTRY OF DATA NOT ALLOWED") but the value is
    # readable, via DDR GETS ENTRY DATA the same way as #address. The
    # USCDI multiples (2 RACE INFORMATION, 6 ETHNICITY INFORMATION) are
    # out of scope for #294.
    #
    # Returns { dfn:, race: } (the external value, or nil when empty), or
    # nil when the DFN is not a positive whole number (the same guard as
    # Practitioner#roles), the broker gives no reply, FileMan errors, or
    # the reply has no field rows. The read binds FILEMAN_CONTEXT and
    # restores the caller's option.
    def race(dfn)
      return nil unless dfn.to_s.match?(/\A\d+\z/) && dfn.to_i.positive?

      fields = ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        telecom_fields("2", dfn, ".06")
      end
      return nil if fields.nil?

      { dfn: dfn.to_i, race: external(fields, ".06") }
    end
    shape :race, resource: "patients", verb: "POST", path: "/patients/{dfn}/race"

    # The parsed fields of one DDR GETS ENTRY DATA read, or nil when it
    # failed. A reply that parsed NO field rows is a failed read, not
    # "nothing on file": a GETS^DIQ read of an existing entry returns one row
    # per requested field even when the values are empty.
    def telecom_fields(file, dfn, fields)
      reply = DdrFileman.gets_entry(file: file, iens: "#{dfn.to_i},", fields: fields, flags: "IE")
      return nil if reply.nil? || reply[:error] || reply[:fields].empty?

      reply[:fields]
    end

    private :telecom_fields

    # Compute integer years between dob and today. `today:` is a keyword arg
    # for testability — production callers omit it and get Date.today.
    # Default is `nil` (not `Date.today`) so the nil-DOB guard runs before
    # touching the Date constant, keeping the helper safe even if `Date`
    # hasn't been required by the caller.
    # AGG LOOKUP PATIENTS is a GLOBAL ARRAY (return type 4) reply: FND^AGGPTLKP
    # sets DATA=$NA(^TMP("AGGPTLK",UID)) (AGGPTLKP.m:7), so the broker sends a
    # typed header followed by $C(30)-separated records, ending at $C(31).
    #
    # $C(30) WAS the CIA EOD until #241 moved the terminator to \x7f, so the
    # default read_until_raw(EOD) used to stop at the header row and lose every
    # patient — on the wire only; seeded tests still passed, which is how that
    # survived review. CiaClient reads to the $C(31) sentinel in
    # #call_rpc_global_array; RpmsRpc::Agg routes its AGG RPCs the same way
    # (Agg#call_array). That remains the correct read: it is framed by the
    # sentinel rather than relying on the terminator not colliding.
    LOOKUP_RECORD_SEP = "\x1e" # $C(30) — record separator
    LOOKUP_ARRAY_END  = "\x1f" # $C(31) — end-of-array sentinel
    LOOKUP_ACK        = "\x00" # broker ack byte after the sequence echo

    # AGG LOOKUP PATIENTS is registered under the AGGRPC option only, so under
    # any other context (CIAV VUECENTRIC, what a CIA sign-on binds) the broker
    # refuses it. Bind AGGRPC for the call and restore the caller's context, as
    # RpmsRpc::Agg does for every AGG RPC; nesting inside Agg is free.
    def in_aggrpc(&block)
      client = RpmsRpc.client
      return block.call unless client.respond_to?(:with_context)

      client.with_context(Agg::CONTEXT, &block)
    end
    private :in_aggrpc

    def fetch_lookup_rows(mapping, *params, require_response: false)
      client = RpmsRpc.client
      raw = if client.respond_to?(:call_rpc_global_array)
        client.call_rpc_global_array(mapping.rpc_name, *params)
      else
        client.call_rpc(mapping.rpc_name, *params)
      end

      decoded = decode_global_array(raw)
      validate_lookup_reply!(decoded) if require_response
      lines, altered = lookup_lines(decoded)
      # The framed blob is split into rows BEFORE the flag is read, so a row's
      # flag has to come from the reply as a whole: when the reply says it
      # replaced a byte, every row holding the replacement character is
      # altered (rpms-rpc#463).
      if Reply.altered?(raw)
        altered |= lines.each_index.select { |i| lines[i].to_s.include?(Reply::REPLACEMENT) }
      end
      mapping.parse_many_flagged(lines, altered)
    end
    private :fetch_lookup_rows

    # [rows, altered_indexes] for what decode_global_array returned: record
    # rows, an ordinary newline-delimited body, or nothing. A "-1^message"
    # error body yields no rows, as DataMapper#parse_many treats it.
    def lookup_lines(decoded)
      return [ [], [] ] if decoded.is_a?(String) && decoded.start_with?("-1^")

      Reply.lines_with_altered(decoded)
    end
    private :lookup_lines

    # HDR^AGGPTLKP has nine columns, with two optional community columns.
    # Validate before DataMapper skips headers or coerces malformed values.
    def validate_lookup_reply!(decoded)
      rows = (decoded.is_a?(Array) ? decoded : decoded.to_s.split(/\r?\n/)).reject { |row| row.to_s.empty? }
      header = rows.shift.to_s.split("^", -1)
      expected = %w[I00010DFN T00030PATIENT_NAME T00030HRN T00009SSN D00030DOB D00030DOD T00003SENS_FLAG T01024ALIAS T00001INACTIVE]
      unless header == expected || header == expected + %w[T00030COMM T00030MOMDN]
        raise Client::RpcError, "AGG LOOKUP PATIENTS did not return a patient header"
      end
      rows.each do |row|
        fields = row.to_s.split("^", -1)
        unless fields.length == header.length && fields.first.match?(/\A[1-9]\d*\z/)
          raise Client::RpcError, "AGG LOOKUP PATIENTS returned an invalid patient row"
        end
      end
    end
    private :validate_lookup_reply!

    # Returns the record lines when the reply carries global-array framing, or
    # the payload untouched when it does not — a client without
    # #call_rpc_global_array answers with an ordinary newline-delimited body,
    # which parse_many splits itself.
    def decode_global_array(raw)
      # XwbClient/BmxClient answer with an Array from split_response, and with
      # word wrap off a type-4 reply arrives as ONE element holding the whole
      # framed blob — join before looking for framing, or it reads as a single
      # unparseable row. MockClient's seeded line arrays have no framing and
      # fall through to the unchanged return below.
      body = raw.is_a?(Array) ? raw.join : raw
      return raw unless body.is_a?(String)

      body = body.split(LOOKUP_ACK, 2).last.to_s if body.include?(LOOKUP_ACK)
      body = body.split(LOOKUP_ARRAY_END, 2).first.to_s
      return raw unless body.include?(LOOKUP_RECORD_SEP)

      # The broker writes every node as `W @X,EOL,!` (CIANBACT.m:122), so
      # framing bytes can follow each $C(30): EOL is $C(13) when the #8994
      # entry has word wrap on and empty when it does not, and what `!` itself
      # emits depends on the device. Reviews of this path have read those bytes
      # differently, so rather than depend on one reading, every combination is
      # handled — CRLF, bare LF, bare CR, and none at all. Left unstripped they
      # lead the next record and trail the last as a bare separator, reaching
      # normalize_lookup_row as a blank DFN and raising.
      #
      # Stripped by byte prefix, not regex: these rows may hold non-UTF-8 name
      # bytes and a regex over them raises. Only a LEADING feed goes — a
      # newline inside a field is data and is left alone.
      body.split(LOOKUP_RECORD_SEP).filter_map do |row|
        row = row.delete_prefix("\r\n").delete_prefix("\n").delete_prefix("\r")
        row unless row.empty?
      end
    end

    # Masked-SSN shape from AGGPTLKP.m:124 (LST) and :194 (LST2). LST2 omits
    # LST's SSN'="" guard, so a patient with no SSN comes back as the bare
    # prefix "XXX-XX-" with no digits — both forms are redactions.
    MASKED_SSN = /\AXXX-XX-\d*\z/

    def normalize_lookup_row(row)
      dfn = row[:dfn_raw].to_s.strip
      unless dfn.match?(/\A\d+\z/)
        raise Client::RpcError,
              "AGG LOOKUP PATIENTS returned a non-numeric DFN (#{PhiSanitizer.sanitize_message(dfn)}) " \
              "— an M error arriving as a data row, not a patient"
      end

      ssn = row[:ssn_raw].to_s.strip
      masked = ssn.match?(MASKED_SSN)

      {
        dfn: dfn.to_i,
        name: row[:name],
        hrn: row[:hrn],
        ssn: (masked || ssn.empty?) ? nil : ssn,
        ssn_masked: masked,
        dob: row[:dob],
        dod: row[:dod],
        sens_flag: row[:sens_flag],
        alias: row[:alias],
        inactive: row[:inactive_raw].to_s.strip.upcase == "Y",
        community: row[:community],
        mothers_maiden_name: row[:mothers_maiden_name],
        # True when any text of this row had a byte replaced to become valid
        # UTF-8; a caller matching on the name must refuse an altered row.
        altered: row[:altered] == true
      }
    end

    def age_from(dob, today: nil)
      return nil if dob.nil?
      today ||= Date.today
      years = today.year - dob.year
      years -= 1 if today.month < dob.month || (today.month == dob.month && today.day < dob.day)
      years
    end
    private :age_from

    private

    # LISTALL^ORWPT pages with $ORDER, which answers the name AFTER the text it
    # is given, so the exact name sent as-is is the one name the page leaves
    # out. The from-text is therefore the string just before the text in
    # collation: its last character stepped back one, then "~" (above every
    # character a name holds). CPRS's patient selector sends the same form.
    def page_start(text)
      return text if text.empty?

      "#{text[0...-1]}#{text[-1].ord.pred.chr(text.encoding)}~"
    end

    # External (display) value of one field from a DdrFileman.gets_entry
    # reply; empty-on-file → nil.
    def external(fields, field_number)
      value = fields[field_number] && fields[field_number][:external]
      value.nil? || value.empty? ? nil : value
    end

    # Internal value of a pointer field as a positive IEN, or nil when it
    # is empty or not a positive whole number.
    def internal_ien(fields, field_number)
      value = fields[field_number] && fields[field_number][:internal]
      value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : nil
    end
  end
end
