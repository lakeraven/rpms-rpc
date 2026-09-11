# frozen_string_literal: true

require_relative "../../mappings/amhg_reference"
require_relative "wire"

module RpmsRpc
  module BehavioralHealth
    module Reference
      extend self
      extend Wire

      # Clinic table. Always [].
      #
      # CLN^AMHGTVF (AMHGTVF.m:15-16) is a stub: it Q's without assigning
      # RETVAL, without a typed header, without rows, without $C(31). The
      # #8994 registry lists RETVAL only — this RPC takes no AMHSTR. An
      # input actual is a second actual on a one-formal entry and
      # YottaDB rejects it with YDB-E-ACTLSTTOOLONG (#198).
      #
      # This is not a screened-empty list. The routine never looks at a
      # clinic file. PRV/TOC/LOC/COM in the same routine are the same
      # stub (AMHGTVF.m:9-22).
      def clinics
        mapping = DataMapper[:amhg_clinics]
        mapping.parse_many(call_amhg(mapping))
      end

      # Patient lookup. `query` is SSN (9N), chart (1-7N), DOB (n/n/yyyy),
      # or a name prefix (AMHGP.m:24-31).
      #
      # Rows are screened by $$GUIPL^AMHUTIL(dfn,DUZ,facility)
      # (AMHGP.m:107). An empty result means "none visible to this user",
      # never "this patient does not exist".
      #
      # `max` defaults to ALL because an empty third pipe piece becomes
      # -1 and PATADO emits zero rows (AMHGP.m:22-23). `after_name` is
      # the PATNAM resume point (AMHGP.m:75).
      #
      # :ssn is "" on the wire unless the sensitive-patient branch wrote
      # **SENSITIVE** (AMHGP.m:134-135). :reg and :more are dead columns.
      # :prf is 0/1, not the flag narrative.
      def patients(query, facility: nil, max: "ALL", after_name: nil)
        pieces = [ facility, query, max ]
        pieces << after_name unless after_name.nil?

        rows(:amhg_patient, *pieces).map do |row|
          {
            ien: row[:ien],
            name:          presence(row[:name]),
            dob:           presence(row[:dob]),
            sex:           presence(row[:sex]),
            chart:         presence(row[:chart]),
            ssn:           presence(row[:ssn]),
            reg:           presence(row[:reg]),
            more:          presence(row[:more]),
            date_of_death: presence(row[:date_of_death]),
            age:           presence(row[:age]),
            message_flag:  presence(row[:message_flag]),
            message:       presence(row[:message]),
            prf:           flag?(row[:prf])
          }
        end
      end

      # Site parameters for one 9002013 IEN, or nil when the IEN yields
      # no row. Live SITE^AMHGU always emits exactly one row
      # (AMHGU.m:287-289) even when GET1 returns blanks.
      #
      # Sixteen pointer columns are IEN~name pairs. Lockout is the
      # fallback number (site 1809 / user 200.1 / kernel 210 / 300 —
      # AMHGU.m:285), not a pair and not a blanked column.
      def site_parameters(site_ien)
        row = first_row(:amhg_site_parameters, site_ien)
        return nil if row.nil?

        {
          ien: row[:ien],
          type_of_visit:              split_ien_name(row[:type_of_visit_raw]),
          type_of_hs:                 split_ien_name(row[:type_of_hs_raw]),
          default_mh_location:        split_ien_name(row[:default_mh_location_raw]),
          default_mh_community:       split_ien_name(row[:default_mh_community_raw]),
          default_mh_clinic:          split_ien_name(row[:default_mh_clinic_raw]),
          default_type_of_contact:    split_ien_name(row[:default_type_of_contact_raw]),
          ask_interpreter:            flag?(row[:ask_interpreter]),
          allow_pcc_problem_update:   flag?(row[:allow_pcc_problem_update]),
          default_ss_location:        split_ien_name(row[:default_ss_location_raw]),
          default_ss_community:       split_ien_name(row[:default_ss_community_raw]),
          default_ss_clinic:          split_ien_name(row[:default_ss_clinic_raw]),
          default_cd_location:        split_ien_name(row[:default_cd_location_raw]),
          default_cd_community:       split_ien_name(row[:default_cd_community_raw]),
          default_cd_clinic:          split_ien_name(row[:default_cd_clinic_raw]),
          default_oth_location:       split_ien_name(row[:default_oth_location_raw]),
          default_oth_community:      split_ien_name(row[:default_oth_community_raw]),
          default_oth_clinic:         split_ien_name(row[:default_oth_clinic_raw]),
          default_ehr_community:      split_ien_name(row[:default_ehr_community_raw]),
          interactive_pcc_link:       flag?(row[:interactive_pcc_link]),
          default_appointment:        presence(row[:default_appointment]),
          lockout:                    presence(row[:lockout]),
          delete_override:            flag?(row[:delete_override])
        }
      end

      # Administrative records visible to `provider` over a FileMan date
      # range. Only type ADMINISTRATIVE (AMHGDA.m:22, :27).
      #
      # The third pipe piece is a PROVIDER IEN, not a patient DFN
      # (AMHGDA.m:18, :28-32). Rows are screened by site-file 16,
      # $$PRV^AMHGU, or field .19 (the .19 path compares external name
      # to IEN and is dead — AMHGDA.m:31). An empty result means "none
      # visible to this user in this range", never "no admin records
      # exist".
      #
      # Inverse dates: AMHIVB=(9999999-AMHB)+.0001,
      # AMHIVE=(9999999-AMHE)-.9999 (AMHGDA.m:19-20). Same as TPL/SFL/
      # INTAKEL/COML, opposite of GROUPL/VISITL — one from/to does not
      # select equivalently across those lists.
      #
      # :pov is the first ^AMHRPRO("AD") hit only (AMHGDA.m:38). :ien
      # is the 9002011 record IEN.
      def admin_records(provider, from:, to:)
        rows(:amhg_admin_records, from, to, provider).map do |row|
          {
            ien: row[:ien],
            sort_date:           presence(row[:sort_date]),
            date:                presence(row[:date]),
            program:             presence(row[:program]),
            activity_code:       presence(row[:activity_code]),
            pov:                 presence(row[:pov]),
            time:                presence(row[:time]),
            provider:            presence(row[:provider]),
            provider_narrative:  presence(row[:provider_narrative]),
            location:            presence(row[:location])
          }
        end
      end
    end
  end
end
