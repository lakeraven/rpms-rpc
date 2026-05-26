# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/vendor"

class VendorTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed_collection(:vendor_list, [
        {
          ien: 101, name: "Metro Health Center", type: "FACILITY", specialty: "Cardiology",
          preferred: true, phone: "555-0100", city: "Portland", state: "OR"
        },
        {
          ien: 102, name: "Northwest Specialists", type: "GROUP", specialty: "Orthopedics",
          preferred: false, phone: "555-0200", city: "Seattle", state: "WA"
        },
        {
          ien: 103, name: "River City Clinic", type: "FACILITY", specialty: "Radiology",
          preferred: true, phone: "555-0300", city: "Portland", state: "OR"
        }
      ])

      m.seed_collection(:preferred_vendor_list, [
        {
          ien: 101, name: "Metro Health Center", type: "FACILITY", specialty: "Cardiology",
          preferred: true, phone: "555-0100", city: "Portland", state: "OR"
        },
        {
          ien: 103, name: "River City Clinic", type: "FACILITY", specialty: "Radiology",
          preferred: true, phone: "555-0300", city: "Portland", state: "OR"
        }
      ])

      m.seed(:vendor_detail, "101", {
        ien: 101,
        name: "Metro Health Center",
        type: "FACILITY",
        specialties_raw: "Cardiology, Internal Medicine",
        preferred: true,
        phone: "555-0100",
        fax: "555-0101",
        email: "contact@example.invalid",
        contact_name: "Primary Contact",
        street: "123 Example Way",
        city: "Portland",
        state: "OR",
        zip: "97201",
        contracted_services_raw: "MRI, CT Scan, Cardiology Consult",
        contract_start_date: Date.new(2024, 1, 1),
        contract_end_date: Date.new(2027, 12, 31),
        active: true
      })

      m.seed(:vendor_detail, "102", {
        ien: 102,
        name: "Northwest Specialists",
        type: "GROUP",
        specialties_raw: "",
        preferred: false,
        phone: "555-0200",
        city: "Seattle",
        state: "WA",
        contracted_services_raw: "",
        active: true
      })

      m.seed_keyed_collection(:vendor_service_list, "MRI", [
        { ien: 101, name: "Metro Health Center", service: "MRI", specialty: "Radiology", rate: "1500.00", preferred: true },
        { ien: 103, name: "River City Clinic", service: "MRI", specialty: "Radiology", rate: "1800.00", preferred: false }
      ])

      m.seed_keyed_collection(:vendor_contract_list, "101", [
        {
          id: 201,
          vendor_ien: 101,
          start_date: Date.new(2024, 1, 1),
          end_date: Date.new(2027, 12, 31),
          services_raw: "MRI, CT Scan, Cardiology Consult",
          notes: "Multi-year contract with preferred rates"
        }
      ])

      m.seed_keyed_collection(:vendor_contract_list, "104", [
        {
          id: 204,
          vendor_ien: 104,
          start_date: Date.new(2022, 1, 1),
          end_date: Date.new(2023, 12, 31),
          services_raw: "General Consult",
          notes: "Expired contract"
        }
      ])

      m.seed_keyed_collection(:vendor_rate_list, "101", [
        { service: "MRI", rate: "1500.00", unit: "procedure", effective_date: Date.new(2024, 1, 1) },
        { service: "Cardiology Consult", rate: "350.00", unit: "visit", effective_date: Date.new(2024, 1, 1) }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_search_returns_matching_vendors
    vendors = RpmsRpc::Vendor.search(name: "Metro", specialty: "Cardiology", type: "FACILITY")

    assert_equal 1, vendors.length
    assert_equal "101", vendors.first[:ien]
    assert_equal "Metro Health Center", vendors.first[:name]
    assert_equal true, vendors.first[:preferred]
  end

  def test_search_uses_mapping_rpc_name
    RpmsRpc::Vendor.search(name: "Metro")

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMCRPC SRCHVEND" }
    refute_nil call
    assert_equal [ "Metro", "", "" ], call[:params]
  end

  def test_search_returns_empty_for_unknown_name
    assert_equal [], RpmsRpc::Vendor.search(name: "Unknown Vendor")
  end

  def test_find_returns_vendor_detail
    vendor = RpmsRpc::Vendor.find(101)

    refute_nil vendor
    assert_equal "101", vendor[:ien]
    assert_equal "Metro Health Center", vendor[:name]
    assert_equal [ "Cardiology", "Internal Medicine" ], vendor[:specialties]
    assert_equal [ "MRI", "CT Scan", "Cardiology Consult" ], vendor[:contracted_services]
    assert_equal "555-0100", vendor[:contact_info][:phone]
    assert_equal "123 Example Way", vendor[:address][:street]
    assert_equal Date.new(2024, 1, 1), vendor[:contract_start_date]
  end

  def test_find_defaults_blank_multi_value_fields_to_empty_arrays
    vendor = RpmsRpc::Vendor.find(102)

    refute_nil vendor
    assert_equal [], vendor[:specialties]
    assert_equal [], vendor[:contracted_services]
  end

  def test_find_rejects_only_blank_ien
    # Vendor IDs are opaque tokens (e.g. "VENDOR-001"), not numeric IENs,
    # so the only invalid input is truly blank — non-numeric strings like
    # "VENDOR-001" or "abc" must be allowed through to the RPC.
    assert_nil RpmsRpc::Vendor.find(nil)
    assert_nil RpmsRpc::Vendor.find("")
    assert_nil RpmsRpc::Vendor.find("   ")
  end

  def test_find_returns_nil_for_unknown_ien
    assert_nil RpmsRpc::Vendor.find(999_999)
  end

  def test_find_accepts_non_numeric_vendor_id
    RpmsRpc.client.seed(:vendor_detail, "VENDOR-001", {
      ien: "VENDOR-001",
      name: "Northwest Specialists",
      type: "GROUP",
      preferred: true,
      active: true
    })

    vendor = RpmsRpc::Vendor.find("VENDOR-001")
    refute_nil vendor, "non-numeric vendor IDs must reach the RPC"
    assert_equal "VENDOR-001", vendor[:ien]
  end

  def test_preferred_returns_preferred_vendors
    vendors = RpmsRpc::Vendor.preferred

    assert_equal [ "101", "103" ], vendors.map { |v| v[:ien] }
    assert vendors.all? { |v| v[:preferred] }
  end

  def test_preferred_filters_by_specialty
    vendors = RpmsRpc::Vendor.preferred(specialty: "Radio")

    assert_equal [ "103" ], vendors.map { |v| v[:ien] }
  end

  def test_for_service_returns_vendors_with_rates
    vendors = RpmsRpc::Vendor.for_service("MRI")

    assert_equal 2, vendors.length
    assert_equal BigDecimal("1500.00"), vendors.first[:rate]
    assert_equal BigDecimal("1500.00"), vendors.first[:contracted_rate]
  end

  def test_for_service_returns_empty_for_blank_service
    assert_equal [], RpmsRpc::Vendor.for_service(nil)
    assert_equal [], RpmsRpc::Vendor.for_service("")
  end

  def test_contracts_returns_vendor_contracts_with_status
    contracts = RpmsRpc::Vendor.contracts(101)

    assert_equal 1, contracts.length
    contract = contracts.first
    assert_equal "201", contract[:id]
    assert_equal "101", contract[:vendor_ien]
    assert_equal [ "MRI", "CT Scan", "Cardiology Consult" ], contract[:services]
    assert_equal "ACTIVE", contract[:status]
    assert_equal true, contract[:active]
  end

  def test_contracts_reject_invalid_ien
    assert_equal [], RpmsRpc::Vendor.contracts(nil)
    assert_equal [], RpmsRpc::Vendor.contracts("")
    assert_equal [], RpmsRpc::Vendor.contracts(0)
    assert_equal [], RpmsRpc::Vendor.contracts(-1)
    assert_equal [], RpmsRpc::Vendor.contracts("abc")
  end

  def test_contracts_returns_empty_for_unknown_ien
    assert_equal [], RpmsRpc::Vendor.contracts(999_999)
  end

  def test_active_contract_returns_current_contract
    contract = RpmsRpc::Vendor.active_contract(101)

    refute_nil contract
    assert_equal "201", contract[:id]
  end

  def test_active_predicate_is_false_for_expired_or_unknown_vendor
    assert_equal false, RpmsRpc::Vendor.active?(104)
    assert_equal false, RpmsRpc::Vendor.active?(999_999)
  end

  def test_rates_returns_contracted_rates
    rates = RpmsRpc::Vendor.rates(101)

    assert_equal 2, rates.length
    assert_equal "MRI", rates.first[:service]
    assert_equal "MRI", rates.first[:service_type]
    assert_equal BigDecimal("1500.00"), rates.first[:amount]
    assert_equal "procedure", rates.first[:unit]
    assert_equal Date.new(2024, 1, 1), rates.first[:effective_date]
  end

  def test_rates_reject_invalid_ien
    assert_equal [], RpmsRpc::Vendor.rates(nil)
    assert_equal [], RpmsRpc::Vendor.rates("")
    assert_equal [], RpmsRpc::Vendor.rates(0)
    assert_equal [], RpmsRpc::Vendor.rates(-1)
    assert_equal [], RpmsRpc::Vendor.rates("abc")
  end
end
