# frozen_string_literal: true

require_relative "../data_mapper"

module RpmsRpc
  module Mappings
    # GROUPL^AMHGDA (AMHGDA.m:96). One param: "begin|end|provider". The third
    # piece is a PROVIDER IEN used for visibility (AMHGDA.m:115-119), not a
    # patient DFN — the loop walks ^AMHGROUP("AINV") (AMHGDA.m:110).
    #
    # Inverse-date constants (AMHGDA.m:107-108):
    #   AMHIVB = (9999999-AMHB)+.9999
    #   AMHIVE = (9999999-AMHE)-.0001
    # Same pair as VISITL^AMHGD (AMHGD.m:22-23). Opposite of TPL/SFL
    # (+.0001 / -.9999, AMHGD.m:167-168) and of INTAKEL in this same
    # routine (AMHGDA.m:152-153). The same from/to does not select
    # equivalently across those lists.
    #
    # Rows are screened per-user by $$ALLOWV^AMHUTIL(DUZ, location)
    # (AMHGDA.m:114) AND by provider-visibility (site file 16, $$PRVG, or
    # field .12). An absent group is not evidence the group does not exist.
    #
    # Header at AMHGDA.m:103 declares 12 columns; the row at :137 emits 12.
    # No pairs — Provider/Clinic/Program/ContactType are external-only.
    # POV is the FIRST 21-multiple entry only (AMHGDA.m:130-132).
    # Signed is inverted: "*" means NOT signed (AMHGDA.m:133).
    DataMapper.define(:amhg_group_list) do |m|
      m.rpc "AMHG GET GROUPS"
      m.field 0,  :ien
      m.field 1,  :sort_date         # internal FileMan (AMHDT)
      m.field 2,  :date              # $$LVDT^AMHGU of the same
      m.field 3,  :group_name
      m.field 4,  :activity_code     # external code, not a pair
      m.field 5,  :program
      m.field 6,  :clinic
      m.field 7,  :provider
      m.field 8,  :contact_type
      m.field 9,  :pov               # first POV only — AMHGDA.m:130
      m.field 10, :signed_marker     # "*" means NOT signed — AMHGDA.m:133
      m.field 11, :location
    end

    # ENC^AMHGDGP (AMHGDGP.m:10). One param: the group IEN. Always exactly
    # one row — there is no existence guard (AMHGDGP.m:54-55).
    #
    # The header is built across TWO SETs (AMHGDGP.m:17-18): 12 columns,
    # then "^T00250ChiefComplaint". Thirteen columns, not the 12 a
    # single-line read shows. The row at :55 emits 13.
    #
    # Six columns carry an "IEN~external" pair (R="~", AMHGDGP.m:13):
    # primary_provider, clinic, type_of_contact, encounter_location,
    # community_of_service, activity. Program is external-only — AMHPRGS
    # is NEW'd at :20 and never assigned. GroupName is GET1^DIQ(...,.03,"I")
    # at :24, not a pair (GROUPL emits the same field without "I").
    #
    # arrival_time is permanently blank: AMHGDGP.m:38 extracts the time
    # fraction, :43 assigns AMHARR="" with the pad logic commented out.
    #
    # Inactive location/community: :45 / :49 clear the IEN, which blanks
    # the entire pair at :47 / :51 — the external name is discarded.
    #
    # EncounterDate is $$VCDT^AMHGU (AMHGDGP.m:23) — "YR,MO,DY,HR,MN" —
    # not the $$LVDT display GROUPL sends for the same field.
    #
    # ChiefComplaint is field 1200 via GET1^DIQ (AMHGDGP.m:53), last
    # column, no $TR. A caret in the complaint truncates the value.
    DataMapper.define(:amhg_group_information) do |m|
      m.rpc "AMHG GET GROUP INFORMATION"
      m.field 0,  :ien
      m.field 1,  :primary_provider_raw
      m.field 2,  :program            # external only — AMHPRGS never assigned
      m.field 3,  :group_name         # "I" of .03 — AMHGDGP.m:24
      m.field 4,  :clinic_raw
      m.field 5,  :type_of_contact_raw
      m.field 6,  :encounter_location_raw
      m.field 7,  :encounter_date     # $$VCDT, not $$LVDT
      m.field 8,  :arrival_time       # always "" — AMHGDGP.m:43
      m.field 9,  :community_of_service_raw
      m.field 10, :activity_raw
      m.field 11, :activity_time
      m.field 12, :chief_complaint
    end

    # PAT^AMHGDGP (AMHGDGP.m:185). One param: the group IEN. Multi-row over
    # ^AMHGROUP(ien,51). Header :193, row :206 — 9 columns, 9 fields.
    #
    # BMXIEN is the GROUP ien repeated, not a patient-row id. PatientIEN
    # is the DFN. AMHREC is $$GETREC^AMHGU (AMHGDGP.m:198) — the linked
    # visit in the 61-multiple. AMHDA is never emitted, so a patient row
    # cannot be addressed for edit or delete by subfile IEN.
    #
    # Sex is INTERNAL (AMHGDGP.m:200). DOB is $$LVDT of file 2 .03.
    # DOD is GET1^DIQ of .351 without "I" (external). Chart is
    # $$HRN^AUPNPAT(dfn,DUZ(2)).
    DataMapper.define(:amhg_group_patients) do |m|
      m.rpc "AMHG GET GROUP PATIENTS"
      m.field 0, :group_ien           # BMXIEN — parent repeated
      m.field 1, :patient_ien
      m.field 2, :visit_ien           # AMHREC
      m.field 3, :name
      m.field 4, :sex                 # internal
      m.field 5, :age
      m.field 6, :dob                 # $$LVDT
      m.field 7, :chart
      m.field 8, :date_of_death
    end

    # CPT^AMHGDGP (AMHGDGP.m:104). One param: "ien|dupe|date". Pieces 2/3
    # optional; AMHDATE defaults to DT when empty (AMHGDGP.m:114). When
    # AMHDUPE is set, CPT^AMHUTIL1 may drop a row — absence is not proof
    # the code is not on the group.
    #
    # Header :115, row :131 — 8 columns, 8 fields. R="~" is set and unused.
    # BMXIEN is AMHCPTI (file 81 pointer), not AMHDA. The subfile IEN is
    # never emitted, so these rows cannot address a CPT entry for edit.
    # Quantity is forced to 1 when empty or <1 (AMHGDGP.m:122-123) before
    # it hits the wire. Modifiers are separate IEN/name columns, not pairs.
    DataMapper.define(:amhg_group_cpt) do |m|
      m.rpc "AMHG GET GROUP CPT"
      m.field 0, :code_pointer        # file 81 IEN, not the subfile IEN
      m.field 1, :code
      m.field 2, :narrative
      m.field 3, :quantity
      m.field 4, :mod1_ien
      m.field 5, :mod1
      m.field 6, :mod2_ien
      m.field 7, :mod2
    end

    # EDU^AMHGDGP (AMHGDGP.m:155). One param: the group IEN. Multi-row over
    # ^AMHGROUP(ien,71). Header :163, row :181 — 9 columns, 9 fields.
    #
    # BMXIEN is AMHDA — the 71-multiple IEN. This is the one group-tab
    # list whose first column is the addressable subfile IEN.
    #
    # Provider is AMHPRVI_"-"_name (AMHGDGP.m:179), a HYPHEN pair, not
    # R="~" (which is set at :158 and unused).
    #
    # Comment is the RAW node ^AMHGROUP(ien,71,AMHDA,11) with no $TR
    # (AMHGDGP.m:173). A caret in the comment shifts CPT/Status/Goal/
    # Provider into phantom columns. Do not treat those four as reliable
    # when the clinician typed "^".
    DataMapper.define(:amhg_group_edu) do |m|
      m.rpc "AMHG GET GROUP EDU"
      m.field 0, :ien                 # AMHDA — the 71-multiple IEN
      m.field 1, :topic
      m.field 2, :time_spent
      m.field 3, :level_of_understanding
      m.field 4, :comment             # raw node — caret-unsafe
      m.field 5, :cpt
      m.field 6, :status
      m.field 7, :goal
      m.field 8, :provider_raw        # IEN-name, hyphen not tilde
    end

    # POV^AMHGDGP (AMHGDGP.m:59). One param: "ien|dupe|date". Same optional
    # dupe/date pieces as CPT (AMHGDGP.m:67-69); $$CHKD^AMHUTIL1 may drop
    # a row when AMHDUPE is set.
    #
    # Header :70, row :81 — 3 columns, 3 fields. BMXIEN is AMHPOVI
    # (+$G of the 21-multiple .01), a pointer into 9002012.2 — not AMHDA.
    # Same AXIS-II trap: the subfile IEN is never emitted.
    DataMapper.define(:amhg_group_pov) do |m|
      m.rpc "AMHG GET GROUP POV"
      m.field 0, :code_pointer        # 9002012.2 pointer, not the subfile IEN
      m.field 1, :code
      m.field 2, :narrative
    end

    # SOAP^AMHGDGP (AMHGDGP.m:85). One param: the group IEN. Single
    # free-text column, multi-row over ^AMHGROUP(ien,31). Raw nodes, no
    # caret sanitisation (AMHGDGP.m:97). No TIU early-return (unlike
    # SOAP^AMHGDVF). Read as whole lines.
    DataMapper.define(:amhg_group_soap) do |m|
      m.rpc "AMHG GET GROUP SOAP"
      m.field 0, :text
    end

    # SP^AMHGDGP (AMHGDGP.m:135). One param: the group IEN. Multi-row over
    # ^AMHGROUP(ien,11), filtered to piece 2="S" (AMHGDGP.m:147) — primaries
    # never appear. Header :143, row :151 — 2 columns, 2 fields.
    #
    # BMXIEN is AMHSPRVI (file 200 pointer), not AMHDA. The subfile IEN
    # is never emitted. Provider is the external name in column 2; R="~"
    # is set and unused — this is not a tilde pair.
    DataMapper.define(:amhg_group_secondary_providers) do |m|
      m.rpc "AMHG GET GROUP SEC PROVIDERS"
      m.field 0, :provider_ien        # file 200 IEN, not the subfile IEN
      m.field 1, :name
    end
  end
end
