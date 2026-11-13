# frozen_string_literal: true

require_relative "../shape"
require_relative "../context_scope"
require_relative "ddr_fileman"

module RpmsRpc
  # A facility's AG registration settings: REGISTRATION PARAMETERS (#9009061,
  # global ^AGFAC), one entry per facility, its IEN the facility's INSTITUTION
  # (#4) IEN, which is DUZ(2) for the signed-on user's division.
  #
  # Two things live there, and AG's own screens read both:
  #
  # - The "Ask for ..." switches on the 0-node (fields 1 to 28, each a YES/NO
  #   set of codes) and field 2101 INSURER SEQUENCING REQ'D. AG's GUI reads
  #   them by piece (AGGETRIG reads pieces 2, 3 and 9 to decide whether blood
  #   quantum, enrollment number and other tribes are asked; AGGPTLKP reads
  #   pieces 11 and 12 for the extra identifiers and deceased patients in its
  #   look-up; AGGPTTRG reads piece 13, limited DOB editing).
  # - The site-specific mandatory fields: field 1101 MANDATORY FIELDS (SITE),
  #   a multiple (#9009061.11) whose .01 SITE REQUIRED FILE names a file, and
  #   whose own multiple REQUIRED FIELD NAME (#9009061.1101) holds .01 REQUIRED
  #   FIELD (the field's LABEL, as ^DD holds it) and .02 REQUIRED? (1 YES,
  #   0 NO). $$ISREQ^AGFLDREQ(file,field) answers from it by label for
  #   DUZ(2), and quits 0 when the file or the field is not listed; AG GET
  #   WINDOW DEFINITION (AGGWDEF) marks a window field required the same way.
  #   BPRM reads the same rows (BMW.Required_field_name_9009061_11C9009061_1101).
  #
  # The reads are DDR LISTER and DDR GETS ENTRY DATA, the stock FileMan reads,
  # registered in CIAV VUECENTRIC; each call binds it and restores the caller's
  # option. A failed read raises Client::RpcError: it is never read as "no
  # switches set" or "nothing required".
  module RegistrationParameters
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"

    FILE = "9009061"
    MANDATORY_FILE = "9009061.11"
    MANDATORY_FIELD_FILE = "9009061.1101"

    # The switches, by field number of #9009061 (each 0-node piece is the
    # field number plus one, ^DD(9009061,n,0)). The ones that shape the
    # registration screens; the face sheet, embossed card, tape export, SSN
    # letter, VQ/270 and MPI settings are not read.
    SWITCHES = {
      blood_quantum: "1",                 # Ask for TRIBAL BLOOD QUANTUM
      enrollment_number: "2",             # Ask TRIBAL ENROLLMENT NUMBER
      other_names: "3",                   # Ask for OTHER NAMES
      medicaid: "4",                      # Ask for MEDICAID DATA
      private_insurance: "5",             # Ask for PRIVATE INSURANCE DATA
      directions_to_home: "6",            # Ask DIRECTIONS TO PAT.'S HOME
      next_of_kin: "7",                   # Ask for NEXT OF KIN
      other_tribes: "8",                  # Ask for OTHER TRIBES
      additional_registration_info: "9",  # Ask for ADDITIONAL REG. INFO.
      extra_identifiers_in_lookup: "10",  # Add extra IDENTIFIERS to SCAN
      deceased_in_lookups: "11",          # DECEASED PATIENTS in look-ups
      limited_dob_editing: "12",          # Limited DOB editing
      official_registering_facility: "20", # OFFICIAL REGISTERING FACILITY
      display_household: "23",            # Disp # HSHLD,HSHLD INC
      link_aob_to_roi: "26",              # LINK AOB TO ROI FIELD
      display_migrant_worker: "27",       # Disp MIGRANT WORKER
      display_homeless: "28",             # Disp HOMELESS
      insurer_sequencing_required: "2101" # INSURER SEQUENCING REQ'D (0/1)
    }.freeze

    # A facility's settings:
    #
    #   { facility: 7819, on_file: true,
    #     switches: { blood_quantum: false, next_of_kin: true, ..., insurer_sequencing_required: nil },
    #     mandatory_fields: [ { file: "2", field: "RACE", required: true }, ... ] }
    #
    # A switch is true (YES), false (NO) or nil (not set). mandatory_fields
    # lists the rows the site has, in the order RPMS holds them, required
    # true or false (an unanswered REQUIRED? reads false, as ISREQ does).
    # A facility with no #9009061 entry answers on_file: false, every switch
    # nil and no mandatory fields: the caller decides what an unset site means.
    # A failed read raises Client::RpcError.
    def for_facility(facility_ien)
      facility = facility_ien.to_s
      raise ArgumentError, "facility_ien must be a positive integer" unless facility.match?(/\A[1-9]\d*\z/)

      unless on_file?(facility)
        return { facility: facility.to_i, on_file: false, switches: SWITCHES.keys.to_h { |key| [ key, nil ] }, mandatory_fields: [] }
      end

      { facility: facility.to_i, on_file: true, switches: switches(facility), mandatory_fields: mandatory_fields(facility) }
    end
    shape :for_facility, resource: "registration-parameters", verb: "GET", path: "/facilities/{facility_ien}/registration-parameters"

    # Whether the site requires the field, by file number and the field's
    # label, from what for_facility returned: AGFLDREQ's ISREQ rule. A field
    # the site does not list is not required.
    def required?(parameters, file, label)
      parameters[:mandatory_fields].any? { |row| row[:file] == file.to_s && row[:field] == label.to_s && row[:required] }
    end

    private

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def on_file?(facility)
      list(FILE, "@;.01I").any? { |entry| entry[:ien] == facility }
    end

    def switches(facility)
      got = in_context { DdrFileman.gets_entry(file: FILE, iens: "#{facility},", fields: SWITCHES.values.join(";"), flags: "I") }
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{FILE} #{facility}" if got.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA refused ##{FILE} #{facility}" if got[:error]

      SWITCHES.transform_values do |field|
        case got[:fields].dig(field, :internal).to_s
        when "Y", "1" then true
        when "N", "0" then false
        end
      end
    end

    def mandatory_fields(facility)
      list(MANDATORY_FILE, "@;.01I", iens: ",#{facility},").flat_map do |file_entry|
        file = file_entry[:pieces].first.to_s
        list(MANDATORY_FIELD_FILE, "@;.01;.02I", iens: ",#{file_entry[:ien]},#{facility},").map do |entry|
          label, required = entry[:pieces]
          { file: file, field: label.to_s, required: required == "1" }
        end
      end
    end

    # Every entry DDR LISTER lists, read on from each MORE marker. These files
    # are small (one entry per facility, a few dozen fields), and their B
    # index values are unique within a parent, so resuming from the value is
    # safe.
    def list(file, fields, iens: nil)
      out = []
      from = nil
      loop do
        page = in_context { DdrFileman.lister(file: file, iens: iens, fields: fields, flags: "IP", max: 100, from: from) }
        raise Client::RpcError, "DDR LISTER gave no reply for file #{file}" if page.nil?
        raise Client::RpcError, "DDR LISTER refused file #{file}" if page[:error]

        out.concat(page[:entries])
        return out unless page[:more]

        from = page[:more][:value]
      end
    end
  end
end
