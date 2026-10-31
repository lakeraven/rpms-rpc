# frozen_string_literal: true

require_relative "../shape"

module RpmsRpc
  # Finding a patient the way VueCentric's patient selection does (BEHOPTPL,
  # IHS EHR): what was typed picks the lookup, and each lists only active
  # patients. A clinician's search, unlike AGG LOOKUP PATIENTS, which RPMS
  # runs for registration users only.
  #
  #   find("MOUSE")       names from MOUSE on (BEHOPTPL LISTALL)
  #   find("9999")        last four of the SSN, and an HRN of 9999
  #   find("M9999")       last-name initial plus last four (BS5)
  #   find("1001")        an HRN at the user's division (BEHOPTPL HRNLKP)
  #   find("2/14/1910")   a date of birth (BEHOPTPL DOBLKP); 1910-02-14 too
  #
  # => [{ dfn:, name: }, ...] in RPMS's order, one row per patient; [] is no
  # match. These RPCs write no error rows (an empty reply is a real no match,
  # as DOBLKP answers for a date nobody was born on), so a refusal is the
  # client's raise, never an empty list.
  module PatientSelection
    extend self
    extend Shape::Declarable

    # LISTALL NEWs its own MAX (BEHOPTPL.m:44), so it always answers 44 names.
    NAME_PAGE = 44

    def find(text)
      query = text.to_s.strip
      return [] if query.empty?

      rows = identifier_rows(query) || names_from(query)
      rows.uniq { |row| row[:dfn] }
    end
    shape :find, resource: "patient-selections", verb: "GET", path: "/patient-selections"

    private

    # The lookup an identifier picks, or nil when what was typed is a name.
    def identifier_rows(query)
      date = date_of_birth(query)
      return DataMapper.patient_selection_dob.fetch_many("B#{date}") if date

      case query
      when /\A\d{4}\z/
        DataMapper.patient_selection_ssn.fetch_many(query) + DataMapper.patient_selection_hrn.fetch_many(query)
      when /\A[A-Za-z]\d{4}\z/, /\A\d{3}-?\d{2}-?\d{4}\z/ then DataMapper.patient_selection_ssn.fetch_many(query)
      when /\A\d+\z/ then DataMapper.patient_selection_hrn.fetch_many(query)
      end
    end

    # LISTALL pages the index from FROM on, so keep the names that begin with
    # what was typed.
    def names_from(query)
      DataMapper.patient_selection_names.fetch_many(name_from(query), "1", NAME_PAGE.to_s)
                .select { |row| row[:name].to_s.upcase.start_with?(query.upcase) }
    end

    # m/d/yyyy as typed, or an ISO date, as ^%DT reads it ("B" + m/d/yyyy).
    def date_of_birth(query)
      if (m = query.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}))
        "#{m[1].to_i}/#{m[2].to_i}/#{m[3]}"
      elsif (m = query.match(/\A(\d{4})-(\d{2})-(\d{2})\z/))
        "#{m[2].to_i}/#{m[3].to_i}/#{m[1]}"
      end
    end

    # $O from the name itself would skip a patient whose whole name was
    # typed, so start just before it: the last letter one lower, then "~".
    def name_from(query)
      upper = query.upcase
      "#{upper[0..-2]}#{(upper[-1].ord - 1).chr}~"
    end
  end
end
