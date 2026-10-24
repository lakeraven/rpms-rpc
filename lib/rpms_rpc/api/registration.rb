# frozen_string_literal: true

require_relative "../mappings"
require_relative "agg"

module RpmsRpc
  # Patient registration on RPMS: delegation to the IHS AG package's own
  # registration RPCs, AGG ADD NEW PATIENT / AGG UPDATE PATIENT under the stock
  # option AGGRPC (RpmsRpc::Agg). It replaces a removed placeholder wire name
  # that never had a server implementation anywhere (docs/rpcs.md, BHDPTRPC
  # provenance notes).
  #
  # The AG capsule owns demographics filing into PATIENT (#2) and IHS PATIENT
  # (#9000001), the 41-multiple HRN, HL7/MPI staging into ^XTMP("AGHL7"), the
  # ^AGPATCH register stamp, and the edit-check battery, so delegation
  # INHERITS that logic instead of drifting from it. (Verdict "delegate":
  # rpms-rpc#214, capture-verified.) The create goes through AG's "New
  # Patient" window, which carries tribe, classification, eligibility and
  # community as its own parameters (RpmsRpc::Agg::NEW_PATIENT_WINDOW;
  # rpms-rpc#297), so AG files them with everything else. Nothing is filed
  # around AG.
  #
  # ## No composition path (rpms-rpc#409)
  #
  # The gem used to fall back, when AG did not answer, to a composition of
  # VAFC VOA ADD PATIENT (PATIENT #2) and the DDR FileMan family (the IHS
  # half). It is gone, under ADR 0008 rule 3: no RPMS build serves
  # VAFC VOA ADD PATIENT to a client. Stock RPMS lists it in no option's RPC
  # multiple, so both brokers refuse it outside the XUPROGMODE bypass
  # (CANRUN^CIANBACT, CHK^XQCS), and rpms-ops keeps it that way on purpose:
  # FIXDDRCX takes off the grants an earlier cut added and deletes the
  # LR REGISTRATION CONTEXT option it once created (rpms-ops#499, #500, #674,
  # docs/DEVIATIONS.md). Its reach class is no-context on every pinned build.
  # AG is on every RPMS baseline (rpms-rpc#407), and its AGGRPC option is how
  # RPMS registers a patient.
  #
  # ## What is stored for community (rpms-rpc#300)
  #
  # `community_ien:` + `community_since:` are filed through AG's window: AG
  # sets 1117 CURRENT RESIDENCE (the #9999999.05 pointer) and a #9000001.51
  # history entry, and derives 1118 CURRENT COMMUNITY from them. AG's window
  # has no free-text community parameter, so `community:` is never sent and is
  # always named in `unfiled:`, with or without the pointer.
  #
  # ## HRN handling (rpms-rpc#214)
  #
  # The client MUST NOT assign or enforce HRNs — HRN integrity is server
  # business logic. Two modes, selected by `Registration.hrn_mode`:
  #
  #   * :derive_from_dfn (DEFAULT, greenfield) — HRN := DFN. FileMan's IEN
  #     allocation IS the server-side atomic assigner, so the HRN is unique by
  #     construction with zero client logic and no race: create the patient,
  #     then file the returned DFN into the facility HRN field through AGG
  #     UPDATE PATIENT. (The DD input transform accepts 1-9 numeric digits —
  #     live-verified.)
  #
  #   * :clerk_supplied (legacy) — send the caller-supplied HRN with the create
  #     as a plain passthrough. NO client-side uniqueness is performed here.
  #
  # There is deliberately NO client-side HRN uniqueness/validation in either
  # mode (the PR #212 lineage's D-xref pre-check has been removed as
  # deprecated-by-design per #214).
  module Registration
    extend self

    # HRN assignment mode — see the module doc / rpms-rpc#214.
    HRN_MODE_DERIVE = :derive_from_dfn # greenfield default: HRN := DFN
    HRN_MODE_CLERK  = :clerk_supplied  # legacy: caller-supplied passthrough

    @hrn_mode = HRN_MODE_DERIVE

    # Site-selectable HRN mode (default :derive_from_dfn). Module-level state
    # via `extend self`, so `Registration.hrn_mode = :clerk_supplied`.
    attr_accessor :hrn_mode

    # IHS PATIENT file (#9000001, ^AUPNPAT). Created against the PATIENT
    # (#2) DFN with DINUM=DFN / DLAYGO=9000001 (AUPNLK2.m:57); AG pairs
    # ^AUPNPAT(RECNO) with ^DPT(RECNO) 1:1 (AG71A1.m:138).
    PATIENT_FILE = "9000001"

    # #9000001 fields AG's "New Patient" window files (RpmsRpc::Agg) and
    # RpmsRpc::Tribal reads back. AUPNPAT field numbers are four-digit
    # (node 11 pieces) — real AG DR strings write them that way
    # (DR="1109////NONE;1110////NONE", AG2.m:19):
    #   1108 TRIBE OF MEMBERSHIP        (AGED2.m:385; pointer to ^AUTTTRI —
    #                                    read at $P(^AUPNPAT(DFN,11),U,8),
    #                                    AG2.m:16-19)
    #   1111 CLASSIFICATION/BENEFICIARY (AGED2.m:384; pointer to ^AUTTBEN —
    #                                    $P(^(11),U,11), AG2.m:31)
    #   1112 ELIGIBILITY STATUS         (AGED1.m:347; $P(^AUPNPAT(DFN,11),U,12),
    #                                    AG0.m:48; set of codes I/D/C/P per
    #                                    the live DD)
    #   1118 CURRENT COMMUNITY          (AGED1.m:354; free text per the live DD)
    # Field definitions confirmed against the live bcer-9.0-ydb DD in rpms-ops
    # docs/REGISTRATION_RPC_CONTRACTS.md §5.
    FIELD_TRIBE = "1108"
    FIELD_CLASSIFICATION = "1111"
    FIELD_ELIGIBILITY = "1112"
    FIELD_COMMUNITY = "1118"

    # AG windows used for delegation (file 9009068.3; see RpmsRpc::Agg). The
    # create goes through "New Patient", the window AG registers through; the
    # HRN update stays on "Mini Registration", where it was captured (#214).
    AGG_ADD_WINDOW = Agg::NEW_PATIENT_WINDOW
    AGG_WINDOW = Agg::DEFAULT_WINDOW

    # attrs (FileMan-external values unless noted):
    #
    #   name:               "LAST,FIRST MIDDLE SUFFIX" (split at the first
    #                       comma), or name_last:/name_first:/name_middle:/
    #                       name_suffix: pieces
    #   dob:                Date/Time (formatted MM/DD/YYYY) or external string
    #   sex:                "F"/"M" or "FEMALE"/"MALE"
    #   ssn:                9 digits, or nil/"" for none
    #   hrn:                caller-supplied HRN — used ONLY in the
    #                       :clerk_supplied legacy mode (see hrn_mode); the
    #                       greenfield default derives HRN := DFN and ignores
    #                       this. Never client-validated for uniqueness (#214).
    #   tribe:/classification:
    #                       pointer IENs (#9999999.03 / #9999999.25); AG files
    #                       them internal
    #   eligibility_status: the set code or its name
    #   community_ien:/community_since:
    #                       the COMMUNITY (#9999999.05) IEN and the date the
    #                       patient moved there (Date/Time, MM/DD/YYYY, or
    #                       :birth for the date of birth; any other value
    #                       raises). AG stores the community as a pointer
    #                       (1117) plus a dated history entry (#9000001.51)
    #                       and derives the text (1118) from them, so the two
    #                       go together
    #   allow_duplicate:    only literal true permits adding after the caller
    #                       reviews AG's name/DOB candidates. Lookup failures
    #                       and invalid identity cannot be overridden.
    #
    # Returns:
    #   { success: true, dfn:, created: true }          — registered
    #   { success: false, error: Symbol, message: }     — rejected; error is
    #     :duplicate_identity (includes candidate_dfns), :identity_unverifiable,
    #     :agg_rejected / :hrn_file_failed
    #   nil                                             — no add response
    #
    # It sends what AG's window takes and files nothing around it. A value
    # AG's window has no parameter for is not sent, and the result names it,
    # so a caller cannot mistake it for filed (rpms-rpc#297):
    #
    #   unfiled: [:community]     free-text community: with no community_ien:
    #   unfiled: [:extra_fields]  the removed composition path's escape hatch
    #
    # `unfiled:` is absent when everything given was sent. The pre-add lookup
    # must answer in AGGRPC; a bind/read failure is :identity_unverifiable.
    # No availability probe or alternative write path is attempted (#409).
    # Name/DOB lookup candidates are conservative: sex is not returned, and
    # a different DOB does not prove a same-name add cannot resolve a chart.
    # See docs/REGISTRATION_SAFETY.md for limits of this two-RPC preflight.
    def register(attrs)
      register_via_agg(attrs)
    end

    # Create via AGG ADD NEW PATIENT, then file the HRN per hrn_mode. Prefer a
    # short broker session per registration (AG routines leak locals into long
    # sessions — see Agg).
    def register_via_agg(attrs)
      clerk = (hrn_mode == HRN_MODE_CLERK)
      params = agg_add_params(attrs)
      invalid = validate_identity(params)
      return invalid if invalid

      # Legacy clerk-supplied HRN rides the create call (the capsule files it
      # into the 41-multiple). Greenfield sends no HRN — it is set to the DFN
      # afterward, below.
      params["AGGPTHRN"] = attrs[:hrn].to_s if clerk && present?(attrs[:hrn])

      # Validate all values before lookup: a parameter delimiter in even an
      # IHS field must not replace the identity after it has been checked.
      Agg.encode_parms(params)
      duplicate = duplicate_identity(params, allow_duplicate: attrs[:allow_duplicate])
      return duplicate if duplicate

      created = Agg.add_patient(window: AGG_ADD_WINDOW, params: params)
      return created unless created && created[:success]

      dfn = created[:dfn]
      unless clerk
        # Greenfield: HRN := DFN. FileMan's IEN allocation already assigned a
        # unique DFN; echo it into the HRN field via the delegation update
        # path. No client-side uniqueness — unique by construction (#214).
        updated = Agg.update_patient(window: AGG_WINDOW, dfn: dfn, params: { "AGGPTHRN" => dfn.to_s })
        unless updated && updated[:success]
          return { success: false, error: :hrn_file_failed, dfn: dfn,
                   message: updated&.dig(:message).to_s }
        end
      end

      with_unfiled({ success: true, dfn: dfn, created: true }, agg_unsent(attrs))
    end

    # -- Patient update through AG (rpms-rpc#381) -----------------------------
    #
    # An edit goes through AG's own update RPC, AGG UPDATE PATIENT
    # (UPD^AGGPTUPD, AGGPTUPD.m:4), under AG's edit lock (Agg.editing), the
    # way a create goes through AGG ADD NEW PATIENT. AG decides what can be
    # edited: UPD takes a window name and that window's parameter names, never
    # field numbers. It refuses a name outside the window's "AC" index
    # (AGGPTUPD.m:48-49), and each name files at most one field, a field of
    # the window's file or of its secondary file (AGGPTUPD.m:20-22,62,74).
    # After filing, it stamps #9000001 .03/.12 and runs EDIT^AGGEXPRT
    # (AGGPTUPD.m:130-133). DDR FILER is not used: the owning package's RPC
    # edits its records.
    #
    # Each attribute below is one parameter of one AGG WINDOW DEFINITION
    # (#9009068.3) entry, as test/fixtures/agg/update_patient_windows.tsv
    # extracts it from the FOIA export. An update sends one AGG UPDATE
    # PATIENT call per window it touches.
    #
    #   attribute           window           parameter  type  files
    #   dob                 Personal Detail  AGGPTDOB   D     #2 .03
    #   sex                 Personal Detail  AGGPTSEX   C     #2 .02
    #   ssn                 Personal Detail  AGGPTSSN   X     #2 .09
    #   marital_status      Personal Detail  AGGPTMAR   T     #2 .05
    #   birth_city          Personal Detail  AGGPTPBC   X     #2 .092
    #   birth_state         Personal Detail  AGGPTPBS   T     #2 .093
    #   address_line1..3    Address          AGGPTAD1-3 X     #2 .111-.113
    #   city                Address          AGGPTCTY   X     #2 .114
    #   state               Address          AGGPTSTE   T     #2 .115
    #   zip                 Address          AGGPTZIP   X     #2 .116 or .1112
    #                                                         (PTZP^AGGUL2,
    #                                                         AGGUL2.m:227-234)
    #   phone_home          Address          AGGPTHPH   X     #2 .131
    #   phone_work          Address          AGGPTWPH   X     #2 .132
    #   phone_other         Address          AGGPTOPH   X     #9000001 1801
    #   email               Address          AGGPTEML   X     #9000001 1802
    #                                                         (+ 9000001.82
    #                                                         history,
    #                                                         EML^AGGUL1)
    #   community_ien       Address          AGGPTCOM   T     #9000001 1117
    #                                                         (+ 1118 text,
    #                                                         AGGPTUPD.m:92-93)
    #   community_since     Address          AGGPTCDT   X     #9000001.51 entry
    #                                                         (COMM^AGGPTADD)
    #   tribe               Eligibility      AGGPTTRI   T     #9000001 1108
    #   classification      Eligibility      AGGPTCLB   T     #9000001 1111
    #   eligibility_status  Eligibility      AGGPTELG   C     #9000001 1112
    #
    # Value forms are AG's (AGGPTUPD.m:50-56): D is an external date that
    # AG converts ($$DATE^AGGUL1, %DT "TS"), so a Date goes as MM/DD/YYYY; C
    # is the choice name (MALE/FEMALE; DIRECT ONLY or the code D); T is the
    # pointed-to IEN, filed internal; X is the text. An empty string clears
    # a field that has a value: UPD turns it into "@" (AGGPTUPD.m:63-64).
    UpdateAttribute = Struct.new(:window, :parameter, :file, :field, :form)

    WINDOW_PERSONAL_DETAIL = "Personal Detail" # #9009068.3 entry 1
    WINDOW_ADDRESS = "Address"                 # #9009068.3 entry 2
    WINDOW_ELIGIBILITY = "Eligibility"         # #9009068.3 entry 3

    UPDATE_ATTRIBUTES = {
      dob:                UpdateAttribute.new(WINDOW_PERSONAL_DETAIL, "AGGPTDOB", "2", ".03", :date),
      sex:                UpdateAttribute.new(WINDOW_PERSONAL_DETAIL, "AGGPTSEX", "2", ".02", :sex),
      ssn:                UpdateAttribute.new(WINDOW_PERSONAL_DETAIL, "AGGPTSSN", "2", ".09", :ssn),
      marital_status:     UpdateAttribute.new(WINDOW_PERSONAL_DETAIL, "AGGPTMAR", "2", ".05", :pointer),
      birth_city:         UpdateAttribute.new(WINDOW_PERSONAL_DETAIL, "AGGPTPBC", "2", ".092", :text),
      birth_state:        UpdateAttribute.new(WINDOW_PERSONAL_DETAIL, "AGGPTPBS", "2", ".093", :pointer),
      address_line1:      UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTAD1", "2", ".111", :text),
      address_line2:      UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTAD2", "2", ".112", :text),
      address_line3:      UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTAD3", "2", ".113", :text),
      city:               UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTCTY", "2", ".114", :text),
      state:              UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTSTE", "2", ".115", :pointer),
      zip:                UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTZIP", "2", nil, :text),
      phone_home:         UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTHPH", "2", ".131", :text),
      phone_work:         UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTWPH", "2", ".132", :text),
      phone_other:        UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTOPH", PATIENT_FILE, "1801", :text),
      email:              UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTEML", PATIENT_FILE, "1802", :text),
      community_ien:      UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTCOM", PATIENT_FILE, "1117", :pointer),
      community_since:    UpdateAttribute.new(WINDOW_ADDRESS, "AGGPTCDT", PATIENT_FILE, nil, :date_moved),
      tribe:              UpdateAttribute.new(WINDOW_ELIGIBILITY, "AGGPTTRI", PATIENT_FILE, FIELD_TRIBE, :pointer),
      classification:     UpdateAttribute.new(WINDOW_ELIGIBILITY, "AGGPTCLB", PATIENT_FILE, FIELD_CLASSIFICATION, :pointer),
      eligibility_status: UpdateAttribute.new(WINDOW_ELIGIBILITY, "AGGPTELG", PATIENT_FILE, FIELD_ELIGIBILITY, :choice)
    }.freeze

    # Raised before anything is sent when an update names something AG's
    # update windows do not file.
    class AttributeNotOfferedError < RpmsRpc::Error; end

    # Fields no AG window files (the FOIA AGG WINDOW DEFINITION export has
    # none of them in any window), by the attribute a caller might reach for.
    NOT_OFFERED = {
      phone_cell: "#2 .134 PHONE NUMBER [CELLULAR] is in no AG window; AG keeps a second " \
                  "number on #9000001 1801 (phone_other:)",
      pager: "#2 .135 PAGER NUMBER is in no AG window",
      community: "#9000001 1118 CURRENT COMMUNITY is not filed directly: AG sets it from " \
                 "community_ien: (AGGPTUPD.m:92-93)"
    }.freeze

    # Why a field-number edit has no attribute, for the migration message.
    FIELD_NOT_OFFERED = {
      [ "2", ".133" ] => "AG keeps email on #9000001 1802: use email:",
      [ "2", ".134" ] => NOT_OFFERED[:phone_cell],
      [ "2", ".135" ] => NOT_OFFERED[:pager],
      [ PATIENT_FILE, "1118" ] => NOT_OFFERED[:community]
    }.freeze

    # Update a patient through AG. attrs are the UPDATE_ATTRIBUTES keys; a
    # nil value is not sent and "" clears. community_ien: and
    # community_since: go together, as for register (AG files the
    # community with the date moved), and community_since: takes :birth
    # when dob: is given.
    #
    # Raises AttributeNotOfferedError for phone_cell:, pager:, community:
    # and the removed patient_fields:/ihs_fields: hashes (its message maps
    # each field number to its attribute), and ArgumentError for any other
    # unknown attribute or a malformed value, all before sending anything.
    #
    # Returns:
    #   { success: true, dfn: }
    #   { success: false, error: :invalid_dfn / :no_fields, message: }
    #     (:invalid_dfn also when AG finds no #2 or #9000001 entry to lock)
    #   { success: false, error: :lock_failed, message: }  AG's lock is held
    #     elsewhere (the message names who) or did not answer; retryable
    #   { success: false, error: :agg_rejected, window:, message:,
    #     filed_windows: [...] }  a window AG refused; each window is its
    #     own AGG UPDATE PATIENT call, so the windows before it are filed
    #   { success: false, error: :frame_too_long, window:, message:,
    #     filed_windows: [...] }  a value is over the wire's framing limit and
    #     was refused before its window was sent (nothing of that window is
    #     filed; message names the limit, never the value)
    #   nil  no broker reply to an AGG UPDATE PATIENT call
    def update(dfn, **attrs)
      params_by_window = update_params(attrs)
      dfn = dfn.to_i
      return { success: false, error: :invalid_dfn, message: "a positive DFN is required" } if dfn <= 0
      return { success: false, error: :no_fields, message: "no attributes to update" } if params_by_window.empty?

      Agg.editing(dfn: dfn) { update_windows(dfn, params_by_window) }
    end

    private

    def validate_identity(params)
      date = identity_date(params["AGGPTDOB"])
      fields = []
      fields << :last_name unless present?(params["AGGPTLNM"])
      fields << :first_name unless present?(params["AGGPTFNM"])
      fields << :dob unless date
      fields << :sex unless %w[MALE FEMALE].include?(params["AGGPTSEX"])
      unless fields.empty?
        return { success: false, error: :identity_unverifiable,
                 message: "patient identity missing or invalid: #{fields.join(', ')}" }
      end

      # Use the same unambiguous date in the lookup and the subsequent add.
      params["AGGPTDOB"] = date.strftime("%m/%d/%Y")
      nil
    end

    def identity_date(value)
      text = value.to_s.strip
      case text
      when %r{\A\d{1,2}/\d{1,2}/\d{4}\z} then Date.strptime(text, "%m/%d/%Y")
      when %r{\A\d{1,2}/\d{1,2}/\d{2}\z} then Date.strptime(text, "%m/%d/%y")
      when /\A\d{4}-\d{2}-\d{2}\z/ then Date.iso8601(text)
      when /\A\d{7}\z/ then FilemanDateParser.parse_date(text)
      else FilemanDateParser.parse_external_date(text)
      end
    rescue ArgumentError
      nil
    end

    def duplicate_identity(params, allow_duplicate:)
      candidates = Agg.registration_candidates(params)
      return if candidates.empty? || allow_duplicate == true

      { success: false, error: :duplicate_identity,
        candidate_dfns: candidates.map { |candidate| candidate[:dfn] }.uniq.sort,
        message: "matching patient candidates require explicit override" }
    rescue Client::RpcError, Client::ConnectionError
      { success: false, error: :identity_unverifiable,
        message: "patient duplicate lookup could not be verified" }
    end

    # The name as LAST^FIRST^MIDDLE^SUFFIX, which name_parts splits into
    # AG's AGGPTLNM/FNM/MNM/SFX. A "LAST,REST" string is split at the first
    # comma, with REST riding the FIRST piece.
    def name_pieces(attrs)
      pieces =
        if attrs[:name_last]
          [ attrs[:name_last], attrs[:name_first], attrs[:name_middle], attrs[:name_suffix] ]
            .map { |p| p.to_s.strip.upcase }
        else
          name = attrs[:name].to_s.strip.upcase
          raise ArgumentError, "registration name is required" if name.empty?
          last, rest = name.split(",", 2)
          [ last.to_s.strip, rest.to_s.strip ]
        end
      if pieces.any? { |p| p.include?("^") }
        raise ArgumentError, "registration name must not contain '^'"
      end
      pieces.join("^").sub(/\^+\z/, "")
    end

    # AG window values are FileMan-external, so dates go over as MM/DD/YYYY.
    def external_date(value)
      return value.strftime("%m/%d/%Y") if value.is_a?(Date) || value.is_a?(Time)
      value.to_s
    end

    # One AGG UPDATE PATIENT call per window, in order; stop at the first
    # window AG refuses or does not answer.
    def update_windows(dfn, params_by_window)
      filed = []
      params_by_window.each do |window, params|
        result = Agg.update_patient(window: window, dfn: dfn, params: params)
        return nil if result.nil?
        unless result[:success]
          return { success: false, error: :agg_rejected, window: window,
                   message: result[:message].to_s, filed_windows: filed }
        end

        filed << window
      rescue RpmsRpc::Client::FrameTooLongError => e
        # A value the wire would mis-frame is refused before that window is
        # sent (#472). The windows before it are already filed, so keep the
        # report the :agg_rejected path gives instead of letting it raise.
        return { success: false, error: :frame_too_long, window: window,
                 message: e.message, filed_windows: filed }
      end
      { success: true, dfn: dfn }
    end

    # { window => { PARAMETER => value } } for the attributes given, after
    # refusing anything AG's update windows do not file.
    def update_params(attrs)
      refuse_unoffered(attrs)
      given = attrs.reject { |_, value| value.nil? }
      check_community(given)

      by_window = {}
      given.each do |name, value|
        attribute = UPDATE_ATTRIBUTES.fetch(name)
        (by_window[attribute.window] ||= {})[attribute.parameter] = update_value(attribute, value, given)
      end
      move_date_moved_last(by_window)
    end

    def refuse_unoffered(attrs)
      legacy = attrs.slice(:patient_fields, :ihs_fields)
      raise AttributeNotOfferedError, legacy_migration_message(legacy) unless legacy.empty?

      attrs.each_key do |name|
        raise AttributeNotOfferedError, "#{name}: is not offered: #{NOT_OFFERED[name]}" if NOT_OFFERED.key?(name)
        raise ArgumentError, "unknown patient attribute #{name}:" unless UPDATE_ATTRIBUTES.key?(name)
      end
    end

    # The message for a caller still sending field numbers: each field's
    # attribute, or why there is none.
    def legacy_migration_message(legacy)
      files = { patient_fields: "2", ihs_fields: PATIENT_FILE }
      lines = legacy.flat_map do |key, fields|
        Hash(fields).keys.map do |field|
          file = files.fetch(key)
          name = UPDATE_ATTRIBUTES.find { |_, a| a.file == file && a.field == field.to_s }&.first
          why = FIELD_NOT_OFFERED[[ file, field.to_s ]] || "not in AG's update windows"
          "##{file} #{field}: #{name ? "use #{name}:" : "not offered (#{why})"}"
        end
      end
      "patient_fields:/ihs_fields: were removed; Patient.update takes named attributes " \
        "that AG files (rpms-rpc#381). #{lines.join('; ')}"
    end

    def check_community(given)
      if given.key?(:community_ien) != given.key?(:community_since)
        raise ArgumentError, "community_ien and community_since go together " \
                             "(AG files the community with the date moved)"
      end
      # UPD reads ^AUTTCOM(AGGPTCOM,0) with no $G (AGGPTUPD.m:93), so a
      # cleared community would be an M error, not a cleared field.
      return unless given.key?(:community_ien) && given[:community_ien].to_s.strip.empty?

      raise ArgumentError, "community_ien cannot be cleared through AG"
    end

    # AGGPTCDT goes last in its window: UPD re-converts it with
    # $$DATE^AGGUL1 at the top of every later parameter's turn
    # (AGGPTUPD.m:61), while COMM^AGGPTADD converts an external date itself
    # (AGGPTADD.m:151). Sent last, it is converted exactly once.
    def move_date_moved_last(by_window)
      params = by_window[WINDOW_ADDRESS]
      date_moved = UPDATE_ATTRIBUTES[:community_since].parameter
      params[date_moved] = params.delete(date_moved) if params&.key?(date_moved)
      by_window
    end

    # The value in the form AG's window type takes (see UPDATE_ATTRIBUTES).
    def update_value(attribute, value, given)
      return "" if value.to_s.strip.empty? && attribute.form != :date_moved

      case attribute.form
      when :date then external_date(value)
      when :date_moved then agg_date_moved(community_since: value, dob: given[:dob])
      when :sex then agg_sex(value)
      when :ssn then value.to_s.delete("-")
      when :choice then value.to_s.strip.upcase
      when :pointer then pointer_value(attribute, value)
      else value.to_s
      end
    end

    # T parameters file internal (AGGPTUPD.m:82-85,125), so the value must
    # be an IEN.
    def pointer_value(attribute, value)
      ien = value.to_s.strip
      return ien if ien.match?(/\A\d+\z/)

      raise ArgumentError, "#{attribute.parameter} takes the pointed-to IEN (digits only)"
    end

    # PARMS for AGG ADD NEW PATIENT (the "New Patient" window).
    # Values are FileMan-external — AGGPTSEX is the coded set value
    # ("MALE"/"FEMALE"), dates MM/DD/YYYY. Absent attributes are omitted
    # (Agg.encode_parms drops nils). HRN is handled by the caller per mode.
    def agg_add_params(attrs)
      last, first, middle, suffix = name_parts(attrs)
      {
        "AGGPTLNM" => last,
        "AGGPTFNM" => first,
        "AGGPTMNM" => blank_to_nil(middle),
        "AGGPTSFX" => blank_to_nil(suffix),
        "AGGPTDOB" => blank_to_nil(external_date(attrs[:dob])),
        "AGGPTSEX" => agg_sex(attrs[:sex]),
        "AGGPTSSN" => blank_to_nil(attrs[:ssn].to_s.delete("-"))
      }.merge(agg_ihs_params(attrs))
    end

    # The IHS PATIENT values the "New Patient" window carries (Agg module
    # doc). Pointers are IENs and eligibility is the set code or its name: AG
    # files them internal. Community is the pointer and the date moved
    # together, as AG's window requires of both.
    def agg_ihs_params(attrs)
      community = present?(attrs[:community_ien])
      since = present?(attrs[:community_since])
      if community != since
        raise ArgumentError, "community_ien and community_since go together " \
                             "(AG files the community with the date moved)"
      end

      {
        "AGGPTCLB" => blank_to_nil(attrs[:classification]),
        "AGGPTELG" => blank_to_nil(attrs[:eligibility_status]),
        "AGGPTTRI" => blank_to_nil(attrs[:tribe]),
        "AGGPTCOM" => blank_to_nil(attrs[:community_ien]),
        "AGGPTCDT" => (since ? agg_date_moved(attrs) : nil)
      }
    end

    # AGGPTCDT, the date moved. AG's window offers "B" for at birth, but its
    # GUI turns that into a date before it sends: sent as "B",
    # COMM^AGGPTADD files no #9000001.51 entry and the create still answers
    # success (live, 2026-10-02). So :birth (or "B") becomes the date of
    # birth here, and anything that is not a date is refused rather than
    # sent to be dropped.
    def agg_date_moved(attrs)
      since = attrs[:community_since]
      since = attrs[:dob] if since == :birth || since.to_s.strip.casecmp?("B")
      raise ArgumentError, "community_since: :birth needs dob:" unless present?(since)

      date = external_date(since)
      return date if date.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z})

      raise ArgumentError, "community_since must be a Date, MM/DD/YYYY or :birth"
    end

    # What the caller gave that AG's window has no parameter for, by attr key.
    def agg_unsent(attrs)
      unsent = []
      unsent << :community if present?(attrs[:community])
      unsent << :extra_fields unless Array(attrs[:extra_fields]).empty?
      unsent
    end

    # A successful result names what was not filed; failures pass through.
    def with_unfiled(result, unsent)
      return result unless result.is_a?(Hash) && result[:success] && !unsent.empty?

      result.merge(unfiled: unsent)
    end

    # AGG name pieces as [last, first, middle, suffix] — same "^"-splitting
    # contract as name_pieces (raises on a "^" in any piece / a blank name).
    def name_parts(attrs)
      pieces = name_pieces(attrs).split("^", -1)
      [ pieces[0].to_s, pieces[1].to_s, pieces[2].to_s, pieces[3].to_s ]
    end

    # AGGPTSEX is the C-type window param coded MALE^M / FEMALE^F — the
    # client sends the external set value. Map "M"/"F" to it; pass any other
    # value through uppercased.
    def agg_sex(sex)
      case sex.to_s.strip.upcase
      when "M", "MALE" then "MALE"
      when "F", "FEMALE" then "FEMALE"
      else blank_to_nil(sex.to_s.strip.upcase)
      end
    end

    def blank_to_nil(value)
      s = value.to_s
      s.empty? ? nil : s
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
