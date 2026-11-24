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
  # => [{ dfn:, name:, dob:, sex:, hrn:, sensitive: }, ...] in RPMS's order, one row per
  # patient; [] is no match. These RPCs write no error rows (an empty reply is
  # a real no match, as DOBLKP answers for a date nobody was born on), so a
  # refusal is the client's raise, never an empty list.
  #
  # The lookups answer DFN^NAME (LISTALL) or DFN^NAME^<one display piece>, and
  # none carries sex, so each row's identifiers come from a second read, BEHOPTCX
  # PTINFO (PTINFO^BEHOPTCX, the chart banner's): dob from piece 3 (a Date), sex
  # from piece 2, hrn from piece 11 (the HRN at the user's division). A search
  # makes one or two lookup calls, then one PTINFO call per patient listed: at
  # most NAME_PAGE (44) for a name. PTINFO is sent the DFN alone, so it does not
  # record the patient as the user's last selection (its SLCT argument), and its
  # sensitive-record check (ISSENS) logs nothing. A row shows what PTINFO shows
  # this user, and no more: its SSN piece is always XXX-XX-XXXX, and it is not
  # kept. sensitive is PTINFO piece 9, PTSEC^DGSEC4's code for this user, as
  # Patient.brief_header reads it (#946): true means the host runs the stock
  # sensitive-record flow (DgSensitive.check_access) before it opens the chart
  # (S-CHT-01.4). A patient PTINFO no longer finds keeps its row with nil
  # identifiers.
  module PatientSelection
    extend self
    extend Shape::Declarable

    # LISTALL NEWs its own MAX (BEHOPTPL.m:44), so it always answers 44 names.
    NAME_PAGE = 44

    def find(text)
      query = text.to_s.strip
      return [] if query.empty?

      rows = identifier_rows(query) || names_from(query)
      rows.uniq { |row| row[:dfn] }.map { |row| with_identifiers(row) }
    end
    shape :find, resource: "patient-selections", verb: "GET", path: "/patient-selections"

    private

    def with_identifiers(row)
      info = DataMapper.patient_ptinfo.fetch_one(row[:dfn].to_s)
      row.merge(dob: info && FilemanDateParser.parse_date(info[:dob_raw]),
                sex: present(info && info[:sex]), hrn: present(info && info[:mrn]),
                sensitive: info ? info[:sensitive_code].to_i.positive? : nil)
    end

    def present(value) = value.to_s.strip.empty? ? nil : value.to_s.strip

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
