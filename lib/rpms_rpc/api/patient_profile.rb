# frozen_string_literal: true

require_relative "agg"

module RpmsRpc
  # The parts of a patient's registration that sit beside the demographics:
  # the emergency contact and next of kin, the patient's languages, and the
  # other names (aliases) they have used. Each is read and filed through AG's
  # own GUI windows (AGG WINDOW DEFINITION, #9009068.3), the way AG's client
  # does it, under AG's edit lock (Agg.editing), all bound to AGGRPC by Agg.
  #
  #   what                window (#9009068.3)       read                        write
  #   emergency contact   8 Emergency Contact Info  AGG BUILD WINDOW DISPLAY    AGG UPDATE PATIENT
  #   next of kin         20 Next of Kin Info       AGG BUILD WINDOW DISPLAY    AGG UPDATE PATIENT
  #   languages           16 Other Patient          AGG BUILD WINDOW DISPLAY    AGG UPDATE PATIENT
  #   other languages     26 Other Languages        AGG PATIENT LANGUAGES       AGG UPDATE SPECIAL MULTIPLES
  #   other names         33 Aliases                AGG BUILD WINDOW MULTIPLE   AGG UPDATE ALIASES
  #
  # What AG's save does not check, and so what this module checks before it
  # sends anything (each proven live on bcer-9.0-20261029-7c3119b-ydb):
  #
  # - UPD^AGGPTUPD files with FILE^DIE flags "" (internal), so PATIENT's input
  #   transforms do not run: E1^DGLOCK2's "'EMERGENCY CONTACT' name must be
  #   specified" and the name format are not applied, and a contact's address
  #   files with no name. AG's client checks each field with AGG WINDOW DATA
  #   VALIDATION before it saves; so does this module (NAM^AGGWVAL for names,
  #   ZIP^AGGWVAL for zip codes), and it refuses a contact with no name.
  # - The lengths are the window's own (node 1 pieces 2-3 of each parameter),
  #   which VAL does not check: a name of two characters is filed.
  # - UPD^AGGPTUPD answers success for a parameter name the window does not
  #   have, and leaves BMXSEC set in the broker job, so the next AGG call
  #   never ends. Only the parameters below are ever sent.
  # - ALIAS^AGGPTNAM adds through FILE^DICN, which runs no input transform: a
  #   name like "AB" or "OLD, NAME" is filed as given.
  #
  # Changing a contact's name clears the contact's address and phones in
  # PATIENT (the .331 and .211 kill cross-references run DGDDC, DGDDC.m tags
  # 331 and 211), and UPD files only values that differ from what is on file.
  # So a caller sends the fields the person changed: a new name alone leaves
  # the new contact with no address, and a new name with a new address keeps
  # the new address.
  module PatientProfile
    extend self
    extend Shape::Declarable

    EMERGENCY_WINDOW = "Emergency Contact Info" # #9009068.3 entry 8
    NEXT_OF_KIN_WINDOW = "Next of Kin Info"     # #9009068.3 entry 20
    OTHER_PATIENT_WINDOW = "Other Patient"      # #9009068.3 entry 16
    OTHER_LANGUAGES_WINDOW = "Other Languages"  # #9009068.3 entry 26
    ALIASES_WINDOW = "Aliases"                  # #9009068.3 entry 33
    ALIAS_NODE = ".01"                          # ^DPT(DFN,.01,...), the ALIAS multiple

    RELATIONSHIP_FILE = "9999999.36"
    LANGUAGE_FILE = "9999999.99"
    STATE_FILE = "5"

    MIGRANT_TYPES = %w[M S].freeze             # #9000001.84 .03
    HOMELESS_TYPES = %w[H T D S O U].freeze    # #9000001.85 .03
    YES_NO = %w[Y N].freeze

    # A contact parameter: its suffix after AGGEC/AGGNK, its type, and the
    # window's length limits (min, max), from the FOIA export of #9009068.3.
    ContactField = Struct.new(:suffix, :min, :max)

    CONTACT_FIELDS = {
      name: ContactField.new("NME", 3, 35),          # #2 .331 / .211
      relationship: ContactField.new("REL", nil, nil), # #9000001 3102 / 2802, pointer to #9999999.36
      other_relationship: ContactField.new("ORL", nil, 30), # #2 .332 / .212
      address_line1: ContactField.new("AD1", 3, 30), # #2 .333 / .213
      address_line2: ContactField.new("AD2", 3, 30), # #2 .334 / .214
      address_line3: ContactField.new("AD3", 3, 30), # #2 .335 / .215
      city: ContactField.new("CTY", 3, 30),          # #2 .336 / .216
      state: ContactField.new("STE", nil, nil),      # #2 .337 / .217, pointer to STATE (#5)
      zip: ContactField.new("ZIP", 5, 15),           # #2 .338 + .2204 / .218 + .2207 (ECZP/NKZP^AGGUL2)
      phone: ContactField.new("PHN", 3, 20),         # #2 .339 / .219
      phone_work: ContactField.new("WPH", 4, 20)     # #2 .33011 / .21011
    }.freeze

    CONTACT_KINDS = {
      emergency: { window: EMERGENCY_WINDOW, prefix: "AGGEC",
                   name_required: "'EMERGENCY CONTACT' name must be specified to enter/edit this field" },
      next_of_kin: { window: NEXT_OF_KIN_WINDOW, prefix: "AGGNK",
                     name_required: "'NEXT OF KIN' name must be specified to enter/edit this field" }
    }.freeze

    # The choices of the Other Patient window's Interpreter Required and English
    # Proficiency parameters (node 5), by the code #9000001.86 stores.
    INTERPRETER = { "Y" => "YES", "N" => "NO", "U" => "UNKNOWN" }.freeze
    PROFICIENCY = { "VW" => "VERY WELL", "W" => "WELL", "NW" => "NOT WELL", "NA" => "NOT AT ALL" }.freeze

    ALIAS_LENGTH = (3..30) # #2.01 .01 input transform and the Aliases window (X^30^3)

    # -- Emergency contact and next of kin ------------------------------------

    # The patient's emergency contact and next of kin, as AG shows them:
    #   { emergency: { name:, relationship: { ien:, name: } or nil, ... },
    #     next_of_kin: { ... } }
    # Each contact is {} when nothing is on file. nil when RPMS did not answer.
    def contacts(dfn)
      CONTACT_KINDS.to_h do |kind, spec|
        record = Agg.window_values(window: spec[:window], dfn: dfn.to_i)
        return nil if record.nil?

        [ kind, contact_from(record, spec[:prefix]) ]
      end
    end
    shape :contacts, resource: "patient-profiles", verb: "GET", path: "/patients/{dfn}/patient-profiles/contacts"

    # File the fields given for one contact (kind :emergency or :next_of_kin).
    # attrs are CONTACT_FIELDS keys; nil is not sent, "" clears. relationship:
    # and state: are IENs. Send only what the person changed (see the module
    # note on a name change).
    #
    # Returns { success: true, dfn: }, or before anything is sent
    #   { success: false, error: :invalid, field:, message: }  a field AG or the
    #     window refuses, with AG's message where AG has one;
    #   { success: false, error: :name_required, field: :name, message: }
    # and after: :lock_failed / :invalid_dfn from Agg.editing, :agg_rejected, or
    # nil when RPMS did not answer.
    def update_contact(dfn, kind, **attrs)
      spec = CONTACT_KINDS.fetch(kind) { raise ArgumentError, "unknown contact #{kind.inspect}" }
      unknown = attrs.keys - CONTACT_FIELDS.keys
      raise ArgumentError, "unknown contact field #{unknown.first}:" unless unknown.empty?

      dfn = dfn.to_i
      given = attrs.reject { |_, value| value.nil? }.transform_values { |value| value.to_s.strip }
      given[:name] = given[:name].upcase if given.key?(:name)
      return { success: false, error: :no_fields, message: "nothing to update" } if given.empty?

      if (refusal = check_contact(dfn, spec, given))
        return refusal
      end

      params = given.to_h { |field, value| [ "#{spec[:prefix]}#{CONTACT_FIELDS.fetch(field).suffix}", value ] }
      Agg.editing(dfn: dfn) do
        result = Agg.update_patient(window: spec[:window], dfn: dfn, params: params)
        result && (result[:success] ? { success: true, dfn: dfn } : result)
      end
    end
    shape :update_contact, resource: "patient-profiles", verb: "PUT", path: "/patients/{dfn}/patient-profiles/contact"

    # Relationships (#9999999.36) whose name starts with the text: [{ ien:, name: }].
    def relationships(text)
      Agg.table_lookup(file: RELATIONSHIP_FILE, text: text.to_s.upcase)
    end
    shape :relationships, resource: "patient-profiles", verb: "GET", path: "/patient-profiles/relationships"

    # States (#5) whose name starts with the text: [{ ien:, name: }], for a
    # contact's address.
    def states(text)
      Agg.table_lookup(file: STATE_FILE, text: text.to_s.upcase)
    end
    shape :states, resource: "patient-profiles", verb: "GET", path: "/patient-profiles/states"

    # -- Languages ------------------------------------------------------------

    # The patient's latest LANGUAGES ENTRY DATE (#9000001.86) entry:
    #   { date:, primary: { ien:, name: }, preferred:, interpreter: "Y"/"N"/"U",
    #     proficiency: "VW"/"W"/"NW"/"NA", others: [{ ien:, name: }] }
    # {} when none is on file; nil when RPMS did not answer.
    def languages(dfn)
      record = Agg.window_values(window: OTHER_PATIENT_WINDOW, dfn: dfn.to_i)
      return nil if record.nil?
      return {} if record["AGGLGDT"].to_s.empty?

      others = Agg.patient_languages(dfn: dfn.to_i)
      return nil if others.nil?

      { date: record["AGGLGDT"].to_s, primary: pointer(record["AGGLGPRI"]), preferred: pointer(record["AGGLGPRF"]),
        interpreter: code(record["AGGINTRP"]), proficiency: code(record["AGGLGEPF"]), others: others }
    end
    shape :languages, resource: "patient-profiles", verb: "GET", path: "/patients/{dfn}/patient-profiles/languages"

    # Languages (#9999999.99) whose name starts with the text: [{ ien:, name: }].
    def language_lookup(text)
      Agg.table_lookup(file: LANGUAGE_FILE, text: text.to_s.upcase)
    end
    shape :language_lookup, resource: "patient-profiles", verb: "GET", path: "/patient-profiles/language-lookup"

    # Record the patient's languages as a new LANGUAGES ENTRY DATE entry dated
    # today; earlier entries are kept. ULNG^AGGPOTH files the entry (run by the
    # Other Patient window's Primary Language filing code) and copies the
    # previous entry's other languages into it; the other languages are then
    # added and removed one by one through AGG UPDATE SPECIAL MULTIPLES until
    # they are exactly others:.
    #
    # primary:, preferred: and others: are language IENs; interpreter: is a
    # code of INTERPRETER, proficiency: of PROFICIENCY.
    #
    # Refuses before sending, as AG's window does (AGG OTH PAT PRM TRG,
    # PLNG^AGGPTRGO): a primary language is required; an interpreter answer is
    # required when the primary language is not English; an English
    # proficiency when English is the primary or another language.
    #
    # Returns { success: true, dfn:, entry: } or a failure hash; :partial when
    # the entry was filed and an other language was not.
    def record_languages(dfn, primary:, interpreter: nil, proficiency: nil, preferred: nil, others: [], english_ien: nil)
      dfn = dfn.to_i
      others = Array(others).map(&:to_i).uniq
      english = english_ien || english_language_ien
      if (refusal = check_languages(primary.to_i, interpreter, proficiency, others, english))
        return refusal
      end

      params = { "AGGLGPRI" => primary.to_i.to_s, "AGGINTRP" => INTERPRETER[interpreter.to_s].to_s,
                 "AGGLGPRF" => preferred.to_s, "AGGLGEPF" => PROFICIENCY[proficiency.to_s].to_s }
      Agg.editing(dfn: dfn) { file_languages(dfn, params, others) }
    end
    shape :record_languages, resource: "patient-profiles", verb: "POST", path: "/patients/{dfn}/patient-profiles/languages"

    # -- Migrant, homeless and internet -----------------------------------------

    # The patient's latest entry of each, as the Other Patient window shows them:
    #   { migrant: { status: "Y"/"N", type: "M"/"S", date: },
    #     homeless: { status: "Y"/"N", type: "H"/"T"/..., date: },
    #     internet: { access: true/false, date: } }
    # A value is nil when nothing is on file; nil when RPMS did not answer.
    def social_status(dfn)
      record = Agg.window_values(window: OTHER_PATIENT_WINDOW, dfn: dfn.to_i)
      return nil if record.nil?

      internet = code(record["AGGINTNT"])
      { migrant: { status: code(record["AGGMGSTS"]), type: code(record["AGGMGTYP"]), date: date_text(record["AGGMSTDT"]) },
        homeless: { status: code(record["AGGHMSTS"]), type: code(record["AGGHMTYP"]), date: date_text(record["AGGHMSDT"]) },
        internet: { access: internet && internet == "1", date: date_text(record["AGGINTDT"]) } }
    end
    shape :social_status, resource: "patient-profiles", verb: "GET", path: "/patients/{dfn}/patient-profiles/social-status"

    # Record whether the patient is a migrant worker or homeless, and whether
    # they can reach the internet (rpms-ux S-REG-31.2, 31.3): AG's edit check
    # warns until each is on file. Only what is given is sent, and each answer
    # is a new entry dated today, kept beside the earlier ones (MSTS, HSTS and
    # UINT^AGGPOTH), so a caller sends what the person answered and no more.
    #
    # migrant: and homeless: take "Y" or "N". "Y" needs its type, the codes
    # #9000001.84 and .85 field .03 define, and "N" takes none: AG's triggers
    # require and disable the type the same way (AGGPTRGO.m:140-141, 160-161),
    # and AG's save does not check it. internet: takes true or false.
    #
    # Returns { success: true, dfn: } or a failure hash.
    def record_social_status(dfn, migrant: nil, migrant_type: nil, homeless: nil, homeless_type: nil, internet: nil)
      params = social_params(:migrant, migrant, migrant_type, "AGGMGSTS", "AGGMGTYP", MIGRANT_TYPES)
      return params if params[:error]

      other = social_params(:homeless, homeless, homeless_type, "AGGHMSTS", "AGGHMTYP", HOMELESS_TYPES)
      return other if other[:error]

      params = params.merge(other)
      params["AGGINTNT"] = internet ? "1" : "0" unless internet.nil?
      return { success: false, error: :no_fields, message: "nothing to update" } if params.empty?

      dfn = dfn.to_i
      Agg.editing(dfn: dfn) do
        result = Agg.update_patient(window: OTHER_PATIENT_WINDOW, dfn: dfn, params: params)
        result && (result[:success] ? { success: true, dfn: dfn } : result)
      end
    end
    shape :record_social_status, resource: "patient-profiles", verb: "POST", path: "/patients/{dfn}/patient-profiles/social-status"

    # -- Other names (aliases) ------------------------------------------------

    # The patient's other names (#2.01): [{ ien:, name: }], nil for no reply.
    def aliases(dfn)
      rows = Agg.window_multiple(window: ALIASES_WINDOW, node: ALIAS_NODE, dfn: dfn.to_i)
      rows&.map { |row| { ien: row[:rien].to_i, name: row[:aggptals].to_s } }
    end
    shape :aliases, resource: "patient-profiles", verb: "GET", path: "/patients/{dfn}/patient-profiles/aliases"

    # Add an other name. Refused before sending when it is not 3 to 30
    # characters or AG's name check (NAM^AGGWVAL) refuses it, with AG's message.
    # Returns { success: true, ien: } or a failure hash.
    def add_alias(dfn, name)
      dfn = dfn.to_i
      name = name.to_s.strip.upcase
      unless ALIAS_LENGTH.cover?(name.length)
        return invalid(:name, "must be #{ALIAS_LENGTH.min} to #{ALIAS_LENGTH.max} characters")
      end
      if (refusal = validate(ALIASES_WINDOW, :name, "AGGPTALS" => name, "DFN" => dfn.to_s))
        return refusal
      end

      Agg.editing(dfn: dfn) { Agg.update_aliases(dfn: dfn, action: "A", params: { "AGGPTALS" => name }) }
    end
    shape :add_alias, resource: "patient-profiles", verb: "POST", path: "/patients/{dfn}/patient-profiles/alias"

    # Remove one other name by its entry number. Refused when the patient has no
    # such entry (ALIAS^AGGPTNAM answers success for any number).
    def remove_alias(dfn, ien)
      dfn = dfn.to_i
      ien = ien.to_i
      Agg.editing(dfn: dfn) do
        current = aliases(dfn)
        next nil if current.nil?
        next { success: false, error: :not_found, message: "no such other name" } unless current.any? { |a| a[:ien] == ien }

        Agg.update_aliases(dfn: dfn, action: "D", ien: ien)
      end
    end
    shape :remove_alias, resource: "patient-profiles", verb: "DELETE", path: "/patients/{dfn}/patient-profiles/{ien}/alias"

    private

    def contact_from(record, prefix)
      return {} if record["#{prefix}NME"].to_s.empty?

      CONTACT_FIELDS.to_h do |field, spec|
        value = record["#{prefix}#{spec.suffix}"]
        [ field, %i[relationship state].include?(field) ? pointer(value) : value.to_s ]
      end
    end

    # Agg.window_values' { internal:, external: } -> { ien:, name: }, or nil when empty.
    def pointer(value)
      return nil unless value.is_a?(Hash) && value[:internal]

      { ien: value[:internal].to_i, name: value[:external].to_s }
    end

    def code(value)
      value.is_a?(Hash) ? value[:internal] : nil
    end

    def check_contact(dfn, spec, given)
      given.each do |field, value|
        next if value.empty?

        limits = CONTACT_FIELDS.fetch(field)
        if limits.max && (value.length > limits.max || value.length < limits.min.to_i)
          return invalid(field, limits.min ? "must be #{limits.min} to #{limits.max} characters" : "must be at most #{limits.max} characters")
        end
        if %i[relationship state].include?(field) && !value.match?(/\A\d+\z/)
          raise ArgumentError, "#{field}: takes an IEN"
        end
      end
      if (refusal = name_presence(dfn, spec, given))
        return refusal
      end

      %i[name zip].each do |field|
        next if given[field].to_s.empty?

        parameter = "#{spec[:prefix]}#{CONTACT_FIELDS.fetch(field).suffix}"
        if (refusal = validate(spec[:window], field, parameter => given[field], "DFN" => dfn.to_s))
          return refusal
        end
      end
      nil
    end

    # PATIENT's rule (E1/K1^DGLOCK2): a contact's other fields need its name.
    def name_presence(dfn, spec, given)
      others = given.except(:name).values.any? { |value| !value.empty? }
      return nil unless others
      return nil unless given.fetch(:name, nil).to_s.empty? && (given.key?(:name) || current_name(dfn, spec).empty?)

      { success: false, error: :name_required, field: :name, message: spec[:name_required] }
    end

    def current_name(dfn, spec)
      record = Agg.window_values(window: spec[:window], dfn: dfn)
      record.to_h["#{spec[:prefix]}NME"].to_s
    end

    # AG's own check of one field (AGG WINDOW DATA VALIDATION). nil when it
    # passes; RPMS gave no answer is a refusal too, so nothing unchecked files.
    def validate(window, field, params)
      check = Agg.validate_field(window: window, params: params)
      return invalid(field, "could not be checked by RPMS; try again") if check.nil?

      check[:valid] ? nil : invalid(field, check[:message])
    end

    def invalid(field, message)
      { success: false, error: :invalid, field: field, message: message }
    end

    def check_languages(primary, interpreter, proficiency, others, english)
      return invalid(:primary, "is required") unless primary.positive?
      if interpreter.to_s != "" && !INTERPRETER.key?(interpreter.to_s)
        raise ArgumentError, "interpreter: takes one of #{INTERPRETER.keys.join(', ')}"
      end
      if proficiency.to_s != "" && !PROFICIENCY.key?(proficiency.to_s)
        raise ArgumentError, "proficiency: takes one of #{PROFICIENCY.keys.join(', ')}"
      end
      if primary != english && interpreter.to_s.empty?
        return invalid(:interpreter, "is required when the primary language is not English")
      end
      if (primary == english || others.include?(english)) && proficiency.to_s.empty?
        return invalid(:proficiency, "is required when the patient speaks English")
      end

      nil
    end

    def social_params(field, status, type, status_param, type_param, types)
      return {} if status.nil?
      raise ArgumentError, "#{field}: takes one of #{YES_NO.join(', ')}" unless YES_NO.include?(status)

      type_field = :"#{field}_type"
      return type ? invalid(type_field, "is only recorded for a yes") : { status_param => status } if status == "N"
      return invalid(type_field, "must be one of #{types.join(', ')}") unless types.include?(type)

      { status_param => status, type_param => type }
    end

    def date_text(value)
      text = value.to_s
      text.empty? ? nil : text
    end

    def english_language_ien
      Array(language_lookup("ENGLISH")).find { |row| row[:name] == "ENGLISH" }&.dig(:ien)
    end

    def file_languages(dfn, params, others)
      result = Agg.update_patient(window: OTHER_PATIENT_WINDOW, dfn: dfn, params: params)
      return result unless result && result[:success]

      entry = result[:other_parms].to_s[/AGGLNG=(\d+)/, 1]
      return { success: false, error: :agg_rejected, message: "RPMS did not say which language entry it filed" } unless entry

      synced = sync_other_languages(dfn, entry.to_i, others)
      synced[:success] ? { success: true, dfn: dfn, entry: entry.to_i } : synced
    end

    # ULNG copies the previous entry's other languages; add and remove until
    # the new entry holds exactly `others`.
    def sync_other_languages(dfn, entry, others)
      current = Agg.patient_languages(dfn: dfn)
      return { success: false, error: :partial, entry: entry, message: "the other languages could not be read back" } if current.nil?

      have = current.map { |row| row[:ien] }
      changes = (others - have).map { |ien| [ "A", ien ] } + (have - others).map { |ien| [ "D", ien ] }
      changes.each do |action, ien|
        done = Agg.update_special_multiple(window: OTHER_LANGUAGES_WINDOW, dfn: dfn, entry: entry, action: action,
                                           params: { "AGGLGOTH" => ien.to_s })
        next if done && done[:success]

        return { success: false, error: :partial, entry: entry, message: done&.dig(:message).to_s }
      end
      { success: true }
    end
  end
end
