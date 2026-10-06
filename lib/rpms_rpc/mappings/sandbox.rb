# frozen_string_literal: true

require_relative "../data_mapper"

# Sandbox-only mappings. Unlike mappings/stock_vista.rb and mappings/ihs.rb,
# nothing here is backed by a live RPC on any RPMS site — each definition
# says so explicitly, and says what the real path is, so it never gets
# mistaken for a verified wire mapping. Loaded via `require "rpms_rpc/mappings"`
# — see ../mappings.rb.
module RpmsRpc
  module Mappings
    # LAKERAVEN SANDBOX PATIENT LOOKUP — not an RPMS RPC name; nothing on
    # any RPMS site answers to it. No live RPC backs this lookup on this
    # commit (the pin lakeraven-ehr's sandbox demo branch resolves,
    # 4063bc25f3). It exists only so a sandbox demo can resolve a patient
    # by a caller-supplied business identifier while this repo is pinned
    # ahead of the typed-header parsing the real lookup needs.
    #
    # The real path is `AGG LOOKUP PATIENTS` TYPE="H" (`H^AGGPTLKP`,
    # traversing `^AUPNPAT("D",TEXT,DFN)`), implemented as
    # RpmsRpc::Patient.find_by_hrn on branch hrn-identifier-lookup (commit
    # bea9cf5), available from rpms-rpc commit a3d5d4d onward. Migrate
    # callers to that once the engine can resolve rpms-rpc at or after
    # a3d5d4d, and delete this file. Until then: deliberate divergence
    # from real RPMS behaviour, not a wire-accurate wrapper. Seeded only
    # by tests — a value nobody seeded resolves to nothing.
    DataMapper.define(:patient_business_identifier) do |m|
      m.rpc "LAKERAVEN SANDBOX PATIENT LOOKUP"
      m.field 0, :dfn, :integer
      m.field 1, :identifier
    end
  end
end
