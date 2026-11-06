# frozen_string_literal: true

require "date"

module RpmsRpc
  # Three registration edits no stock RPC files for a registration user
  # (rpms-ops#1055): the address history, the cell phone, and race and
  # ethnicity. Two are filed with DDR FILER under the rules of rpms-rpc#549:
  # inside AG's edit lock (Agg.editing), read before write (a failed read
  # files nothing), what AG's own screens do around the write done
  # explicitly, and a live spec that reads every write back through FileMan.
  #
  # What AG's screens do around these fields, from the FOIA source:
  # - Address history. When a clerk changes the address in AG's
  #   roll-and-scroll (ASKADD^AG3A, L10^AG3), AG copies the address into
  #   PREVIOUS MAIL ADDRESSES (#9000001.83) with UPDTHADD^AGUTILS; AG's GUI
  #   carries the same copy as ADR^AGGUL1, which nothing calls. Both copy
  #   #2 .111-.116 and .131 into .02-.08 (state as its #5 IEN; ADR^AGGUL1
  #   takes the zip from .1112 ZIP+4 when it is set) under .01 DATE CHANGED
  #   = today. BPRM (ChangeAddressCommandHandler) copies the address being
  #   REPLACED, and adds .11 DATE FROM (from #9000001 7911 ADDRESS DATE FROM)
  #   and .12 DATE TO (the date the patient moved), then files 7911 with
  #   that date for the new address. rpms-ux S-REG-21.1 asks for BPRM's
  #   form: "holds the old one, ended on the date they moved". This module
  #   files that: ADR^AGGUL1's fields and value forms, from the address as it
  #   stood before the change, plus .11, .12 and 7911.
  # - Cell phone. AG*7.1*17 edits #2 .134 with a plain ^DIE (CPH^AG3A), and
  #   BPRM with ^DIE too (AG_SetPatientCellNumberM), after it sets DFN. Both
  #   callers have DFN defined, and the field needs it: the new-style index
  #   AXENR13 on #2 .133/.134/.135 runs D EVENT^IVMPLOG(DFN). DDR FILER has
  #   no DFN, so FileMan files .134 and its .139 trigger and then stops on
  #   LVUNDEF at XECUTE+10^DIKC (seen live on 7c3119b, 2026-11-03): a write
  #   that half lands and errors. So the cell phone is read here and not
  #   filed; set_cell_phone answers :not_supported (rpms-ops#1055).
  # - Race and ethnicity. AG's page 10 (EDRACE/EDETHNIC^AGED10B) edits the
  #   RACE INFORMATION (#2.02) and ETHNICITY INFORMATION (#2.06) multiples
  #   with ^DIE, .01 and .02 METHOD OF COLLECTION (#10.3) for each. Both
  #   .01s are DINUM'd to the #10 / #10.2 entry and screen out inactive
  #   entries. Then CHKRE^AGUTL2 asks the clerk to keep either DECLINED TO
  #   ANSWER (0000-0) or UNKNOWN BY PATIENT (9999-4) or the other entries,
  #   never both: this module refuses that mix (rpms-ux S-REG-20.4) rather
  #   than asking. FileMan fires the .01 TRIGGER (.02 defaults to SELF) and
  #   ARACE (sets the historical #2 .06 when it is empty).
  # - Eligibility modifiers. AG's roll-and-scroll (ADDMOD^AGED11A) adds a
  #   reason to ELIGIBILITY MODIFIERS (#9000001.03401), DINUM'd to its
  #   #9000030 entry, picking only from the entries whose .02 TYPE is the
  #   patient's eligibility status. AG's GUI has no window for it, so no
  #   stock RPC files it for a registration user: filed here with DDR FILER,
  #   under the same rules.
  # - AG's edit pages end with UPDATE1^AGED: #9000001 .03 DATE OF LAST REG.
  #   UPDATE and .16 DATE OF LAST UPDATE today, .12 USER-LAST UPDATE the
  #   DUZ. The race and ethnicity write files those in the same call, as
  #   PatientApplication does. The address history rides on
  #   AGG UPDATE PATIENT, which stamps .03 and .12 itself (AGGPTUPD.m:130).
  module Registration
    ADDRESS_HISTORY_FILE = "9000001.83"
    ADDRESS_DATE_FROM_FIELD = "7911"
    # #2 fields read before and after an address change: date of birth, the
    # address lines, city, state, zip, ZIP+4 and the home phone.
    ADDRESS_READ_FIELDS = ".03;.111;.112;.113;.114;.115;.116;.1112;.131"
    ADDRESS_COMPARED = %w[.111 .112 .113 .114 .115 .116 .1112 .131].freeze
    # #9000001.83 field => the #2 field ADR^AGGUL1 copies into it.
    ADDRESS_HISTORY_COPY = {
      ".02" => ".111", ".03" => ".112", ".04" => ".113", ".05" => ".114",
      ".06" => ".115", ".07" => :zip, ".08" => ".131"
    }.freeze
    ADDRESS_HISTORY_FIELDS = "@;.01I;.02;.03;.04;.05;.06E;.07;.08;.11I;.12I"
    EARLIEST_DATE = Date.new(1871, 1, 1)

    ELIGIBILITY_MODIFIER_FILE = "9000030"
    PATIENT_MODIFIER_FILE = "9000001.03401"
    ELIGIBILITY_STATUSES = %w[C D I P].freeze # #9000001 1112

    CELL_PHONE_FILE = "2"
    CELL_PHONE_FIELD = ".134"

    RACE_FILE = "2.02"
    ETHNICITY_FILE = "2.06"
    RACE_CODE_FILE = "10"
    ETHNICITY_CODE_FILE = "10.2"
    COLLECTION_METHOD_FILE = "10.3"
    # #10 / #10.2 field 3 HL7 VALUE of DECLINED TO ANSWER and UNKNOWN BY
    # PATIENT, as CHKRE^AGUTL2 tests them.
    DECLINED_OR_UNKNOWN = %w[0000-0 9999-4].freeze
    # The races and ethnicities a clerk picks from: active (200 INACTIVE not set,
    # the .01 input transform's own screen) and carrying an
    # ABBREVIATION, which only the OMB categories have.
    CHOICE_SCREEN = "I '$G(^(.02)),$P(^(0),U,2)'=\"\""

    # The addresses the patient used to live at (rpms-ux S-REG-21.1),
    # newest first, from PREVIOUS MAIL ADDRESSES (#9000001.83):
    #   [{ ien:, changed_on: Date, line1:, line2:, line3:, city:, state: name,
    #      zip:, phone:, lived_from: Date or nil, lived_to: Date or nil }]
    # Raises Client::RpcError when the patient has no #9000001 entry or the
    # list cannot be read, so a failed read is never "no history".
    def address_history(dfn)
      id = patient_dfn(dfn)
      raise ArgumentError, "a positive DFN is required" unless id

      listed = in_context do
        require_ihs_patient!(id)
        DdrFileman.lister(file: ADDRESS_HISTORY_FILE, iens: ",#{id},", fields: ADDRESS_HISTORY_FIELDS, flags: "IP")
      end
      raise Client::RpcError, "DDR LISTER gave no reply for ##{ADDRESS_HISTORY_FILE}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{ADDRESS_HISTORY_FILE}" if listed[:error] || listed[:more]

      listed[:entries].map { |entry| address_history_row(entry) }.sort_by { |row| -row[:ien] }
    end
    shape :address_history, resource: "registrations", verb: "GET",
          path: "/patients/{dfn}/registrations/address-history"

    # Change the address, phones or email through AG's Address window, the
    # way update does, and keep the address being replaced (rpms-ux
    # S-REG-21.1). attrs are the update attributes of the Address window;
    # moved_on is the date the patient moved (default today).
    #
    # All of it runs inside one Agg.editing:
    # 1. read #2 (date of birth and the address) and #9000001 7911; a failed
    #    read files nothing;
    # 2. AGG UPDATE PATIENT files the Address window (AG's own update and
    #    checks, as update);
    # 3. read the address again. When the lines, city, state, zip or home
    #    phone changed and the old address was not empty, one DDR FILER ADD
    #    files the old address as a new #9000001.83 entry (.01 today, .02-.08
    #    as ADR^AGGUL1 copies them, .11 the old 7911 when set, .12 moved_on)
    #    and moved_on into #9000001 7911.
    #
    # Refused before anything is locked (sends no RPC): an attribute outside
    # the Address window (ArgumentError for an unknown one, as update),
    # moved_on not a Date, in the future or before 1871. Refused after the
    # read and before any write: moved_on before the date of birth or before
    # the old address's 7911.
    #
    # Returns update's answers, with history: true when the old address was
    # kept and false when the address itself did not change; or
    # { success: false, error: :partial, message: } when the Address window
    # was filed and the history was not (the message says so); nil when AGG
    # UPDATE PATIENT gave no reply.
    def change_address(dfn, moved_on: Date.today, **attrs)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id

      refused = refuse_moved_on(moved_on) || refuse_outside_address(attrs)
      return refused if refused

      params_by_window = update_params(attrs)
      return { success: false, error: :no_fields, message: "no attributes to update" } if params_by_window.empty?

      refused = validate_update(id.to_i, params_by_window)
      return refused if refused

      Agg.editing(dfn: id) { change_address_locked(id, moved_on, params_by_window) }
    end
    shape :change_address, resource: "registrations", verb: "PUT",
          path: "/patients/{dfn}/registrations/address"

    # The patient's cell phone, #2 .134 PHONE NUMBER [CELLULAR]: the stored
    # text, "" when none is on file. Raises Client::RpcError on a failed read.
    def cell_phone(dfn)
      id = patient_dfn(dfn)
      raise ArgumentError, "a positive DFN is required" unless id

      read = in_context { read_internal_field(CELL_PHONE_FILE, "#{id},", CELL_PHONE_FIELD) }
      raise Client::RpcError, read[:message] if read.is_a?(Hash)

      read
    end
    shape :cell_phone, resource: "registrations", verb: "GET",
          path: "/patients/{dfn}/registrations/cell-phone"

    # Not supported (rpms-ux S-REG-21.5, rpms-ops#1055). No stock RPC files
    # #2 .134, and DDR FILER cannot: the AXENR13 index on the field runs
    # EVENT^IVMPLOG(DFN), and DDR has no DFN, so FileMan files the number
    # and then errors (see the module comment). Sends no RPC.
    def set_cell_phone(_dfn, _phone)
      not_supported("The cell phone (#2 .134) cannot be filed over the broker: its AXENR13 index " \
                    "needs DFN, which DDR FILER does not define (rpms-ops#1055).")
    end

    # The races and ethnicities a clerk picks from (CHOICE_SCREEN), by name:
    #   { races: [{ ien:, name: }], ethnicities: [...], methods: [{ ien:, name: }] }
    # methods are the METHOD OF COLLECTION entries (#10.3). Raises
    # Client::RpcError when a list cannot be read.
    def race_ethnicity_choices
      in_context do
        {
          races: choice_list(RACE_CODE_FILE, CHOICE_SCREEN),
          ethnicities: choice_list(ETHNICITY_CODE_FILE, CHOICE_SCREEN),
          methods: choice_list(COLLECTION_METHOD_FILE, nil)
        }
      end
    end
    shape :race_ethnicity_choices, resource: "registrations", verb: "GET",
          path: "/registrations/race-ethnicity-choices"

    # The patient's races and ethnicities, each with how it was collected:
    #   { races: [{ ien:, name:, method: ien or nil, method_name: }], ethnicities: [...] }
    # ien is the #10 / #10.2 entry (the multiples are DINUM'd to it). Raises
    # Client::RpcError on a failed read.
    def race_ethnicity(dfn)
      id = patient_dfn(dfn)
      raise ArgumentError, "a positive DFN is required" unless id

      in_context do
        require_ihs_patient!(id)
        { races: race_rows(RACE_FILE, id), ethnicities: race_rows(ETHNICITY_FILE, id) }
      end
    end
    shape :race_ethnicity, resource: "registrations", verb: "GET",
          path: "/patients/{dfn}/registrations/race-ethnicity"

    # Record the patient's races and ethnicities (rpms-ux S-REG-20.2 to
    # 20.4): races: and ethnicities: are [{ code: ien, method: ien }], code a
    # #10 / #10.2 entry and method a #10.3 entry. The lists replace what is
    # on file: an entry not listed is deleted, a listed one keeps its
    # sub-entry and gets the method given.
    #
    # Refused with no RPC (:invalid): an empty list (the message names
    # race or ethnicity, S-REG-20.3), a code listed twice, a missing or
    # non-integer code or method. Inside Agg.editing, read before write:
    # each code is read (#10 / #10.2 .01, 200 INACTIVE, 3 HL7 VALUE)
    # and each method (#10.3 .01); an unknown or inactive code or an
    # unknown method is :invalid, and DECLINED TO ANSWER or UNKNOWN BY
    # PATIENT listed with any other entry is :invalid (S-REG-20.4). The
    # multiples are listed; a failed read files nothing. Then one DDR FILER
    # ADD (UPDATE^DIE): "@" for each entry dropped, .02 for each kept, "+n"
    # DINUM'd to the code with .01 and .02 for each new one, and the
    # UPDATE1^AGED stamp. Returns { success: true }, :filer_failed, or nil
    # when DDR FILER gives no reply.
    def set_race_ethnicity(dfn, races:, ethnicities:)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id

      refused = refuse_race_list(races, "race") || refuse_race_list(ethnicities, "ethnicity")
      return refused if refused

      Agg.editing(dfn: id) { in_context { write_race_ethnicity(id, races, ethnicities) } }
    end
    shape :set_race_ethnicity, resource: "registrations", verb: "PUT",
          path: "/patients/{dfn}/registrations/race-ethnicity"

    # The reasons a clerk may give for an eligibility status (rpms-ux
    # S-REG-07.3): [{ ien:, name: }] from #9000030, as ADDMOD^AGED11A screens
    # them. Raises Client::RpcError on a failed read.
    def eligibility_modifier_choices(status)
      raise ArgumentError, "status: takes one of #{ELIGIBILITY_STATUSES.join(', ')}" unless ELIGIBILITY_STATUSES.include?(status)

      in_context { choice_list(ELIGIBILITY_MODIFIER_FILE, modifier_screen(status)) }
    end
    shape :eligibility_modifier_choices, resource: "registrations", verb: "GET",
          path: "/registrations/eligibility-modifier-choices"

    # The patient's reasons: [{ ien:, name: }], ien the #9000030 entry (the
    # multiple is DINUM'd to it). Raises Client::RpcError on a failed read.
    def eligibility_modifiers(dfn)
      id = patient_dfn(dfn)
      raise ArgumentError, "a positive DFN is required" unless id

      in_context { modifier_rows(id) }
    end
    shape :eligibility_modifiers, resource: "registrations", verb: "GET",
          path: "/patients/{dfn}/registrations/eligibility-modifiers"

    # Add one reason (S-REG-07.3). Inside Agg.editing, read before write: a
    # reason that does not belong to the patient's status, or one already on
    # file, is :invalid and files nothing. Returns { success: true },
    # :filer_failed, or nil when DDR FILER gives no reply.
    def add_eligibility_modifier(dfn, modifier)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id
      return invalid("a reason is required") unless positive_integer?(modifier)

      Agg.editing(dfn: id) { in_context { write_eligibility_modifier(id, modifier) } }
    end
    shape :add_eligibility_modifier, resource: "registrations", verb: "POST",
          path: "/patients/{dfn}/registrations/eligibility-modifier"

    # Remove one reason. :not_found when the patient does not have it.
    def remove_eligibility_modifier(dfn, modifier)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id

      Agg.editing(dfn: id) do
        in_context do
          next not_found("no such reason on file") unless modifier_rows(id).any? { |row| row[:ien] == modifier }

          stamp = update1_stamp_rows(id)
          next stamp if stamp.is_a?(Hash)

          rows = [ edit_row(PATIENT_MODIFIER_FILE, ".01", "#{modifier},#{id},", "@") ]
          filer_outcome(DdrFileman.filer(mode: "ADD", rows: rows + stamp))
        end
      end
    end
    shape :remove_eligibility_modifier, resource: "registrations", verb: "DELETE",
          path: "/patients/{dfn}/registrations/eligibility-modifier"

    private

    def address_history_row(entry)
      pieces = entry[:pieces] || []
      changed = FilemanDateParser.parse_date(pieces[0].to_s)
      raise Client::RpcError, "DDR LISTER returned a previous address with no date changed" unless changed

      { ien: entry[:ien].to_i, changed_on: changed,
        line1: pieces[1].to_s, line2: pieces[2].to_s, line3: pieces[3].to_s, city: pieces[4].to_s,
        state: pieces[5].to_s, zip: pieces[6].to_s, phone: pieces[7].to_s,
        lived_from: FilemanDateParser.parse_date(pieces[8].to_s),
        lived_to: FilemanDateParser.parse_date(pieces[9].to_s) }
    end

    def refuse_moved_on(moved_on)
      return invalid("the date they moved must be a date") unless moved_on.instance_of?(Date)
      return invalid("the date they moved cannot be in the future") if moved_on > Date.today

      invalid("the date they moved cannot be before 1871") if moved_on < EARLIEST_DATE
    end

    def refuse_outside_address(attrs)
      outside = attrs.keys.select { |key| UPDATE_ATTRIBUTES.key?(key) && UPDATE_ATTRIBUTES[key].window != WINDOW_ADDRESS }
      invalid("change_address files the Address window only, not #{outside.join(', ')}") unless outside.empty?
    end

    def change_address_locked(id, moved_on, params_by_window)
      before = in_context { read_address(id) }
      return before if before.key?(:success)

      refused = refuse_moved_on_for(before, moved_on)
      return refused if refused

      updated = update_windows(id.to_i, params_by_window)
      return updated unless updated && updated[:success]

      after = in_context { read_address(id) }
      return address_partial(after[:message]) if after.key?(:success)
      return updated.merge(history: false) if same_address?(before, after) || empty_address?(before)

      filed = in_context { DdrFileman.filer(mode: "ADD", rows: address_history_rows(id, before, moved_on)) }
      return address_partial("RPMS gave no reply") if filed.nil?
      return address_partial(Array(filed[:errors]).join("\n")) unless filed[:success]

      updated.merge(history: true)
    end

    # #2 date of birth and address (internal, with .1112's external form)
    # and #9000001 7911, or a :lookup_failed / :not_found hash.
    def read_address(id)
      read = DdrFileman.gets_entry(file: "2", iens: "#{id},", fields: ADDRESS_READ_FIELDS, flags: "IE")
      return lookup_failed("DDR GETS ENTRY DATA gave no reply for #2") if read.nil?
      return lookup_failed("DDR GETS ENTRY DATA gave a malformed reply for #2") if read[:malformed]
      return not_found("no #2 entry at #{id},") if read[:error]

      fields = read[:fields]
      missing = ADDRESS_READ_FIELDS.split(";").reject { |field| fields.key?(field) }
      return lookup_failed("DDR GETS ENTRY DATA gave no #{missing.join(', ')} row for #2") unless missing.empty?

      from = read_internal_field(PATIENT_FILE, "#{id},", ADDRESS_DATE_FROM_FIELD)
      return from if from.is_a?(Hash)

      { values: fields.transform_values { |value| value[:internal].to_s },
        zip4: fields[".1112"][:external].to_s, date_from: from }
    end

    def refuse_moved_on_for(before, moved_on)
      dob = FilemanDateParser.parse_date(before[:values][".03"])
      return invalid("the date they moved cannot be before the date of birth") if dob && moved_on < dob

      from = FilemanDateParser.parse_date(before[:date_from])
      invalid("the date they moved cannot be before they moved to the old address (#{from})") if from && moved_on < from
    end

    def same_address?(before, after)
      ADDRESS_COMPARED.all? { |field| before[:values][field] == after[:values][field] }
    end

    def empty_address?(before)
      ADDRESS_COMPARED.all? { |field| before[:values][field].empty? }
    end

    def address_history_rows(id, before, moved_on)
      node = "+1,#{id},"
      moved = FilemanDateParser.to_fileman(moved_on)
      rows = [ edit_row(ADDRESS_HISTORY_FILE, ".01", node, FilemanDateParser.to_fileman(Date.today)) ]
      ADDRESS_HISTORY_COPY.each do |field, source|
        value = source == :zip ? history_zip(before) : before[:values][source]
        rows << edit_row(ADDRESS_HISTORY_FILE, field, node, value) unless value.empty?
      end
      rows << edit_row(ADDRESS_HISTORY_FILE, ".11", node, before[:date_from]) unless before[:date_from].empty?
      rows << edit_row(ADDRESS_HISTORY_FILE, ".12", node, moved)
      rows << edit_row(PATIENT_FILE, ADDRESS_DATE_FROM_FIELD, "#{id},", moved)
    end

    # ADR^AGGUL1: .1112 ZIP+4 in its external form when set, else .116.
    def history_zip(before)
      before[:zip4].empty? ? before[:values][".116"] : before[:zip4]
    end

    def address_partial(reason)
      { success: false, error: :partial, filed_windows: [ WINDOW_ADDRESS ],
        message: "The address was saved, but the previous address was not kept: #{reason}" }
    end

    # UPDATE1^AGED's FileMan part: #9000001 .03 and .16 today, .12 DUZ.
    def update1_stamp_rows(id)
      duz = signed_on_duz
      return invalid("a signed-on DUZ is required") unless duz

      today = FilemanDateParser.to_fileman(Date.today)
      [ edit_row(PATIENT_FILE, ".03", "#{id},", today), edit_row(PATIENT_FILE, ".12", "#{id},", duz),
        edit_row(PATIENT_FILE, ".16", "#{id},", today) ]
    end

    def modifier_screen(status) = "I $P(^(0),U,2)=\"#{status}\""

    def modifier_rows(id)
      listed = DdrFileman.lister(file: PATIENT_MODIFIER_FILE, iens: ",#{id},", fields: "@;.01E", flags: "IP")
      raise Client::RpcError, "DDR LISTER gave no reply for ##{PATIENT_MODIFIER_FILE}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{PATIENT_MODIFIER_FILE}" if listed[:error] || listed[:more]

      listed[:entries].map { |entry| { ien: entry[:ien].to_i, name: entry[:pieces][0].to_s } }
    end

    def write_eligibility_modifier(id, modifier)
      read = DdrFileman.gets_entry(file: PATIENT_FILE, iens: "#{id},", fields: FIELD_ELIGIBILITY, flags: "I")
      return lookup_failed("DDR GETS ENTRY DATA gave no reply for ##{PATIENT_FILE}") if read.nil?
      return not_found("no ##{PATIENT_FILE} entry at #{id},") if read[:error]

      status = read[:fields].dig(FIELD_ELIGIBILITY, :internal).to_s
      return invalid("record the eligibility status first") unless ELIGIBILITY_STATUSES.include?(status)
      return invalid("is not a reason for this eligibility status") unless
        choice_list(ELIGIBILITY_MODIFIER_FILE, modifier_screen(status)).any? { |row| row[:ien] == modifier }
      return invalid("is already recorded") if modifier_rows(id).any? { |row| row[:ien] == modifier }

      stamp = update1_stamp_rows(id)
      return stamp if stamp.is_a?(Hash)

      rows = [ { file: PATIENT_MODIFIER_FILE, field: ".01", iens: "+1,#{id},", value: modifier.to_s } ]
      filer_outcome(DdrFileman.filer(mode: "ADD", rows: rows + stamp, iens: { 1 => modifier }))
    end

    def choice_list(file, screen)
      listed = DdrFileman.lister(file: file, fields: "@;.01", flags: "IP", screen: screen)
      raise Client::RpcError, "DDR LISTER gave no reply for ##{file}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{file}" if listed[:error] || listed[:more]

      listed[:entries].map { |entry| { ien: entry[:ien].to_i, name: entry[:pieces][0].to_s } }
    end

    def race_rows(file, id)
      listed = DdrFileman.lister(file: file, iens: ",#{id},", fields: "@;.01E;.02I;.02E", flags: "IP")
      raise Client::RpcError, "DDR LISTER gave no reply for ##{file}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{file}" if listed[:error] || listed[:more]

      listed[:entries].map do |entry|
        pieces = entry[:pieces] || []
        { ien: entry[:ien].to_i, name: pieces[0].to_s, method: int_or_nil(pieces[1]), method_name: pieces[2].to_s }
      end
    end

    def int_or_nil(value) = value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : nil

    def refuse_race_list(list, what)
      return invalid("record at least one #{what}") unless list.is_a?(Array) && !list.empty?
      unless list.all? { |item| item.is_a?(Hash) && positive_integer?(item[:code]) && positive_integer?(item[:method]) }
        return invalid("each #{what} needs a code and how it was collected")
      end

      invalid("the same #{what} is listed twice") unless list.map { |item| item[:code] }.uniq.size == list.size
    end

    def write_race_ethnicity(id, races, ethnicities)
      checked = check_race_codes(races, RACE_CODE_FILE, "race") ||
                check_race_codes(ethnicities, ETHNICITY_CODE_FILE, "ethnicity") ||
                check_collection_methods((races + ethnicities).map { |item| item[:method] }.uniq)
      return checked if checked

      stored_races = stored_race_codes(RACE_FILE, id)
      return stored_races if stored_races.key?(:success)

      stored_ethnicities = stored_race_codes(ETHNICITY_FILE, id)
      return stored_ethnicities if stored_ethnicities.key?(:success)

      stamp = update1_stamp_rows(id)
      return stamp if stamp.is_a?(Hash)

      rows = []
      pins = {}
      race_multiple_rows(rows, pins, RACE_FILE, id, races, stored_races)
      race_multiple_rows(rows, pins, ETHNICITY_FILE, id, ethnicities, stored_ethnicities)
      filer_outcome(DdrFileman.filer(mode: "ADD", rows: rows + stamp, iens: pins))
    end

    # Reads each code's .01, 200 INACTIVE and 3 HL7 VALUE. Refuses an
    # unknown or inactive code, and DECLINED TO ANSWER or UNKNOWN BY PATIENT
    # beside another entry (CHKRE^AGUTL2). nil when all pass.
    def check_race_codes(list, code_file, what)
      hl7 = []
      list.each do |item|
        read = DdrFileman.gets_entry(file: code_file, iens: "#{item[:code]},", fields: ".01;200;3", flags: "I")
        return lookup_failed("DDR GETS ENTRY DATA gave no reply for ##{code_file}") if read.nil?
        return lookup_failed("DDR GETS ENTRY DATA gave a malformed reply for ##{code_file}") if read[:malformed]
        return invalid("#{item[:code]} is not a #{what} in ##{code_file}") if read[:error]
        return lookup_failed("DDR GETS ENTRY DATA gave no 200 INACTIVE row for ##{code_file}") unless read[:fields].key?("200")

        name = read[:fields].dig(".01", :internal).to_s
        return invalid("#{name} is no longer an active #{what}") if read[:fields]["200"][:internal].to_i.positive?

        hl7 << read[:fields].dig("3", :internal).to_s
      end
      return nil unless hl7.size > 1 && hl7.intersect?(DECLINED_OR_UNKNOWN)

      invalid("declined to answer or unknown by patient cannot be recorded with another #{what}")
    end

    def check_collection_methods(methods)
      methods.each do |ien|
        read = DdrFileman.gets_entry(file: COLLECTION_METHOD_FILE, iens: "#{ien},", fields: ".01", flags: "I")
        return lookup_failed("DDR GETS ENTRY DATA gave no reply for ##{COLLECTION_METHOD_FILE}") if read.nil?
        return lookup_failed("DDR GETS ENTRY DATA gave a malformed reply for ##{COLLECTION_METHOD_FILE}") if read[:malformed]
        return invalid("#{ien} is not a method of collection") if read[:error]
      end
      nil
    end

    # { code => method } on file, or a :lookup_failed hash (told apart by its
    # :success key; the codes are Integers). The multiples
    # are DINUM'd, so the sub-entry IEN is the code.
    def stored_race_codes(file, id)
      listed = DdrFileman.lister(file: file, iens: ",#{id},", fields: "@;.02I", flags: "IP")
      return lookup_failed("DDR LISTER gave no reply for ##{file}") if listed.nil?
      return lookup_failed("DDR LISTER refused ##{file}") if listed[:error] || listed[:more]

      listed[:entries].to_h { |entry| [ entry[:ien].to_i, entry[:pieces].to_a.first.to_s ] }
    end

    def race_multiple_rows(rows, pins, file, id, wanted, stored)
      codes = wanted.map { |item| item[:code] }
      stored.each_key do |code|
        rows << edit_row(file, ".01", "#{code},#{id},", "@") unless codes.include?(code)
      end
      wanted.each do |item|
        if stored.key?(item[:code])
          next if stored[item[:code]] == item[:method].to_s

          rows << edit_row(file, ".02", "#{item[:code]},#{id},", item[:method].to_s)
        else
          number = pins.size + 1
          pins[number] = item[:code].to_s
          rows << edit_row(file, ".01", "+#{number},#{id},", item[:code].to_s)
          rows << edit_row(file, ".02", "+#{number},#{id},", item[:method].to_s)
        end
      end
    end
  end
end
