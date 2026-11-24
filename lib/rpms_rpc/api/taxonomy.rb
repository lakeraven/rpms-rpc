# frozen_string_literal: true

require_relative "../shape"
require_relative "ddr_fileman"

module RpmsRpc
  # RPMS taxonomies: the named code lists CRS/GPRA and the Diabetes Audit
  # count denominators with (rpms-rpc#918). They live in two files, read
  # through DDR LISTER, the stock FileMan reader:
  #
  #   TAXONOMY (#9002226, ^ATXAX)        kind :code. Each member is a
  #     VALUE (#9002226.02101) range: LOW VALUE (.01), HIGH VALUE (.02) and
  #     CODING SYSTEM (.03, #80.4). The values are codes of FILE (.15):
  #     #80 ICD diagnoses, #81 CPT, #95.3 LOINC, #50 drugs, and so on.
  #     A range is kept as a range.
  #   LAB TAXONOMY (#9002228, ^ATXLAB)   kind :lab. Each member is a LAB
  #     TESTS (#9002228.02101) entry, a pointer to LABORATORY TEST (#60).
  #     A site fills these in with its own lab tests.
  #
  # RPMS records no "site-populated" flag. Each list row carries what it
  # does record: the kind, the member file and READ ONLY (.22).
  module Taxonomy
    extend self
    extend Shape::Declarable

    # An unknown taxonomy name: not the same as a taxonomy with no members.
    class NotFoundError < RpmsRpc::Error; end

    CODE_FILE = "9002226"
    CODE_MEMBERS = "9002226.02101"
    LAB_FILE = "9002228"
    LAB_MEMBERS = "9002228.02101"

    # Every taxonomy, code and lab, whose name starts with +prefix+ (all
    # of them when nil), by name:
    #
    #   list(prefix: "BGP") => [{ ien:, name:, kind: :code or :lab, file:, read_only: }, ...]
    #
    # file is the member file number as a String ("80", "60"); read_only
    # is READ ONLY (.22) = 1. A read that cannot be had whole raises
    # Client::RpcError.
    def list(prefix: nil)
      rows = listed(CODE_FILE, "@;.01;.15;.22", prefix).map { |e| row(e, :code) } +
             listed(LAB_FILE, "@;.01;.09;.22", prefix).map { |e| row(e, :lab) }
      rows.sort_by { |r| [ r[:name], r[:kind] ] }
    end
    shape :list, resource: "taxonomies", verb: "GET", path: "/taxonomies"

    # One taxonomy's members, by its exact name:
    #
    #   members("SURVEILLANCE DIABETES")
    #   => { name:, kind: :code, file: "80",
    #        members: [{ low: "250.00", high: "250.93", code_system: "ICD-9-CM" }, ...] }
    #   members("DM AUDIT HGB A1C TAX")
    #   => { name:, kind: :lab, file: "60", members: [{ ien: 97, name: "HEMOGLOBIN A1C" }, ...] }
    #
    # Codes are as stored, less the trailing blank FileMan keeps on ICD
    # values. A name on neither file raises NotFoundError; a read that
    # cannot be had whole raises Client::RpcError.
    def members(name)
      found = list(prefix: name.to_s).find { |t| t[:name] == name.to_s }
      raise NotFoundError, "no taxonomy is named #{name.inspect}" unless found

      { name: found[:name], kind: found[:kind], file: found[:file], members: member_rows(found) }
    end
    shape :members, resource: "taxonomies", verb: "GET", path: "/taxonomies/members"

    private

    def listed(file, fields, prefix)
      DdrFileman.list_all(file: file, fields: fields, part: prefix.to_s.empty? ? nil : prefix)
    end

    def row(entry, kind)
      name, file, read_only = entry[:pieces]
      { ien: entry[:ien].to_i, name: name.to_s, kind: kind, file: file.to_s, read_only: read_only == "1" }
    end

    def member_rows(taxonomy)
      iens = ",#{taxonomy[:ien]},"
      if taxonomy[:kind] == :lab
        DdrFileman.list_all(file: LAB_MEMBERS, iens: iens, fields: "@;.01I;.01E", xref: "#").map do |e|
          test_ien, test_name = e[:pieces]
          { ien: test_ien.to_i, name: test_name.to_s }
        end
      else
        DdrFileman.list_all(file: CODE_MEMBERS, iens: iens, fields: "@;.01;.02;.03E", xref: "#").map do |e|
          low, high, system = e[:pieces]
          { low: low.to_s.strip, high: high.to_s.strip, code_system: system.to_s.empty? ? nil : system.to_s }
        end
      end
    end
  end
end
