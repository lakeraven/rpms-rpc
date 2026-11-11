# frozen_string_literal: true

require_relative "../shape"
require "date"
require_relative "../mappings"
require_relative "../context_scope"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for visit procedures (CPT codes). Read via BGOVCPT GET;
  # write via BEHOENPC SAVE, the encounter write VueCentric uses
  # (rpms-rpc#524, #645).
  #
  # `for_patient` once sent ORWPCE PROCEDURE LIST, a name no built image
  # registers (#207). It is kept, rebuilt on BGOVCPT GET (GET^BGOVCPT), the
  # V CPT read VueCentric's procedure component uses.
  module Procedure
    extend self
    extend Shape::Declarable

    # The patient's V CPT entries, one hash per entry:
    #   :ien (V CPT IEN), :visit_ien, :date (the visit date, a Date),
    #   :cpt_code, :cpt_name, :name (the provider narrative, or the CPT name
    #   when none was filed), :diagnosis, :modifier_1, :modifier_2
    #   (CODE~NAME), :quantity, :provider (name), :facility.
    # V CPT carries no status, so there is no :status key. A refused or
    # failed read raises; an empty list means none on file.
    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.procedure_list.fetch_many(dfn.to_s).map do |row|
        row.merge(date: visit_date(row[:date]))
      end
    end
    shape :for_patient, resource: "procedures", verb: "GET", path: "/patients/{dfn}/procedures"

    # File a CPT on a patient's visit, through BEHOENPC SAVE with one CPT
    # line: HDR (the visit, by its location, date, category and IEN), VST^PT
    # (the patient) and CPT+^code^^^^^quantity. "+" always adds a V CPT
    # (STORE^BEHOENPC). The CPT line files the code (.01) and quantity
    # (.16) only (CPT^BEHOENPC: SET(.16,7),STORE(.18)); the narrative and
    # modifier pieces it documents are not filed, so a caller that passes
    # either gets ArgumentError rather than a silent drop. No POV line is
    # sent, so the SNOMED concept a POV carries in piece 9 (POV^BEHOENPC,
    # rpms-rpc#704) does not arise here: CPT^BEHOENPC and STORE^BEHOENPC
    # use no piece the gem leaves empty as a subscript.
    #
    # The visit is read first (VISIT .01, .05, .07, .22): nothing is sent
    # unless it is this patient's (:not_found, :wrong_patient): the build
    # files the V CPT for the visit's patient whatever VST^PT names (seen on
    # the pinned build), so a mismatch would land on the other chart. The
    # build answers 0 and files nothing for a CPT code it cannot resolve
    # (CPT^BEHOENPC skips STORE when $$CPT^ICPTCOD fails), so the patient's
    # V CPT rows are read before and after (BGOVCPT GET): success is a new
    # row on this visit with this code, and its IEN is returned. A visit
    # the build will not change any more answers -1^text.
    #
    # The save answers no IEN, so when another session filed the same code
    # on the same visit between the two reads, more than one new row matches
    # and none can be told to be this call's: the CPT is filed (success:
    # true, so a caller does not file it again), its IEN is nil and error: is
    # :ambiguous.
    #
    # Returns { success:, ien:, raw: }, plus error: on a refusal or an
    # ambiguous IEN.
    def add(dfn, visit_ien, cpt_code, modifiers: [], narrative: nil, quantity: 1)
      unless Array(modifiers).empty? && narrative.to_s.empty?
        raise ArgumentError, "BEHOENPC SAVE's CPT line files no modifiers or narrative; send neither"
      end
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(cpt_code)
      return failure if quantity.nil? || quantity.to_i <= 0

      ContextScope.scoped(RpmsRpc.client, CONTEXT) do
        visit = visit_fields(visit_ien)
        next failure.merge(error: :not_found) if visit.nil?
        next failure.merge(error: :wrong_patient) unless visit[".05"] == dfn.to_s

        before = for_patient(dfn).map { |row| row[:ien] }
        raw = DataMapper.encounter_save.fetch_scalar(encounter_lines(dfn, visit_ien, visit, cpt_code, quantity),
                                                     "0", visit[".22"])
        next { success: false, ien: nil, raw: raw } unless raw.to_s == "0"

        filed = for_patient(dfn).select do |row|
          !before.include?(row[:ien]) && row[:visit_ien] == visit_ien.to_s && row[:cpt_code] == cpt_code.to_s
        end
        next { success: false, ien: nil, raw: raw, error: :not_filed } if filed.empty?
        next { success: true, ien: nil, raw: raw, error: :ambiguous } if filed.size > 1

        { success: true, ien: filed.first[:ien].to_i, raw: raw }
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: e.message)
    end
    shape :add, resource: "procedures", verb: "POST", path: "/patients/{dfn}/procedures"

    # The option that carries BEHOENPC SAVE, BGOVCPT GET and DDR GETS ENTRY
    # DATA on the pinned build (the context CIA sign-on binds).
    CONTEXT = "CIAV VUECENTRIC"
    VISIT_FILE = "9000010"

    private

    # The PCC list SAVE^BEHOENPC reads: HDR piece 4 is
    # location;date;category;visit IEN (HDR^BEHOENPC); CPT piece 7 is the
    # quantity (CPT^BEHOENPC).
    def encounter_lines(dfn, visit_ien, visit, cpt_code, quantity)
      {
        1 => "HDR^0^^#{visit['.22']};#{visit['.01']};#{visit['.07']};#{visit_ien}",
        2 => "VST^PT^#{dfn}",
        3 => "CPT+^#{cpt_code}^^^^^#{quantity.to_i}"
      }
    end

    # VISIT .01 (date), .05 (patient), .07 (category), .22 (location),
    # internal, or nil when the visit is not on file or the read failed.
    def visit_fields(visit_ien)
      entry = DdrFileman.gets_entry(file: VISIT_FILE, iens: "#{visit_ien},", fields: ".01;.05;.07;.22", flags: "I")
      return nil if entry.nil? || entry[:error] || entry[:malformed] || entry[:fields].empty?

      entry[:fields].transform_values { |f| f[:internal].to_s }
    end

    # $$FMTDATE^BGOUTL writes the visit date as MM/DD/YYYY (BGOUTL.m:373-377).
    def visit_date(value)
      Date.strptime(value.to_s, "%m/%d/%Y")
    rescue Date::Error
      nil
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
