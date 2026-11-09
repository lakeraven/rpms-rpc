# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health/reference"
require_relative "../../captured_replies"

# RpmsRpc::BehavioralHealth::Reference on the AMHG replies a fresh rpms-ydb
# container sent (test/fixtures/captured_replies/amhg-reference.yml), replayed
# through CiaClient's GLOBAL ARRAY read, per ADR 0009: the parameter each read
# sends, and the empty and not-on-file answers. The round trip is
# test/live/behavioral_health_reference_live_test.rb (rpms-rpc#622).
#
# These replies are why Wire#rows splits the frame: read whole, the sequence
# echo stays on the typed header and the header parses as a record (#673).
class BehavioralHealthReferenceTest < Minitest::Test
  R = RpmsRpc::BehavioralHealth::Reference
  SLUG = "amhg-reference"

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }

  def replay(*names)
    script = Hash.new { |h, k| h[k] = [] }
    names.each { |n| script[capture(n)["rpc"] || "AMHG GET PATIENT"] << CapturedReplies.raw(SLUG, n) }
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }

  def test_patients_reads_the_one_match_and_not_the_header
    client = replay("patients")

    assert_equal [ { ien: "4", name: "DEMO,PATIENT ONE", dob: "01/01/2001", sex: "F", chart: "99901", ssn: nil,
                     reg: nil, more: nil, date_of_death: nil, age: "25", message_flag: nil, message: nil, prf: false } ],
                 R.patients("DEMO")
    assert_equal [ { rpc: "AMHG GET PATIENT", params: capture("patients")["inputs"] } ], sent(client),
                 "one pipe-joined parameter: facility|query|max, max ALL by default"
  end

  def test_patients_with_no_match_is_empty
    client = replay("patients_none")

    assert_empty R.patients("ZZZNOMATCH", facility: 7819)
    assert_equal capture("patients_none")["inputs"], sent(client).first[:params]
  end

  def test_site_parameters_reads_one_row_and_its_ien
    client = replay("site")

    site = R.site_parameters(1)
    assert_equal "1", site[:ien]
    assert_equal capture("site")["inputs"], sent(client).first[:params]
  end

  # SITE^AMHGU writes one row for any IEN (AMHGU.m:287-289), so an IEN with no
  # site parameters answers a row of blanks, not nil. Lockout is the fallback
  # number the build answers (AMHGU.m:285), the only value on the row.
  def test_site_parameters_for_an_ien_not_on_file_is_a_row_of_blanks
    replay("site_not_on_file")

    site = R.site_parameters(99_999)
    assert_equal "99999", site[:ien]
    assert_equal "99999", site[:lockout]
    assert_empty site.except(:ien, :lockout).values.reject { |v| v.nil? || v == false }
  end

  def test_admin_records_with_none_on_file_is_empty_and_sends_the_provider
    client = replay("admin_none")

    assert_empty R.admin_records("4", from: "3000101", to: "3271231")
    assert_equal capture("admin_none")["inputs"], sent(client).first[:params]
  end
  # A client whose #call_rpc already splits the recordset into rows
  # (BmxClient splits at $C(30)) hands Wire an Array. Each element is a row
  # and stays whole: a newline inside a field is data, not another record.
  # The rows are the captured patients reply, split as BmxClient splits it,
  # with a newline put into the name field.
  def test_rows_a_client_already_split_keep_a_newline_inside_a_field
    header, row = CapturedReplies.raw(SLUG, "patients").byteslice(2..).split("\x1e").first(2)
    split_rows = [ header, row.sub("DEMO,PATIENT ONE", "DEMO,PATIENT\nONE") ]
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| split_rows }
    RpmsRpc.configure { |cfg| cfg.client = client }

    patients = R.patients("DEMO")
    assert_equal 1, patients.size, "a newline inside a field is not a record boundary"
    assert_equal "DEMO,PATIENT\nONE", patients.first[:name]
    assert_equal "99901", patients.first[:chart]
  end
end
