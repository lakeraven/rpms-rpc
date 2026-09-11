# frozen_string_literal: true

require_relative "../../mappings/amhg_intake"
require_relative "wire"

module RpmsRpc
  module BehavioralHealth
    module Intake
      extend self
      extend Wire

      # Intakes for a patient over a FileMan date range, newest first.
      #
      # The third pipe piece is a PATIENT DFN (AMHGDA.m:151, :154), not a
      # provider IEN. INTAKEL walks ^AMHRINTK("AE",AMHP,...) — same
      # AE-by-patient shape as VISITL. There is no $$ALLOWINT screen
      # (unlike INT^AMHGDINT). Initials and updates both appear as flat
      # rows; there is no type filter.
      #
      # Inverse dates: AMHIVB=(9999999-AMHB)+.0001,
      # AMHIVE=(9999999-AMHE)-.9999 (AMHGDA.m:152-153). Same as TPL/SFL,
      # opposite of VISITL/GROUPL — one from/to does not select
      # equivalently across those lists.
      #
      # :program is the VISIT's .02 (AMHGDA.m:161), not the intake's .05.
      # :initial_provider is intake .04; :primary_provider is the visit
      # primary. BMXIEN is the intake IEN.
      def intakes(dfn, from:, to:)
        rows(:amhg_intake_list, from, to, dfn).map do |row|
          {
            ien: row[:ien],
            sort_date:         presence(row[:sort_date]),
            date:              presence(row[:date]),
            program:           presence(row[:program]),
            initial_provider:  presence(row[:initial_provider]),
            visit_ien:         presence(row[:visit_ien]),
            visit_date:        presence(row[:visit_date]),
            primary_provider:  presence(row[:primary_provider])
          }
        end
      end

      # Intake documents (initial + nested updates) visible to this DUZ
      # for a patient, program, and FileMan date range.
      #
      # The first pipe piece is a PATIENT DFN, not an intake IEN
      # (AMHGDINT.m:14). ASSESS^AMHGDINT in the same routine is the one
      # that takes an intake IEN despite the GET VISIT ASSESSMENT name.
      # Argument order is dfn|program|from|to — the reverse of INTAKEL.
      #
      # Dates are DIRECT FileMan compares (AMHGDINT.m:34-35), not inverse,
      # and apply to the INITIAL's .01 only. Updates of a passing parent
      # are appended even when the update date is outside the range.
      #
      # Rows are screened by $$ALLOWINT^AMHLEIV(DUZ,AMHXI)
      # (AMHGDINT.m:30). An empty result means "none visible to this user
      # in this range", never "no intake documents exist".
      #
      # :type is :initial / :update from the wire's "I"/"U". :signed is
      # true when the column is "Y" (AMHGDINT.m:52) — not the inverted
      # "*" VISITL uses, and not flag? (which treats "N" as true).
      # :entered_by_ien is the header's "UpdIen" — field .13, the
      # entering user, not an update-record IEN. :last_update_date is
      # internal FileMan (.07 "I"); :date_initial / :date_update are
      # $$LVDT display.
      def intake_documents(dfn, program:, from:, to:)
        rows(:amhg_intake_documents, dfn, program, from, to).map do |row|
          {
            ien: row[:ien],
            type:                 document_type(row[:type]),
            visit_ien:            presence(row[:visit_ien]),
            date_initial:         presence(row[:date_initial]),
            program:              presence(row[:program]),
            provider:             document_provider(row),
            date_update:          presence(row[:date_update]),
            signed:               row[:signed_flag].to_s == "Y",
            entered_by_ien:       presence(row[:entered_by_ien]),
            initial_intake_ien:   presence(row[:initial_intake_ien]),
            update_program:       presence(row[:update_program]),
            last_update_user_ien: presence(row[:last_update_user_ien]),
            last_update_date:     presence(row[:last_update_date])
          }
        end
      end

      private

      def document_type(raw)
        case raw.to_s
        when "I" then :initial
        when "U" then :update
        else presence(raw)
        end
      end

      # IPIen (.04 "I") plus whichever name column this row filled.
      # Initials emit ProviderInitial; updates emit ProviderUpdate
      # (AMHGDINT.m:55, :71). R="~" is unused — join here.
      def document_provider(row)
        name = presence(row[:provider_initial]) || presence(row[:provider_update])
        ien  = presence(row[:provider_ien])
        return nil if ien.nil? && name.nil?

        { ien: ien, name: name }
      end
    end
  end
end
