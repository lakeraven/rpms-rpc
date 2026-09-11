# frozen_string_literal: true

require_relative "../data_mapper"

module RpmsRpc
  module Mappings
    # CLN^AMHGTVF (AMHGTVF.m:15). The body is a bare Q. No AMHSTR formal,
    # no RETVAL assignment, no typed header, no rows, no $C(31). The
    # #8994 registry lists RETVAL only. This is not a late-built header
    # and not a plain list — the broker receives an empty GLOBAL ARRAY.
    # PRV/TOC/LOC/COM in the same routine are the same stub
    # (AMHGTVF.m:9-22). Sending an input actual is ACTLSTTOOLONG.
    #
    # No fields: there is nothing on the wire to map.
    DataMapper.define(:amhg_clinics) do |m|
      m.rpc "AMHG GET CLINICS"
    end

    # GETPAT^AMHGP (AMHGP.m:7). One param: "duz2|query|max|after_name".
    # Empty max becomes (""-1)=-1 and PATADO emits zero rows
    # (AMHGP.m:22-23) — callers must send ALL or a positive count.
    # Lookup dispatch (AMHGP.m:24-31): 9N SSN, 1.7N chart, n/n/yyyy DOB,
    # else name. Rows are screened by $$GUIPL^AMHUTIL (AMHGP.m:107);
    # an absent patient is not evidence the patient does not exist.
    #
    # Header at AMHGP.m:15 declares 13 columns; the row at :143 emits 13.
    # No pairs. IEN is the DFN.
    #
    # SSN is computed as XXX-XX-last4 then blanked unconditionally
    # (AMHGP.m:134); a later sensitive-patient branch may overwrite it
    # with **SENSITIVE** (:135). REG emits $G(AMHHD) and MORE emits
    # $G(AMHMORE) — both never assigned. AMHUPD (last reg update) is
    # computed at :136 and never emitted. AMHNM from DPT .01 at :122-123
    # is overwritten by $$GETPREF^AUPNSOGI at :124. $$PRF^AMHGUVF
    # returns 0/1; the narrative is discarded (AMHGUVF.m:21).
    DataMapper.define(:amhg_patient) do |m|
      m.rpc "AMHG GET PATIENT"
      m.field 0,  :ien               # DFN
      m.field 1,  :name              # preferred name — AMHGP.m:124
      m.field 2,  :dob               # $$LVDT, or **SENSITIVE**
      m.field 3,  :sex               # internal
      m.field 4,  :chart
      m.field 5,  :ssn               # "" or **SENSITIVE** — AMHGP.m:134
      m.field 6,  :reg               # always "" — AMHHD never assigned
      m.field 7,  :more              # always "" — AMHMORE never assigned
      m.field 8,  :date_of_death
      m.field 9,  :age               # or **SENSITIVE** when any AMHFLAG
      m.field 10, :message_flag
      m.field 11, :message
      m.field 12, :prf               # 0/1, not the narrative
    end

    # SITE^AMHGU (AMHGU.m:220). One param: the site IEN (file 9002013).
    # Always exactly one row — there is no existence guard (AMHGU.m:287-289).
    #
    # The header is built across TWO SETs (AMHGU.m:228-229): 13 columns,
    # then "^T00030DefCDComm^...^T00001DeleteOverride". Twenty-three
    # columns, not the 13 a single-line read (or the contracts scan) shows.
    # The row at :288-289 emits 23.
    #
    # Sixteen columns carry an "IEN~external" pair (R="~", AMHGU.m:223):
    # type_of_visit, type_of_hs, the four MH/SS/CD/Oth location-community-
    # clinic triples, type_of_contact, and default_ehr_community.
    # AskInterpreter / AllowPCCPrbUp are GET1 "I" (AMHGU.m:248, :252).
    # InteractivePCCLink is forced "1"/"0" (AMHGU.m:283). DefAppt is
    # external-only (AMHGU.m:284). Lockout falls through site 1809, user
    # 200.1, kernel 8989.3/210, else 300 (AMHGU.m:285). DeleteOverride
    # is 1 when DUZ is in the 21-multiple (AMHGU.m:286).
    DataMapper.define(:amhg_site_parameters) do |m|
      m.rpc "AMHG GET SITE PARAMETERS"
      m.field 0,  :ien
      m.field 1,  :type_of_visit_raw
      m.field 2,  :type_of_hs_raw
      m.field 3,  :default_mh_location_raw
      m.field 4,  :default_mh_community_raw
      m.field 5,  :default_mh_clinic_raw
      m.field 6,  :default_type_of_contact_raw
      m.field 7,  :ask_interpreter
      m.field 8,  :allow_pcc_problem_update
      m.field 9,  :default_ss_location_raw
      m.field 10, :default_ss_community_raw
      m.field 11, :default_ss_clinic_raw
      m.field 12, :default_cd_location_raw
      m.field 13, :default_cd_community_raw
      m.field 14, :default_cd_clinic_raw
      m.field 15, :default_oth_location_raw
      m.field 16, :default_oth_community_raw
      m.field 17, :default_oth_clinic_raw
      m.field 18, :default_ehr_community_raw
      m.field 19, :interactive_pcc_link
      m.field 20, :default_appointment
      m.field 21, :lockout
      m.field 22, :delete_override
    end

    # ADML^AMHGDA (AMHGDA.m:8). One param: "begin|end|provider". The third
    # piece is a PROVIDER IEN used for visibility (AMHGDA.m:18, :28-32),
    # not a patient DFN — the loop walks ^AMHREC("AB") (AMHGDA.m:23).
    # Only records whose .07 is ADMINISTRATIVE are emitted (AMHGDA.m:22, :27).
    #
    # Inverse-date constants (AMHGDA.m:19-20):
    #   AMHIVB = (9999999-AMHB)+.0001
    #   AMHIVE = (9999999-AMHE)-.9999
    # Same pair as TPL (AMHGD.m:167-168), SFL, INTAKEL (AMHGDA.m:152-153),
    # and COML (AMHGDA.m:62-63). Opposite of GROUPL (AMHGDA.m:107-108)
    # and VISITL (AMHGD.m:22-23), which use +.9999 / -.0001. The same
    # from/to does not select equivalently across those lists.
    #
    # Rows are screened by site-file 16, $$PRV^AMHGU, or field .19
    # (AMHGDA.m:28-32). The .19 path compares GET1 without "I" (external
    # name) to AMHP (an IEN) and is effectively dead. An absent row is
    # not evidence the record does not exist — it may be typed out or
    # screened.
    #
    # Header at AMHGDA.m:15 declares 10 columns; the row at :47 emits 10.
    # No pairs. BMXIEN is AMHIEN — the 9002011 record IEN, so a row CAN
    # be addressed. POV is the first ^AMHRPRO("AD") hit only (AMHGDA.m:38).
    DataMapper.define(:amhg_admin_records) do |m|
      m.rpc "AMHG GET ADMIN RECORDS"
      m.field 0, :ien                # 9002011 IEN
      m.field 1, :sort_date          # internal FileMan (AMHDT)
      m.field 2, :date               # $$LVDT^AMHGU of the same
      m.field 3, :program            # external only
      m.field 4, :activity_code      # file 9002012 .02, not a pair
      m.field 5, :pov                # first POV only — AMHGDA.m:38
      m.field 6, :time
      m.field 7, :provider           # external only
      m.field 8, :provider_narrative
      m.field 9, :location
    end
  end
end
