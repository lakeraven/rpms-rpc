# frozen_string_literal: true

require_relative "behavioral_health/wire"
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

    # Raised when a visit is refused before the RPC, or the reply is not a
    # filed record IEN. The message names the check, never a value the
    # caller passed and never the broker's text.
    class SaveError < RpmsRpc::Error; end

    # External values of BH VISIT (#9002011) field .02, piece 3 of
    # ^DD(9002011,.02,0) on the pinned image. $$SCI^AMHGT returns "" for
    # any other external value (AMHGT.m:183-196) and VISIT files that
    # blank (AMHGSVF.m:22).
    PROGRAM_CODES = [
      "MENTAL HEALTH",
      "SOCIAL SERVICES",
      "OTHER",
      "CHEMICAL DEPENDENCY"
    ].freeze

    # #9002011 field .11: A:APPOINTMENT;W:WALK-IN;U:UNSPECIFIED. Same SCI
    # collapse (AMHGSVF.m:31).
    APPOINTMENT_WITH_CODES = [
      "APPOINTMENT",
      "WALK-IN",
      "UNSPECIFIED"
    ].freeze

    POSITIVE_IEN = /\A[1-9]\d*\z/
    # Pipe splits AMHSTR. $C(30)/$C(31) frame the reply. The other C0
    # controls and DEL are not field text.
    UNSAFE_WIRE = /[|\x00-\x1f\x7f]/
    private_constant :POSITIVE_IEN, :UNSAFE_WIRE

    # Visit list for a patient over a FileMan date range, newest first.
    #
    # Rows are screened per-user by $$ALLOWVI^AMHUTIL(DUZ,AMHIEN)
    # (AMHGD.m:33). An empty result means "no visits VISIBLE TO THIS USER in
    # this range", never "this patient has no visits" — callers must not
    # render it as the latter.
    def visits(dfn, from:, to:)
      mapping = DataMapper[:amhg_visit_list]
      response = call_amhg(mapping, from, to, dfn)

      mapping.parse_many(response).map { |row| decorate_visit(row) }
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
    # (VISIT^AMHGSVF, AMHGSVF.m:11-45). One pipe-delimited AMHSTR. Runs
    # under AMHGRPC via {Wire#call_amhg}.
    #
    # Pieces, in order: mode A/E, record IEN, primary provider (files
    # #9002011.02), program external (.02, $$SCI^AMHGT at AMHGSVF.m:22;
    # an unknown external becomes "" and is filed blank), clinic (.25 ->
    # 40.7), type of contact (.07 -> 9002012.1), arrival, encounter date
    # (.01, taken with unary + at AMHGSVF.m:26), location (.04 ->
    # 9999999.06), appointment/walk-in external (.11, set
    # A:APPOINTMENT;W:WALK-IN;U:UNSPECIFIED, SCI at AMHGSVF.m:31),
    # community of service (.05 -> AUTTCOM; a pointer, not a comment),
    # patient DFN (.08), group name, group time, e-sign flag, activity
    # time.
    #
    # Arrival is piece 7 and is always blank. VISIT $TR's colons out of
    # it and passes it to MODV as ARR, and MODV never files ARR
    # (AMHGEVF.m:77-88). The date of service is piece 8 (AMHGSVF.m:26).
    # Every call sends exactly these 16 pieces, blanks included.
    # Omitting the arrival piece would put the date in piece 7.
    #
    # MODV^AMHGEVF (AMHGEVF.m:77-121): mode "E" with a blank record IEN
    # becomes "A" (line 79), so a blank record_ien is refused here and
    # never sent. Group fields (.12 activity time, .34, 1109 group name,
    # 1104 group time) are filed only when the group name is non-empty
    # (lines 91-95). An add that fails leaves AMHIEN 0 (lines 106-108).
    # An edit that fails still returns REC (lines 116-118): a reply IEN
    # equal to the requested record does not prove the edit was filed.
    #
    # The reply is "T00010BMXIEN" $C(30) <+AMHIEN> $C(30) $C(31)
    # (AMHGSVF.m:41-44). MERR^AMHGU writes one row "M ERROR|<text>"
    # $C(30) (AMHGU.m:108-120). Piece 15 is sent as "1" only when esign
    # is true; VISIT calls UPDREC^AMHGESIG when that piece is set
    # (AMHGSVF.m:40).
    #
    # Returns the record IEN as a string.
    def save_visit(provider:, patient:, encounter_date:, record_ien: nil, program: nil,
                   clinic: nil, type_of_contact: nil, encounter_location: nil,
                   community_of_service: nil, appointment_with: nil, group_name: nil,
                   group_time: nil, activity_time: nil, esign: false)
      wire, requested = save_visit_wire(
        provider: provider, patient: patient, encounter_date: encounter_date,
        record_ien: record_ien, program: program, clinic: clinic,
        type_of_contact: type_of_contact, encounter_location: encounter_location,
        community_of_service: community_of_service, appointment_with: appointment_with,
        group_name: group_name, group_time: group_time, activity_time: activity_time,
        esign: esign
      )
      mapping = DataMapper[:amhg_save_visit]
      save_visit_ien(call_amhg(mapping, wire), requested)
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
                        appointment_with:, group_name:, group_time:, activity_time:, esign:)
      requested = save_visit_record_ien(record_ien)
      name = save_visit_text(group_name)
      gtime = save_visit_text(group_time)
      atime = save_visit_text(activity_time)
      save_visit_refuse!("group time requires a group name") if name.empty? && (!gtime.empty? || !atime.empty?)

      program_piece = save_visit_code(program, PROGRAM_CODES, "program")
      clinic_piece = save_visit_optional_ien(clinic, "clinic")
      contact_piece = save_visit_optional_ien(type_of_contact, "type of contact")
      location_piece = save_visit_optional_ien(encounter_location, "encounter location")
      appointment_piece = save_visit_code(appointment_with, APPOINTMENT_WITH_CODES, "appointment/walk-in")
      community_piece = save_visit_optional_ien(community_of_service, "community of service")
      esign_piece = esign == true ? "1" : ""
      pieces = [
        requested.empty? ? "A" : "E",
        requested,
        save_visit_required_ien(provider, "provider"),
        program_piece,
        clinic_piece,
        contact_piece,
        "",
        save_visit_encounter(encounter_date),
        location_piece,
        appointment_piece,
        community_piece,
        save_visit_required_ien(patient, "patient"),
        name,
        gtime,
        esign_piece,
        atime
      ]
      wire = pieces.join("|")
      # Internal invariant: VISIT^AMHGSVF is 16 pieces, date in piece 8.
      count = wire.split("|", -1).length
      raise Error, "AMHG SAVE VISIT wire has #{count} pieces, not 16" unless count == 16
      [ wire, requested ]
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

    def save_visit_required_ien(value, label)
      text = save_visit_text(value)
      save_visit_refuse!("#{label} is required") if text.empty?
      save_visit_refuse!("#{label} must be a positive integer") unless text.match?(POSITIVE_IEN)
      text
    end

    def save_visit_optional_ien(value, label)
      text = save_visit_text(value)
      return "" if text.empty?
      save_visit_refuse!("#{label} must be a positive integer") unless text.match?(POSITIVE_IEN)

      text
    end

    def save_visit_code(value, allowed, label)
      text = save_visit_text(value)
      return "" if text.empty?
      save_visit_refuse!("#{label} is not a filed code") unless allowed.include?(text)

      text
    end

    def save_visit_encounter(value)
      text = save_visit_text(value)
      save_visit_refuse!("encounter date is required") if text.empty?
      save_visit_refuse!("encounter date is not a FileMan date") if FilemanDateParser.parse_datetime_or_date(text).nil?
      text
    end

    def save_visit_text(value)
      return "" if value.nil?

      text = value.to_s
      save_visit_refuse!("a value contains a separator or control character") if text.match?(UNSAFE_WIRE)
      text.strip
    end

    # GLOBAL ARRAY reply: optional "<seq>\x00" ack, rows split on $C(30),
    # cut at $C(31). A newline-only body (a client that already split, or
    # a line seed) is used as rows. The IEN field is a string so an
    # "M ERROR|..." row is not coerced to 0.
    def save_visit_ien(response, requested)
      rows = save_visit_rows(response)
      save_visit_refuse!("AMHG SAVE VISIT returned an M error") if rows.any? { |row| row.start_with?("M ERROR|") }

      data = rows.reject { |row| DataMapper.recordset_header_row?(row) }
      ien = data.empty? ? "" : DataMapper[:amhg_save_visit].parse_one(data.first)&.dig(:ien).to_s
      save_visit_refuse!("AMHG SAVE VISIT returned no record") unless ien.match?(POSITIVE_IEN)
      save_visit_refuse!("AMHG SAVE VISIT edit did not return the requested record") if !requested.empty? && ien != requested
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
