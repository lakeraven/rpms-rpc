# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/tribal"

# Tribal.enrollment on a panel patient, the fields a seed gap left unproven on
# DFN 2 (rpms-ops#1079, rpms-rpc#616). SEEDPNL files TRIBAL ENROLLMENT NO. as
# SYN<DFN> on every panel patient; the pin predates it until #639. The panel
# carries no tribe or quantum, so those fields stay unproven here.
class TribalPanelEnrollmentLiveTest < LiveSpec::Test
  DFN = 990_001 # ALPHA,CASEY, a synthetic panel patient
  BUILD_BEFORE_THE_SEED = "bcer-9.0-20261012-e7923a4-ydb"

  def test_a_panel_patient_answers_enrollment_classification_and_community
    enrollment = RpmsRpc::Tribal.enrollment(DFN)
    if enrollment[:enrollment_number].to_s.empty? && LiveSpec.build_label.start_with?(BUILD_BEFORE_THE_SEED)
      skip_tracked("#639", "the pinned build seeds no panel enrollment number")
    end

    assert_equal "SYN#{DFN}", enrollment[:enrollment_number]
    assert_equal "INDIAN/ALASKA NATIVE", enrollment[:classification]
    assert_equal "STONE MESA", enrollment[:community]
  end
end
