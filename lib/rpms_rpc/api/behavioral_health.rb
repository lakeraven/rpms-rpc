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

    def presence(value)
      v = value.to_s
      v.empty? ? nil : v
    end
  end
end
