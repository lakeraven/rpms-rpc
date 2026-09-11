# frozen_string_literal: true

require_relative "data_mapper"

# Built-in RPMS RPC response mappings.
#
# Each mapping declares the caret-delimited field positions for a specific
# RPC response format. Gateways use these to parse responses into hashes
# without hand-written split/index code.
#
# Mappings are registered in the DataMapper registry and looked up by name:
#
#   RpmsRpc::DataMapper[:patient_select].parse_one(response, extras: { dfn: 42 })
#
# The mapping data is bucketed by origin ahead of the vista-rpc extraction:
# stock-VistA namespaces (ORW*/ORQQ*/TIU/XUS/...) vs IHS/RPMS-only
# namespaces (B*/MAGG*/CIAV*). Both files register into the one DataMapper
# registry at load time, so requiring this file yields the identical full
# mapping set regardless of the bucketing.
require_relative "mappings/stock_vista"
require_relative "mappings/ihs"

# IHS Behavioral Health (AMHG), split per cluster so the surface stays
# navigable — 60 RPCs across visits, treatment plans, suicide risk, groups,
# intake, case management and reference data (rpms-rpc#227). The visits,
# treatment-plan and suicide-risk mappings live in mappings/ihs.rb; the rest
# are here. All register into the same DataMapper registry, so requiring this
# file still yields the complete set.
require_relative "mappings/amhg_groups"
require_relative "mappings/amhg_reference"
require_relative "mappings/amhg_case_management"
require_relative "mappings/amhg_intake"
