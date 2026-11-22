# frozen_string_literal: true

require_relative "encounter_save_test"

# The gate's findings on PR #926 (rpms-rpc#921), pinned beside the spec:
# entries are validated before anything is sent, a failed read before the save
# stops it, a row the request does not explain is never success, and a read
# that fails after the save says the save may have filed. Reuses the spec's
# fake twin and reply rows; runs only its own tests.
class EncounterSaveGateTest < EncounterSaveTest
  def self.runnable_methods = methods_matching(/\Atest_gate_/)

  def test_gate_an_entry_that_is_not_a_hash_or_has_unknown_keys_is_refused_before_sending
    client = twin(before: empty_before, after: full_after)

    [ { diagnoses: [ nil ] }, { diagnoses: [ "F32.9" ] }, { procedures: [ :A0021 ] }, { health_factors: [ 7 ] },
      { diagnoses: [ diagnosis.merge(snomedct: "1") ] }, { procedures: [ { code: CPT } ] } ].each do |overrides|
      result = save(**overrides)

      refute result[:success], "#{overrides.inspect}: #{result.inspect}"
      assert_equal :invalid, result[:error], overrides.inspect
      refute result[:may_have_filed]
      refute_empty result[:not_filed], overrides.inspect
    end
    assert_empty client.calls
  end

  def test_gate_a_value_a_pcc_line_needs_is_required_before_sending
    client = twin(before: empty_before, after: full_after)

    [ { diagnoses: [ diagnosis(icd: nil) ] }, { diagnoses: [ diagnosis(icd: " ") ] },
      { procedures: [ { cpt: "" } ] }, { procedures: [ { cpt: CPT, quantity: "not a number" } ] },
      { procedures: [ { cpt: CPT, quantity: 0 } ] }, { health_factors: [ { ien: nil } ] },
      { health_factors: [ { ien: "x" } ] } ].each do |overrides|
      result = save(**overrides)

      assert_equal :invalid, result[:error], "#{overrides.inspect}: #{result.inspect}"
    end
    assert_empty client.calls
  end

  def test_gate_a_failed_visit_read_before_the_save_stops_it
    before = empty_before.merge("BEHOENCX FETCH" => [ "-1^FETCH refused" ])
    client = twin(before: before, after: full_after)

    result = save

    refute result[:success]
    assert_equal :snapshot_failed, result[:error]
    refute result[:may_have_filed]
    assert_empty client.sent("BEHOENPC SAVE"), "nothing is written after a failed read before the save"
  end

  def test_gate_a_fetch_error_text_before_the_save_stops_it
    before = empty_before.merge("BEHOENCX FETCH" => [ "EXAMPLE CLINIC^EXC^^#{DUZ}^PROVIDER,EXAMPLE^^^^Invalid location" ])
    client = twin(before: before, after: full_after)

    assert_equal :snapshot_failed, save[:error]
    assert_empty client.sent("BEHOENPC SAVE")
  end

  def test_gate_a_read_after_the_save_that_fails_says_the_save_may_have_filed
    after = full_after.merge("BGOVPOV GET" => [ "-1^read refused" ])
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :read_back_failed, result[:error]
    assert result[:may_have_filed], "the save was sent: #{result.inspect}"
    assert_equal "0", result[:raw], "the save's own reply is kept"
    assert_match(/read refused/, result[:read_back_error])
  end

  def test_gate_a_connection_failure_during_the_save_says_it_may_have_filed
    client = twin(before: empty_before, after: full_after)
    def client.call_rpc(rpc_name, *params)
      raise RpmsRpc::Client::TimeoutError, "read timed out" if rpc_name == "BEHOENPC SAVE"

      super
    end

    result = save

    refute result[:success]
    assert result[:may_have_filed]
    assert_equal :save_failed, result[:error], "no reply came back from the save itself"
    assert_nil result[:raw]
  end

  def test_gate_a_connection_failure_before_the_save_raises_and_nothing_is_sent
    client = twin(before: empty_before, after: full_after)
    def client.call_rpc(rpc_name, *params)
      raise RpmsRpc::Client::ConnectionError, "broker gone" if rpc_name == "BEHOENCX FETCH"

      super
    end

    assert_raises(RpmsRpc::Client::ConnectionError) { save }
    assert_empty client.sent("BEHOENPC SAVE")
  end

  def test_gate_another_sessions_pov_on_the_visit_is_not_this_calls
    # This call's POV did not file; another session's POV (another narrative)
    # landed on the visit between the reads. It must not stand in for it.
    after = full_after.merge("BGOVPOV GET" => [ pov_row(ien: 305, icd: ICD, snomed: SNOMED, text: "SYNTH another session") ])
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :partial, result[:error]
    assert_equal [ { kind: :diagnosis, icd: ICD, snomed: SNOMED } ], result[:not_filed].map { |e| e.slice(:kind, :icd, :snomed) }
    assert_equal [ { kind: :diagnosis, ien: 305 } ], result[:unattributed]
  end

  def test_gate_an_extra_new_row_no_request_explains_is_ambiguous_not_success
    after = full_after
    after["BGOVCPT GET"] = [ cpt_row(ien: 11), cpt_row(ien: 12) ]
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :ambiguous, result[:error]
    assert_equal [ { kind: :procedure, ien: 12 } ], result[:unattributed]
  end

  def test_gate_a_procedure_is_matched_by_quantity_too
    after = full_after
    after["BGOVCPT GET"] = [ cpt_row(ien: 11, quantity: 3) ]
    twin(before: empty_before, after: after)

    result = save(procedures: [ { cpt: CPT, quantity: 2 } ])

    refute result[:success]
    assert_includes result[:not_filed].map { |e| e[:kind] }, :procedure
  end

  def test_gate_a_primary_provider_already_on_the_visit_is_reported_as_pre_existing
    before = empty_before.merge("BEHOENCX FETCH" => fetch_found, "BEHOENCX GETPRV" => [ prv_row ])
    twin(before: before, after: full_after)

    result = save

    assert result[:success], result.inspect
    assert result[:provider][:pre_existing]
  end

  # A concept that maps to two ICDs (e.g. 301011002 -> B96.20;N39.0 on the
  # pinned build) files a second V POV with the same narrative and problem
  # (ADDICD^BEHOENP2). It belongs to the diagnosis, not to nobody.
  def test_gate_a_concepts_extra_icd_row_is_reported_under_its_diagnosis
    after = full_after.merge("BGOVPOV GET" => [ pov_row(ien: 301, icd: "B96.20", snomed: "", problem: 77),
                                               pov_row(ien: 302, icd: "N39.0", snomed: "", primary: "S", problem: 77) ])
    twin(before: empty_before, after: after)

    result = save

    assert result[:success], result.inspect
    assert_equal [ { ien: 302, icd: "N39.0" } ], result[:diagnoses].first[:additional]
    assert_equal [], result[:unattributed]
  end

  def test_gate_two_diagnoses_with_one_narrative_keep_their_own_rows
    narrative = "SYNTH same narrative"
    after = full_after.merge("BGOVPOV GET" => [ pov_row(ien: 301, icd: ICD, snomed: "", text: narrative, problem: 77),
                                               pov_row(ien: 302, icd: "Z00.0", snomed: "", text: narrative, problem: 77),
                                               pov_row(ien: 303, icd: ICD2, snomed: "", text: narrative, problem: 78) ])
    twin(before: empty_before, after: after)

    result = save(diagnoses: [ diagnosis(narrative: narrative), diagnosis(icd: ICD2, snomed: SNOMED2, narrative: narrative, primary: false) ])

    assert result[:success], result.inspect
    assert_equal [ [ 301, 77, [ 302 ] ], [ 303, 78, [] ] ],
                 result[:diagnoses].map { |d| [ d[:ien], d[:problem_ien], d[:additional].map { |a| a[:ien] } ] }
  end

  def test_gate_a_health_factor_the_build_has_no_entry_for_is_never_reported_filed
    after = full_after.merge("BGOVHF GET" => [ "^^11/22/2026^^^#{VISIT}^41^#{HF_IEN}^^0^^^^" ])
    twin(before: empty_before, after: after)

    result = save

    refute result[:success]
    assert_equal :partial, result[:error]
    assert_equal [], result[:health_factors]
    assert_equal [ { kind: :health_factor, factor_ien: HF_IEN, ien: 41, reason: :unknown_health_factor } ],
                 result[:not_filed].select { |e| e[:kind] == :health_factor }
  end

  def test_gate_a_datetime_string_must_be_a_fileman_date_before_sending
    client = twin(before: empty_before, after: full_after)

    [ "11/22/2026", "3261122.", "326112", "today" ].each do |bad|
      assert_equal :invalid, save(datetime: bad)[:error], bad
    end
    assert_empty client.calls
  end
end
