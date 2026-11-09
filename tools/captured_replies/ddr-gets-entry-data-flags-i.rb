# frozen_string_literal: true

# DDR GETS ENTRY DATA with FLAGS "I" on a Behavioral Health visit (#9002011)
# that test/live/behavioral_health_wellness_live_test.rb filed on the same
# container just before (screening and measurements on the synthetic DFN
# 990045, visit 1), read with the fields Wellness reads back. rpms-rpc#612.
CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM)",
  access: "SYS123", verify: "RPMS.000",
  note: "Run after the Wellness live spec, which leaves its visit on the throwaway container. " \
        "GETSC^DDR2 writes FILE^IENS^FIELD^internal^external (DDR2.m:42); under FLAGS I only the internal is set.",
  calls: [
    { name: "bh_visit_screening_fields",
      inputs: [ { "FILE" => "9002011", "IENS" => "1,",
                  "FIELDS" => ".08;1112;1401;1402;1403;1404;1405;1406;1407;1408;1409;1410;1501;1601;1701;1901;2001",
                  "FLAGS" => "I" } ],
      about: "BH visit 1 on synthetic DFN 990045, as the Wellness live spec filed it" },
    { name: "patient_fields",
      inputs: [ { "FILE" => "2", "IENS" => "2,", "FIELDS" => ".01;.02;.03;.09;.301;1901", "FLAGS" => "I" } ],
      about: "seed patient DFN 2 (synthetic USER,TEST): free text, set, date, blank and set-of-codes fields" },
    { name: "provider_name",
      inputs: [ { "FILE" => "200", "IENS" => "204,", "FIELDS" => ".01", "FLAGS" => "I" } ],
      about: "NEW PERSON 204, the demo persona PROFILE,MA: the provider read Wellness makes before a save" }
  ]
}.freeze
