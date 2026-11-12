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
#   note and ignores DFN (GETVISIT^ORWPCE2). Optional visit_string / location_ien /
#   datetime on that path are sent only when blank or well-formed; malformed values
#   must not reach the broker.
# - Because the server ignores DFN there, ClinicalEvent reads the note's patient
#   first (issue #531): TIU GET ALERT INFO (GETALRT^TIUSRVR), one parameter, the
#   note IEN, under OR CPRS GUI CHART. The reply is "note^DFN^tab", or -1. The
#   ORWPCE RPC is sent only when that DFN is the DFN the caller passed; anything
#   else raises ClinicalEvent::NotePatientMismatchError and sends no ORWPCE RPC.
#   Note 0 (the location lookup, which does use DFN) makes no such read.
# - PCE4NOTE HDR piece 5 (1-indexed) is the note author ($P(^TIU(8925,IEN,12),U,2)),
#   exposed as :author_ien (Integer), not :visit_ien.
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

  # The note-ownership read (#531). Not an ORWPCE read and not a promoted
  # capture, so it stays out of IN_SCOPE_RPCS; ClinicalEvent still requires it.
  NOTE_PATIENT_RPC = "TIU GET ALERT INFO"
  NOTE_PATIENT_MAPPING = :tiu_note_patient
  NOTE_PATIENT_CONTEXT = "OR CPRS GUI CHART"
  NOTE_KEYED_RPCS = [ "ORWPCE GET VISIT", "ORWPCE HASVISIT", "ORWPCE PCE4NOTE" ].freeze
  REQUIRED_RPCS = (IN_SCOPE_RPCS + [ NOTE_PATIENT_RPC ]).freeze

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

  # The reply GETALRT^TIUSRVR gives for a note on file: note^DFN^tab.
  def note_owner_reply(note_ien, dfn)
    "#{note_ien}^#{dfn}^903"
  end

  # Seed a MockClient with the note's patient, as verbatim wire lines.
  def seed_note_owner(mock, note_ien, dfn)
    mock.seed_raw_lines(NOTE_PATIENT_MAPPING, note_ien, [ note_owner_reply(note_ien, dfn) ])
  end

  def note_patient_calls(client)
    client.calls.select { |rpc, *| rpc == NOTE_PATIENT_RPC }
  end

  # Every call but the ownership read.
  def orwpce_calls(client)
    client.calls.reject { |rpc, *| rpc == NOTE_PATIENT_RPC }
  end

  # A positive-note read: one ownership read carrying the note IEN, then the
  # ORWPCE call, and nothing else.
  def assert_guarded_calls(client, note_ien, expected_call, msg = nil)
    assert_equal [ expected_call ], orwpce_calls(client), msg
    owner = note_patient_calls(client)
    assert_equal 1, owner.size, "expected one #{NOTE_PATIENT_RPC} call; got #{client.calls.inspect}"
    assert_equal [ note_ien.to_s ], owner.first.drop(1).map(&:to_s),
                 "#{NOTE_PATIENT_RPC} takes the note IEN and nothing else"
    assert_equal NOTE_PATIENT_RPC, client.calls.first.first,
                 "the ownership read must come before #{expected_call.first}"
  end

  # Records every call as [ rpc, *params ] and the option it ran under
  # (#contexts, same index). ORWPCE calls answer empty. TIU GET ALERT INFO
  # answers +owner_reply+: by default the note asked for, owned by
  # +owner_dfn+; otherwise the raw reply given (String, Array or nil), or an
  # exception to raise.
  class RecordingClient
    OWNED = Object.new.freeze

    attr_reader :calls, :contexts

    def initialize(served: REQUIRED_RPCS, owner_dfn: "4", owner_reply: OWNED)
      @calls = []
      @contexts = []
      @context_stack = []
      @served = served.to_set
      @owner_dfn = owner_dfn
      @owner_reply = owner_reply
    end

    def authenticated? = true

    def served_rpcs(names) = names.to_set & @served

    def with_context(option_name)
      @context_stack.push(option_name)
      yield
    ensure
      @context_stack.pop
    end

    def call_rpc(rpc, *params)
      record(rpc, params)
      return owner_reply(params) if rpc == NOTE_PATIENT_RPC

      ""
    end

    def call_rpc_lines(rpc, *params)
      record(rpc, params)
      return [] unless rpc == NOTE_PATIENT_RPC

      reply = owner_reply(params)
      reply.is_a?(String) ? reply.split(/\r\n|\r|\n/) : reply
    end

    private

    def record(rpc, params)
      @calls << [ rpc, *params ]
      @contexts << @context_stack.last
    end

    def owner_reply(params)
      raise @owner_reply if @owner_reply.is_a?(Exception)
      return "#{params.first}^#{@owner_dfn}^903" if @owner_reply.equal?(OWNED)

      @owner_reply
    end
  end
end
