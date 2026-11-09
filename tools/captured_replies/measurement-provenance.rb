# frozen_string_literal: true

require "rpms_rpc/api/measurement"

# The conversations RpmsRpc::Measurement's reads have with the build, recorded
# as flows as PROFILE,MD: BGOVMSR GET / LAST, ORQQVI VITALS, then the
# BEHOENCX GETVISIT, DDR GETS ENTRY DATA and BEHOVM2 VUNITS calls each row's
# provenance takes. Demo patient 4's vitals (measurements 5-10) are on visit 6;
# measurement 13 belongs to demo patient 990001 and has no EVENT DATE/TIME.
# rpms-rpc#620.
Measurement = RpmsRpc::Measurement

CAPTURE = {
  rpc: "BGOVMSR GET", entry_point: "GET^BGOVMSR",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  setup: lambda { |client|
    # Mark demo patient 4's respiration (measurement 7) entered in error, as
    # VueCentric's vitals EIE does: EIE^BEHOVM2, reason 2 (incorrect reading).
    raw = client.call_rpc_raw("BEHOVM2 EIE", "7^206^2", "0").b
    raise "BEHOVM2 EIE did not mark measurement 7: #{raw.inspect}" unless raw.byteslice(2..) == "OK"

    {}
  },
  note: "Run on a throwaway container. Setup marks measurement 7 entered in error with BEHOVM2 EIE; nothing else " \
        "is filed. Every visit on the build with a measurement is ambulatory (A), so no capture holds a reported " \
        "(T, E) visit.",
  flows: {
    "for_visit" => { about: "for_visit(6): demo patient 4's vitals and their provenance",
                     run: -> { Measurement.for_visit(6) } },
    "for_visit_none" => { about: "for_visit of a visit IEN no visit holds", run: -> { Measurement.for_visit(999_999) } },
    "latest" => { about: "latest(4): the newest of each type", run: -> { Measurement.latest(4) } },
    "latest_types_visit" => { about: "latest(4, types: BP and WT, visit 6)",
                              run: -> { Measurement.latest(4, types: %w[BP WT], visit_ien: 6) } },
    "latest_none" => { about: "latest of a DFN no patient holds", run: -> { Measurement.latest(999_999) } },
    "find_event" => { about: "find(8): demo patient 4's blood pressure, with an EVENT DATE/TIME",
                      run: -> { Measurement.find(8) } },
    "find_visit_date" => { about: "find(13): a height with no EVENT DATE/TIME", run: -> { Measurement.find(13) } },
    "find_eie" => { about: "find(7): the respiration setup marked entered in error", run: -> { Measurement.find(7) } },
    "find_unknown" => { about: "find of an IEN no measurement holds", run: -> { Measurement.find(999_999_999) } },
    "newest" => { about: "newest_by_type(4)", run: -> { Measurement.newest_by_type(4) } },
    "newest_range" => { about: "newest_by_type(4) bounded to September 2026",
                        run: lambda {
                          Measurement.newest_by_type(4, start_date: Time.new(2026, 9, 1, 0, 0, 0),
                                                        end_date: Time.new(2026, 9, 30, 23, 59, 0))
                        } },
    "newest_none" => { about: "newest_by_type of a DFN no patient holds", run: -> { Measurement.newest_by_type(999_999) } }
  }
}.freeze
