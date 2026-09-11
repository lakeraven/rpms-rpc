# frozen_string_literal: true

require_relative "../data_mapper"

module RpmsRpc
  module Mappings
    # CML^AMHGD (AMHGD.m:122). One param: "begin|end|dfn". The third piece
    # is a patient DFN — the loop walks ^AMHPCASE("AA",AMHP) (AMHGD.m:135).
    #
    # Inverse-date constants (AMHGD.m:133-134):
    #   AMHIVB = (9999999-AMHB)+.0001
    #   AMHIVE = (9999999-AMHE)-.9999
    # Same pair as COML^AMHGDA (AMHGDA.m:62-63) and as TPL/SFL
    # (AMHGD.m:167-168). Opposite of VISITL (AMHGD.m:22-23) and GROUPL
    # (AMHGDA.m:107-108). The same from/to does not select equivalently
    # across those lists, but CML and COML agree with each other.
    #
    # Rows are screened per-user by $$ALLOWCD^AMHLCD(DUZ,AMHIEN)
    # (AMHGD.m:138). An absent case is not evidence the case does not exist.
    #
    # Header at AMHGD.m:129 declares 8 columns; the row at :152 emits 8.
    # Three columns carry an "IEN~external" pair (R="~", AMHGD.m:125):
    # Disposition (AMHDSPS), Program (AMHPRGS), Provider (AMHPRVS). All
    # three pair variables are actually emitted — no dead-pair trap here.
    #
    # BMXIEN is AMHIEN, the 9002011.58 record IEN — addressable.
    # SortDate is field .01 internal; Open/Admit/Closed are $$LVDT of
    # .01 / .04 / .05 (AMHGD.m:139-141, :152).
    DataMapper.define(:amhg_case_dates) do |m|
      m.rpc "AMHG GET CASE DATES"
      m.field 0, :ien
      m.field 1, :sort_date          # internal FileMan (AMHCO)
      m.field 2, :open_date          # $$LVDT of the same
      m.field 3, :admit_date         # $$LVDT of .04
      m.field 4, :closed_date        # $$LVDT of .05
      m.field 5, :disposition_raw    # IEN~name — AMHGD.m:144
      m.field 6, :program_raw        # IEN~name — AMHGD.m:147
      m.field 7, :provider_raw       # IEN~name — AMHGD.m:150
    end

    # CM^AMHGDCM (AMHGDCM.m:10). One param: the case IEN. Always exactly
    # one row — there is no existence guard (AMHGDCM.m:38-40).
    #
    # Header at AMHGDCM.m:18 declares 10 columns; the row at :39 emits 10.
    #
    # Three columns carry an "IEN~external" pair (R="~", AMHGDCM.m:13):
    # Disposition (AMHDSPS), Provider (AMHPRVS), Problem (AMHPRBS).
    # Problem's external half is field .02 of file 9002012.2
    # (AMHGDCM.m:34), not the .09 external from the case file.
    #
    # Program is a dead-pair trap: AMHPRGS is built at AMHGDCM.m:28 and
    # the row emits $G(AMHPRG) — external only.
    #
    # CaseOpen / CaseAdmit / CaseClosed / NextReview are INTERNAL FileMan
    # dates (AMHGDCM.m:20-22, :36). CML sends $$LVDT of the same three
    # date fields. Same record, two formats.
    #
    # Comment is GET1^DIQ of field 1101 (AMHGDCM.m:37), last column, no
    # $TR. A caret in the comment truncates the value.
    DataMapper.define(:amhg_case_management) do |m|
      m.rpc "AMHG GET CASE MANAGEMENT"
      m.field 0, :ien
      m.field 1, :case_open          # internal FileMan — AMHGDCM.m:20
      m.field 2, :case_admit         # internal FileMan — AMHGDCM.m:21
      m.field 3, :case_closed        # internal FileMan — AMHGDCM.m:22
      m.field 4, :disposition_raw
      m.field 5, :program            # external only — AMHPRGS discarded
      m.field 6, :provider_raw
      m.field 7, :problem_raw        # 9002012.2 IEN ~ .02
      m.field 8, :next_review        # internal FileMan — AMHGDCM.m:36
      m.field 9, :comment            # GET1 of 1101 — caret-unsafe
    end

    # COML^AMHGDA (AMHGDA.m:51). One param: "begin|end|provider". The
    # third piece is a PROVIDER IEN that the live filter no longer
    # consults — the site-file / $$PRV / field-.19 checks at
    # AMHGDA.m:70-76 are commented out, as is `Q:'$G(AMHPRVM)` at :76.
    # AMHP is assigned at :61 and then unused. The loop walks
    # ^AMHREC("AB") (AMHGDA.m:66), not a patient or provider index, and
    # keeps only records whose patient piece (0;8) is empty (:75).
    #
    # Inverse-date constants (AMHGDA.m:62-63):
    #   AMHIVB = (9999999-AMHB)+.0001
    #   AMHIVE = (9999999-AMHE)-.9999
    # Same pair as CML^AMHGD (AMHGD.m:133-134). Opposite of GROUPL in
    # this same routine (AMHGDA.m:107-108). CML and COML agree.
    #
    # Rows are screened per-user by $$ALLOWVI^AMHUTIL(DUZ,AMHIEN)
    # (AMHGDA.m:74). An absent activity is not evidence it does not exist.
    # AMHTYP is computed at :65 (ADMINISTRATIVE set) and the filter that
    # would use it is commented out at :77.
    #
    # Header at AMHGDA.m:58 declares 9 columns; the row at :92 emits 9.
    # No pairs — R is never set in this entry (AMHGDA.m:54). Provider,
    # ActivityCode, POV and Location are external-only.
    # POV is the FIRST AMHRPRO entry only (AMHGDA.m:83-85).
    # SortDate is the date-only piece of .01 (AMHGDA.m:80).
    #
    # BMXIEN is AMHIEN, the AMHREC IEN — addressable.
    DataMapper.define(:amhg_community_activities) do |m|
      m.rpc "AMHG GET COMMUNITY ACTIVITIES"
      m.field 0, :ien
      m.field 1, :sort_date          # date-only of .01 — AMHGDA.m:80
      m.field 2, :date               # $$LVDT of the same
      m.field 3, :provider           # external only
      m.field 4, :time
      m.field 5, :activity_code      # .02 of 9002012, not a pair
      m.field 6, :pov                # first POV only — AMHGDA.m:83
      m.field 7, :provider_narrative
      m.field 8, :location
    end

    # COM^AMHGDCOM (AMHGDCOM.m:11). One param: the AMHREC IEN. Always
    # exactly one row — there is no existence guard (AMHGDCOM.m:58-60).
    #
    # The header is built across TWO SETs (AMHGDCOM.m:18-19): 13 columns,
    # then "^T00010Flag^T00050Clinic". Fifteen columns, not the 13 a
    # single-line read shows. The row at :59 emits 15.
    #
    # Seven columns carry an "IEN~external" pair (R="~", AMHGDCOM.m:14):
    # provider, type_of_contact, location, community_of_service,
    # activity, local_service_site, clinic. Program is external-only.
    #
    # start_time is permanently blank: AMHGDCOM.m:37 assigns AMHST=""
    # with the $P(...,"@",2) extract commented out. AMHARR is computed
    # at :38 from $$LVDT of an already-VCDT'd AMHDT and never emitted.
    #
    # AMHPOVS (first-POV pair) and AMHPRVN (provider narrative) are
    # computed at :32-33 and never appended — dead pair / dead column.
    #
    # Date is $$VCDT^AMHGU (AMHGDCOM.m:23-24) — "YR,MO,DY,HR,MN" — not
    # the $$LVDT display COML sends for the same field.
    DataMapper.define(:amhg_community_activity) do |m|
      m.rpc "AMHG GET COMMUNITY ACTIVITY"
      m.field 0,  :ien
      m.field 1,  :provider_raw
      m.field 2,  :program            # external only
      m.field 3,  :type_of_contact_raw
      m.field 4,  :start_time         # always "" — AMHGDCOM.m:37
      m.field 5,  :time
      m.field 6,  :number_served
      m.field 7,  :target
      m.field 8,  :date               # $$VCDT, not $$LVDT
      m.field 9,  :location_raw
      m.field 10, :community_of_service_raw
      m.field 11, :activity_raw
      m.field 12, :local_service_site_raw
      m.field 13, :flag
      m.field 14, :clinic_raw
    end
  end
end
