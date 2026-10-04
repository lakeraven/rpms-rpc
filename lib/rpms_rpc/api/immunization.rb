# frozen_string_literal: true

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
  #   - BEHOCIR GETTXT (text_summary): the CCD patient-summary text blob
  #
  # `for_patient` and `find` once sent BIPC IMMLIST / IMMGET, names no
  # built image registers (#207). They are kept, rebuilt on BGOVIMM GET.
  module Immunization
    extend self

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

    # One immunization by V IMMUNIZATION IEN, as for_patient returns it, or
    # nil when no such entry is on file. BGOVIMM GET reads by patient, so
    # find asks FileMan whose dose it is and filters that patient's read.
    def find(ien)
      return nil if invalid_id?(ien)

      dfn = patient_of(ien)
      return nil if dfn.nil?

      for_patient(dfn).find { |row| row[:ien] == ien.to_s }
    end

    # The CCD patient-summary text blob (BEHOCIR GETTXT).
    def text_summary(dfn)
      return nil if invalid_id?(dfn)

      DataMapper.immunization_text.fetch_text(dfn.to_s)
    end

    private

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
