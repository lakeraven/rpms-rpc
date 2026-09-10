# frozen_string_literal: true

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
  module BehavioralHealth
    extend self

    IEN_NAME_SEPARATOR = "~" # R="~" — AMHGDVF.m:12

    # Visit list for a patient over a FileMan date range, newest first.
    #
    # Rows are screened per-user by $$ALLOWVI^AMHUTIL(DUZ,AMHIEN)
    # (AMHGD.m:33). An empty result means "no visits VISIBLE TO THIS USER in
    # this range", never "this patient has no visits" — callers must not
    # render it as the latter.
    def visits(dfn, from:, to:)
      mapping = DataMapper[:amhg_visit_list]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, [ from, to, dfn ].join("|"))

      mapping.parse_many(response).map { |row| decorate_visit(row) }
    end

    # Detail for one visit, or nil when the IEN yields no row.
    def visit_information(visit_ien)
      mapping = DataMapper[:amhg_visit_information]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, visit_ien.to_s)
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

    # -- visit detail tabs ---------------------------------------------------

    # Activity tab. One row (AMHGDVF.m:291).
    def visit_activity(visit_ien)
      row = single_row(:amhg_visit_activity, visit_ien)
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
      row = single_row(:amhg_visit_axis_v, visit_ien)
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
          provider:       split_ien_name([ row[:provider_ien], row[:provider] ].join(IEN_NAME_SEPARATOR)),
          comment:        presence(row[:comment])
        }
      end
    end

    private

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

    # "412~THERAPIST,EXAMPLE" -> { ien: "412", name: "THERAPIST,EXAMPLE" }.
    # An empty column yields nil rather than a pair of blanks: the wire emits
    # "" when the pointer is unset (the $S guards at AMHGDVF.m:22, :29, :33).
    def split_ien_name(raw)
      value = raw.to_s
      return nil if value.empty?

      ien, name = value.split(IEN_NAME_SEPARATOR, 2)
      return { ien: nil, name: ien } if name.nil?

      { ien: presence(ien), name: presence(name) }
    end

    def flag?(value)
      v = value.to_s.strip
      !v.empty? && v != "0"
    end

    def call(mapping, param)
      RpmsRpc.client.call_rpc(mapping.rpc_name, param.to_s)
    end

    def single_row(mapping_name, param)
      mapping = DataMapper[mapping_name]
      mapping.parse_many(call(mapping, param)).first
    end

    def code_rows(mapping_name, param)
      mapping = DataMapper[mapping_name]
      mapping.parse_many(call(mapping, param)).map do |row|
        { code_pointer: presence(row[:code_pointer]),
          code: presence(row[:code]),
          narrative: presence(row[:narrative]) }
      end
    end

    # Single-column free-text responses. Read whole lines: these columns carry
    # unsanitised clinical text and caret-splitting them would fabricate
    # fields out of punctuation.
    def text_lines(mapping_name, param)
      mapping = DataMapper[mapping_name]
      response = call(mapping, param)
      lines = response.is_a?(String) ? response.split(/\r?\n/) : Array(response)

      lines.filter_map do |line|
        next if line.nil?
        next if DataMapper.recordset_header_row?(line)

        stripped = DataMapper.strip_recordset_separators(line)
        stripped.empty? ? nil : stripped
      end
    end

    def presence(value)
      v = value.to_s
      v.empty? ? nil : v
    end
  end
end
