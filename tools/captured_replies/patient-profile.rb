# frozen_string_literal: true

require "rpms_rpc/api/patient_profile"

# PatientProfile's conversations with AG's GUI windows, recorded as flows as
# PROFILE,REG on synthetic seed patient DFN 990007: the emergency contact and
# next of kin (S-REG-08), languages (S-REG-10), other names (S-REG-12) and
# the look-ups, as test/live/patient_profile_live_test.rb walks them. Run on
# a fresh throwaway container: the flows run in this order, and each builds
# on the one before. rpms-rpc#620.
Profile = RpmsRpc::PatientProfile
DFN = 990_007
SPOUSE = 22   # RELATIONSHIP (#9999999.36)
ENGLISH = 144 # LANGUAGE (#9999999.99)
SPANISH = 531
ALIAS = {} # the other name aliases_add files, for aliases_remove

CAPTURE = {
  rpc: "AGG UPDATE PATIENT", entry_point: "UPD^AGGPTUPD",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a fresh throwaway container, flows in order. DFN 990007 is a synthetic seed patient with no " \
        "emergency contact, next of kin, language entry or other name before the first flow.",
  flows: {
    "contacts_none" => { about: "contacts before any is filed: both windows answer only their header",
                         run: -> { Profile.contacts(DFN) } },
    "emergency_name_required" => { about: "emergency contact relationship and phone with no name on file",
                                   run: -> { Profile.update_contact(DFN, :emergency, relationship: SPOUSE, phone: "555-555-0100") } },
    "emergency_name_refused" => { about: "emergency contact name DOE, JANE: AG's name check refuses it",
                                  run: -> { Profile.update_contact(DFN, :emergency, name: "DOE, JANE") } },
    "emergency" => {
      about: "emergency contact doe,jane, SPOUSE, 1 MAIN ST, 12345, 555-555-0100",
      run: lambda {
        Profile.update_contact(DFN, :emergency, name: "doe,jane ", relationship: SPOUSE, address_line1: "1 MAIN ST",
                                           zip: "12345", phone: "555-555-0100")
      }
    },
    "next_of_kin" => { about: "next of kin DOE,JOHN with a work phone",
                       run: -> { Profile.update_contact(DFN, :next_of_kin, name: "DOE,JOHN", phone_work: "555-555-0102") } },
    "contacts" => { about: "contacts after both are filed", run: -> { Profile.contacts(DFN) } },
    "emergency_city" => { about: "emergency contact city alone, the name on file",
                          run: -> { Profile.update_contact(DFN, :emergency, city: "ANYTOWN") } },
    "emergency_zip_refused" => { about: "emergency contact zip ABCDE: AG refuses it",
                                 run: -> { Profile.update_contact(DFN, :emergency, zip: "ABCDE") } },
    "languages_english" => {
      about: "a first language entry: English, very well",
      run: -> { Profile.record_languages(DFN, primary: ENGLISH, proficiency: "VW", preferred: ENGLISH, english_ien: ENGLISH) }
    },
    "languages_spanish" => {
      about: "a new entry: Spanish with an interpreter, English not well, English as another language",
      run: lambda {
        Profile.record_languages(DFN, primary: SPANISH, interpreter: "Y", preferred: SPANISH, proficiency: "NW",
                                 others: [ ENGLISH ], english_ien: ENGLISH)
      }
    },
    "languages_switch" => {
      about: "a new entry: English, Spanish as another language; AG copies English from the entry before",
      run: -> { Profile.record_languages(DFN, primary: ENGLISH, proficiency: "VW", others: [ SPANISH ], english_ien: ENGLISH) }
    },
    "languages" => { about: "the latest language entry and its other languages", run: -> { Profile.languages(DFN) } },
    "languages_other_refused" => {
      about: "a new entry with LANGUAGE 999999, not on file, as another language",
      run: -> { Profile.record_languages(DFN, primary: ENGLISH, proficiency: "VW", others: [ 999_999 ], english_ien: ENGLISH) }
    },
    "alias_add" => { about: "add the other name oldname,robin",
                     run: -> { ALIAS[:ien] = Profile.add_alias(DFN, "oldname,robin")[:ien] } },
    "alias_refused" => { about: "add the other name OLD, NAME: AG's name check refuses it",
                         run: -> { Profile.add_alias(DFN, "OLD, NAME") } },
    "aliases" => { about: "the other names on file", run: -> { Profile.aliases(DFN) } },
    "alias_remove_missing" => { about: "remove other name entry 999, which the patient does not have",
                                run: -> { Profile.remove_alias(DFN, 999) } },
    "alias_remove" => { about: "remove the other name alias_add filed", run: -> { Profile.remove_alias(DFN, ALIAS.fetch(:ien)) } },
    "relationships" => { about: "RELATIONSHIP look-up for sp", run: -> { Profile.relationships("sp") } },
    "states" => { about: "STATE look-up for mont", run: -> { Profile.states("mont") } }
  }
}.freeze
