# frozen_string_literal: true

require_relative "../../mappings/amhg_case_management"
require_relative "wire"

module RpmsRpc
  module BehavioralHealth
    module CaseManagement
      extend self
      extend Wire

      # Case-status records for a patient over a FileMan date range,
      # newest first.
      #
      # The third pipe piece is a patient DFN, not a provider
      # (AMHGD.m:132, :135). Rows are screened by
      # $$ALLOWCD^AMHLCD(DUZ,AMHIEN) (AMHGD.m:138). An empty result means
      # "none visible to this user in this range", never "no cases exist".
      #
      # Inverse dates: AMHIVB=(9999999-AMHB)+.0001,
      # AMHIVE=(9999999-AMHE)-.9999 (AMHGD.m:133-134). Same pair as
      # COML^AMHGDA (AMHGDA.m:62-63). Opposite of VISITL/GROUPL — one
      # from/to does not select equivalently across those lists, but CML
      # and COML agree with each other.
      #
      # :disposition, :program and :provider are IEN~name pairs
      # (AMHGD.m:144, :147, :150). Open/Admit/Closed are $$LVDT; the
      # matching CM^AMHGDCM columns are internal FileMan dates.
      def case_dates(dfn, from:, to:)
        rows(:amhg_case_dates, from, to, dfn).map do |row|
          {
            ien: row[:ien],
            sort_date:    presence(row[:sort_date]),
            open_date:    presence(row[:open_date]),
            admit_date:   presence(row[:admit_date]),
            closed_date:  presence(row[:closed_date]),
            disposition:  split_ien_name(row[:disposition_raw]),
            program:      split_ien_name(row[:program_raw]),
            provider:     split_ien_name(row[:provider_raw])
          }
        end
      end

      # Detail for one case-status record, or nil when the IEN yields no
      # row. Live CM^AMHGDCM always emits exactly one row (AMHGDCM.m:38-40).
      #
      # :program is external-only — AMHPRGS is computed at AMHGDCM.m:28
      # and discarded. :case_open / :case_admit / :case_closed /
      # :next_review are internal FileMan dates, not the $$LVDT CML
      # sends for the same fields. :problem is IEN ~ file-9002012.2 .02
      # (AMHGDCM.m:34), not the case-file .09 external.
      #
      # :comment is GET1^DIQ of 1101 (AMHGDCM.m:37); a caret truncates it.
      def case_management(case_ien)
        row = first_row(:amhg_case_management, case_ien)
        return nil if row.nil?

        {
          ien: row[:ien],
          case_open:    presence(row[:case_open]),
          case_admit:   presence(row[:case_admit]),
          case_closed:  presence(row[:case_closed]),
          disposition:  split_ien_name(row[:disposition_raw]),
          program:      presence(row[:program]),
          provider:     split_ien_name(row[:provider_raw]),
          problem:      split_ien_name(row[:problem_raw]),
          next_review:  presence(row[:next_review]),
          comment:      presence(row[:comment])
        }
      end

      # Community (no-patient) visits visible to `provider`'s DUZ over a
      # FileMan date range, newest first.
      #
      # The third pipe piece is a PROVIDER IEN, but the live filter that
      # would use it is commented out (AMHGDA.m:70-76). The loop walks
      # ^AMHREC("AB") and keeps records whose patient piece is empty
      # (AMHGDA.m:66, :75). We still send the provider so the outgoing
      # call matches the Delphi shape; it does not narrow the result.
      #
      # Rows are screened by $$ALLOWVI^AMHUTIL(DUZ,AMHIEN) (AMHGDA.m:74).
      # An empty result means "none visible to this user in this range",
      # never "no community activities exist".
      #
      # Inverse dates: AMHIVB=(9999999-AMHB)+.0001,
      # AMHIVE=(9999999-AMHE)-.9999 (AMHGDA.m:62-63). Same pair as CML.
      #
      # :pov is the first AMHRPRO entry only (AMHGDA.m:83). No pair
      # columns — R is never set (AMHGDA.m:54).
      def community_activities(provider, from:, to:)
        rows(:amhg_community_activities, from, to, provider).map do |row|
          {
            ien: row[:ien],
            sort_date:           presence(row[:sort_date]),
            date:                presence(row[:date]),
            provider:            presence(row[:provider]),
            time:                presence(row[:time]),
            activity_code:       presence(row[:activity_code]),
            pov:                 presence(row[:pov]),
            provider_narrative:  presence(row[:provider_narrative]),
            location:            presence(row[:location])
          }
        end
      end

      # Detail for one community activity, or nil when the IEN yields no
      # row. Live COM^AMHGDCOM always emits exactly one row
      # (AMHGDCOM.m:58-60).
      #
      # start_time is permanently blank (AMHGDCOM.m:37). Date is $$VCDT,
      # not the $$LVDT the list sends for the same field. AMHPOVS and
      # AMHPRVN are computed and never emitted (AMHGDCOM.m:32-33).
      def community_activity(activity_ien)
        row = first_row(:amhg_community_activity, activity_ien)
        return nil if row.nil?

        {
          ien: row[:ien],
          provider:              split_ien_name(row[:provider_raw]),
          program:               presence(row[:program]),
          type_of_contact:       split_ien_name(row[:type_of_contact_raw]),
          # AMHGDCOM.m:37 blanks this unconditionally. nil, not "", so a
          # caller cannot mistake a dead column for an observed empty value.
          start_time:            nil,
          time:                  presence(row[:time]),
          number_served:         presence(row[:number_served]),
          target:                presence(row[:target]),
          date:                  presence(row[:date]),
          location:              split_ien_name(row[:location_raw]),
          community_of_service:  split_ien_name(row[:community_of_service_raw]),
          activity:              split_ien_name(row[:activity_raw]),
          local_service_site:    split_ien_name(row[:local_service_site_raw]),
          flag:                  presence(row[:flag]),
          clinic:                split_ien_name(row[:clinic_raw])
        }
      end
    end
  end
end
