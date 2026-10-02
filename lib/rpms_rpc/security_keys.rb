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
      cprs_gui_chart: "OR CPRS GUI CHART",

      # The AG, SD and DG keys BPRM v4 gates registration, scheduling and ADT on.
      # Each is real on the built baseline: an option LOCK in rpms-diffs
      # inquire/19.norm and/or a user's KEY in inquire/200.norm (main, yotta-0930).
      # Registration (AG)
      registration_menu: "AGZMENU",
      registration_manager: "AGZMGR",
      registration_view_only: "AGZVIEWONLY",
      registration_view_ssn: "AGZVIEWSSN",
      benefits_case_reopen: "AGZCREOPN",

      # Scheduling (SD)
      scheduling_menu: "SDZMENU",
      scheduling_supervisor: "SDZSUP",
      scheduling_registration_menu: "SDZREGMENU",

      # ADT (DG)
      adt_menu: "DGZMENU",
      adt_movement: "DGZADT",
      adt_nurse: "DGZNUR",
      adt_supervisor: "DGZSUP",
      adt_system: "DGZSYS",
      adt_incomplete_chart: "DGZICE",
      adt_pcc: "DGZPCC"
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
