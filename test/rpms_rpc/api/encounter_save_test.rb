# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/api/encounter"
require "rpms_rpc/retry_safety"
require_relative "../captured_replies"

# Encounter.save files an encounter through BEHOENPC SAVE (SAVE^BEHOENPC):
# the visit, its V POVs (with SNOMED concept and narrative), V CPTs, V HEALTH
# FACTORs and the primary V PROVIDER, in one call (rpms-rpc#921). The list
# layout is the one test/live/encounter_save_behoenpc_live_test.rb proved on
# the pinned build and BEHOENPC.m documents:
#
#   HDR^0^^<loc>;<fm datetime>;<category>     (HDR^BEHOENPC: piece 4 = loc;date;cat[;visit])
#   VST^DT^<fm datetime>   VST^PT^<dfn>   VST^HL^<loc>   VST^VC^<category>
#   PRV^<duz>^^^^1                            (PRV^BEHOENPC: piece 6 1=primary)
#   POV+^<icd>^^^^<1|0>^^^<snomed>^<narrative> (POV^BEHOENPC: 2 code, 6 P/S, 9 SNOMED, 10 text)
#   CPT+^<cpt>^^^^^<quantity>                 (CPT^BEHOENPC: piece 7 quantity, as Procedure.add)
#   HF+^<factor ien>^^^^<duz>                 (HF^BEHOENPC)
#
# followed by "0" and the location, the two "not used (but required)"
# formals (BEHOENPC.m:6-10). "+" always adds a row (STORE^BEHOENPC), so the
# rows this call filed are the ones that were not there before it.
#
# POV^BEHOENPC uses piece 9 as a subscript in PROBLST^BEHOENP2; an empty
# concept is a null subscript IRIS and a strict-null YottaDB refuse
# (rpms-rpc#704), so a diagnosis with no SNOMED concept is refused here,
# before anything is sent. A caret, semicolon or pipe inside a value would
# shift pieces (^), the HDR visit string (;) or the "text|description id"
# NARR^BEHOENPC files (|), so those are refused before sending too.
#
# The save answers 0 and names nothing it filed, so the wrapper reads back:
# the visit through BEHOENCX FETCH with CREATE=0 (the same FNDVIS^BEHOENCX
# lookup STORE^BEHOENPC used, and a read form that can never add a visit),
# the V POVs through BGOVPOV GET, the V CPTs through BGOVCPT GET, the V HEALTH
# FACTORs through BGOVHF GET and the V PROVIDERs through BEHOENCX GETPRV — the
# gem's existing readers, all in CIAV VUECENTRIC with the save. Success is the
# visit AND every requested entry read back as a row that was not there
# before; anything less is a failure that lists what was and was not filed.
#
# The broker here is a fake twin: it answers reads from a "before" state until
# BEHOENPC SAVE is called and from an "after" state afterwards, so the test
# pins outcomes, not the order of reads. The gem never sends a problem-list
# RPC (BGOPROB*, ORQQPL*) from this method; what the server does inside
# PROBLST^BEHOENP2 is the live spec's to witness.
class EncounterSaveTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  DFN = 990_053
  LOC = 6
  DUZ = 206
  CATEGORY = "A"
  AT = Time.new(2026, 11, 22, 10, 30, 0)
  FM = "3261122.1030" # FilemanDateParser.format_datetime(AT)
  VSTR = "#{LOC};#{FM};#{CATEGORY}".freeze
  VISIT = 117

  ICD = "F32.9"
  SNOMED = "35489007"
  NARRATIVE = "SYNTH depressive disorder, single episode"
  ICD2 = "I10"
  SNOMED2 = "38341003"
  CPT = "A0021"
  HF_IEN = 7

  PROBLEM_RPC = /\A(BGOPROB|ORQQPL)/

  # --- a fake twin -----------------------------------------------------------

  # Answers each RPC from `before` until BEHOENPC SAVE is called, then from
  # `after`. A reply is what call_rpc returns: a String for a scalar, an
  # Array of lines for a list. Records every call. No with_context, so
  # ContextScope.scoped runs the block as-is, like any plain stub.
  class FakeTwin
    attr_reader :calls

    def initialize(before: {}, after: {}, save: "0")
      @before = before
      @after = after
      @save = save
      @saved = false
      @calls = []
    end

    def duz = DUZ.to_s

    def call_rpc(rpc_name, *params)
      @calls << { rpc: rpc_name, params: params }
      if rpc_name == "BEHOENPC SAVE"
        @saved = true
        return @save
      end

      state = @saved ? @after : @before
      raise "FakeTwin: no reply for #{rpc_name} #{@saved ? 'after' : 'before'} the save" unless state.key?(rpc_name)

      reply = state[rpc_name]
      reply.respond_to?(:call) ? reply.call(params) : reply
    end

    def sent(rpc) = @calls.select { |c| c[:rpc] == rpc }
    def rpcs = @calls.map { |c| c[:rpc] }
  end

  def teardown
    RpmsRpc.reset!
  end

  def twin(**)
    RpmsRpc.reset!
    client = FakeTwin.new(**)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  # --- reply rows, in each reader's documented layout ------------------------

  # BEHOENCX FETCH: LOCNAME^LOCABBR^ROOMBED^PROVIEN^PROVNAME^VISITIEN^VISITID^LOCKED^ERRORTXT
  # (BEHOENCX.m:28-46). Piece 6 is empty when FNDVIS found nothing.
  def fetch_found(visit = VISIT) = [ "EXAMPLE CLINIC^EXC^^#{DUZ}^PROVIDER,EXAMPLE^#{visit}^^0" ]
  def fetch_not_found = [ "EXAMPLE CLINIC^EXC^^#{DUZ}^PROVIDER,EXAMPLE^^^^" ]

  # BGOVPOV GET row (BGOVPOV.m, 29 pieces; mapping :visit_povs): piece 1 IEN,
  # 5 ICD, 16 P/S, 18 visit IEN, 21 SNOMED, 22 provider text.
  def pov_row(ien:, icd:, snomed:, visit: VISIT, primary: "P", text: NARRATIVE)
    pieces = Array.new(29, "")
    pieces[0] = ien.to_s
    pieces[1] = "11/22/2026"
    pieces[2] = "000012"
    pieces[3] = "EXAMPLE CLINIC"
    pieces[4] = icd
    pieces[6] = "Example narrative | #{text}"
    pieces[15] = primary
    pieces[16] = "PROVIDER,EXAMPLE"
    pieces[17] = visit.to_s
    pieces[18] = "0"
    pieces[20] = snomed.to_s
    pieces[21] = text
    pieces[25] = "Example diagnosis"
    pieces[26] = "503126"
    pieces.join("^")
  end

  # BGOVCPT GET row (ARRAY^BGOVCPT, BGOVCPT.m:180-199): piece 4 CPT, 11 V CPT
  # IEN, 12 visit IEN, 14 quantity (as test/fixtures/captured_replies/procedure-add.yml).
  def cpt_row(ien:, cpt: CPT, visit: VISIT, quantity: 1)
    "11/22/2026^000012^EXAMPLE CLINIC^#{cpt}^Example procedure^Example procedure^^^^^#{ien}^#{visit}^1^#{quantity}^PROVIDER,EXAMPLE^^^0^CPT^"
  end

  # BGOVHF GET row (BGOVHF.m:6-7; mapping :patient_health_factors): piece 6
  # visit IEN, 7 V HEALTH FACTOR IEN, 8 HEALTH FACTOR IEN.
  def hf_row(ien:, factor: HF_IEN, visit: VISIT)
    "TOBACCO (SMOKING)^NEVER SMOKED^11/22/2026^^^#{visit}^#{ien}^#{factor}^^0^^^^"
  end

  # BEHOENCX GETPRV row: DUZ ^ NAME ^ PRIMARY ^ EVENT DATE/TIME
  def prv_row(duz: DUZ, primary: 1) = "#{duz}^PROVIDER,EXAMPLE^#{primary}^#{FM}"

  def no_rows = []

  # The state of a twin on which nothing of this encounter exists yet.
  def empty_before
    {
      "BEHOENCX FETCH" => fetch_not_found,
      "BGOVPOV GET" => no_rows,
      "BGOVCPT GET" => no_rows,
      "BGOVHF GET" => no_rows,
      "BEHOENCX GETPRV" => no_rows
    }
  end

  # The state after a save that filed everything the full request asked for.
  def full_after(pov_ien: 301, cpt_ien: 11, hf_ien: 41)
    {
      "BEHOENCX FETCH" => fetch_found,
      "BGOVPOV GET" => [ pov_row(ien: pov_ien, icd: ICD, snomed: SNOMED) ],
      "BGOVCPT GET" => [ cpt_row(ien: cpt_ien) ],
      "BGOVHF GET" => [ hf_row(ien: hf_ien) ],
      "BEHOENCX GETPRV" => [ prv_row ]
    }
  end

  def diagnosis(icd: ICD, snomed: SNOMED, narrative: NARRATIVE, primary: true)
    { icd: icd, snomed: snomed, narrative: narrative, primary: primary }
  end

  def save(**overrides)
    args = {
      location_ien: LOC, datetime: AT, service_category: CATEGORY, provider_duz: DUZ,
      diagnoses: [ diagnosis ], procedures: [ { cpt: CPT } ], health_factors: [ { ien: HF_IEN } ]
    }.merge(overrides)
    RpmsRpc::Encounter.save(DFN, **args)
  end

  def assert_no_problem_rpc(client)
    sent = client.rpcs.grep(PROBLEM_RPC)
    assert_empty sent, "Encounter.save must never send a problem-list RPC; it sent #{sent.inspect}"
  end

  def save_call(client)
    calls = client.sent("BEHOENPC SAVE")
    assert_equal 1, calls.size, "exactly one BEHOENPC SAVE is sent; saw #{calls.size}"
    calls.first
  end

  # --- the parameter list ----------------------------------------------------

  def test_save_sends_behoenpc_save_with_the_live_proven_list_layout
    client = twin(before: empty_before, after: full_after)

    save

    call = save_call(client)
    expected = {
      1 => "HDR^0^^#{LOC};#{FM};#{CATEGORY}",
      2 => "VST^DT^#{FM}",
      3 => "VST^PT^#{DFN}",
      4 => "VST^HL^#{LOC}",
      5 => "VST^VC^#{CATEGORY}",
      6 => "PRV^#{DUZ}^^^^1",
      7 => "POV+^#{ICD}^^^^1^^^#{SNOMED}^#{NARRATIVE}",
      8 => "CPT+^#{CPT}^^^^^1",
      9 => "HF+^#{HF_IEN}^^^^#{DUZ}"
    }
    assert_equal [ expected, "0", LOC.to_s ], call[:params],
                 "PCC list, then the two unused-but-required formals 0 and the location (BEHOENPC.m:6-10)"
  end

  def test_save_orders_every_pov_then_every_cpt_then_every_hf_and_marks_secondary_diagnoses_0
    after = full_after
    after["BGOVPOV GET"] = [ pov_row(ien: 301, icd: ICD, snomed: SNOMED),
                             pov_row(ien: 302, icd: ICD2, snomed: SNOMED2, primary: "S", text: "SYNTH hypertension") ]
    after["BGOVCPT GET"] = [ cpt_row(ien: 11), cpt_row(ien: 12, cpt: "99213", quantity: 2) ]
    after["BGOVHF GET"] = [ hf_row(ien: 41), hf_row(ien: 42, factor: 9) ]
    client = twin(before: empty_before, after: after)

    result = save(diagnoses: [ diagnosis, diagnosis(icd: ICD2, snomed: SNOMED2, narrative: "SYNTH hypertension", primary: false) ],
                  procedures: [ { cpt: CPT }, { cpt: "99213", quantity: 2 } ],
                  health_factors: [ { ien: HF_IEN }, { ien: 9 } ])

    pcc = save_call(client)[:params][0]
    assert_equal (1..11).to_a, pcc.keys, "the list is numbered 1..n with no gaps"
    assert_equal "POV+^#{ICD}^^^^1^^^#{SNOMED}^#{NARRATIVE}", pcc[7]
    assert_equal "POV+^#{ICD2}^^^^0^^^#{SNOMED2}^SYNTH hypertension", pcc[8], "a non-primary diagnosis is 0 in piece 6 (SET(.12,6,\"1:P;0:S\"))"
    assert_equal "CPT+^#{CPT}^^^^^1", pcc[9]
    assert_equal "CPT+^99213^^^^^2", pcc[10], "quantity rides piece 7 (CPT^BEHOENPC: SET(.16,7))"
    assert_equal "HF+^9^^^^#{DUZ}", pcc[11]
    assert result[:success], result.inspect
    assert_equal [ 301, 302 ], result[:diagnoses].map { |d| d[:ien] }
    assert_equal [ 11, 12 ], result[:procedures].map { |p| p[:ien] }
    assert_equal [ 41, 42 ], result[:health_factors].map { |h| h[:ien] }
  end

  def test_save_accepts_a_preformatted_fileman_datetime_string_verbatim
    client = twin(before: empty_before, after: full_after)

    save(datetime: "3261122.1030")

    pcc = save_call(client)[:params][0]
    assert_equal "HDR^0^^#{LOC};3261122.1030;#{CATEGORY}", pcc[1]
    assert_equal "VST^DT^3261122.1030", pcc[2]
  end

  def test_save_with_only_a_visit_and_provider_sends_the_six_header_lines
    after = full_after
    after["BGOVPOV GET"] = no_rows
    after["BGOVCPT GET"] = no_rows
    after["BGOVHF GET"] = no_rows
    client = twin(before: empty_before, after: after)

    result = save(diagnoses: [], procedures: [], health_factors: [])

    pcc = save_call(client)[:params][0]
    assert_equal (1..6).to_a, pcc.keys
    assert result[:success], result.inspect
    assert_equal VISIT, result[:visit_ien]
    assert_equal [], result[:diagnoses]
  end

  # --- refusals before sending ---------------------------------------------

  def test_a_diagnosis_without_a_snomed_concept_is_refused_before_anything_is_sent
    client = twin(before: empty_before, after: full_after)

    [ nil, "", "  " ].each do |blank|
      result = save(diagnoses: [ diagnosis(snomed: blank) ])

      refute result[:success], "snomed #{blank.inspect}: #{result.inspect}"
      assert_equal :missing_snomed, result[:error]
      assert_nil result[:raw], "nothing came back because nothing was sent"
      named = result[:not_filed].find { |e| e[:kind] == :diagnosis && e[:icd] == ICD }
      refute_nil named, "the result names the diagnosis it refused: #{result.inspect}"
    end
    assert_empty client.calls, "nothing is sent for a diagnosis with no SNOMED concept (rpms-rpc#704)"
  end

  def test_one_diagnosis_without_a_snomed_concept_refuses_the_whole_save_and_names_only_it
    client = twin(before: empty_before, after: full_after)

    result = save(diagnoses: [ diagnosis, diagnosis(icd: ICD2, snomed: nil, narrative: "SYNTH hypertension") ])

    refute result[:success]
    assert_equal :missing_snomed, result[:error]
    assert_equal [ ICD2 ], result[:not_filed].select { |e| e[:kind] == :diagnosis }.map { |e| e[:icd] },
                 "the save is all-or-nothing; the refusal names the diagnosis at fault, not the sound one"
    assert_empty client.calls
  end

  def test_a_delimiter_inside_a_value_is_refused_before_anything_is_sent
    client = twin(before: empty_before, after: full_after)

    bad = {
      "a caret in the narrative" => { diagnoses: [ diagnosis(narrative: "SYNTH text^with caret") ] },
      "a semicolon in the narrative" => { diagnoses: [ diagnosis(narrative: "SYNTH text; with semicolon") ] },
      "a pipe in the narrative" => { diagnoses: [ diagnosis(narrative: "SYNTH text|with pipe") ] },
      "a caret in the ICD" => { diagnoses: [ diagnosis(icd: "F32.9^P") ] },
      "a semicolon in the SNOMED" => { diagnoses: [ diagnosis(snomed: "35489007;1") ] },
      "a pipe in the CPT" => { procedures: [ { cpt: "A0021|25" } ] },
      "a caret in the health factor" => { health_factors: [ { ien: "7^1" } ] },
      "a semicolon in the category" => { service_category: "A;1" },
      "a caret in the location" => { location_ien: "6^1" },
      "a caret in the provider" => { provider_duz: "206^1" }
    }
    bad.each do |label, overrides|
      result = save(**overrides)

      refute result[:success], "#{label} was not refused: #{result.inspect}"
      assert_equal :delimiter, result[:error], label
      assert_nil result[:raw], label
    end
    assert_empty client.calls, "nothing is sent when a value carries ^ ; or |"
  end

  def test_a_delimiter_refusal_names_the_entry_at_fault
    twin(before: empty_before, after: full_after)

    result = save(procedures: [ { cpt: CPT }, { cpt: "992|13" } ])

    assert_equal :delimiter, result[:error]
    assert_equal [ "992|13" ], result[:not_filed].select { |e| e[:kind] == :procedure }.map { |e| e[:cpt] }
  end

  def test_blank_required_arguments_are_refused_without_a_call
    client = twin(before: empty_before, after: full_after)

    refute RpmsRpc::Encounter.save(nil, location_ien: LOC, datetime: AT, service_category: CATEGORY, provider_duz: DUZ)[:success]
    refute RpmsRpc::Encounter.save("0", location_ien: LOC, datetime: AT, service_category: CATEGORY, provider_duz: DUZ)[:success]
    refute save(location_ien: nil)[:success]
    refute save(location_ien: "")[:success]
    refute save(service_category: "")[:success]
    refute save(provider_duz: nil)[:success]
    refute save(provider_duz: 0)[:success]
    refute save(datetime: nil)[:success]
    assert_empty client.calls
  end

  def test_required_keywords_are_required
    twin(before: empty_before, after: full_after)

    assert_raises(ArgumentError) { RpmsRpc::Encounter.save(DFN, datetime: AT, service_category: CATEGORY, provider_duz: DUZ) }
    assert_raises(ArgumentError) { RpmsRpc::Encounter.save(DFN, location_ien: LOC, service_category: CATEGORY, provider_duz: DUZ) }
    assert_raises(ArgumentError) { RpmsRpc::Encounter.save(DFN, location_ien: LOC, datetime: AT, provider_duz: DUZ) }
    assert_raises(ArgumentError) { RpmsRpc::Encounter.save(DFN, location_ien: LOC, datetime: AT, service_category: CATEGORY) }
  end

  # --- the reply -------------------------------------------------------------

  def test_a_server_error_row_is_a_refused_failure_carrying_the_row_and_nothing_is_read_back
    client = twin(before: empty_before, after: full_after,
                  save: "-1^The data associated with this visit may no longer be modified.")

    result = save

    refute result[:success]
    assert_equal :refused, result[:error]
    assert_equal "-1^The data associated with this visit may no longer be modified.", result[:raw]
    assert_nil result[:visit_ien]
    assert_equal client.rpcs.size - 1, client.rpcs.index("BEHOENPC SAVE"),
                 "after a refusal nothing is read back: #{client.rpcs.inspect}"
    assert_no_problem_rpc(client)
  end

  def test_a_server_error_row_as_a_list_reply_is_the_same_refusal
    client = twin(before: empty_before, after: full_after, save: [ "-1003^Visit entry does not exist" ])

    result = save

    refute result[:success]
    assert_equal :refused, result[:error]
    assert_equal "-1003^Visit entry does not exist", result[:raw]
    assert_equal client.rpcs.index("BEHOENPC SAVE"), client.rpcs.size - 1, "nothing is read back after a refusal"
  end

  def test_a_nil_reply_is_a_failure_not_a_success
    client = twin(before: empty_before, after: full_after, save: nil)

    result = save

    refute result[:success]
    assert_nil result[:raw]
    assert_no_problem_rpc(client)
  end

  def test_a_reply_other_than_0_or_an_error_row_is_a_failure
    twin(before: empty_before, after: full_after, save: [ "unexpected", "lines" ])

    result = save

    refute result[:success]
    refute_nil result[:error]
  end

  # --- read-back -------------------------------------------------------------

  def test_success_reads_back_the_visit_and_every_entry_and_names_their_iens
    client = twin(before: empty_before, after: full_after(pov_ien: 301, cpt_ien: 11, hf_ien: 41))

    result = save

    assert result[:success], result.inspect
    assert_nil result[:error]
    assert_equal "0", result[:raw]
    assert_equal VISIT, result[:visit_ien]
    assert_equal [ { ien: 301, icd: ICD, snomed: SNOMED } ], result[:diagnoses].map { |d| d.slice(:ien, :icd, :snomed) }
    assert_equal [ { ien: 11, cpt: CPT } ], result[:procedures].map { |p| p.slice(:ien, :cpt) }
    assert_equal [ { ien: 41, factor_ien: HF_IEN } ], result[:health_factors].map { |h| h.slice(:ien, :factor_ien) }
    assert_equal({ duz: DUZ, primary: true }, result[:provider].slice(:duz, :primary))
    assert_equal [], result[:not_filed]
    assert_no_problem_rpc(client)
  end

  def test_read_back_uses_the_existing_readers_in_the_save_context_and_a_fetch_that_can_never_create
    client = twin(before: empty_before, after: full_after)

    save

    after_save = client.rpcs.drop(client.rpcs.index("BEHOENPC SAVE") + 1)
    %w[BEHOENCX\ FETCH BGOVPOV\ GET BGOVCPT\ GET BGOVHF\ GET BEHOENCX\ GETPRV].each do |rpc|
      assert_includes after_save, rpc, "#{rpc} is the read-back for its V file"
    end
    client.sent("BEHOENCX FETCH").each do |call|
      assert_equal "0", call[:params][3].to_s, "every FETCH sent is the CREATE=0 read form, never one that files a visit: #{call.inspect}"
      assert_equal VSTR, call[:params][1], "the visit is looked up by the location;datetime;category the save named"
      assert_equal DFN.to_s, call[:params][0].to_s
    end
    assert_no_problem_rpc(client)
  end

  def test_a_reply_of_0_with_no_visit_read_back_is_a_failure_naming_the_visit
    after = full_after
    after["BEHOENCX FETCH"] = fetch_not_found
    client = twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :no_visit, result[:error]
    assert_equal "0", result[:raw]
    assert_nil result[:visit_ien]
    assert_includes result[:not_filed].map { |e| e[:kind] }, :visit
    assert_no_problem_rpc(client)
  end

  def test_a_partial_save_is_a_failure_naming_the_diagnosis_not_filed_and_the_entries_that_were
    after = full_after
    after["BGOVPOV GET"] = no_rows # the server filed the visit, CPT, HF and provider, but not the POV
    client = twin(before: empty_before, after: after)

    result = save

    refute result[:success], "a partial save is never success: #{result.inspect}"
    assert_equal :partial, result[:error]
    assert_equal "0", result[:raw]
    assert_equal VISIT, result[:visit_ien], "what was filed is reported"
    assert_equal [ 11 ], result[:procedures].map { |p| p[:ien] }
    assert_equal [ 41 ], result[:health_factors].map { |h| h[:ien] }
    assert_equal({ duz: DUZ, primary: true }, result[:provider].slice(:duz, :primary))
    assert_equal [ { kind: :diagnosis, icd: ICD, snomed: SNOMED } ],
                 result[:not_filed].map { |e| e.slice(:kind, :icd, :snomed) }
    assert_equal [], result[:diagnoses]
    assert_no_problem_rpc(client)
  end

  def test_a_partial_save_names_every_kind_of_entry_not_filed
    after = full_after
    after["BGOVCPT GET"] = no_rows
    after["BGOVHF GET"] = no_rows
    after["BEHOENCX GETPRV"] = no_rows
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :partial, result[:error]
    kinds = result[:not_filed].map { |e| e[:kind] }
    assert_equal %i[procedure health_factor provider], kinds, result[:not_filed].inspect
    assert_equal CPT, result[:not_filed].find { |e| e[:kind] == :procedure }[:cpt]
    assert_equal HF_IEN, result[:not_filed].find { |e| e[:kind] == :health_factor }[:factor_ien]
    assert_equal DUZ, result[:not_filed].find { |e| e[:kind] == :provider }[:duz]
    assert_equal [ 301 ], result[:diagnoses].map { |d| d[:ien] }, "the POV that did file is still reported"
  end

  def test_a_pov_of_the_same_code_on_another_visit_is_not_this_calls
    after = full_after
    after["BGOVPOV GET"] = [ pov_row(ien: 301, icd: ICD, snomed: SNOMED, visit: 118) ]
    after["BGOVCPT GET"] = [ cpt_row(ien: 11, visit: 118) ]
    after["BGOVHF GET"] = [ hf_row(ien: 41, visit: 118) ]
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :partial, result[:error]
    assert_equal %i[diagnosis procedure health_factor], result[:not_filed].map { |e| e[:kind] }
  end

  def test_a_second_provider_row_that_is_not_primary_or_not_the_provider_sent_is_not_read_back
    after = full_after
    after["BEHOENCX GETPRV"] = [ prv_row(duz: 999, primary: 1), prv_row(duz: DUZ, primary: 0) ]
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal [ :provider ], result[:not_filed].map { |e| e[:kind] }
  end

  def test_a_matching_row_that_was_on_the_visit_before_the_save_is_not_this_calls
    # A rerun on the same day, clinic and category files onto the visit already
    # there (FNDVIS^BEHOENCX), and "+" always adds a row (STORE^BEHOENPC). When
    # the server adds nothing, the rows after are the rows before: the old POV
    # of the same code must not pass as the one this call asked for.
    before = {
      "BEHOENCX FETCH" => fetch_found,
      "BGOVPOV GET" => [ pov_row(ien: 300, icd: ICD, snomed: SNOMED) ],
      "BGOVCPT GET" => [ cpt_row(ien: 10) ],
      "BGOVHF GET" => [ hf_row(ien: 40) ],
      "BEHOENCX GETPRV" => [ prv_row ]
    }
    after = before.dup
    client = twin(before: before, after: after)

    result = save

    refute result[:success], "rows that were there before the save are not what this call filed: #{result.inspect}"
    assert_equal :partial, result[:error]
    assert_equal %i[diagnosis procedure health_factor], result[:not_filed].map { |e| e[:kind] }
    assert_equal VISIT, result[:visit_ien]
    assert_no_problem_rpc(client)
  end

  def test_on_an_existing_visit_only_the_new_rows_are_this_calls
    before = {
      "BEHOENCX FETCH" => fetch_found,
      "BGOVPOV GET" => [ pov_row(ien: 300, icd: ICD, snomed: SNOMED) ],
      "BGOVCPT GET" => [ cpt_row(ien: 10) ],
      "BGOVHF GET" => [ hf_row(ien: 40) ],
      "BEHOENCX GETPRV" => [ prv_row ]
    }
    after = {
      "BEHOENCX FETCH" => fetch_found,
      "BGOVPOV GET" => [ pov_row(ien: 300, icd: ICD, snomed: SNOMED), pov_row(ien: 301, icd: ICD, snomed: SNOMED) ],
      "BGOVCPT GET" => [ cpt_row(ien: 10), cpt_row(ien: 11) ],
      "BGOVHF GET" => [ hf_row(ien: 40), hf_row(ien: 41) ],
      "BEHOENCX GETPRV" => [ prv_row ]
    }
    twin(before: before, after: after)

    result = save

    assert result[:success], result.inspect
    assert_equal [ 301 ], result[:diagnoses].map { |d| d[:ien] }, "the new row, not the one that was there"
    assert_equal [ 11 ], result[:procedures].map { |p| p[:ien] }
    assert_equal [ 41 ], result[:health_factors].map { |h| h[:ien] }
  end

  def test_a_read_back_refusal_is_a_failure_not_a_success
    after = full_after
    after["BGOVPOV GET"] = [ "-1^Bad visit specifier" ]
    twin(before: empty_before, after: after)

    result = save

    refute result[:success], "a read-back the server refused cannot prove the POV filed: #{result.inspect}"
  end

  # --- declarations and contract files --------------------------------------

  def test_save_declares_a_post_shape_distinct_from_create
    shape = RpmsRpc::Shape.for(RpmsRpc::Encounter, :save)

    refute_nil shape, "Encounter.save must declare a shape"
    assert_equal "encounters", shape[:resource]
    assert_equal "POST", shape[:verb]
    assert_equal "/patients/{dfn}/encounters/pcc", shape[:path]
    refute_equal RpmsRpc::Shape.for(RpmsRpc::Encounter, :create)[:path], shape[:path]
  end

  def test_save_is_classified_a_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Encounter, :save)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Encounter, :save)
  end

  def test_required_rpcs_json_lists_the_save_and_its_read_backs_under_encounter
    doc = JSON.parse(File.read(File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")))
    listed = doc.fetch("modules").fetch("RpmsRpc::Encounter")
    [ "BEHOENPC SAVE", "BEHOENCX FETCH", "BGOVPOV GET", "BGOVCPT GET", "BGOVHF GET", "BEHOENCX GETPRV" ].each do |rpc|
      assert_includes listed, rpc, "required_rpcs.json must list #{rpc} under RpmsRpc::Encounter (run `bundle exec rake rpc:required_rpcs`)"
    end
    methods = doc.fetch("rpcs").fetch("BEHOENPC SAVE").fetch("methods")
    assert_equal "non_idempotent_write", methods["RpmsRpc::Encounter.save"],
                 "the contract names Encounter.save as a writer of BEHOENPC SAVE: #{methods.inspect}"
  end

  # The contract points BEHOENPC SAVE at the replies its parser is tested
  # against. Procedure.add's flow (procedure-add.yml) sends no POV line, so the
  # SNOMED-bearing conversation this method has with the build must be
  # captured too: a flow whose save carries a POV+ line, recorded on a
  # throwaway container with tools/capture_replies.rb.
  def test_a_captured_encounter_save_flow_with_a_pov_line_is_on_file
    doc = JSON.parse(File.read(File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")))
    replies = doc.fetch("rpcs").fetch("BEHOENPC SAVE").fetch("replies")
    slug = "encounter-save"
    path = "test/fixtures/captured_replies/#{slug}.yml"
    assert_includes replies, path, "required_rpcs.json must point BEHOENPC SAVE at #{path}"

    captures = CapturedReplies.file(slug).fetch("captures") # fails on a broken seal
    saves = captures.select { |c| c["rpc"] == "BEHOENPC SAVE" }
    refute_empty saves, "#{path} must record at least one BEHOENPC SAVE"
    with_pov = saves.select { |c| Array(c["inputs"]).first.is_a?(Hash) && c["inputs"].first.values.any? { |v| v.to_s.start_with?("POV+^") } }
    refute_empty with_pov, "#{path} must record a save whose list carries a POV+ line (the SNOMED path, rpms-rpc#704)"
    with_pov.each do |c|
      pov = c["inputs"].first.values.find { |v| v.to_s.start_with?("POV+^") }
      assert_match(/\A\d+\z/, pov.split("^", -1)[8].to_s, "the recorded POV+ line carries a SNOMED concept in piece 9: #{pov.inspect}")
    end
  end
end
