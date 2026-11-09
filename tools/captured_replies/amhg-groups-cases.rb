# frozen_string_literal: true

# The AMHG group and case-management reads, as BehavioralHealth::Groups and
# BehavioralHealth::CaseManagement send them: one pipe-joined parameter,
# under AMHGRPC. rpms-rpc#622, #673. A fresh container of the pinned build has
# no BH group, case or community activity, so the lists are captured empty and
# the single-record reads for an IEN not on file.
CAPTURE = {
  rpc: "AMHG GET GROUPS", entry_point: "GROUPL^AMHGDA",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM)",
  access: "SYS123", verify: "RPMS.000", context: "AMHGRPC",
  note: "Reads only. Lists send from|to|provider (or dfn); provider 4 is the operator's DUZ. 999999 is an IEN " \
        "with no record in any of these files.",
  calls: [
    { name: "groups_none", inputs: [ "3000101|3271231|4" ], about: "the operator's groups over 2000-2027: none" },
    { name: "group_information_not_on_file", rpc: "AMHG GET GROUP INFORMATION", inputs: [ "999999" ],
      about: "a group IEN not on file: one row of blanks" },
    { name: "group_patients_not_on_file", rpc: "AMHG GET GROUP PATIENTS", inputs: [ "999999" ], about: "no group: no patients" },
    { name: "group_cpt_not_on_file", rpc: "AMHG GET GROUP CPT", inputs: [ "999999" ], about: "no group: no CPT rows" },
    { name: "group_edu_not_on_file", rpc: "AMHG GET GROUP EDU", inputs: [ "999999" ], about: "no group: no education rows" },
    { name: "group_pov_not_on_file", rpc: "AMHG GET GROUP POV", inputs: [ "999999" ], about: "no group: no POV rows" },
    { name: "group_soap_not_on_file", rpc: "AMHG GET GROUP SOAP", inputs: [ "999999" ], about: "no group: the SOAP header alone" },
    { name: "group_secondary_providers_not_on_file", rpc: "AMHG GET GROUP SEC PROVIDERS", inputs: [ "999999" ],
      about: "no group: no secondary providers" },
    { name: "case_dates_none", rpc: "AMHG GET CASE DATES", inputs: [ "3000101|3271231|4" ],
      about: "demo patient 4's case dates over 2000-2027: none" },
    { name: "case_management_not_on_file", rpc: "AMHG GET CASE MANAGEMENT", inputs: [ "999999" ],
      about: "a case IEN not on file: one row of blanks" },
    { name: "community_activities_none", rpc: "AMHG GET COMMUNITY ACTIVITIES", inputs: [ "3000101|3271231|4" ],
      about: "the operator's community activities over 2000-2027: none" },
    { name: "community_activity_not_on_file", rpc: "AMHG GET COMMUNITY ACTIVITY", inputs: [ "999999" ],
      about: "a community activity IEN not on file: one row of blanks" }
  ]
}.freeze
