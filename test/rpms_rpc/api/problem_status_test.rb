# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/problem"
require_relative "../captured_replies"

# Problem.add / .update: the status in piece 8 of the BGOPROB SET "P" line
# is never guessed (rpms-rpc#923).
#
# PROB^BGOPROB3 (BGOPROB3.m:111-115 on the pinned build) matches piece 8
# case-sensitively against the names Chronic, Inactive, Sub-acute, Episodic,
# Social/Environmental, Routine/Admin and Admin, and files ANYTHING else as E
# (EPISODIC) without an error — including the internal letters a caller reads
# back from PROBLEM (#9000011) .12 (A:CHRONIC; I:INACTIVE; D:DELETED;
# S:SUB-ACUTE; E:EPISODIC; O:SOCIAL; R:ROUTINE/ADMIN). Reproduced live:
# status "A" answered success and .12 read back E.
#
# So the gem sends only a name BGOPROB matches: an accepted name is sent as
# itself, an internal letter is mapped to its name, a status is matched
# without regard to case but always sent as the exact name, and any other
# value — including D / Deleted, which belongs to Problem.delete — is refused
# with the failure hash, naming the status, before anything goes over the
# wire. An omitted status keeps today's behaviour: piece 8 empty, and the
# build applies its own default (BGOPROB3.m:113-114).
#
# Replies are the build's (test/fixtures/captured_replies/problem-write.yml);
# ReplayCiaClient does not check inputs, so the P line each case sends is
# read off the recorded call.
class ProblemStatusTest < Minitest::Test
  SLUG = "problem-write"
  DFN = 990_055
  IEN = 148
  PROBLEM = {
    icd_code: "F32.9", description: "SYNTH CAPTURE DEPRESSION", location_ien: "7819", onset_date: "11/01/2026"
  }.freeze

  # The names PROB^BGOPROB3 matches (BGOPROB3.m:115), each sent exactly.
  ACCEPTED_NAMES = %w[Chronic Inactive Sub-acute Episodic Social/Environmental Routine/Admin Admin].freeze

  # PROBLEM .12 internal letter => the name BGOPROB files it under.
  LETTERS = {
    "A" => "Chronic", "I" => "Inactive", "S" => "Sub-acute",
    "E" => "Episodic", "O" => "Social/Environmental", "R" => "Routine/Admin"
  }.freeze

  # Caller spelling => the exact name that must go in piece 8.
  CASE_VARIANTS = {
    "chronic" => "Chronic", "CHRONIC" => "Chronic", "inactive" => "Inactive", "SUB-ACUTE" => "Sub-acute",
    "episodic" => "Episodic", "social/environmental" => "Social/Environmental", "ROUTINE/ADMIN" => "Routine/Admin",
    "admin" => "Admin", "a" => "Chronic", "i" => "Inactive", "s" => "Sub-acute", "e" => "Episodic",
    "o" => "Social/Environmental", "r" => "Routine/Admin"
  }.freeze

  # Values BGOPROB would file as EPISODIC today: a word a caller might mean
  # "active" by, and the deleted letter and its names (delete is its own method).
  REFUSED = [ "ACTIVE-ISH", "Active", "ACTIVE", "D", "d", "Deleted", "DELETED", "Social", "Routine", "P", "X", "1" ].freeze

  # A caret shifts every later piece of the P line (class, number, priority).
  CARETS = [ "Chronic^X", "^", "A^", "^Chronic", "Routine^Admin" ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # Piece 8 of the one BGOPROB SET "P" line the client sent (1-based in M;
  # PROB_FIELDS puts :status after "P", snomed_ct, descriptive_ct,
  # description, icd_code, location_ien, onset_date).
  def status_sent(client)
    sets = client.calls.select { |c| c[:rpc] == "BGOPROB SET" }
    assert_equal 1, sets.size, "exactly one BGOPROB SET is sent, got #{sets.map { |c| c[:params] }.inspect}"
    lines = sets.first[:params][3]
    assert_equal 1, lines.size, "one P line, got #{lines.inspect}"
    lines.first.split("^", -1)[7]
  end

  def add(client_flow, status)
    client = replay_flow(client_flow)
    result = RpmsRpc::Problem.add(DFN, PROBLEM.merge(status: status))
    [ client, result ]
  end

  def update(client_flow, status)
    client = replay_flow(client_flow)
    result = RpmsRpc::Problem.update(DFN, IEN, PROBLEM.merge(status: status))
    [ client, result ]
  end

  def assert_refused(result, status, client)
    assert_equal({ success: false, ien: nil, raw: nil }, result.except(:error),
                 "status #{status.inspect} must answer the module's failure hash, got #{result.inspect}")
    assert_kind_of String, result[:error], "status #{status.inspect}: the refusal names the status, so it is text"
    assert_includes result[:error], status, "status #{status.inspect}: the refusal must name the status it refused"
    assert_empty sent(client), "status #{status.inspect} was refused yet something was sent: #{sent(client).inspect}"
  end

  # --- an accepted name is sent as itself ------------------------------------

  def test_add_sends_each_accepted_name_as_itself
    ACCEPTED_NAMES.each do |name|
      client, result = add("add_new", name)

      assert result[:success], "status #{name.inspect}: #{result.inspect}"
      assert_equal name, status_sent(client), "status #{name.inspect} must go out in piece 8 exactly as BGOPROB matches it"
    end
  end

  def test_update_sends_each_accepted_name_as_itself
    ACCEPTED_NAMES.each do |name|
      client, result = update("update", name)

      assert result[:success], "status #{name.inspect}: #{result.inspect}"
      assert_equal name, status_sent(client), "status #{name.inspect} must go out in piece 8 exactly as BGOPROB matches it"
      assert_equal [ "DDR GETS ENTRY DATA", "BGOPROB SET", "DDR GETS ENTRY DATA" ], sent(client).map(&:first),
                   "the patient check and read-back still bracket the write"
    end
  end

  # --- the .12 internal letters map to their names -----------------------------

  def test_add_maps_each_internal_letter_to_the_name_bgoprob_files_it_under
    LETTERS.each do |letter, name|
      client, result = add("add_new", letter)

      assert result[:success], "status #{letter.inspect}: #{result.inspect}"
      assert_equal name, status_sent(client), "letter #{letter.inspect} (PROBLEM .12) must be sent as #{name.inspect}, not as itself (filed E today)"
    end
  end

  def test_update_maps_each_internal_letter_to_the_name_bgoprob_files_it_under
    LETTERS.each do |letter, name|
      client, result = update("update", letter)

      assert result[:success], "status #{letter.inspect}: #{result.inspect}"
      assert_equal name, status_sent(client), "letter #{letter.inspect} (PROBLEM .12) must be sent as #{name.inspect}, not as itself (filed E today)"
    end
  end

  # --- case: matched without regard to case, sent as the exact name -----------

  def test_add_matches_a_status_without_regard_to_case_and_sends_the_exact_name
    CASE_VARIANTS.each do |given, name|
      client, result = add("add_new", given)

      assert result[:success], "status #{given.inspect}: #{result.inspect}"
      assert_equal name, status_sent(client), "#{given.inspect} must be sent as #{name.inspect}: BGOPROB compares case-sensitively (BGOPROB3.m:115)"
    end
  end

  def test_update_matches_a_status_without_regard_to_case_and_sends_the_exact_name
    CASE_VARIANTS.each do |given, name|
      client, result = update("update", given)

      assert result[:success], "status #{given.inspect}: #{result.inspect}"
      assert_equal name, status_sent(client), "#{given.inspect} must be sent as #{name.inspect}: BGOPROB compares case-sensitively (BGOPROB3.m:115)"
    end
  end

  # --- anything else is refused before anything is sent ------------------------

  def test_add_refuses_a_status_bgoprob_does_not_know_before_sending
    REFUSED.each do |status|
      client = replay({})

      result = RpmsRpc::Problem.add(DFN, PROBLEM.merge(status: status))

      assert_refused result, status, client
    end
  end

  def test_update_refuses_a_status_bgoprob_does_not_know_before_sending
    REFUSED.each do |status|
      client = replay({})

      result = RpmsRpc::Problem.update(DFN, IEN, PROBLEM.merge(status: status))

      assert_refused result, status, client
    end
  end

  def test_deleted_is_not_a_status_add_or_update_takes
    # .12 D is what DEL^BGOPROB3 files; Problem.delete owns it (who, when,
    # reason). Through SET it would in any case have filed E.
    [ "D", "Deleted", "DELETED", "d" ].each do |status|
      client = replay({})
      assert_refused RpmsRpc::Problem.add(DFN, PROBLEM.merge(status: status)), status, client

      client = replay({})
      assert_refused RpmsRpc::Problem.update(DFN, IEN, PROBLEM.merge(status: status)), status, client
    end
  end

  def test_a_status_containing_a_caret_is_refused_before_sending
    CARETS.each do |status|
      client = replay({})
      assert_refused RpmsRpc::Problem.add(DFN, PROBLEM.merge(status: status)), status, client

      client = replay({})
      assert_refused RpmsRpc::Problem.update(DFN, IEN, PROBLEM.merge(status: status)), status, client
    end
  end

  def test_a_refused_status_is_refused_before_the_patient_check_on_update
    # "Before anything is sent" includes update's DDR read of the problem:
    # the status is the caller's input, checked before any RPC.
    client = replay({})

    result = RpmsRpc::Problem.update(DFN, IEN, PROBLEM.merge(status: "ACTIVE-ISH"))

    refute result[:success]
    assert_empty client.calls, "not even the patient check (DDR GETS ENTRY DATA) goes out for a refused status"
  end

  def test_a_status_that_is_not_a_string_is_refused_before_sending
    [ :chronic, 1, [ "Chronic" ] ].each do |status|
      client = replay({})

      result = RpmsRpc::Problem.add(DFN, PROBLEM.merge(status: status))

      assert_equal({ success: false, ien: nil, raw: nil }, result.except(:error), "status #{status.inspect}: #{result.inspect}")
      assert_includes result[:error].to_s, status.to_s, "status #{status.inspect}: the refusal names the status"
      assert_empty sent(client)
    end
  end

  # --- an omitted status keeps today's behaviour --------------------------------

  def test_an_omitted_status_leaves_piece_8_empty_for_the_builds_default
    # BGOPROB3.m:113-114: an empty piece 8 takes the SNOMED lookup's default
    # status, else "Episodic". The gem does not fill it in; what the build
    # files then is the build's choice, not a guess of the gem's.
    [ PROBLEM, PROBLEM.merge(status: nil), PROBLEM.merge(status: "") ].each do |problem|
      client = replay_flow("add_new")
      result = RpmsRpc::Problem.add(DFN, problem)

      assert result[:success], "problem #{problem.inspect}: #{result.inspect}"
      assert_equal "", status_sent(client), "problem #{problem.inspect}: piece 8 is empty"

      client = replay_flow("update")
      result = RpmsRpc::Problem.update(DFN, IEN, problem)

      assert result[:success], "problem #{problem.inspect}: #{result.inspect}"
      assert_equal "", status_sent(client), "problem #{problem.inspect}: piece 8 is empty"
    end
  end

  # --- the other pieces are untouched -------------------------------------------

  def test_mapping_the_status_changes_no_other_piece
    client, = add("add_new", "A")

    assert_equal [ "P^^^SYNTH CAPTURE DEPRESSION^F32.9^7819^11/01/2026^Chronic^^^" ],
                 client.calls.find { |c| c[:rpc] == "BGOPROB SET" }[:params][3]
    assert_equal CapturedReplies.flow_calls(SLUG, "add_new"), sent(client),
                 "status A sends the very frame the Chronic capture recorded"
  end
end
