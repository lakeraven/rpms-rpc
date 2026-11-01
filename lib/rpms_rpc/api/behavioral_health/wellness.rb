# frozen_string_literal: true

require_relative "../../shape"
require_relative "../../reply"
require_relative "../../mappings/amhg_wellness"
require_relative "../ddr_fileman"
require_relative "wire"

module RpmsRpc
  module BehavioralHealth
    # AMHG SAVE SCREENING and AMHG SAVE MEASUREMENTS (rpms-rpc#540).
    #
    # SCREEN^AMHGSVF (AMHGSVF.m:307-341) hands nineteen pipe pieces to
    # SCREEN^AMHGEVF (AMHGEVF.m:331-355). Results are external set names;
    # $$SCI^AMHGT (AMHGT.m:183-196) returns the internal code on an exact
    # match and blank otherwise, and a blank clears the field. FILE^DIE("K")
    # files all fifteen fields with no input transform (AMHGEVF.m:335-353),
    # so a screening the caller did not name is resent from the pre-read and
    # an omitted comment or provider is sent blank. Pipe pieces 9 and 10
    # (AMHPP, AMHP; AMHGSVF.m:323-324) are not filed. The reply data row is
    # the record IEN, or "0~Edit Screening" (AMHGSVF.m:337-340).
    #
    # MSR^AMHGSVF (AMHGSVF.m:343-370) files "A|REC|TYPE~~VALUE~PROV*...|DFN".
    # ARRAY^AMHGU (AMHGU.m:22-32) splits on "*" and turns "^" into a space.
    # The value piece is $P(..., R, 3) and the provider is $P(..., R, 4)
    # (AMHGSVF.m:360-363), so the unused second "~" piece stays empty.
    # Mode "E" runs DELMSR^AMHGEVF (AMHGSVF.m:365, AMHGEVF.m:429-443) and
    # deletes measurements the call did not list, so the mode is always "A".
    # MODMSR^AMHGEVF (AMHGEVF.m:411-427) has no input transform on the edit
    # path (FILE^DIE("K"), AMHGEVF.m:418-421); the add path is UPDATE^DIE
    # (AMHGEVF.m:425). The last error overwrites AMHER, so an earlier row
    # may already be filed when the reply is "0~Add Measurement" or
    # "0~Edit Measurement" (AMHGSVF.m:366-369).
    #
    # The measurement read-back is MSR^AMHGDVF1 (AMHGDVF1.m:38-59). Its
    # BMXIEN column is the measurement-type IEN (AMHGDVF1.m:50-57).
    #
    # #9002011 field .08 is PATIENT and field 1112 is DATE/TIME NOTE SIGNED.
    # A non-empty 1112 means the note is signed. The score ranges enforced
    # here are the ones FILE^DIE("K") will not: PHQ2 0-6, PHQ9 0-27, and
    # PHQT 0-27 (AUPNVMSR.m:245-259), and GAD7 0-21 and GAD2 0-6, the value
    # transforms stored on #9999999.07 field 1201 (AUMUPD2.m:244).
    #
    # DDR GETS ENTRY DATA and DDR LOCK/UNLOCK NODE are not registered on
    # AMHGRPC. Every one of those calls binds Patient::FILEMAN_CONTEXT
    # ("CIAV VUECENTRIC") and restores the caller's option.
    #
    # SCREEN^AMHGEVF rewrites all fifteen fields from the snapshot just
    # read. ^AMHREC(ien) is locked before that read and unlocked after the
    # read-back, on every path that took the lock. An unlock that raises or
    # returns false does not change the result or replace an exception
    # already in flight. FILE^DIE("K") takes an incremental lock on the same
    # node inside the broker job that files, so holding this lock does not
    # block the write. A caller-supplied provider IEN is confirmed on file
    # 200 field .01 before the write; a provider that is only resent from
    # the visit is not. U+FFFD in a comment, stored or supplied, is refused
    # before the write, and read-back text that contains it is not a match.
    module Wellness
      extend self
      extend Wire
      extend Shape::Declarable

      # The write was refused, or it was sent and the chart could not be
      # shown to match. After the RPC has been sent the message says the
      # record may have been filed. `cause` is the broker error when there
      # was one. The message never includes a comment or other caller text.
      class SaveError < RpmsRpc::Error; end

      # #9002011. The field list is patient, the signature, and the fifteen
      # fields SCREEN^AMHGEVF files (AMHGEVF.m:335-352). Flags "I": the
      # result codes come back internal. A missing row is not a blank.
      VISIT_FILE = "9002011"
      VISIT_FIELDS =
        ".08;1112;1401;1402;1403;1404;1405;1406;1407;1408;1409;1410;1501;1601;1701;1901;2001"
      VISIT_FLAGS = "I"

      SCREENING_RPC = "AMHG SAVE SCREENING"
      MEASUREMENTS_RPC = "AMHG SAVE MEASUREMENTS"

      # Positive integer, no sign, no leading zero. "0", "007", "1.0", and
      # " 1" are not accepted. A score may be zero; an IEN may not.
      POSITIVE_IEN = /\A[1-9]\d*\z/
      SCORE_TEXT = /\A(?:0|[1-9]\d*)\z/
      # U+FFFD is a byte the broker replaced, or a literal replacement
      # character already stored. Either one is not a value we can resend
      # or treat as a confirmed read-back.
      UNSAFE_WIRE = /[|\x00-\x1f\x7f^\uFFFD]/
      REPLACEMENT = "\uFFFD"
      PROVIDER_FILE = "200"
      VISIT_LOCK_TIMEOUT = 5

      # External names $$SCI^AMHGT matches exactly (AMHGT.m:183-196). An
      # unknown name becomes blank and FILE^DIE clears the field.
      ALCOHOL_CODES = {
        "N" => "NEGATIVE", "P" => "POSITIVE", "UAS" => "UNABLE TO SCREEN",
        "REF" => "PATIENT REFUSED SCREENING", "RF" => "REFERRAL NEEDED"
      }.freeze
      DEPRESSION_CODES = ALCOHOL_CODES
      IPV_CODES = {
        "N" => "NEGATIVE", "PR" => "PRESENT", "PAP" => "PRESENT AND PAST", "PA" => "PAST",
        "REF" => "PATIENT REFUSED SCREENING", "UAS" => "UNABLE TO SCREEN", "RF" => "REFERRAL NEEDED"
      }.freeze
      SUICIDE_RISK_CODES = {
        "L" => "LOW", "M" => "MODERATE", "H" => "HIGH", "RF" => "REFERRAL NEEDED",
        "REF" => "PATIENT REFUSED SCREENING", "UAS" => "UNABLE TO SCREEN"
      }.freeze
      SUICIDE_SCREENING_CODES = {
        "N" => "NEGATIVE", "AP" => "ACUTE POSITIVE", "NAP" => "NON-ACUTE POSITIVE",
        "REF" => "PATIENT REFUSED SCREENING", "UAS" => "UNABLE TO SCREEN"
      }.freeze

      # result / comment / provider field numbers on #9002011.
      SCREENINGS = {
        alcohol: { result: "1403", comment: "1601", provider: "1404", codes: ALCOHOL_CODES },
        depression: { result: "1405", comment: "1701", provider: "1406", codes: DEPRESSION_CODES },
        ipv: { result: "1401", comment: "1501", provider: "1402", codes: IPV_CODES },
        suicide_risk: { result: "1407", comment: "1901", provider: "1408", codes: SUICIDE_RISK_CODES },
        suicide_screening: { result: "1409", comment: "2001", provider: "1410", codes: SUICIDE_SCREENING_CODES }
      }.freeze

      # 0-based indexes in the nineteen-piece parameter (AMHGSVF.m:316-335).
      # Indexes 8 and 9 stay blank: pipe pieces 9 and 10 are not filed.
      WIRE_INDEX = {
        alcohol: { result: 2, comment: 3, provider: 10 },
        depression: { result: 4, comment: 5, provider: 11 },
        ipv: { result: 6, comment: 7, provider: 12 },
        suicide_risk: { result: 13, comment: 14, provider: 15 },
        suicide_screening: { result: 16, comment: 17, provider: 18 }
      }.freeze

      SCREENING_NAMES = SCREENINGS.keys.to_h { |name| [ name.to_s, name ] }.freeze
      SCREENING_FIELDS = { "result" => :result, "provider" => :provider, "comment" => :comment }.freeze

      # PHQ2/PHQ9/PHQT: AUPNVMSR.m:245-259 (`X'?1N` / `1.2N`, `X'=+X`, then
      # the range). GAD7 and GAD2: the transforms on #9999999.07 field 1201.
      MEASUREMENT_RANGES = {
        "PHQ9" => 0..27, "PHQ2" => 0..6, "PHQT" => 0..27, "GAD7" => 0..21, "GAD2" => 0..6
      }.freeze
      MEASUREMENT_FIELDS = { "type" => :type, "value" => :value, "provider" => :provider }.freeze

      # File the named screenings on visit `record_ien` for `patient`.
      #
      # `record_ien` is the first argument. Callers may instead pass it by
      # name; passing it both ways is refused. `screenings` is a non-empty
      # Hash whose keys are alcohol, depression, ipv, suicide_risk, and
      # suicide_screening. Each value is `{ result:, provider:, comment: }`.
      # `result` is the internal set code. `provider` is a positive integer
      # IEN. `comment`, when the key is present, is 2 to 245 characters and
      # must not contain a pipe, a caret, a control character, or U+FFFD. A named
      # screening that omits provider or comment sends that piece blank.
      #
      # Returns `{ record_ien:, screenings: }` with all five screenings read
      # back from #9002011. Raises SaveError without calling the write when
      # the visit lock is not acquired, the visit cannot be shown to be this
      # patient's unsigned note, a caller-supplied provider is not on file
      # 200, or a stored screening cannot be resent. After AMHG SAVE
      # SCREENING is sent, raises SaveError and says the record may have
      # been filed unless the reply is that record IEN and the read-back
      # matches. Read-back text that contains U+FFFD is not a match.
      def save_screening(record_ien = nil, patient:, screenings:, **rest)
        rec = record_ien!(record_ien, rest)
        patient_ien = positive_ien!(patient, "patient")
        updates = screening_updates!(screenings)
        with_visit_lock(rec) do
          before = editable_visit!(rec, patient_ien)
          filed = merged_screenings!(before, updates)
          confirm_providers!(screening_provider_iens(updates))
          parameter = screening_parameter(rec, filed)
          response = send_screening(rec, parameter)
          confirm_reply!(response, rec, SCREENING_RPC)
          after = confirmed_visit!(rec, patient_ien, SCREENING_RPC)
          confirm_screenings!(after, filed, rec)
          { record_ien: rec, screenings: screenings_from(after) }
        end
      end
      shape :save_screening, resource: "behavioral-health", verb: "POST",
            path: "/behavioral-health/wellness/screening"

      # File `measurements` on visit `record_ien` for `patient`.
      #
      # The record IEN follows the same calling convention as save_screening.
      # Each measurement is `{ type:, value:, provider: }`. `type` is PHQ9,
      # PHQ2, PHQT, GAD7, or GAD2. `value` is an Integer, or a String of
      # digits, inside that instrument's range. `provider` is a positive
      # integer IEN. The same type twice is refused. The wire mode is "A".
      #
      # Returns every measurement row from AMHG GET VISIT MSR DATA ENTRY.
      # A row of a type that was sent has :value as an Integer. A row of any
      # other type has :value as an Integer when that column is a canonical
      # integer, and the raw string otherwise; that row does not fail the
      # save. A row with the wrong number of columns does. Each row has
      # :type and :provider => { :ien }.
      # Raises SaveError the way save_screening does. After the write, the
      # visit is read again; an unreadable visit or a different .08 says the
      # record may have been filed. So does a reply that is not the record
      # IEN, or a read-back that does not contain each sent type once with
      # the same value and provider IEN: MODMSR may already have stored an
      # earlier row.
      def save_measurements(record_ien = nil, patient:, measurements:, **rest)
        rec = record_ien!(record_ien, rest)
        patient_ien = positive_ien!(patient, "patient")
        sent = measurement_list!(measurements)
        with_visit_lock(rec) do
          editable_visit!(rec, patient_ien)
          confirm_providers!(sent.map { |row| row.fetch(:provider) }.uniq)
          parameter = measurements_parameter(rec, patient_ien, sent)
          response = send_measurements(rec, parameter)
          confirm_reply!(response, rec, MEASUREMENTS_RPC)
          confirmed_visit!(rec, patient_ien, MEASUREMENTS_RPC)
          readback = read_measurements(rec, sent)
          ambiguous!(rec, MEASUREMENTS_RPC) unless measurements_match?(readback, sent)
          readback
        end
      end
      shape :save_measurements, resource: "behavioral-health", verb: "POST",
            path: "/behavioral-health/wellness/measurements"

      private

      # Hold ^AMHREC(rec) from the pre-read through the read-back. The lock
      # call itself is not a taken lock unless it returns true.
      def with_visit_lock(rec)
        holding = false
        holding = visit_lock!(rec)
        yield
      ensure
        visit_unlock(rec) if holding
      end

      def visit_lock!(rec)
        node = visit_node(rec)
        acquired = begin
          under_fileman { DdrFileman.lock(node: node, timeout: VISIT_LOCK_TIMEOUT) }
        rescue RpmsRpc::Error => e
          refuse!("the lock #{node} was not acquired", e)
        end
        refuse!("the lock #{node} was not acquired") unless acquired == true
        true
      end

      # Best-effort. A false reply or a broker error must not replace a
      # result or an exception the write already produced.
      def visit_unlock(rec)
        under_fileman { DdrFileman.unlock(node: visit_node(rec)) }
      rescue RpmsRpc::Error
        nil
      end

      def visit_node(rec)
        "^AMHREC(#{rec})"
      end

      # AMHGRPC does not list the DDR RPCs. Patient::FILEMAN_CONTEXT does.
      def under_fileman(&block)
        ContextScope.scoped(RpmsRpc.client, RpmsRpc::Patient::FILEMAN_CONTEXT, &block)
      end

      def screening_provider_iens(updates)
        updates.values.map { |row| row.fetch(:provider) }.reject(&:empty?).uniq
      end

      # Caller-supplied IENs only, each distinct IEN once. nil, a broker
      # error, or a blank .01 is a missing provider; nothing is filed.
      def confirm_providers!(iens)
        iens.each { |ien| confirm_provider!(ien) }
      end

      def confirm_provider!(ien)
        got = read_provider(ien)
        refuse!("provider is not on file") unless provider_on_file?(got)
      end

      def read_provider(ien)
        under_fileman do
          DdrFileman.gets_entry(file: PROVIDER_FILE, iens: "#{ien},", fields: ".01", flags: "I")
        end
      rescue RpmsRpc::Error => e
        refuse!("provider is not on file", e)
      end

      def provider_on_file?(got)
        return false if got.nil? || !got.is_a?(Hash) || got[:error]
        return false unless got[:fields].is_a?(Hash)

        field = got[:fields][".01"]
        return false unless field.is_a?(Hash)

        !field[:internal].to_s.strip.empty?
      end

      def record_ien!(positional, rest)
        extra = rest.dup
        named = extra.key?(:record_ien)
        value = extra.delete(:record_ien)
        refuse!("a field is not accepted") unless extra.empty?
        refuse!("record IEN must be a positive integer") if named && !positional.nil?

        positive_ien!(named ? value : positional, "record IEN")
      end

      def positive_ien!(value, label)
        text = case value
        when Integer
                 refuse!("#{label} must be a positive integer") unless value.positive?
                 value.to_s
        when String
                 value
        else
                 refuse!("#{label} must be a positive integer")
        end
        refuse!("#{label} must be a positive integer") unless safe_match?(text, POSITIVE_IEN)
        text
      end

      def screening_updates!(screenings)
        refuse!("screenings are required") unless screenings.is_a?(Hash) && !screenings.empty?

        screenings.each_with_object({}) do |(key, attrs), out|
          name = screening_name!(key)
          refuse!("a field is not accepted") if out.key?(name)
          out[name] = screening_attrs!(name, attrs)
        end
      end

      def screening_name!(key)
        text = case key
        when Symbol then key.to_s
        when String then key
        else refuse!("screening is not a known type")
        end
        name = SCREENING_NAMES[text]
        refuse!("screening is not a known type") unless name
        name
      end

      def screening_attrs!(name, attrs)
        refuse!("screening result is not a filed code") unless attrs.is_a?(Hash)

        fields = {}
        attrs.each do |key, value|
          field = screening_field!(key)
          refuse!("a field is not accepted") if fields.key?(field)
          fields[field] = value
        end
        refuse!("screening result is not a filed code") unless fields.key?(:result)
        {
          result: screening_result!(name, fields[:result]),
          comment: fields.key?(:comment) ? comment_text!(fields[:comment]) : "",
          provider: fields.key?(:provider) ? positive_ien!(fields[:provider], "provider") : ""
        }
      end

      def screening_field!(key)
        text = case key
        when Symbol then key.to_s
        when String then key
        else refuse!("a field is not accepted")
        end
        field = SCREENING_FIELDS[text]
        refuse!("a field is not accepted") unless field
        field
      end

      def screening_result!(name, value)
        codes = SCREENINGS.fetch(name)[:codes]
        refuse!("screening result is not a filed code") unless value.is_a?(String) && codes.key?(value)
        value
      end

      def comment_text!(value)
        refuse!("screening comment must be text") unless value.is_a?(String) && utf8_text?(value)

        text = value.dup.force_encoding(Encoding::UTF_8)
        unless text.length.between?(2, 245) && text.bytesize <= 245
          refuse!("screening comment must be 2 to 245 characters")
        end
        refuse!("screening comment contains a separator or control character") if unsafe?(text) || replacement_text?(text)
        text
      end

      def utf8_text?(value)
        case value.encoding
        when Encoding::UTF_8, Encoding::US_ASCII
          value.valid_encoding?
        when Encoding::ASCII_8BIT
          value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        else
          false
        end
      end

      def editable_visit!(rec, patient_ien)
        got = readable_visit!(rec)
        refuse!("the stored patient does not match this visit") unless stored_patient(got) == patient_ien
        refuse!("the visit is signed") if signed?(got)
        got
      end

      def readable_visit!(rec)
        got = read_visit(rec)
        refuse!("the visit could not be read") if unreadable?(got)
        refuse!("the stored patient could not be read") unless patient_present?(got)
        refuse!("the stored signature date could not be read") unless got[:fields].key?("1112")
        got
      end

      # A broker error on the pre-read filed nothing.
      def read_visit(rec)
        visit_fields(rec)
      rescue RpmsRpc::Error => e
        refuse!("the visit could not be read", e)
      end

      def visit_fields(rec)
        under_fileman do
          DdrFileman.gets_entry(file: VISIT_FILE, iens: "#{rec},", fields: VISIT_FIELDS, flags: VISIT_FLAGS)
        end
      end

      def unreadable?(got)
        return true unless got.is_a?(Hash)
        return true if got[:error]
        return true unless got[:fields].is_a?(Hash)

        got[:fields].empty?
      end

      def patient_present?(got)
        got[:fields].key?(".08") && !pointer_text(field_internal(got, ".08")).empty?
      end

      def signed?(got)
        !field_internal(got, "1112").to_s.empty?
      end

      def stored_patient(got)
        pointer_text(field_internal(got, ".08"))
      end

      def merged_screenings!(got, updates)
        fields = got[:fields]
        SCREENINGS.each_with_object({}) do |(name, spec), filed|
          if (update = updates[name])
            filed[spec[:result]] = update.fetch(:result)
            filed[spec[:comment]] = update.fetch(:comment)
            filed[spec[:provider]] = update.fetch(:provider)
          else
            filed[spec[:result]] = stored_code!(fields, spec[:result], spec[:codes])
            filed[spec[:comment]] = stored_text!(fields, spec[:comment])
            filed[spec[:provider]] = stored_provider!(fields, spec[:provider])
          end
        end
      end

      # A missing field is not resent as a clear. A blank result is.
      def stored_code!(fields, field, codes)
        refuse!("a stored screening cannot be resent") unless fields.key?(field)

        code = fields[field][:internal].to_s
        return "" if code.empty?
        refuse!("a stored screening cannot be resent") unless codes.key?(code)

        code
      end

      # Stored text is resent as filed. The 2..245 limit applies only to a
      # comment the caller supplied. A separator or U+FFFD still cannot go
      # on the wire: the stored comment would be rewritten as whatever the
      # broker substituted.
      def stored_text!(fields, field)
        refuse!("a stored screening cannot be resent") unless fields.key?(field)

        text = fields[field][:internal].to_s
        refuse!("a stored screening cannot be resent") if unsafe?(text) || replacement_text?(text)
        text
      end

      def stored_provider!(fields, field)
        refuse!("a stored screening cannot be resent") unless fields.key?(field)

        ien = pointer_text(fields[field][:internal])
        return "" if ien.empty?
        refuse!("a stored screening cannot be resent") unless safe_match?(ien, POSITIVE_IEN)

        ien
      end

      def screening_parameter(rec, filed)
        pieces = Array.new(19, "")
        pieces[0] = "E"
        pieces[1] = rec
        SCREENINGS.each do |name, spec|
          index = WIRE_INDEX.fetch(name)
          pieces[index[:result]] = external_name!(spec[:codes], filed.fetch(spec[:result]))
          pieces[index[:comment]] = filed.fetch(spec[:comment])
          pieces[index[:provider]] = filed.fetch(spec[:provider])
        end
        refuse!("a screening value contains a separator") if pieces.any? { |piece| unsafe?(piece) }

        wire = pieces.join("|")
        refuse!("a screening value contains a separator") unless wire.split("|", -1).length == 19
        wire
      end

      def external_name!(codes, internal)
        return "" if internal.empty?

        name = codes[internal]
        refuse!("a stored screening cannot be resent") unless name.is_a?(String) && !unsafe?(name)
        name
      end

      def send_screening(rec, parameter)
        call_amhg(DataMapper[:amhg_save_screening], parameter)
      rescue RpmsRpc::Error => e
        ambiguous!(rec, SCREENING_RPC, e)
      end

      def confirm_screenings!(got, filed, rec)
        SCREENINGS.each_value do |spec|
          ambiguous!(rec, SCREENING_RPC) unless same_filed_text?(field_internal(got, spec[:result]), filed.fetch(spec[:result]))
          ambiguous!(rec, SCREENING_RPC) unless same_filed_text?(field_internal(got, spec[:comment]), filed.fetch(spec[:comment]))
          unless same_filed_text?(pointer_text(field_internal(got, spec[:provider])), filed.fetch(spec[:provider]))
            ambiguous!(rec, SCREENING_RPC)
          end
        end
      end

      def screenings_from(got)
        SCREENINGS.to_h do |name, spec|
          [
            name,
            {
              result: field_internal(got, spec[:result]).to_s,
              provider: pointer_text(field_internal(got, spec[:provider])),
              comment: field_internal(got, spec[:comment]).to_s
            }
          ]
        end
      end

      def measurement_list!(measurements)
        refuse!("measurements are required") unless measurements.is_a?(Array) && !measurements.empty?

        seen = {}
        measurements.map { |row| measurement_item!(row, seen) }
      end

      def measurement_item!(row, seen)
        fields = measurement_fields!(row)
        type = measurement_type!(fields[:type])
        refuse!("measurement type is duplicated") if seen[type]

        seen[type] = true
        {
          type: type,
          value: score!(fields[:value], MEASUREMENT_RANGES.fetch(type)),
          provider: positive_ien!(fields[:provider], "provider")
        }
      end

      def measurement_fields!(row)
        refuse!("measurement type is not a filed code") unless row.is_a?(Hash)

        fields = {}
        row.each do |key, value|
          field = measurement_field!(key)
          refuse!("a field is not accepted") if fields.key?(field)
          fields[field] = value
        end
        fields
      end

      def measurement_field!(key)
        text = case key
        when Symbol then key.to_s
        when String then key
        else refuse!("a field is not accepted")
        end
        field = MEASUREMENT_FIELDS[text]
        refuse!("a field is not accepted") unless field
        field
      end

      def measurement_type!(type)
        refuse!("measurement type is not a filed code") unless type.is_a?(String) && MEASUREMENT_RANGES.key?(type)
        type
      end

      # Integer, or a String of digits with no sign and no leading zero
      # ("0" is a score; "00", "14.5", and "1e1" are not). AUPNVMSR kills a
      # value `X'=+X` or outside the range; FILE^DIE("K") will not.
      def score!(value, range)
        text = case value
        when Integer then value.to_s
        when String then value
        else refuse!("measurement value is not an integer in range")
        end
        refuse!("measurement value is not an integer in range") unless safe_match?(text, SCORE_TEXT)

        number = Integer(text, 10)
        refuse!("measurement value is not an integer in range") unless range.cover?(number)
        number
      end

      def measurements_parameter(rec, patient_ien, rows)
        body = rows.map { |row| "#{row[:type]}~~#{row[:value]}~#{row[:provider]}" }.join("*")
        "A|#{rec}|#{body}|#{patient_ien}"
      end

      def send_measurements(rec, parameter)
        call_amhg(DataMapper[:amhg_save_measurements], parameter)
      rescue RpmsRpc::Error => e
        ambiguous!(rec, MEASUREMENTS_RPC, e)
      end

      def read_measurements(rec, sent)
        sent_types = sent.map { |row| row.fetch(:type) }
        measurement_readback(call_amhg(DataMapper[:amhg_visit_msr_data_entry], rec), sent_types)
      rescue RpmsRpc::Error => e
        ambiguous!(rec, MEASUREMENTS_RPC, e)
      end

      def measurement_readback(response, sent_types)
        return nil if response.nil? || Reply.altered?(response)

        lines = recordset_rows(response)
        return nil if lines.nil?

        parsed = lines.map { |line| measurement_row(line, sent_types) }
        return nil if parsed.any?(&:nil?)

        parsed
      end

      # Rows of a type this call sent must be an integer value, a positive
      # type IEN, and a provider IEN. Any other type is returned as stored:
      # a value that is not a canonical integer stays the raw string and
      # does not fail the save. The wrong number of columns fails closed
      # for every row.
      def measurement_row(line, sent_types)
        pieces = line.split("^", 6)
        return nil unless pieces.length == 6

        type_ien = pieces[0].to_s.strip
        type = pieces[1].to_s.strip
        description = pieces[2].to_s.strip
        raw_value = pieces[3].to_s.strip
        provider_ien = pieces[4].to_s.strip
        provider_name = pieces[5].to_s.strip
        value = canonical_integer(raw_value)
        if sent_types.include?(type) && !strict_sent_measurement?(type_ien, type, value, provider_ien)
          return nil
        end

        {
          type_ien: type_ien,
          type: type,
          description: description.empty? ? nil : description,
          value: value.nil? ? raw_value : value,
          provider: {
            ien: provider_ien.empty? ? nil : provider_ien,
            name: provider_name.empty? ? nil : provider_name
          }
        }
      end

      def strict_sent_measurement?(type_ien, type, value, provider_ien)
        return false unless safe_match?(type_ien, POSITIVE_IEN)
        return false if type.empty? || unsafe?(type) || value.nil?
        return false unless safe_match?(provider_ien, POSITIVE_IEN)

        true
      end

      def canonical_integer(text)
        return nil unless safe_match?(text, SCORE_TEXT)

        Integer(text, 10)
      rescue ArgumentError, EncodingError
        nil
      end

      def measurements_match?(rows, sent)
        return false unless rows.is_a?(Array)

        sent.all? do |item|
          hits = rows.select { |row| same_filed_text?(row[:type], item[:type]) }
          next false unless hits.length == 1

          hit = hits.first
          same_filed_text?(hit[:value], item[:value]) &&
            same_filed_text?(hit.dig(:provider, :ien), item[:provider])
        end
      end

      # After the write RPC was sent. Anything but a proven success.
      def confirmed_visit!(rec, patient_ien, label)
        got = read_visit_after(rec, label)
        ambiguous!(rec, label) if unreadable?(got)
        ambiguous!(rec, label) unless patient_present?(got)
        ambiguous!(rec, label) unless got[:fields].key?("1112")
        ambiguous!(rec, label) unless same_filed_text?(stored_patient(got), patient_ien)
        got
      end

      def read_visit_after(rec, label)
        visit_fields(rec)
      rescue RpmsRpc::Error => e
        ambiguous!(rec, label, e)
      end

      def confirm_reply!(response, rec, label)
        ambiguous!(rec, label) unless recordset_rows(response) == [ rec ]
      end

      # One AMHG global-array recordset. Nil when the reply cannot be read:
      # nothing came back, a byte was replaced, or the error flag is set.
      # Header rows and the $C(31) sentinel are dropped. A live CIA frame is
      # a sequence echo, a $C(0) ack, then $C(30)-separated rows.
      def recordset_rows(response)
        return nil if response.nil? || Reply.altered?(response)

        text = response.is_a?(Array) ? response.join("\n") : response.to_s
        return nil if text.empty? || text.include?("\x01")

        body = text.include?("\x00") ? text.split("\x00", 2).last.to_s : text
        body = body.split("\x1f", 2).first.to_s
        return nil if body.empty?

        parts = body.include?("\x1e") ? body.split("\x1e") : body.split(/\r?\n/)
        parts.filter_map { |part| recordset_data_row(part) }
      end

      def recordset_data_row(part)
        line = DataMapper.strip_recordset_separators(part).strip
        return nil if line.empty? || DataMapper.recordset_header_row?(line)

        line
      end

      def field_internal(got, field)
        return nil unless got[:fields].key?(field)

        got[:fields][field][:internal].to_s
      end

      def pointer_text(raw)
        text = raw.to_s.strip
        return "" if text.empty?

        text.split(";", 2).first.to_s.strip
      end

      # Equal, and neither side is a replacement character. A missing field
      # stays nil: nil is not the empty string that an omitted comment sends.
      def same_filed_text?(readback, expected)
        return false if replacement_text?(readback) || replacement_text?(expected)

        readback == expected
      end

      def replacement_text?(value)
        return false unless value.is_a?(String)

        value.include?(REPLACEMENT)
      rescue ArgumentError, EncodingError
        true
      end

      def safe_match?(text, pattern)
        text.match?(pattern)
      rescue ArgumentError, EncodingError
        false
      end

      def unsafe?(text)
        return true unless text.is_a?(String)
        return true if replacement_text?(text)

        text.match?(UNSAFE_WIRE)
      rescue ArgumentError, EncodingError
        true
      end

      def refuse!(message, cause = nil)
        raise SaveError, message, cause: cause if cause

        raise SaveError, message
      end

      def ambiguous!(rec, label, cause = nil)
        refuse!("#{label} outcome unknown; record #{rec} may have been filed", cause)
      end
    end
  end
end
