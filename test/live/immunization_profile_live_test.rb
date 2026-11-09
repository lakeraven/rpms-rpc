# frozen_string_literal: true

require_relative "live_helper"
require_relative "immunization_profile_checks"

# Immunization.text_summary reads the patient's Immunization Profile through
# BGOVIMM PROFILE (PROFILE^BGOVIMM2 -> IMMPROF^BIRPC), the text VueCentric's
# immunization component shows (#656). It used to send the DFN to BEHOCIR
# GETTXT, a SNOMED CT lookup that answered "^" for every patient.
#
# Reads only; files nothing. The checks are in immunization_profile_checks.rb,
# shared with test/live/bmx/immunization_profile_live_test.rb. A package
# error raises; the captured error reply is pinned in
# test/rpms_rpc/api/immunization_test.rb.
class ImmunizationProfileLiveTest < LiveSpec::Test
  include ImmunizationProfileChecks
end
