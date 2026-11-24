# frozen_string_literal: true

# The TIU template reads (TIUSRVT): the roots and items NODEDATA rows, a
# template's unexpanded boilerplate, the expansion of text for a patient,
# and the user's access level, recorded as flows as the clinician
# PROVIDER,TEST (DUZ 200) on the build's shared templates and the seed
# patient DFN 4. Nothing is filed. rpms-rpc#620.
NoteTemplate = RpmsRpc::NoteTemplate

CAPTURE = {
  rpc: "TIU TEMPLATE GETROOTS", entry_point: "GETROOTS^TIUSRVT",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair; DUZ 200)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "roots" => { about: "roots of DUZ 200", run: -> { NoteTemplate.roots(200) } },
    "items" => { about: "items of template 1, Shared Templates", run: -> { NoteTemplate.items(1) } },
    "boilerplate" => { about: "boilerplate of template 3337, Vitals", run: -> { NoteTemplate.boilerplate(3337) } },
    "text" => { about: "text: two lines with patient objects, for DFN 4",
                run: -> { NoteTemplate.text([ "Name: |PATIENT NAME|", "Sex: |PATIENT SEX|" ], dfn: "4") } },
    "access_level" => { about: "access level of template 1 for DUZ 200", run: -> { NoteTemplate.access_level(1, 200) } }
  }
}.freeze
