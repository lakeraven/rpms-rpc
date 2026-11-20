# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# The DDR GETS ENTRY DATA reads Patient.address and Patient.contact make, as
# PROFILE,REG. Setup fills, on synthetic seed patient DFN 990055, the pieces
# the seed leaves empty that AG's Address window files (address lines 2 and
# 3, a ZIP+4, the IHS PATIENT other phone and email), through Patient.update
# (AGG UPDATE PATIENT under AG's edit lock), as a registration clerk would,
# and the cell phone, which AG's window does not offer, through DDR FILER.
# Seed patient DFN 2 has every piece empty; DFN 5 has no PATIENT entry. Run
# on a throwaway container. rpms-rpc#620.
Patient = RpmsRpc::Patient

FILLED = {
  address_line2: "UNIT 4", address_line3: "BLDG C", zip: "59000-1234",
  phone_other: "MSG 406-555-0100", email: "synthetic.patient@example.test"
}.freeze

CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Setup files, on synthetic DFN 990055 through Patient.update: address lines 2 and 3 UNIT 4 and BLDG C, " \
        "ZIP+4 59000-1234, other phone MSG 406-555-0100, email synthetic.patient@example.test; " \
        "and through DDR FILER under CIAV VUECENTRIC, .134 PHONE NUMBER [CELLULAR] 406-555-0198.",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    updated = Patient.update(990_055, **FILLED)
    abort "setup: Patient.update did not file: #{updated.inspect}" unless updated&.dig(:success)
    cell = RpmsRpc::ContextScope.scoped(client, Patient::FILEMAN_CONTEXT) do
      RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "2", field: ".134", iens: "990055,", value: "406-555-0198" } ])
    end
    abort "setup: DDR FILER did not file .134: #{cell.inspect}" unless cell&.dig(:success)
    RpmsRpc.reset!
    {}
  },
  flows: {
    "address_full" => { about: "address of DFN 990055: every piece filled", run: -> { Patient.address(990_055) } },
    "address_empty" => { about: "address of DFN 2: every piece empty", run: -> { Patient.address(2) } },
    "address_unknown" => { about: "address of DFN 5, no PATIENT entry", run: -> { Patient.address(5) } },
    "contact_full" => { about: "contact of DFN 990055: PATIENT phones, then IHS PATIENT other phone and email",
                        run: -> { Patient.contact(990_055) } },
    "contact_empty" => { about: "contact of DFN 2: every piece empty", run: -> { Patient.contact(2) } },
    "contact_unknown" => { about: "contact of DFN 5: the PATIENT read fails, so IHS PATIENT is not read",
                           run: -> { Patient.contact(5) } }
  }
}.freeze
