# frozen_string_literal: true

require_relative "../live_helper"
require_relative "../immunization_profile_checks"

# Immunization.text_summary over BMX (#656). BmxClient#call_rpc reads the
# profile's $C(31)$C(31) end line as a recordset end marker and a query
# error, so text_summary reads the BMX reply raw; this proves that path on
# the wire. The checks are shared with test/live/immunization_profile_live_test.rb.
# Reads only. BGOVIMM PROFILE is in CIAV VUECENTRIC.
#   BROKER_PROTOCOL=bmx BROKER_PORT=<the image's 9101> rake test:live
class BmxImmunizationProfileLiveTest < LiveSpec::Test
  broker :bmx
  include ImmunizationProfileChecks

  CONTEXT = "CIAV VUECENTRIC"

  # DDR GETS ENTRY DATA takes a list parameter, which BmxClient does not
  # send yet, so the register is not read over BMX: the profile is checked
  # for text (or the package's own error), not against the register.
  def registered?(_dfn) = nil

  def setup
    super
    client.create_context(CONTEXT)
  rescue RpmsRpc::Client::RpcError => e
    flunk "#{persona} cannot bind #{CONTEXT} on this build (#{e.message}): BGOVIMM PROFILE is registered there"
  end
end
