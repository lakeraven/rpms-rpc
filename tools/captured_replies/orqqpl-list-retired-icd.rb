# frozen_string_literal: true

# ORQQPL LIST, a patient's problem list, as Problem.for_patient asks for it,
# with one problem whose ICD code is retired. rpms-rpc#532.
#
# Setup files that problem through the stock IHS write the gem's Problem.add
# sends (BGOPROB SET, SET^BGOPROB), with ICD-9-CM 203.1: on the pinned build
# ICD*18.0*6 is installed and $$STATCHK^ICDAPIU("203.1",DT) is 0 (inactive
# since 2911001), so LIST^ORQQPL marks the row "#" (ORQQPL.m:14-16) and keeps
# the code in piece 4. Run on a fresh throwaway container: each run files one
# more problem.
CAPTURE = {
  rpc: "ORQQPL LIST", entry_point: "LIST^ORQQPL",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "CIAV VUECENTRIC",
  note: "Setup files one problem for demo patient 4 with retired ICD-9-CM 203.1 (BGOPROB SET, " \
        "location 1, SPEC 1). Patient 4's seeded problems carry ICD-10 codes, which this build's " \
        "LIST^GMPLUTL2 answers with $$ICDDX error text in piece 4, also marked '#'.",
  setup: lambda { |client|
    line = [ "P", "", "", "Retired code demo", "203.1", "1", "", "A", "", "", "" ].join("^")
    reply = client.call_rpc("BGOPROB SET", "4", "", "", [ line ], "1").first.to_s
    abort "setup: BGOPROB SET did not file the problem: #{reply.inspect}" unless reply.match?(/\A[1-9]\d*\z/)
  },
  calls: [
    { name: "retired_code", inputs: [ "4", "" ],
      about: "demo patient 4, all statuses: four seeded rows with error text in piece 4 and the filed row with 203.1, every row '#'" },
    { name: "no_problems", inputs: [ "999999", "" ], about: "a DFN no patient has: the '^No problems found.' sentinel" }
  ]
}.freeze
