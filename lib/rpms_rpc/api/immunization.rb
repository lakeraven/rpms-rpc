# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for patient immunization records.
  #
  # Underlying RPCs:
  #   - BGOVIMM GET (for_patient, find): the patient's V IMMUNIZATION
  #     history, the read VueCentric's immunization component uses
  #     (GET^BGOVIMM -> GET^BGOVIMM5)
  #   - DDR GETS ENTRY DATA (find): the patient a V IMMUNIZATION belongs to
  #   - BGOVIMM PROFILE (text_summary): the Immunization Profile text
  #
  # `for_patient` and `find` once sent BIPC IMMLIST / IMMGET, names no
  # built image registers (#207). They are kept, rebuilt on BGOVIMM GET.
  module Immunization
    extend self
    extend Shape::Declarable

    # V IMMUNIZATION, the file BGOVIMM GET reads.
    V_IMMUNIZATION_FILE = "9000010.11"

    # The patient's immunizations, one hash per dose:
    #   :ien (V IMMUNIZATION IEN), :vaccine_display (the vaccine's name),
    #   :occurrence_datetime (event date, a Time), :lot_number, :site,
    #   :dose_quantity, :performer_duz, :performer_name, :manufacturer.
    # The keys are the removed read's, less those GET^BGOVIMM5 does not
    # return (:vaccine_code as CVX, :status, :expiration_date, :route,
    # :dose_unit, :vfc_eligibility_code, :funding_source); a key with no
    # value is left out. A refused or failed read raises; an empty list
    # means none on file.
    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.immunization_list.fetch_many("#{dfn}^I")
                .select { |row| row[:record_type] == "I" }
                .map { |row| dose(row) }
    end
    shape :for_patient, resource: "immunizations", verb: "GET", path: "/patients/{dfn}/immunizations"

    # One immunization by V IMMUNIZATION IEN, as for_patient returns it, or
    # nil when no such entry is on file. BGOVIMM GET reads by patient, so
    # find asks FileMan whose dose it is and filters that patient's read.
    def find(ien)
      return nil if invalid_id?(ien)

      dfn = patient_of(ien)
      return nil if dfn.nil?

      for_patient(dfn).find { |row| row[:ien] == ien.to_s }
    end
    shape :find, resource: "immunizations", verb: "GET", path: "/immunizations/{ien}"

    # The patient's Immunization Profile as text, one line per profile line:
    # BGOVIMM PROFILE, the read VueCentric's immunization component shows
    # (see the :immunization_profile mapping). A patient not in the
    # Immunization Register gets the package's three lines saying so. When
    # the package reports an error (text on the $C(31)$C(31) end line, or
    # that line rewritten as -1082^text: no profile produced, deceased
    # patient) this raises RpcError; it never returns an error as a
    # summary. nil for an
    # invalid DFN, sent nowhere.
    #
    # It once sent the DFN to BEHOCIR GETTXT, which is a SNOMED CT term
    # lookup (GETTXT^BEHOCIR, BEHOCIR.m:101-109) and answered "^" for every
    # patient (#656).
    def text_summary(dfn)
      return nil if invalid_id?(dfn)

      rpc = DataMapper.immunization_profile.rpc_name
      profile_text(rpc, profile_lines(RpmsRpc.client, rpc, dfn.to_s))
    end
    shape :text_summary, resource: "immunizations", verb: "GET", path: "/patients/{dfn}/immunizations/text-summary"

    private

    # The reply's lines. BmxClient#call_rpc reads $C(31) as a recordset's
    # end marker and the byte after it as a query error, so over BMX the
    # profile is read raw: the data, after the security and application
    # packets (which still raise), split at CR LF. Every other client splits
    # it itself.
    def profile_lines(client, rpc, dfn)
      return client.call_rpc_raw(rpc, dfn).to_s.split(/\r?\n/) if defined?(RpmsRpc::BmxClient) && client.is_a?(RpmsRpc::BmxClient)

      Array(client.call_rpc(rpc, dfn)).map(&:to_s)
    end

    # IMMPROF^BIRPC ends every line with $C(30) and the reply with a line of
    # $C(31)$C(31) and the error text, if any (BIRPC.m:268-275). The CIA
    # reply grammar turns the two $C(31) into spaces and splits each line at
    # its $C(30); another client may keep the bytes. Either way, with the
    # $C(30)s gone and the empty lines they leave dropped, the end line is
    # the last line, and it is blank once its $C(31)s are gone. A blank
    # profile line is " " (BIRPC.m:268) and reads "". When no line came
    # before it, PROFILE^BGOVIMM2 rewrites the end line as -1082^text
    # (BGOVIMM2.m:131), which is not blank either.
    def profile_text(rpc, lines)
      lines = lines.map { |line| line.delete("\x1E") }.reject(&:empty?)
      trailer = lines.pop&.delete("\x1F")
      raise RpmsRpc::Client::RpcError, "#{rpc}: the reply has no end line" if trailer.nil?
      raise RpmsRpc::Client::RpcError, "#{rpc}: #{trailer.strip}" unless trailer.strip.empty?

      lines.map(&:rstrip).join("\n")
    end

    def dose(row)
      performer_duz, performer_name = pair(row[:performer])
      {
        ien: row[:ien],
        vaccine_display: row[:vaccine_display],
        occurrence_datetime: row[:occurrence_datetime],
        lot_number: row[:lot_number],
        site: pair(row[:site]).last,
        dose_quantity: row[:dose_quantity],
        performer_duz: performer_duz,
        performer_name: performer_name,
        manufacturer: row[:manufacturer]
      }.compact
    end

    # "IEN~NAME" (GI1^BGOVIMM5, BGOVIMM5.m:323-326) -> [IEN, NAME].
    def pair(value)
      return [ nil, nil ] if value.nil?

      ien, name = value.split("~", 2)
      [ ien.to_s.empty? ? nil : ien, name.to_s.empty? ? nil : name ]
    end

    def patient_of(ien)
      entry = DdrFileman.gets_entry(file: V_IMMUNIZATION_FILE, iens: "#{ien.to_s.strip},", fields: ".02", flags: "I")
      return nil if entry.nil? || entry[:error]

      dfn = entry[:fields].dig(".02", :internal).to_s
      dfn.empty? ? nil : dfn
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
