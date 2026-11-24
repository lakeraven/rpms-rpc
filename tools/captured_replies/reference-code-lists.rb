# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/taxonomy"

# The RPMS local code lists, read through DDR LISTER as the provider test
# role: every MEASUREMENT TYPE (#9999999.07) and EXAM (#9999999.15) entry,
# a code taxonomy (#9002226) and a lab taxonomy (#9002228) with their
# members, a name on neither file, and one paged listing (20 a page) to
# record LISTER's MORE^ continuation, and a file number no file has. Every
# flow reads. rpms-rpc#917, #918.
CAPTURE = {
  rpc: "DDR LISTER", entry_point: "LISTC^DDR",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container; every call reads.",
  flows: {
    "measurement_types" => { about: "Measurement.types", run: -> { RpmsRpc::Measurement.types } },
    "exam_types" => { about: "ExamComponent.types", run: -> { RpmsRpc::ExamComponent.types } },
    "members_code" => { about: "Taxonomy.members of SURVEILLANCE DIABETES, an ICD taxonomy",
                        run: -> { RpmsRpc::Taxonomy.members("SURVEILLANCE DIABETES") } },
    "members_lab" => { about: "Taxonomy.members of APCP PAP SMEAR TESTS, the build's one lab taxonomy with a lab test",
                       run: -> { RpmsRpc::Taxonomy.members("APCP PAP SMEAR TESTS") } },
    "members_unknown" => { about: "Taxonomy.members of a name no taxonomy has",
                           run: lambda do
                             RpmsRpc::Taxonomy.members("NO SUCH TAXONOMY")
                           rescue RpmsRpc::Taxonomy::NotFoundError => e
                             e
                           end },
    "paged" => { about: "DdrFileman.list_all of the SURVEILLANCE taxonomies, 20 a page",
                 run: -> { RpmsRpc::DdrFileman.list_all(file: "9002226", fields: "@;.01", part: "SURVEILLANCE", page: 20) } },
    "no_such_file" => { about: "DdrFileman.list_all of file 9999999.999, which the build does not have",
                        run: lambda do
                          RpmsRpc::DdrFileman.list_all(file: "9999999.999", fields: "@;.01")
                        rescue RpmsRpc::Client::RpcError => e
                          e
                        end }
  }
}.freeze
