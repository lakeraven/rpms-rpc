# frozen_string_literal: true

require_relative "crs_test"

# The gate's findings on RpmsRpc::Crs (rpms-rpc#920), pinned beside the spec:
# the wait never sleeps past its deadline, a request CRS would file but compute
# nonsense from is refused before sending (a baseline after the period, a name
# outside the report name's input transform, a loose export flag or list), the
# RPC names come from the crs_* mappings, and a row that does not fit its
# header is a reply error. Reuses the spec's fake twin and rows; runs only its
# own tests.
class CrsGateTest < CrsTest
  def self.runnable_methods = methods_matching(/\Atest_gate_/)

  # A fake clock, injected where Crs reads its clock: now reads it, pause
  # advances it and records the wait.
  class FakeClock
    attr_reader :now, :waits

    def initialize
      @now = 0.0
      @waits = []
    end

    def pause(seconds)
      @waits << seconds
      @now += seconds
    end
  end

  def with_fake_clock
    fake = FakeClock.new
    Crs.instance_variable_set(:@clock, fake)
    yield fake.waits, -> { fake.now }
  ensure
    Crs.remove_instance_variable(:@clock) if Crs.instance_variable_defined?(:@clock)
  end

  def running_twin
    twin(RPCS[:report_status] => blob(CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: "RUNNING")))
  end

  def test_gate_the_last_wait_is_cut_short_at_the_deadline_and_the_timeout_is_raised_there
    client = running_twin

    with_fake_clock do |waits, clock|
      assert_raises(Crs::TimeoutError) { Crs.wait_for_report(12, timeout: 10, interval: 4) }

      assert_equal [ 4, 4, 2 ], waits, "the third wait stops at the deadline instead of sleeping a whole interval"
      assert_in_delta 10.0, clock.call, 1e-9, "the timeout is raised at the deadline, not an interval after it"
    end
    assert_equal 4, client.sent(RPCS[:report_status]).size, "polled at 0, 4, 8 and once more at the deadline"
  end

  def test_gate_a_timeout_shorter_than_the_interval_waits_only_the_timeout
    running_twin

    with_fake_clock do |waits, clock|
      assert_raises(Crs::TimeoutError) { Crs.wait_for_report(12, timeout: 1.5, interval: 30) }

      assert_equal [ 1.5 ], waits
      assert_in_delta 1.5, clock.call, 1e-9
    end
  end

  def test_gate_a_baseline_year_after_the_report_period_is_refused_before_sending
    client = twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "21"))

    assert_raises(ArgumentError) { queue_lists(baseline_year: 2027) } # period ends 2026-11-23
    assert_raises(ArgumentError) { queue_lists(period: { year: 2024, quarter: 4 }, baseline_year: 2025) }
    assert_empty client.calls

    queue_lists(baseline_year: 2026)
    queue_lists(period: { year: 2024, quarter: 4 }, baseline_year: 2024)
    assert_equal 2, client.calls.size, "a baseline in the period's own year is allowed"
  end

  def test_gate_a_name_outside_the_report_name_input_transform_is_refused_before_sending
    client = twin(RPCS[:queue_national_gpra] => blob(DATA_HEADER, "12"), RPCS[:queue_patient_lists] => blob(DATA_HEADER, "21"))

    # .01 of BGP 25 GUI REPORT OUTPUT: K:$L(X)>60!($L(X)<3)!'(X'?1P.E) X
    [ "AB", "A" * 61, " ABC", ".ABC", "-ABC", "(SYNTH)", "SYNTHÉ" ].each do |name|
      assert_raises(ArgumentError, name.inspect) { Crs.queue_national_gpra(community_taxonomy: TAX, name: name) }
      assert_raises(ArgumentError, name.inspect) { queue_lists(name: name) }
    end
    assert_empty client.calls

    [ "ABC", "A" * 60, "1ABC", "abc" ].each { |name| Crs.queue_national_gpra(community_taxonomy: TAX, name: name) }
    assert_equal 4, client.calls.size
  end

  def test_gate_export_to_area_takes_only_true_or_false
    client = twin(RPCS[:queue_national_gpra] => blob(DATA_HEADER, "12"))

    [ "1", 1, nil, "true", :yes ].each do |flag|
      assert_raises(ArgumentError, flag.inspect) { Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL", export_to_area: flag) }
    end
    assert_empty client.calls
  end

  def test_gate_a_measure_given_twice_or_a_list_that_is_not_an_array_is_refused_before_sending
    client = twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "21"))

    assert_raises(ArgumentError) { queue_lists(lists: { 1 => [ 1 ], "1" => [ 2 ] }) }
    assert_raises(ArgumentError) { queue_lists(lists: { 1 => 1 }) }
    assert_raises(ArgumentError) { queue_lists(lists: { 1 => "1" }) }
    assert_empty client.calls
  end

  def test_gate_the_rpc_names_and_option_come_from_the_crs_mappings
    mappings = %i[crs_site_parameters crs_community_taxonomy_check crs_taxonomies crs_indicators
                  crs_national_gpra_queue crs_patient_lists_queue crs_report_status crs_report_output]
    assert_equal RPCS.values.sort, mappings.map { |m| RpmsRpc::DataMapper[m].rpc_name }.sort
    mappings.each { |m| assert_equal Crs::CONTEXT, RpmsRpc::DataMapper[m].bound_context, m }
    refute Crs.constants.any? { |c| c.to_s.end_with?("_RPC") }, "no second copy of the RPC names in Crs"
  end

  def test_gate_a_row_that_does_not_fit_its_header_is_a_reply_error
    twin(RPCS[:site_parameters] => blob(SP_HEADER, "7819^7819~DEMO IHS CLINIC^^"),
         RPCS[:indicators] => blob(GI_HEADER, "1^Diabetes^Prevalence"),
         RPCS[:report_status] => blob(CHK_HEADER, "12^SYNTH NPL^MANAGER,SYSTEM"))

    error = assert_raises(Crs::ReplyError) { Crs.site_parameters }
    assert_includes error.message, RPCS[:site_parameters]
    assert_raises(Crs::ReplyError) { Crs.indicators }
    assert_raises(Crs::ReplyError) { Crs.report_status }
  end

  def test_gate_a_one_column_table_keeps_a_caret_inside_its_row
    twin(RPCS[:report_output] => blob(DATA_HEADER, "NUMERATOR^DENOMINATOR  12^40"),
         RPCS[:community_taxonomy] => blob(COMM_HEADER, "Warning A^B is in the taxonomy but not in the standard community table."))

    assert_equal [ "NUMERATOR^DENOMINATOR  12^40" ], Crs.report_output(12)
    assert_equal [ "Warning A^B is in the taxonomy but not in the standard community table." ], Crs.community_taxonomy(TAX)[:warnings]
  end
end
