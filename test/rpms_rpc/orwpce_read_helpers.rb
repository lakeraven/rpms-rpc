# frozen_string_literal: true

require "yaml"
require "set"

# Shared helpers for ORWPCE read specs (issue #286). Evidence lives in
# test/fixtures/wire_captures/unmapped/orwpce-*.yml until promotion.
#
# Builder contract:
# - ORWPCE HASVISIT (HASVISIT^ORWPCE): -1 = no visit; 0 = visit exists, stand-alone;
#   1 = visit exists, tied to an appointment. has_visit? is true for 0 and 1.
#   visit_status returns :none, :stand_alone, or :appointment (nil when no RPC).
# - note_ien is a non-negative integer (Integer or digit-only String). 0 selects
#   location lookup when args are complete (GET VISIT/PCE4NOTE: visit_string with
#   positive location piece 1 and FileMan datetime piece 2; HASVISIT/visit_status:
#   positive-integer location_ien and FileMan datetime). Note 0 without them: no RPC.
#   Positive note IENs need no location args; the server reads the visit from the TIU
#   note and ignores DFN (GETVISIT^ORWPCE2).
module OrwpceReadHelpers
  ROOT = File.expand_path("../..", __dir__).freeze
  UNMAPPED_DIR = File.join(ROOT, "test/fixtures/wire_captures/unmapped").freeze
  PROMOTED_DIR = File.join(ROOT, "test/fixtures/wire_captures").freeze
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json").freeze

  MODULE_NAME = "RpmsRpc::ClinicalEvent"

  IN_SCOPE_RPCS = [
    "ORWPCE GET VISIT",
    "ORWPCE GET IMMUNIZATION TYPE",
    "ORWPCE GET SKIN TEST TYPE",
    "ORWPCE GET EXAM TYPE",
    "ORWPCE GET HEALTH FACTORS TY",
    "ORWPCE GET EDUCATION TOPICS",
    "ORWPCE PCE4NOTE",
    "ORWPCE HASVISIT",
    "ORWPCE NOTEVSTR"
  ].freeze

  RPC_TO_MAPPING = {
    "ORWPCE GET VISIT" => :pce_get_visit,
    "ORWPCE GET IMMUNIZATION TYPE" => :pce_immunization_types,
    "ORWPCE GET SKIN TEST TYPE" => :pce_skin_test_types,
    "ORWPCE GET EXAM TYPE" => :pce_exam_types,
    "ORWPCE GET HEALTH FACTORS TY" => :pce_health_factor_types,
    "ORWPCE GET EDUCATION TOPICS" => :pce_education_topics,
    "ORWPCE PCE4NOTE" => :pce_for_note,
    "ORWPCE HASVISIT" => :pce_has_visit,
    "ORWPCE NOTEVSTR" => :pce_note_visit_string
  }.freeze

  CAPTURE_BASENAME = ->(rpc) { "#{rpc.downcase.tr(" /", "--")}.yml" }

  INVALID_NOTE_IDS = [ nil, "", " ", -1, "abc", "3.5" ].freeze
  INVALID_DFN_IDS = [ nil, "", " ", 0, -1, "abc", "3.5" ].freeze

  WRITE_RPC_PATTERN = /
    \bFILER\b |
    \bDELETE\b |
    \bDEL\b |
    \bSAVE\b |
    \bLOCK\b |
    \bUNLOCK\b
  /ix

  def load_unmapped_capture(rpc)
    path = File.join(UNMAPPED_DIR, CAPTURE_BASENAME.call(rpc))
    YAML.safe_load_file(path)
  end

  # Strip the CIA sequence echo and ack byte the way CiaClient#parse_cia_reply does.
  def cia_data_body(raw_return)
    bytes = raw_return.to_s.b
    rest = bytes.byteslice(1..) || "".b
    case rest.getbyte(0)
    when 0x00 then rest.byteslice(1..) || "".b
    else rest
    end
  end

  def cia_data_lines(raw_return)
    cia_data_body(raw_return).split("\r", -1)
  end

  def mapping_for(rpc)
    RpmsRpc::DataMapper[RPC_TO_MAPPING.fetch(rpc)]
  end

  class NoWireClient
    class WireReached < StandardError; end

    %i[call_rpc call_rpc_lines call_rpc_global_array call_rpc_raw].each do |name|
      define_method(name) { |rpc, *| raise WireReached, "#{rpc} reached the wire" }
    end

    def authenticated? = true

    def served_rpcs(names) = names.to_set
  end

  class RecordingClient
    attr_reader :calls

    def initialize(served: IN_SCOPE_RPCS)
      @calls = []
      @served = served.to_set
    end

    def authenticated? = true

    def served_rpcs(names) = names.to_set & @served

    def call_rpc(rpc, *params)
      @calls << [ rpc, *params ]
      ""
    end

    def call_rpc_lines(rpc, *params)
      @calls << [ rpc, *params ]
      []
    end
  end
end
