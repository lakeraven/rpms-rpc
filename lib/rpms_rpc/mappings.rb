# frozen_string_literal: true

require_relative "data_mapper"

# Built-in RPMS RPC response mappings.
#
# Stock VistA mappings are loaded from the vista-rpc gem and register into
# the shared VistaRpc::DataMapper registry. IHS/RPMS-only mappings are
# defined here and register into the same registry via the RpmsRpc::DataMapper
# alias.
require "vista_rpc/mappings"
require_relative "mappings/ihs"
