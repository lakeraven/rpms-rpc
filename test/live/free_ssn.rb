# frozen_string_literal: true

require "rpms_rpc/api/agg"

# An SSN no patient on the container holds, shared by the registration live
# specs (test/live/registration_window_validation_live_test.rb,
# test/live/patient_registration_record_live_test.rb). A container that
# already ran the suite holds earlier runs' patients (#810, #853), so an SSN
# is drawn until AG's own SSN check, the one that refuses a duplicate,
# accepts it. Signed on as the spec's persona, over the spec's own client.
module FreeSsn
  SSN_TRIES = 10

  def fresh_ssn
    tried = Array.new(SSN_TRIES) do
      ssn = draw_ssn
      checked = RpmsRpc::Agg.validate_field(window: RpmsRpc::Agg::NEW_PATIENT_WINDOW,
                                            params: { "AGGPTSSN" => ssn, "AGGNOSSN" => "", "DFN" => "" })
      flunk "AG gave no answer checking SSN #{ssn} (AGG WINDOW DATA VALIDATION)" unless checked
      return ssn if checked[:valid]

      "#{ssn} (#{checked[:message]})"
    end
    flunk "every SSN tried is already on a patient: #{tried.join(', ')}"
  end

  def draw_ssn = "6660#{format('%05d', rand(100_000))}"
end
