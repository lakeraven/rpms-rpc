# frozen_string_literal: true

require_relative "../../mappings/amhg_reference"
require_relative "wire"
require_relative "../../shape"

module RpmsRpc
  module BehavioralHealth
    module Reference
      extend self
      extend Wire
      extend Shape::Declarable

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
        mapping.parse_many(frame_rows(call_amhg(mapping)))
      end
      shape :clinics, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/clinics"

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
      shape :patients, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/patients"

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
      shape :site_parameters, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/sites/{site_ien}/parameters"

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
      shape :admin_records, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/admin-records"
      # The health summary type names the BH GUI offers (HS^AMHGT).
      def health_summary_types
        rows(:amhg_health_summary_types).filter_map { |row| presence(row[:name]) }
      end
      shape :health_summary_types, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/health-summary-types"

      # The MHSS ACTIVITY CODE (#9002012.4) with this code (ACTCODE^AMHGUA):
      # { ien:, name:, code: }, or nil when no activity has it.
      def activity_code(code)
        value = first_row(:amhg_activity_code, code)&.dig(:value).to_s
        return nil if value.empty?

        ien, name, found = value.split(Wire::IEN_NAME_SEPARATOR, -1)
        { ien: presence(ien), name: presence(name), code: presence(found) }
      end
      shape :activity_code, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/activity-code"

      # Whether a visit with this activity (its #9002012.4 IEN) passes to PCC
      # (ACT^AMHGPCC): true when the activity's .04 is set.
      def activity_passes_to_pcc?(activity_ien)
        presence(first_row(:amhg_activity_pcc_check, activity_ien)&.dig(:error)).nil?
      end
      shape :activity_passes_to_pcc?, resource: "behavioral-health", verb: "GET",
                                      path: "/behavioral-health/activities/{activity_ien}/passes-to-pcc"

      # The package's answer to "does this client version match" (VC^AMHGUA).
      # Stock answers true whatever version is sent: the routine's
      # mismatch branch still writes 1, as its own comment says, for testing.
      def version_current?(version)
        flag?(first_row(:amhg_version_check, version)&.dig(:present))
      end
      shape :version_current?, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/version-current"

      # The signed-on user's security keys in a namespace (KEYS^AMHGU).
      def keys(namespace = "AMH")
        rows(:amhg_keys, namespace).filter_map { |row| presence(row[:key]) }
      end
      shape :keys, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/keys"

      # A user's timeout in seconds (TIME^AMHGUA): the user's own (#200
      # 200.1), else the kernel's (#8989.3 210). nil when neither is set.
      def timeout(user_ien, division: nil)
        value = first_row(:amhg_timeout, user_ien, division)&.dig(:seconds).to_s
        value.match?(/\A\d+\z/) ? Integer(value) : nil
      end
      shape :timeout, resource: "behavioral-health", verb: "GET", path: "/users/{user_ien}/behavioral-health/timeout"

      # The help a measurement type's entry shows (HELP^AMHGMSR), as lines.
      def measurement_help(type_code)
        rows(:amhg_measurement_help, type_code).map { |row| row[:line].to_s.rstrip }
      end
      shape :measurement_help, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/measurement-help"

      # Whether a value passes the measurement type's input transform
      # (VAL^AMHGMSR): { valid: true } when it does, { valid: false, help: }
      # with the type's help lines when it does not.
      def measurement_validation(type_code, value)
        lines = rows(:amhg_measurement_validation, type_code, value).map { |row| row[:line].to_s.rstrip }.reject(&:empty?)
        lines.empty? ? { valid: true } : { valid: false, help: lines }
      end
      shape :measurement_validation, resource: "behavioral-health", verb: "GET",
                                   path: "/behavioral-health/measurement-validation"

      # Whether an MHSS PROBLEM/POV (#9002012.2) passes to PCC: true when the
      # entry names the code PCC files (VALIDBH^AMHGBPL, its .05).
      def pov_passes_to_pcc?(pov_ien)
        flag?(first_row(:amhg_pov_pcc_check, pov_ien)&.dig(:valid))
      end
      shape :pov_passes_to_pcc?, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/povs/{pov_ien}/passes-to-pcc"

      # Whether another session holds the lock on a FileMan entry
      # (LOCK^AMHGUA: an incremental lock with a 1-second timeout, released
      # at once when it is got). The BH GUI asks before it opens a record.
      def locked?(file, ien)
        flag?(first_row(:amhg_lock_check, file, ien)&.dig(:locked))
      end
      shape :locked?, resource: "behavioral-health", verb: "POST", path: "/behavioral-health/files/{file}/{ien}/locked"

      # A set-of-codes field's external values, in the DD's order (SC^AMHGT).
      def field_codes(file, field)
        rows(:amhg_field_codes, file, field).filter_map { |row| presence(row[:value]) }
      end
      shape :field_codes, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/files/{file}/field-codes"
    end
  end
end
