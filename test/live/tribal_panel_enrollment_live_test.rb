# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/tribal"

# Tribal.enrollment on a panel patient, the fields a seed gap left unproven on
# DFN 2 (openrpms#1079, rpms-rpc#616). SEEDPNL files TRIBAL ENROLLMENT NO. as
# SYN<DFN> on every panel patient, with a tribe and both quanta.
class TribalPanelEnrollmentLiveTest < LiveSpec::Test
  runs_as "PREG123"
  DFN = 990_001 # ALPHA,CASEY, a synthetic panel patient

  def test_a_panel_patient_answers_enrollment_classification_and_community
    enrollment = RpmsRpc::Tribal.enrollment(DFN)

    assert_equal "SYN#{DFN}", enrollment[:enrollment_number]
    assert_equal "INDIAN/ALASKA NATIVE", enrollment[:classification]
    assert_equal "STONE MESA", enrollment[:community]
  end

  def test_a_panel_patient_answers_tribe_and_quantum
    enrollment = RpmsRpc::Tribal.enrollment(DFN)

    assert_equal "INDIAN - TRIBE UNSPECIFIED", enrollment[:tribe_name]
    assert_equal "1/4", enrollment[:tribe_quantum]
    assert_equal "1/2", enrollment[:indian_blood_quantum]
  end
end
