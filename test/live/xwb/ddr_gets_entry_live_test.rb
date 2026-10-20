# frozen_string_literal: true

require_relative "../live_helper"
require "rpms_rpc/api/ddr_fileman"

# DdrFileman.gets_entry over XWB gives the same fields as over CIA (#432, from #333).
#
# Both brokers answer DDR GETS ENTRY DATA from GETSC^DDR2 (DDR2.m:29-40); only the framing differs. The
# expected results are the ones test/rpms_rpc/api/ddr_fileman_cia_test.rb asserts on CIA replies recorded
# on yotta-1016 (bcer-9.0-20261015-46dd047-ydb, SYS123, 2026-10-16), so this spec holds the XWB reply
# of an IRIS build to the same {fields:, error:} result.
#
# The session binds CIAV VUECENTRIC, the option the CIA recordings ran under; it serves the DDR read
# family. DEMO,PATIENT ONE (DFN 4) and MANAGER,SYSTEM (DUZ 4) are the same records on both lines.
#
# Read only: GETS^DIQ reads; nothing is filed.
class DdrGetsEntryXwbLiveTest < LiveSpec::Test
  broker :xwb

  CONTEXT = "CIAV VUECENTRIC"

  PATIENT = {
    ".01" => { internal: "DEMO,PATIENT ONE", external: "DEMO,PATIENT ONE" },
    ".02" => { internal: "F", external: "FEMALE" },
    ".03" => { internal: "3010101", external: "01/01/2001" }
  }.freeze

  USER = {
    ".01" => { internal: "MANAGER,SYSTEM", external: "MANAGER,SYSTEM" },
    "1" => { internal: "SM", external: "SM" },
    "4" => { internal: "M", external: "MALE" }
  }.freeze

  def setup
    super
    flunk "#{persona} cannot bind #{CONTEXT} over XWB on this build" unless client.create_context(CONTEXT)
  end

  def test_a_patient_reads_the_fields_the_cia_recording_gives
    result = RpmsRpc::DdrFileman.gets_entry(file: "2", iens: "4,", fields: ".01;.02;.03", flags: "IE")

    assert_equal({ fields: PATIENT, error: false }, result)
    puts "\n#{persona}: file 2 entry 4 over XWB = the CIA recording (#{result[:fields].size} fields)"
  end

  def test_a_user_reads_the_fields_the_cia_recording_gives
    result = RpmsRpc::DdrFileman.gets_entry(file: "200", iens: "4,", fields: ".01;1;4", flags: "IE")

    assert_equal({ fields: USER, error: false }, result)
    puts "\n#{persona}: file 200 entry 4 over XWB = the CIA recording (#{result[:fields].size} fields)"
  end
end
