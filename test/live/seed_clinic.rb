# frozen_string_literal: true

require "rpms_rpc/api/location"

module LiveSpec
  # The clinic the demo build files seed patient DFN 2's visit 1 at: SEEDCLIN
  # sets the visit's HOSPITAL LOCATION to DEMO PRIMARY CARE. Its #44 IEN is
  # whatever the seed order hands out (6 on earlier builds, 10 on
  # bcer-9.0-20261119-f67498c-ydb, rpms-rpc#837), so a spec reads it from the
  # build by name rather than writing the number down.
  module SeedClinic
    SEED_CLINIC = "DEMO PRIMARY CARE"

    # The clinic's #44 IEN, by its exact name (Location.search: DDR LISTER on "B").
    def seed_clinic_ien
      @seed_clinic_ien ||= begin
        found = RpmsRpc::Location.search(SEED_CLINIC).to_a.select { |loc| loc[:name] == SEED_CLINIC }
        assert_equal 1, found.size, "#44 must hold exactly one #{SEED_CLINIC}: #{found.inspect}"
        found.first[:ien]
      end
    end
  end
end
