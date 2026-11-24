# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/adt"
require "rpms_rpc/api/patient"

# Adt.movements reads PATIENT MOVEMENT (#405) through DDR LISTER (rpms-rpc#747).
# A patient never admitted reads [], a confirmed empty list rather than a failed
# read. A stay cannot be made through the broker yet (no RPC reaches the ADT
# silent API, openrpms#1231). Since bcer-9.0-20261124-60d39b6-ydb the demo
# build seeds a stay for NOVEMBER,ROWAN (openrpms#1263), so the never-admitted
# patient here is OSCAR,EMERSON; the read of a stay is proven by replies
# captured where one was made through stock $$ADD^BDGAPI (adt-movements.yml).
class AdtMovementsLiveTest < LiveSpec::Test
  runs_as :provider

  NEVER_ADMITTED = 990_015 # OSCAR,EMERSON, a synthetic seed patient; unused by other live specs

  def test_a_patient_never_admitted_has_no_movements
    refute_nil RpmsRpc::Patient.find(NEVER_ADMITTED), "DFN #{NEVER_ADMITTED} must exist on this container's seed data"

    assert_equal [], RpmsRpc::Adt.movements(dfn: NEVER_ADMITTED)
  end
end
