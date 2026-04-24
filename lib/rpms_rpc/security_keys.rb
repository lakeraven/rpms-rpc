# frozen_string_literal: true

module RpmsRpc
  module SecurityKeys
    REGISTRY = {
      # PRC/CHS
      prc_supervisor: "PRCFA SUPERVISOR",
      prc_tech: "PRCFA TECH",
      prc_manager: "BPRC MANAGER",
      chs_approve: "BGOZ CHS APPROVE",
      chs_clerk: "BGOZ CHS CLERK",

      # Clinical
      consult_manager: "GMRC MGR",
      eligibility_verify: "APCL VERIFY",
      scheduling_admin: "SD SUPERVISOR",

      # Behavioral Health (42 CFR Part 2)
      bh_provider: "BGMH PROVIDER",
      bh_supervisor: "BGMH SUPERVISOR",

      # Dental
      dental_provider: "DENTP PROVIDER",
      dental_supervisor: "DENTP SUPERVISOR",

      # CPRS
      cprs_gui_chart: "OR CPRS GUI CHART"
    }.freeze

    REVERSE = REGISTRY.invert.freeze

    # Resolve raw RPMS key strings to symbols, ignoring unknown keys.
    def self.symbolize(key_strings)
      Array(key_strings).filter_map { |s| REVERSE[s] }
    end

    # Resolve a symbol to its RPMS key string.
    def self.rpms_name(symbol)
      REGISTRY[symbol]
    end
  end
end
