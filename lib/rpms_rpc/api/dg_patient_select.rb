# frozen_string_literal: true

require_relative "../client"
require_relative "../mappings"
require_relative "../fileman_date_parser"
require_relative "../shape"

module RpmsRpc
  # The ADT patient-selection calls a VueCentric session makes under its
  # sign-on option, CIAV VUECENTRIC (DGWPT, DGWPT1 and DPTLK6 in Registration):
  # whether a patient has died, how sensitive the record is, the selection
  # itself and the user's last-selected patient, the clinic date ranges a
  # patient list offers, the primary care assignment, and whether a means
  # test is required. Every registration and scheduling role signs on with
  # CIAV VUECENTRIC, so none of them is refused these.
  module DgPatientSelect
    extend self
    extend Shape::Declarable

    # Each RPC's mapping (lib/rpms_rpc/mappings/stock_vista.rb) binds CIAV
    # VUECENTRIC, the one option the build lists them in (ADR 0011).

    # DIEDON^DGWPT: the patient's DATE OF DEATH (#2 .351) as a Date, or nil
    # when none is on file (the routine answers 0).
    def date_of_death(dfn)
      value = single(:dgwpt_died_on, dfn.to_s)
      value.to_i.positive? ? FilemanDateParser.parse_date(value.split(".").first) : nil
    end
    shape :date_of_death, resource: "patients", verb: "GET", path: "/patients/{dfn}/date-of-death"

    # SELCHK^DGWPT over $$EN1^DGQPT2: 0 when the record is not sensitive, 1
    # when it is, 2 when the patient is the signed-on user's own record.
    def sensitivity(dfn)
      Integer(single(:dgwpt_sensitive_check, dfn.to_s), exception: false)
    end
    shape :sensitivity, resource: "patients", verb: "GET", path: "/patients/{dfn}/sensitivity"

    # SELECT^DGWPT: selects the patient for the session and answers the
    # banner pieces { name:, sex:, dob:, ssn:, location_ien:, location:,
    # room_bed:, cwad:, sensitive:, admitted:, age: }. It also records the
    # patient as the user's last selected (^DISV), which #last_selected reads.
    def select(dfn)
      pieces = single(:dgwpt_select, dfn.to_s).split("^", -1)
      return nil if pieces.first.to_s.empty?

      { name: pieces[0], sex: blank(pieces[1]), dob: FilemanDateParser.parse_date(pieces[2].to_s), ssn: blank(pieces[3]),
        location_ien: blank(pieces[4]), location: blank(pieces[5]), room_bed: blank(pieces[6]), cwad: blank(pieces[7]),
        sensitive: pieces[8].to_s == "1", admitted: blank(pieces[9]), age: pieces[14].to_i }
    end
    shape :select, resource: "patients", verb: "POST", path: "/patients/{dfn}/select"

    # TOP^DGWPT: the user's last-selected patient as { dfn:, name: }, nil when none.
    def last_selected
      line = lines(:dgwpt_last_selected).first.to_s
      dfn, name = line.split("^", 2)
      dfn.to_i.positive? ? { dfn: dfn.to_i, name: name.to_s } : nil
    end
    shape :last_selected, resource: "patients", verb: "GET", path: "/patients/last-selected"

    # CLINRNG^DGWPT: the date ranges a clinic patient list offers, as
    # { range: "T-7;T", label: "Past Week" }.
    def clinic_date_ranges
      lines(:dgwpt_clinic_ranges).filter_map do |line|
        range, label = line.split("^", 2)
        { range: range, label: label.to_s } unless range.to_s.empty?
      end
    end
    shape :clinic_date_ranges, resource: "patients", verb: "GET", path: "/patients/clinic-date-ranges"

    # PRCARE^DGWPT1: the patient's primary care team, primary care provider
    # and attending, each nil when not assigned.
    def primary_care(dfn)
      team, provider, attending = single(:dgwpt_primary_care, dfn.to_s).split("^", -1)
      { team: blank(team), provider: blank(provider), attending: blank(attending) }
    end
    shape :primary_care, resource: "patients", verb: "GET", path: "/patients/{dfn}/primary-care"

    # GUIMT^DPTLK6: whether the patient must complete a means test (the
    # routine answers 1), as registration asks before it saves.
    def means_test_required?(dfn)
      single(:dg_means_test_required, dfn.to_s) == "1"
    end
    shape :means_test_required?, resource: "patients", verb: "GET", path: "/patients/{dfn}/means-test-required"

    private

    # The reply's lines, read under the mapping's option (DataMapper#lines!).
    def lines(mapping_name, *params) = DataMapper[mapping_name].lines!(*params).map(&:to_s)

    def single(mapping_name, *params) = lines(mapping_name, *params).first.to_s.strip

    def blank(value) = value.to_s.empty? ? nil : value.to_s
  end
end
