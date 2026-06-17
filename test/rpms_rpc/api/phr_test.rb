# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/phr"

class PhrTest < Minitest::Test
  DFN = 8791
  INVALID_IDS = [ nil, "", 0, -5, "abc" ].freeze

  def setup
    @start_date = Date.new(2025, 5, 26)
    @end_date = Date.new(2026, 5, 26)
    ccd_key = "#{DFN}^05/26/2025^05/26/2026"

    RpmsRpc.mock! do |m|
      # BEHOCCD PHR is line-based: line 0 = "1"/"0", line 1 = optional message.
      # seed_text models the multi-line wire shape; fetch_one would only see
      # the first line.
      m.seed_text(:phr_access, DFN.to_s, "1\nPatient portal enabled")
      m.seed_text(:phr_access, "123", "0")

      m.seed_keyed_collection(:ccd_document, ccd_key, [
        {
          ien: 501, date: Date.new(2026, 5, 1), source: "External Clinic",
          title: "Visit CCD", type: "CCD"
        },
        {
          ien: 502, date: Date.new(2026, 5, 2), source: "Hospital",
          title: nil, type: nil
        }
      ])

      m.seed_text(:immunization_text, "501",
        "<?xml version=\"1.0\"?>\n" \
        "<ClinicalDocument>\n" \
        "  <title>Continuity of Care Document</title>\n" \
        "</ClinicalDocument>")
      m.seed_text(:immunization_text, "502",
        "<html>\n" \
        "<body>CCD preview</body>\n" \
        "</html>")

      m.seed(:immunization_count, DFN.to_s, { total: 5, reconciled: 2 })

      m.seed_keyed_collection(:ccd_referral, "9001^9002", [
        {
          referral_ien: 7001, visit_ien: 9001, has_ccd: true,
          ccd_sent_date: Date.new(2026, 5, 10), provider_name: "PROVIDER,TEST",
          facility: "Test Facility"
        },
        {
          referral_ien: 7002, visit_ien: 9002, has_ccd: false,
          ccd_sent_date: nil, provider_name: "PROVIDER,TWO", facility: nil
        }
      ])

      m.seed(:phr_patient_direct, DFN.to_s, { direct_address: "patient@example.direct", status: "active" })
      m.seed(:phr_patient_direct, "123", { direct_address: "-1^No address", status: nil })
      m.seed(:phr_provider_direct, "301", { direct_address: "provider@example.direct", status: "active" })
      m.seed(:phr_facility_direct, "55", { direct_address: "clinic.example.direct", status: "active" })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_enrollment_status_returns_access_hash
    status = RpmsRpc::Phr.enrollment_status(DFN)

    assert_equal true, status[:enrolled]
    assert_equal true, status[:has_access]
    assert_equal "Patient portal enabled", status[:message]
  end

  def test_enrollment_status_defaults_blank_message
    status = RpmsRpc::Phr.enrollment_status(123)

    assert_equal false, status[:enrolled]
    assert_equal false, status[:has_access]
    assert_equal "PHR not enrolled", status[:message]
  end

  def test_enrollment_status_rejects_blank_zero_negative_and_nonnumeric_dfn
    INVALID_IDS.each do |dfn|
      assert_equal false, RpmsRpc::Phr.enrollment_status(dfn)[:has_access]
      assert_equal false, RpmsRpc::Phr.has_access?(dfn)
    end
  end

  def test_enrollment_status_returns_disabled_for_unknown_dfn
    status = RpmsRpc::Phr.enrollment_status(999_999)

    assert_equal false, status[:has_access]
    assert_equal "No response", status[:message]
  end

  def test_for_patient_sends_caret_delimited_date_range
    RpmsRpc::Phr.for_patient(DFN, start_date: @start_date, end_date: @end_date)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOCIR1 GETCCDS" }
    refute_nil call
    assert_equal [ "#{DFN}^05/26/2025^05/26/2026" ], call[:params]
  end

  def test_for_patient_returns_ccd_documents_with_defaults
    documents = RpmsRpc::Phr.for_patient(DFN, start_date: @start_date, end_date: @end_date)

    assert_equal 2, documents.length
    first = documents.first
    assert_equal 501, first[:ien]
    assert_equal Date.new(2026, 5, 1), first[:date]
    assert_equal "External Clinic", first[:source]
    assert_equal "Visit CCD", first[:title]

    second = documents.last
    assert_equal "Clinical Document", second[:title]
    assert_equal "CCD", second[:type]
  end

  def test_for_patient_returns_empty_for_invalid_or_unknown_dfn
    INVALID_IDS.each do |dfn|
      assert_equal [], RpmsRpc::Phr.for_patient(dfn, start_date: @start_date, end_date: @end_date)
    end

    assert_equal [], RpmsRpc::Phr.for_patient(999_999, start_date: @start_date, end_date: @end_date)
  end

  def test_find_returns_multiline_ccd_content_and_detects_xml
    document = RpmsRpc::Phr.find(501)

    refute_nil document
    assert_equal "xml", document[:format]
    assert_includes document[:content], "<ClinicalDocument>"
    assert_includes document[:content], "\n"
  end

  def test_find_detects_html_content
    assert_equal "html", RpmsRpc::Phr.find(502)[:format]
  end

  def test_find_returns_nil_for_invalid_or_unknown_ien
    INVALID_IDS.each do |ien|
      assert_nil RpmsRpc::Phr.find(ien)
    end

    assert_nil RpmsRpc::Phr.find(999_999)
  end

  def test_counts_returns_total_reconciled_and_pending
    counts = RpmsRpc::Phr.counts(DFN)

    assert_equal 5, counts[:total]
    assert_equal 2, counts[:reconciled]
    assert_equal 3, counts[:pending]
  end

  def test_counts_returns_zeroes_for_invalid_or_unknown_dfn
    (INVALID_IDS + [ 999_999 ]).each do |dfn|
      assert_equal({ total: 0, reconciled: 0, pending: 0 }, RpmsRpc::Phr.counts(dfn))
    end
  end

  def test_referrals_for_visits_returns_ccd_status
    referrals = RpmsRpc::Phr.referrals_for_visits([ 9001, 9002 ])

    assert_equal 2, referrals.length
    assert_equal 7001, referrals.first[:referral_ien]
    assert_equal 9001, referrals.first[:visit_ien]
    assert_equal true, referrals.first[:has_ccd]
    assert_equal Date.new(2026, 5, 10), referrals.first[:ccd_sent_date]
  end

  def test_referrals_for_visits_rejects_invalid_ids
    assert_equal [], RpmsRpc::Phr.referrals_for_visits(INVALID_IDS)
  end

  def test_direct_address_methods_return_addresses
    assert_equal "patient@example.direct", RpmsRpc::Phr.patient_direct_address(DFN)
    assert_equal "provider@example.direct", RpmsRpc::Phr.provider_direct_address(301)
    assert_equal "clinic.example.direct", RpmsRpc::Phr.facility_direct_domain(55)
  end

  def test_direct_address_methods_return_nil_for_errors_and_invalid_ids
    assert_nil RpmsRpc::Phr.patient_direct_address(123)
    assert_nil RpmsRpc::Phr.patient_direct_address(0)
  end

  def test_record_access_sends_bphr_record_access_payload
    RpmsRpc::Phr.record_access(DFN, access_type: "DOWNLOAD", date: Date.new(2026, 5, 26))

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BPHR RECORD ACCESS" }
    refute_nil call
    assert_equal [ "#{DFN}^DOWNLOAD^05/26/2026" ], call[:params]
  end

  # === :bphr_phr_endpoints capability gating ===============================

  def test_patient_direct_address_nil_when_bphr_unsupported
    RpmsRpc.client.seed_capability(:bphr_phr_endpoints, supported: false)
    assert_nil RpmsRpc::Phr.patient_direct_address(DFN)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BPHR PATIENT DIRECT" }
  end

  def test_provider_direct_address_nil_when_bphr_unsupported
    RpmsRpc.client.seed_capability(:bphr_phr_endpoints, supported: false)
    assert_nil RpmsRpc::Phr.provider_direct_address(301)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BPHR PROVIDER DIRECT" }
  end

  def test_facility_direct_domain_nil_when_bphr_unsupported
    RpmsRpc.client.seed_capability(:bphr_phr_endpoints, supported: false)
    assert_nil RpmsRpc::Phr.facility_direct_domain(55)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BPHR FACILITY DIRECT" }
  end

  def test_record_access_nil_when_bphr_unsupported
    RpmsRpc.client.seed_capability(:bphr_phr_endpoints, supported: false)
    assert_nil RpmsRpc::Phr.record_access(DFN, access_type: "VIEW")
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BPHR RECORD ACCESS" }
  end
end
