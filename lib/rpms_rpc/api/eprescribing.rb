# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for e-prescribing.
  # Underlying RPCs (PSO* family): PSO NEW RX, PSO ERX STATUS, PSO CANCEL RX.
  #
  # Return shapes are plain hashes — engine-layer callers wrap these in a
  # Result + state machine (see lakeraven-ehr Rpms::Eprescribing).
  module Eprescribing
    extend self

    RX_PARAM_ORDER = %i[
      patient_dfn
      medication_code
      medication_display
      dosage_instruction
      route
      frequency
      dispense_quantity
      refills
      days_supply
      pharmacy_ien
      requester_duz
    ].freeze

    CANONICAL_STATUS = {
      "transmitted" => "transmitted",
      "sent"        => "transmitted",
      "delivered"   => "delivered",
      "received"    => "delivered",
      "cancelled"   => "cancelled",
      "voided"      => "cancelled",
      "error"       => "error",
      "failed"      => "error"
    }.freeze

    # Transmit a prescription. Returns:
    #   { success: true, transmission_id: "..." }
    #   { success: false, error: "..." }
    def transmit(attrs)
      param = build_rx_param(attrs)
      result = DataMapper.prescription_new.fetch_one(param)
      return { success: false, error: "Empty response from RPMS" } if result.nil?

      if result[:success]
        { success: true, transmission_id: result[:rx_ien_or_error].to_s }
      else
        { success: false, error: result[:rx_ien_or_error] || "Unknown RPMS error" }
      end
    end

    # Check transmission status. Returns:
    #   { status: "transmitted" | "delivered" | "cancelled" | "error" | "queued" }
    # plus { error: "..." } when status is "error".
    def status(transmission_id)
      return { status: "error", error: "transmission_id is required" } if blank?(transmission_id)

      result = DataMapper.erx_status.fetch_one(transmission_id.to_s)
      return { status: "error", error: "Empty response from RPMS" } if result.nil?

      mapped = CANONICAL_STATUS.fetch(result[:status].to_s.strip.downcase, "queued")
      out = { status: mapped }
      out[:error] = result[:message] if mapped == "error" && !blank?(result[:message])
      out
    end

    # Cancel a transmitted prescription. Returns:
    #   { success: true }
    #   { success: false, error: "..." }
    def cancel(transmission_id, reason: nil)
      return { success: false, error: "transmission_id is required" } if blank?(transmission_id)

      param  = blank?(reason) ? transmission_id.to_s : "#{transmission_id}^#{reason}"
      result = DataMapper.prescription_cancel.fetch_one(param)
      return { success: false, error: "Empty response from RPMS" } if result.nil?

      if result[:success]
        { success: true }
      else
        { success: false, error: result[:message] || "Unknown RPMS error" }
      end
    end

    # Build the PSO NEW RX caret-delimited single-param payload from an attrs hash.
    # Public so callers and tests can observe the wire shape.
    def build_rx_param(attrs)
      RX_PARAM_ORDER.map { |k| attrs[k].to_s }.join("^")
    end

    private

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
