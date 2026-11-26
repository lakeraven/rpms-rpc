# frozen_string_literal: true

require_relative "../../mappings/amhg_encounters"
require_relative "../../context_scope"
require_relative "wire"
require_relative "../../shape"

module RpmsRpc
  module BehavioralHealth
    # What the Behavioral Health GUI reads around one encounter: the record
    # selector's lists, the record and PCC visit displays, the screenings
    # and wellness rows, the patient's PCC problems and banner, and the
    # checks it makes before it signs a note or links a visit to PCC. All
    # run under AMHGRPC (Wire#call_amhg). Reads only.
    #
    # Values are the strings AMHG sends, nil for a blank column, as the
    # rest of BehavioralHealth answers them; IENs stay strings.
    module Encounters
      extend self
      extend Wire
      extend Shape::Declarable

      # The VueCentric BH component's record display (AMHBH RECORD DISPLAY,
      # RECDISP^AMHBHDSP): two actuals, a GLOBAL ARRAY whose node .5 is the
      # line count.
      RECORD_SUMMARY_RPC = "AMHBH RECORD DISPLAY"
      # The TIU field a BH word-processing field is edited through
      # (TIUF^AMHBHAPI), and the TIU document a record's TIU field points at
      # (TIUIEN^AMHBHAPI). Three actuals each, a single value.
      TIU_FIELD_RPC = "AMHBH TIU FIELD"
      TIU_DOCUMENT_RPC = "AMHBH TIU IEN"
      MHSS_RECORD_FILE = 9_002_011

      # The patient's BH visits from `from` to `to` (FileMan dates), newest
      # first, as the record selector lists them (VISITL^AMHGD). Screened by
      # the user's access to each record: [] means none this user may see.
      def visit_list(dfn, from:, to:)
        rows(:amhg_record_selector_visits, from, to, dfn).map do |row|
          compact(row).except(:unsigned).merge(signed: row[:unsigned].to_s != "*")
        end
      end
      shape :visit_list, resource: "behavioral-health", verb: "GET", path: "/patients/{dfn}/behavioral-health/visit-list"

      # Every patient's BH visits in the range the user may see (VISITAP^AMHGD).
      # :patient is { ien:, name: } from the row's "dfn~name".
      def visits_all_patients(from:, to:)
        rows(:amhg_visits_all_patients, from, to, "").map do |row|
          compact(row).merge(patient: split_ien_name(row[:patient_raw]), signed: row[:unsigned].to_s != "*")
                      .except(:patient_raw, :unsigned)
        end
      end
      shape :visits_all_patients, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/visits-all-patients"

      # Every patient's suicide forms in the range (SFLAP^AMHGD). :complete
      # is false when the form is marked "I" (incomplete).
      def suicide_forms_all_patients(from:, to:)
        rows(:amhg_suicide_forms_all_patients, from, to, "").map do |row|
          compact(row).merge(patient: split_ien_name(row[:patient_raw]), complete: row[:incomplete].to_s != "I")
                      .except(:patient_raw, :incomplete)
        end
      end
      shape :suicide_forms_all_patients, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/suicide-forms-all-patients"

      # The PCC visits a BH record may be linked to (LIST^AMHGPCC): the
      # record's patient's visits on its date at its location.
      def pcc_visit_choices(record_ien)
        rows(:amhg_pcc_visit_choices, record_ien).map { |row| compact(row) }
      end
      shape :pcc_visit_choices, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/records/{record_ien}/pcc-visit-choices"

      # The BH GUI's display of one MHSS record, line by line (BHREC^AMHGR).
      def mhss_record_display(record_ien)
        display_lines(:amhg_record_display, record_ien)
      end
      shape :mhss_record_display, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/mhss-records/{record_ien}/display"

      # The display of one PCC visit, line by line (PCC^AMHGR).
      def pcc_visit_display(visit_ien)
        display_lines(:amhg_pcc_visit_display, visit_ien)
      end
      shape :pcc_visit_display, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/pcc-visits/{visit_ien}/display"

      # VueCentric's display of one MHSS record (AMHBH RECORD DISPLAY), line
      # by line. The reply's first line is the count node RECDISP writes at
      # .5; it is dropped. [] for a record not on file.
      def mhss_record_summary(record_ien)
        lines = amhbh(RECORD_SUMMARY_RPC) { |client| client.call_rpc_lines(RECORD_SUMMARY_RPC, record_ien.to_s) }
        Array(lines).drop(1).map(&:to_s)
      end
      shape :mhss_record_summary, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/mhss-records/{record_ien}/summary"

      # The screenings on the patient's BH visits in the range (HSCR^AMHGDVF3).
      def screening_history(dfn, from:, to:)
        rows(:amhg_screening_history, from, to, dfn).map { |row| compact(row) }
      end
      shape :screening_history, resource: "behavioral-health", verb: "GET", path: "/patients/{dfn}/behavioral-health/screening-history"

      # The wellness tab's BH rows for the range (BHWELL^AMHGDVF1).
      def wellness_activities(dfn, from:, to:)
        rows(:amhg_wellness_activities, from, to, dfn).map { |row| compact(row) }
      end
      shape :wellness_activities, resource: "behavioral-health", verb: "GET", path: "/patients/{dfn}/behavioral-health/wellness-activities"

      # Whether the record's note can be signed now (CHKESIG^AMHGESIG over
      # $$ESIG^AMHESIG). :can_sign is the first piece; :satisfied is true when
      # nothing more is needed (already signed, not required); :message is
      # the package's reason. nil when the reply carries no row.
      def signature_status(record_ien)
        row = first_row(:amhg_signature_status, record_ien)
        return nil if row.nil?

        can, satisfied, message, = row[:value].to_s.split("~", -1)
        { can_sign: can == "1", satisfied: satisfied == "1", message: presence(message) }
      end
      shape :signature_status, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/records/{record_ien}/signature-status"

      # True when the record is linked to a PCC visit (VEXIST^AMHGUA).
      def pcc_visit?(record_ien)
        flag?(first_row(:amhg_visit_exists, record_ien)&.dig(:exists))
      end
      shape :pcc_visit?, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/records/{record_ien}/pcc-visit"

      # The suicide form's other relevant information (ORI^AMHGDSF), or nil.
      def suicide_form_other_information(form_ien)
        presence(first_row(:amhg_suicide_form_other_information, form_ien)&.dig(:text))
      end
      shape :suicide_form_other_information, resource: "behavioral-health", verb: "GET",
                                             path: "/behavioral-health/suicide-forms/{form_ien}/other-information"

      # The patient's PCC problem list as the BH GUI shows it (PLIST^AMHGBPL),
      # active and inactive ("A" asks for all, as the GUI does).
      def pcc_problems(dfn)
        rows(:amhg_pcc_problems, dfn, "A").map do |row|
          compact(row).merge(id: presence(row[:id].to_s.strip))
        end
      end
      shape :pcc_problems, resource: "behavioral-health", verb: "GET", path: "/patients/{dfn}/behavioral-health/pcc-problems"

      # One patient's banner row (PATSTR^AMHGP). :chart is the chart at
      # `facility` (an INSTITUTION IEN); nil when the patient has none there.
      def demographics(dfn, facility:)
        row = first_row(:amhg_patient_demographics, facility, dfn)
        return nil if row.nil? || presence(row[:name]).nil?

        compact(row).merge(chart: row[:chart].to_s == "-1" ? nil : presence(row[:chart]), prf: flag?(row[:prf]))
      end
      shape :demographics, resource: "behavioral-health", verb: "GET", path: "/patients/{dfn}/behavioral-health/demographics"

      # The number the next PCC problem at `facility` takes (NN^AMHGBPL).
      def next_pcc_problem_number(dfn, facility:)
        value = first_row(:amhg_next_pcc_problem_number, dfn, facility)&.dig(:number).to_s
        value.match?(/\A\d+\z/) ? Integer(value) : nil
      end
      shape :next_pcc_problem_number, resource: "behavioral-health", verb: "GET",
                                      path: "/patients/{dfn}/behavioral-health/next-pcc-problem-number"

      # The TIU field a BH word-processing field is edited through
      # (TIUF^AMHBHAPI): the field number, 0 when the record already holds
      # word-processing text (edit that), or an error text from the package
      # raised as RpcMError. `record_ien` nil asks for a new record.
      def tiu_field(wp_field, record_ien: nil, file: MHSS_RECORD_FILE)
        value = amhbh(TIU_FIELD_RPC) { |client| client.call_rpc(TIU_FIELD_RPC, file.to_s, record_ien.to_s, wp_field.to_s) }
        integer_or_error(value)
      end
      shape :tiu_field, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/tiu-field"

      # The TIU document a record's TIU field points at (TIUIEN^AMHBHAPI):
      # { ien:, title:, date: }, or nil when the field is blank.
      def tiu_document(record_ien, tiu_field:, file: MHSS_RECORD_FILE)
        value = amhbh(TIU_DOCUMENT_RPC) { |client| client.call_rpc(TIU_DOCUMENT_RPC, file.to_s, record_ien.to_s, tiu_field.to_s) }
        text = Array(value).join.strip
        raise Client::RpcMError, RpmsRpc.sanitize_error(text) if text.start_with?("-1")
        return nil if text.empty? || text == "0"

        ien, title, date = text.split("^", -1)
        { ien: ien, title: presence(title), date: presence(date) }
      end
      shape :tiu_document, resource: "behavioral-health", verb: "GET", path: "/behavioral-health/records/{record_ien}/tiu-document"

      private

      def compact(row) = row.transform_values { |value| presence(value) }

      def display_lines(mapping_name, ien)
        rows(mapping_name, ien).map { |row| row[:line].to_s }
      end

      # An AMHBH RPC under AMHGRPC, the caller's option restored after.
      def amhbh(_rpc, &block)
        client = RpmsRpc.client
        ContextScope.scoped(client, CONTEXT) { block.call(client) }
      end

      def integer_or_error(value)
        text = Array(value).join.strip
        raise Client::RpcMError, RpmsRpc.sanitize_error(text) if text.start_with?("-1")

        text.match?(/\A\d+\z/) ? Integer(text) : nil
      end
    end
  end
end
