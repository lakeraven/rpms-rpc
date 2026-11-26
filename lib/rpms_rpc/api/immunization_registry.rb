# frozen_string_literal: true

require_relative "immunization"

module RpmsRpc
  # The immunization component's reads beside a patient's history (BGOVIMM,
  # under the CIAV VUECENTRIC sign-on option): the contraindications it
  # offers, whether the state forecaster is on and when it last ran for a
  # patient, whether a vaccine may be given twice on one day, and the
  # patient's immunization registry entry. Reads only.
  module Immunization
    # Each RPC's mapping (lib/rpms_rpc/mappings/ihs.rb) binds CIAV
    # VUECENTRIC, the one option the build lists them in (ADR 0011).
    # $$ERR^BGOUTL(1083): the patient has no IMMUNIZATION PATIENT (#9002084) entry.
    NOT_REGISTERED = "-1083"
    NO_STATE_DATA = "No state data found"

    # GETCONT^BGOVIMM2: the active CONTRAINDICATION REASONS (#9002084.81)
    # the component offers, as { ien:, name: }.
    def contraindications
      bgovimm_lines(:immunization_contraindications, "").filter_map do |line|
        ien, name = line.split("^", 2)
        { ien: ien.to_i, name: name.to_s } if ien.to_i.positive?
      end
    end
    shape :contraindications, resource: "immunizations", verb: "GET", path: "/immunizations/contraindications"

    # FOREON^BGOVIMM5: false when a BGO IMM REGISTRY ON parameter turns the
    # state forecaster off, true otherwise.
    def state_forecaster_on?
      bgovimm_lines(:immunization_state_forecaster_on).first.to_s.strip == "1"
    end
    shape :state_forecaster_on?, resource: "immunizations", verb: "GET", path: "/immunizations/state-forecaster-on"

    # DTERUN^BGOVIMM5: the date the state forecaster last answered for the
    # patient, as the external text the routine sends, or nil when it never
    # has ("No state data found").
    def state_forecast_last_run(dfn)
      text = bgovimm_lines(:immunization_state_forecast_run, dfn.to_s).first.to_s.strip
      text.empty? || text == NO_STATE_DATA ? nil : text
    end
    shape :state_forecast_last_run, resource: "immunizations", verb: "GET", path: "/patients/{dfn}/immunizations/state-forecast-last-run"

    # DUPALLOW^BGOVIMM6: whether the vaccine (#9999999.14 IEN) may be given
    # twice on one day: true when IMMUNIZATION DUPLICATE ALLOWED (#9002084.97)
    # lists it.
    def duplicates_allowed?(vaccine_ien)
      bgovimm_lines(:immunization_duplicates_allowed, vaccine_ien.to_s).first.to_s.strip == "1"
    end
    shape :duplicates_allowed?, resource: "immunizations", verb: "GET", path: "/immunizations/vaccines/{vaccine_ien}/duplicates-allowed"

    # GETCASE^BGOVIMM2: the patient's IMMUNIZATION PATIENT (#9002084) entry as
    # the GETS^DIQ lines the routine answers, or nil when the patient is not
    # registered in the immunization package. Another package error raises.
    def registry_case(dfn)
      lines = bgovimm_lines(:immunization_registry_case, dfn.to_s)
      first = lines.first.to_s
      return nil if first.start_with?("#{NOT_REGISTERED}^")
      raise RpmsRpc::Client::RpcError, "BGOVIMM GETCASE: #{first.split('^', 2).last}" if first.start_with?("-")

      lines
    end
    shape :registry_case, resource: "immunizations", verb: "GET", path: "/patients/{dfn}/immunizations/registry-case"

    private

    # The reply's lines, under the mapping's option. Read raw, not through
    # DataMapper#lines!, so a package error row (-1083^...) reaches the caller.
    def bgovimm_lines(mapping_name, *params)
      mapping = DataMapper[mapping_name]
      client = RpmsRpc.client
      lines = mapping.in_context(client) { client.call_rpc_lines(mapping.rpc_name, *params) }
      Array(lines).map { |line| line.to_s.delete("\x1E\x1F") }.reject(&:empty?)
    end
  end
end
