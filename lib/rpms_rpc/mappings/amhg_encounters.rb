# frozen_string_literal: true

require_relative "../data_mapper"

module RpmsRpc
  module Mappings
    # The Behavioral Health GUI's record-selector lists, the record
    # displays, the patient's PCC problem list and demographics, and the
    # visit checks it makes before it signs or links a visit (rpms-rpc
    # BehavioralHealth::Encounters). Every one is a GLOBAL ARRAY under
    # AMHGRPC with a typed header row; the column order below is the order
    # that header declares on the image's routine, read live on
    # bcer-9.0-20261125-9df42d6-ydb.

    # VISITL^AMHGD: "begin|end|dfn". The record selector's visit list for
    # one patient, newest first. BMXIEN is the MHSS RECORD (#9002011) IEN.
    DataMapper.define(:amhg_record_selector_visits) do |m|
      m.rpc "AMHG GET VISIT LIST"
      m.field 0,  :ien
      m.field 1,  :sort_date          # internal FileMan date
      m.field 2,  :date               # $$LVDT^AMHGU, MM/DD/YYYY
      m.field 3,  :pov
      m.field 4,  :axis_v
      m.field 5,  :clinic
      m.field 6,  :activity
      m.field 7,  :visit_type
      m.field 8,  :contact_type
      m.field 9,  :provider
      m.field 10, :unsigned           # "*" while the note has no signature (#9002011 1112)
      m.field 11, :ehr
      m.field 12, :delete_intakes
      m.field 13, :location
      m.field 14, :group
      m.field 15, :program
      m.field 16, :activity_time
      m.field 17, :dob_internal
      m.field 18, :needs_cosign
    end

    # VISITAP^AMHGD: "begin|end|" (no patient). The same list across every
    # patient the user may see, with the patient as "dfn~name".
    DataMapper.define(:amhg_visits_all_patients) do |m|
      m.rpc "AMHG GET VISITS ALL PATS"
      m.field 0,  :ien
      m.field 1,  :sort_date
      m.field 2,  :date
      m.field 3,  :patient_raw        # dfn~name
      m.field 4,  :chart
      m.field 5,  :sex
      m.field 6,  :dob
      m.field 7,  :pov
      m.field 8,  :axis_v
      m.field 9,  :clinic
      m.field 10, :activity
      m.field 11, :visit_type
      m.field 12, :contact_type
      m.field 13, :provider
      m.field 14, :unsigned
      m.field 15, :ehr
      m.field 16, :delete_intakes
      m.field 17, :location
      m.field 18, :group
      m.field 19, :sensitive          # Spt
      m.field 20, :message
      m.field 21, :program
      m.field 22, :activity_time
      m.field 23, :dob_internal
      m.field 24, :needs_cosign
    end

    # SFLAP^AMHGD: "begin|end|". Suicide forms across patients.
    DataMapper.define(:amhg_suicide_forms_all_patients) do |m|
      m.rpc "AMHG GET SUIC FORMS ALL PATS"
      m.field 0,  :ien
      m.field 1,  :sort_date
      m.field 2,  :date
      m.field 3,  :patient_raw        # dfn~name
      m.field 4,  :chart
      m.field 5,  :sex
      m.field 6,  :dob
      m.field 7,  :local_case_number
      m.field 8,  :provider
      m.field 9,  :suicidal_behavior
      m.field 10, :sensitive
      m.field 11, :message
      m.field 12, :incomplete         # "I" when the form is incomplete
      m.field 13, :dob_internal
    end

    # LIST^AMHGPCC: "record". The PCC visits a BH record may link to, as
    # BSDAPI^AMHGPCC finds them for the record's patient, date and site.
    DataMapper.define(:amhg_pcc_visit_choices) do |m|
      m.rpc "AMHG GET PCC VISITS"
      m.field 0, :ien                 # VISIT (#9000010) IEN
      m.field 1, :date
      m.field 2, :time
      m.field 3, :location
      m.field 4, :provider
      m.field 5, :clinic
      m.field 6, :service_category
      m.field 7, :pov                 # "code-narrative"
    end

    # BHREC^AMHGR: "record". One column of display lines.
    DataMapper.define(:amhg_record_display) do |m|
      m.rpc "AMHG GET MHSS RECORD DISPLAY"
      m.field 0, :line
    end

    # PCC^AMHGR: "visit". One column of display lines.
    DataMapper.define(:amhg_pcc_visit_display) do |m|
      m.rpc "AMHG GET PCC RECORD DISPLAY"
      m.field 0, :line
    end

    # HSCR^AMHGDVF3: "begin|end|dfn". The screenings on the patient's BH
    # visits in the range; BMXIEN is the visit's record IEN.
    DataMapper.define(:amhg_screening_history) do |m|
      m.rpc "AMHG GET HISTORICAL SCREENING"
      m.field 0, :ien
      m.field 1, :date
      m.field 2, :type
      m.field 3, :result
      m.field 4, :provider
      m.field 5, :comment
    end

    # BHWELL^AMHGDVF1: "begin|end|dfn". The wellness tab's BH rows, one per
    # visit that carries an education topic, health factor or screening.
    DataMapper.define(:amhg_wellness_activities) do |m|
      m.rpc "AMHG GET VISIT BH WELLNES ACT"
      m.field 0,  :ien
      m.field 1,  :date
      m.field 2,  :education_topic
      m.field 3,  :health_factor
      m.field 4,  :alcohol_screening
      m.field 5,  :depression_screening
      m.field 6,  :ipv_screening
      m.field 7,  :suicide_risk_assessment
      m.field 8,  :suicide
      m.field 9,  :provider
      m.field 10, :visit_ien
    end

    # CHKESIG^AMHGESIG: "record". One row: $$ESIG^AMHESIG with "^" made
    # "~": can_sign~satisfied~message[~note_needed].
    DataMapper.define(:amhg_signature_status) do |m|
      m.rpc "AMHG GET ESIG"
      m.field 0, :value
    end

    # VEXIST^AMHGUA: "record". 1 when the record has a PCC visit (.16).
    DataMapper.define(:amhg_visit_exists) do |m|
      m.rpc "AMHG CHECK VISIT EXISTS"
      m.field 0, :exists
    end

    # ORI^AMHGDSF: "form". The suicide form's other relevant information.
    DataMapper.define(:amhg_suicide_form_other_information) do |m|
      m.rpc "AMHG GET SUICIDE FORM ORI"
      m.field 0, :ien
      m.field 1, :text
    end

    # PLIST^AMHGBPL: "dfn|A". The patient's PCC problem list as the BH GUI
    # shows it. 27 columns; the note columns are blank when a problem has
    # no note.
    DataMapper.define(:amhg_pcc_problems) do |m|
      m.rpc "AMHG GET PCC PROBLEM LIST"
      m.field 0,  :ien                # PROBLEM (#9000011) IEN
      m.field 1,  :id                 # facility abbreviation and number
      m.field 2,  :dx_ien
      m.field 3,  :dx
      m.field 4,  :status
      m.field 5,  :last_modified
      m.field 6,  :dsm_narrative
      m.field 7,  :provider_narrative
      m.field 8,  :date_of_onset
      m.field 9,  :facility
      m.field 10, :problem_class
      m.field 11, :number
      m.field 12, :added_by_ien
      m.field 13, :added_by
    end

    # PATSTR^AMHGP: "facility|dfn". One patient's banner row, as GET
    # PATIENT's lookup rows read (PATADO^AMHGP). CHART is the chart at the
    # facility the first piece names, -1 when it names none.
    DataMapper.define(:amhg_patient_demographics) do |m|
      m.rpc "AMHG GET PATIENT DEMOGRAPHICS"
      m.field 0,  :ien
      m.field 1,  :name
      m.field 2,  :dob
      m.field 3,  :sex
      m.field 4,  :chart
      m.field 5,  :ssn
      m.field 6,  :reg
      m.field 7,  :more
      m.field 8,  :date_of_death
      m.field 9,  :age
      m.field 10, :message_flag
      m.field 11, :message
      m.field 12, :prf
    end

    # NN^AMHGBPL: "dfn|facility". The next PCC problem number at the facility.
    DataMapper.define(:amhg_next_pcc_problem_number) do |m|
      m.rpc "AMHG GET PCC PL NN"
      m.field 0, :number
    end
  end
end
