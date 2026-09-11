# frozen_string_literal: true

require_relative "../../mappings/amhg_groups"
require_relative "wire"

module RpmsRpc
  module BehavioralHealth
    module Groups
      extend self
      extend Wire

      # Group encounters visible to `provider` over a FileMan date range,
      # newest first.
      #
      # The third pipe piece is a PROVIDER IEN, not a patient DFN
      # (AMHGDA.m:106, :115-119). Rows are screened by
      # $$ALLOWV^AMHUTIL(DUZ, location) (AMHGDA.m:114) and by whether
      # `provider` is privileged at the site, on the encounter, or is
      # field .12. An empty result means "none visible to this user in
      # this range", never "no groups exist".
      #
      # Inverse dates: AMHIVB=(9999999-AMHB)+.9999,
      # AMHIVE=(9999999-AMHE)-.0001 (AMHGDA.m:107-108). Same as VISITL,
      # opposite of TPL/SFL/INTAKEL — one from/to does not select
      # equivalently across those lists.
      #
      # :pov is the first 21-multiple entry only (AMHGDA.m:130). :signed
      # is inverted — "*" means NOT signed (AMHGDA.m:133).
      def groups(provider, from:, to:)
        rows(:amhg_group_list, from, to, provider).map do |row|
          {
            ien: row[:ien],
            sort_date:     presence(row[:sort_date]),
            date:          presence(row[:date]),
            group_name:    presence(row[:group_name]),
            activity_code: presence(row[:activity_code]),
            program:       presence(row[:program]),
            clinic:        presence(row[:clinic]),
            provider:      presence(row[:provider]),
            contact_type:  presence(row[:contact_type]),
            pov:           presence(row[:pov]),
            signed:        row[:signed_marker].to_s.strip != "*",
            location:      presence(row[:location])
          }
        end
      end

      # Detail for one group encounter, or nil when the IEN yields no row.
      # Live ENC^AMHGDGP always emits exactly one row (AMHGDGP.m:54-55).
      #
      # arrival_time is permanently blank (AMHGDGP.m:43). EncounterDate is
      # $$VCDT, not the $$LVDT the list sends for the same field.
      def group_information(group_ien)
        row = first_row(:amhg_group_information, group_ien)
        return nil if row.nil?

        {
          ien: row[:ien],
          primary_provider:     split_ien_name(row[:primary_provider_raw]),
          program:              presence(row[:program]),
          group_name:           presence(row[:group_name]),
          clinic:               split_ien_name(row[:clinic_raw]),
          type_of_contact:      split_ien_name(row[:type_of_contact_raw]),
          encounter_location:   split_ien_name(row[:encounter_location_raw]),
          encounter_date:       presence(row[:encounter_date]),
          # AMHGDGP.m:43 blanks this unconditionally. nil, not "", so a
          # caller cannot mistake a dead column for an observed empty value.
          arrival_time:         nil,
          community_of_service: split_ien_name(row[:community_of_service_raw]),
          activity:             split_ien_name(row[:activity_raw]),
          activity_time:        presence(row[:activity_time]),
          chief_complaint:      presence(row[:chief_complaint])
        }
      end

      # Patients on a group. BMXIEN is the group IEN repeated; :patient_ien
      # is the DFN; :visit_ien is the linked AMHREC. The 51-multiple IEN is
      # never emitted (AMHGDGP.m:206), so a row cannot be addressed for edit.
      def group_patients(group_ien)
        rows(:amhg_group_patients, group_ien).map do |row|
          {
            group_ien:     row[:group_ien],
            patient_ien:   presence(row[:patient_ien]),
            visit_ien:     presence(row[:visit_ien]),
            name:          presence(row[:name]),
            sex:           presence(row[:sex]),
            age:           presence(row[:age]),
            dob:           presence(row[:dob]),
            chart:         presence(row[:chart]),
            date_of_death: presence(row[:date_of_death])
          }
        end
      end

      # CPT codes on a group. :code_pointer is a file-81 IEN, not a record
      # address — AMHDA is never emitted (AMHGDGP.m:117). When `dupe` is
      # set, CPT^AMHUTIL1 may drop a row (AMHGDGP.m:120).
      def group_cpt(group_ien, dupe: nil, date: nil)
        rows(:amhg_group_cpt, *optional_tail(group_ien, dupe:, date:)).map do |row|
          {
            code_pointer: presence(row[:code_pointer]),
            code:         presence(row[:code]),
            narrative:    presence(row[:narrative]),
            quantity:     presence(row[:quantity]),
            mod1_ien:     presence(row[:mod1_ien]),
            mod1:         presence(row[:mod1]),
            mod2_ien:     presence(row[:mod2_ien]),
            mod2:         presence(row[:mod2])
          }
        end
      end

      # Education topics on a group. :ien is the 71-multiple IEN (AMHDA) —
      # the one group-tab list whose first column is addressable.
      #
      # :provider is IEN-name joined with a hyphen (AMHGDGP.m:179), not
      # R="~". :comment is a raw global node (AMHGDGP.m:173); a caret in
      # the comment shifts the columns after it.
      def group_edu(group_ien)
        rows(:amhg_group_edu, group_ien).map do |row|
          {
            ien:                    row[:ien],
            topic:                  presence(row[:topic]),
            time_spent:             presence(row[:time_spent]),
            level_of_understanding: presence(row[:level_of_understanding]),
            comment:                presence(row[:comment]),
            cpt:                    presence(row[:cpt]),
            status:                 presence(row[:status]),
            goal:                   presence(row[:goal]),
            provider:               split_hyphen_ien_name(row[:provider_raw])
          }
        end
      end

      # POVs on a group. :code_pointer is a 9002012.2 pointer, not a record
      # address — AMHDA is never emitted (AMHGDGP.m:72). When `dupe` is set,
      # $$CHKD^AMHUTIL1 may drop a row (AMHGDGP.m:75).
      def group_pov(group_ien, dupe: nil, date: nil)
        rows(:amhg_group_pov, *optional_tail(group_ien, dupe:, date:)).map do |row|
          {
            code_pointer: presence(row[:code_pointer]),
            code:         presence(row[:code]),
            narrative:    presence(row[:narrative])
          }
        end
      end

      # SOAP text. Raw nodes, no caret sanitisation (AMHGDGP.m:97). No TIU
      # early-return (unlike SOAP^AMHGDVF). Read as whole lines.
      def group_soap(group_ien)
        text_lines(:amhg_group_soap, group_ien)
      end

      # Secondary providers. Primaries are filtered out (AMHGDGP.m:147).
      # :provider_ien is a file-200 pointer; the 11-multiple IEN is never
      # emitted (AMHGDGP.m:145).
      def group_secondary_providers(group_ien)
        rows(:amhg_group_secondary_providers, group_ien).map do |row|
          {
            provider_ien: presence(row[:provider_ien]),
            name:         presence(row[:name])
          }
        end
      end

      private

      def optional_tail(ien, dupe:, date:)
        return [ ien ] if dupe.nil? && date.nil?

        [ ien, dupe, date ]
      end

      # EDU joins provider as IEN-name with a hyphen (AMHGDGP.m:179), not
      # the AMHG-wide R="~". Split on the first "-" so "LAST-HYPHEN,FIRST"
      # stays in the name.
      def split_hyphen_ien_name(raw)
        value = raw.to_s
        return nil if value.empty?

        ien, name = value.split("-", 2)
        return { ien: nil, name: ien } if name.nil?

        { ien: presence(ien), name: presence(name) }
      end
    end
  end
end
