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
