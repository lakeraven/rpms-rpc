# frozen_string_literal: true

# The AMHG reference and intake reads, as BehavioralHealth::Reference and
# BehavioralHealth::Intake send them: one pipe-joined parameter, under
# AMHGRPC. rpms-rpc#622, #673. A fresh container of the pinned build has no
# BH intake or administrative record, so those lists are captured empty.
# AMHG GET CLINICS is not captured: CLN^AMHGTVF writes nothing, and the CIA
# read waits for a $C(31) that never comes (#673).
CAPTURE = {
  rpc: "AMHG GET PATIENT", entry_point: "GETPAT^AMHGP",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM)",
  access: "SYS123", verify: "RPMS.000", context: "AMHGRPC",
  note: "Reads only. Pieces are facility|query|max (patients), site IEN, from|to|provider (admin, intakes) " \
        "and dfn|program|from|to (intake documents); provider 4 is the operator's DUZ.",
  calls: [
    { name: "patients", inputs: [ "|DEMO|ALL" ], about: "name prefix DEMO, no facility: demo patient 4" },
    { name: "patients_none", inputs: [ "7819|ZZZNOMATCH|ALL" ], about: "a name prefix no patient has: the header alone" },
    { name: "site", rpc: "AMHG GET SITE PARAMETERS", inputs: [ "1" ], about: "BH site parameters entry 1" },
    { name: "site_not_on_file", rpc: "AMHG GET SITE PARAMETERS", inputs: [ "99999" ],
      about: "an IEN with no site parameters: SITE^AMHGU still writes one row" },
    { name: "admin_none", rpc: "AMHG GET ADMIN RECORDS", inputs: [ "3000101|3271231|4" ],
      about: "the operator's administrative records over 2000-2027: none on file" },
    { name: "intakes_none", rpc: "AMHG GET INTAKE", inputs: [ "3000101|3271231|4" ],
      about: "demo patient 4's intakes over 2000-2027: none on file" },
    { name: "intake_documents_none", rpc: "AMHG GET INTAKE DOCUMENTS", inputs: [ "4|M|3000101|3271231" ],
      about: "demo patient 4's mental health intake documents over 2000-2027: none on file" }
  ]
}.freeze
