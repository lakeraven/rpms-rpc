# frozen_string_literal: true

# The canonical DataMapper framework lives in the vista-rpc gem.
# rpms-rpc uses the shared registry so that stock VistA and IHS/RPMS
# mappings coexist in one VistaRpc::DataMapper registry.
require "vista_rpc"

module RpmsRpc
  DataMapper = VistaRpc::DataMapper
end
