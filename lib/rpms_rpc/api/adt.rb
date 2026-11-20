# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../client"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for ADT (Admission / Discharge / Transfer) patient-movement
  # data over ^DGPM (INPATIENT MOVEMENT #405). Engine code calls these instead
  # of referencing DataMapper mappings or RPC names directly.
  #
  # READS ONLY. There is no stock movement-WRITE RPC in the #8994 registry —
  # admit/transfer/discharge/cancel-movement have no broker-callable entry
  # point. The BPRM twin's ADT-write scenario (lakeraven-ehr#412 scenario #15)
  # therefore requires a NEW FileMan-safe (^DIE / DGPMV*) server-side RPC to be
  # authored and re-exported before those writes can be wrapped here — tracked
  # with openrpms#371 and openrpms#1231. Until then this module exposes only
  # reads: ORWPT's, and the movement file itself through DDR LISTER.
  module Adt
    extend self
    extend Shape::Declarable

    # The option DDR LISTER is read under (CiaClient::SIGNON_CONTEXT; api/ files load before cia_client).
    CONTEXT = "CIAV VUECENTRIC"

    # A patient's admission movements — ORWPT ADMITLST (ADMITLST^ORWPT).
    # Returns an Array of
    #   { movement_datetime:, location_ien:, location:, movement_type:,
    #     movement_ien:, tiu_document_ien: }
    # ordered as the broker returns them (most recent admission first).
    def admissions(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.patient_admissions.fetch_many(dfn.to_s)
    end
    shape :admissions, resource: "admissions", verb: "GET", path: "/patients/{dfn}/admissions"

    # A patient's current inpatient location — ORWPT INPLOC (INPLOC^ORWPT).
    # Returns { location_ien:, ward:, ward_synonym: } when the patient is
    # currently admitted, or nil when they are not an inpatient or the DFN is
    # invalid. A leading 0 alone does NOT mean "not admitted": the routine
    # starts REC at 0 and only the HOSPITAL LOCATION piece stays 0 when the
    # ward has no 44-node link — an admitted patient on an unlinked ward
    # comes back "0^MED WARD^MW" with pieces 2-3 populated (ORWPT.m:222-227).
    # Not-admitted is "0^^" (all ward pieces empty). :location_ien is nil
    # when the ward lacks the link.
    def current_location(dfn)
      return nil if invalid_id?(dfn)

      rec = DataMapper.patient_current_location.fetch_one(dfn.to_s)
      return nil if rec.nil?

      linked = rec[:location_ien].to_i.positive?
      return nil unless linked || !rec[:ward].to_s.empty?

      rec[:location_ien] = nil unless linked
      rec
    end
    shape :current_location, resource: "admissions", verb: "GET", path: "/patients/{dfn}/admissions/current-location"

    # Discharge date/time for a given admission — ORWPT DISCHARGE (DISCHRG^ORWPT).
    #   admit_datetime: the EXACT admission movement datetime — pass the
    #     :movement_datetime from admissions() through unchanged (Time
    #     round-trips; seconds are preserved when nonzero). The routine keys
    #     VAIP("D") on it, so an inexact value is a miss.
    # Returns a Time, or nil when unavailable.
    #
    # The routine cannot say "not found": it returns bare DT — TODAY,
    # date-only — both for an unknown admission (ORWPT.m:205) and for an
    # admission with no discharge yet (ORWPT.m:207). A date-only reply is
    # therefore treated as the no-data sentinel and reads as nil; real
    # discharge movement values carry a time part (+VAIP(17,1),
    # ORWPT.m:208-209). Consequence: a discharge recorded at exactly
    # midnight is indistinguishable from a miss and also reads as nil.
    def discharge_datetime(dfn, admit_datetime)
      return nil if invalid_id?(dfn)

      raw = DataMapper.patient_discharge.fetch_scalar(dfn.to_s, fm(admit_datetime))
      return nil if raw.nil? || !raw.include?(".")

      FilemanDateParser.parse_datetime(raw)
    end
    shape :discharge_datetime, resource: "admissions", verb: "GET", path: "/patients/{dfn}/admissions/discharge-datetime"

    MOVEMENT_FILE = "405"
    # .01 DATE/TIME, .02 TRANSACTION (#405.3, internal and name), .04 TYPE OF
    # MOVEMENT, .06 WARD LOCATION, .07 ROOM-BED, .09 FACILITY TREATING SPECIALTY, .14 ADMISSION/CHECK-IN MOVEMENT, .17 DISCHARGE/CHECK-OUT MOVEMENT.
    MOVEMENT_FIELDS = "@;.01I;.02I;.02E;.04E;.06E;.07E;.09E;.14I;.17I"
    # #405.3 MAS MOVEMENT TRANSACTION TYPE, by internal number.
    TRANSACTIONS = { "1" => :admission, "2" => :transfer, "3" => :discharge, "4" => :lodger_check_in,
                     "5" => :lodger_check_out, "6" => :specialty_transfer }.freeze
    POSITIVE_IEN = /\A[1-9]\d*\z/
    private_constant :MOVEMENT_FIELDS, :TRANSACTIONS, :POSITIVE_IEN

    # Every movement on file for a patient — PATIENT MOVEMENT (#405) through
    # DDR LISTER on its patient index (C) under CIAV VUECENTRIC, oldest first
    # (then by IEN). Each is
    #   { ien:, at:, transaction:, transaction_name:, type:, ward:, room_bed:,
    #     specialty:, admission_ien:, discharge_ien: }
    # transaction is a Symbol (:admission, :transfer, :discharge,
    # :specialty_transfer, :lodger_check_in, :lodger_check_out), or nil for a
    # #405.3 entry the table does not name; transaction_name is the build's
    # own name. Blank names are nil. admission_ien ties each movement to its
    # stay; an admission's discharge_ien is its discharge movement, nil while
    # the patient is still admitted.
    #
    # [] when the patient has no movement. Raises ArgumentError for a DFN that
    # is not a positive integer (nothing is sent), and Client::RpcError when
    # the list gives no reply, refuses, or is cut short, so a failed read is
    # never an empty stay.
    def movements(dfn:)
      id = dfn.to_s
      raise ArgumentError, "dfn must be a positive integer" unless id.match?(POSITIVE_IEN)

      listed = ContextScope.scoped(RpmsRpc.client, CONTEXT) do
        # FROM 0 with the piece-3 screen: PART alone would also match DFN 40 for DFN 4.
        DdrFileman.lister(file: MOVEMENT_FILE, fields: MOVEMENT_FIELDS, flags: "IP", max: "*",
                          xref: "C", part: id, from: "0", screen: "I $P(^(0),U,3)=#{id}")
      end
      raise Client::RpcError, "DDR LISTER gave no reply for ##{MOVEMENT_FILE}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{MOVEMENT_FILE}" if listed[:error] || listed[:more]

      listed[:entries].map { |entry| movement(entry) }.sort_by { |m| [ m[:at] || Time.at(0), m[:ien] ] }
    end
    shape :movements, resource: "admissions", verb: "GET", path: "/patients/{dfn}/admissions/movements"

    private

    def movement(entry)
      at, transaction, transaction_name, type, ward, room_bed, specialty, admission, discharge = entry[:pieces]
      {
        ien: entry[:ien].to_i, at: at.to_s.empty? ? nil : FilemanDateParser.parse_datetime(at),
        transaction: TRANSACTIONS[transaction], transaction_name: blank_nil(transaction_name),
        type: blank_nil(type), ward: blank_nil(ward), room_bed: blank_nil(room_bed), specialty: blank_nil(specialty),
        admission_ien: positive_or_nil(admission), discharge_ien: positive_or_nil(discharge)
      }
    end

    def blank_nil(value) = value.to_s.empty? ? nil : value.to_s
    def positive_or_nil(value) = value.to_i.positive? ? value.to_i : nil

    def invalid_id?(id)
      id.nil? || id.to_i <= 0
    end

    # Time/DateTime keep their time of day (seconds preserved when nonzero —
    # ^DGPM movement times are stored to the second and DISCHRG^ORWPT keys on
    # the exact value); Date formats date-only; strings pass through.
    def fm(value)
      FilemanDateParser.to_fileman(value)
    end
  end
end
