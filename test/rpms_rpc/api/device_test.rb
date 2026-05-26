# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/device"

class DeviceTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:device_list, "1", [
        {
          ien: "101",
          udi: "UDI-101",
          device_identifier: "DEV-101",
          status: "inactive",
          name: "Pacemaker",
          manufacturer: "Acme Medical",
          model_number: "PM-100",
          serial_number: "SN101",
          lot_number: "LOT101",
          manufacture_date: Date.new(2021, 2, 3),
          expiration_date: Date.new(2031, 2, 3),
          snomed_code: "14106009",
          device_type: "Cardiac pacemaker",
          distinct_id: "DIST-101"
        },
        {
          ien: "102",
          udi: "UDI-102",
          device_identifier: "DEV-102",
          status: nil,
          name: "Implantable defibrillator"
        }
      ])

      m.seed(:device_detail, "101", {
        udi: "UDI-101",
        device_identifier: "DEV-101",
        status: "inactive",
        name: "Pacemaker",
        manufacturer: "Acme Medical",
        model_number: "PM-100",
        serial_number: "SN101",
        lot_number: "LOT101",
        manufacture_date: Date.new(2021, 2, 3),
        expiration_date: Date.new(2031, 2, 3),
        snomed_code: "14106009",
        device_type: "Cardiac pacemaker",
        distinct_id: "DIST-101",
        patient_dfn: "1"
      })
      m.seed(:device_detail, "102", {
        udi: "UDI-102",
        device_identifier: "DEV-102",
        status: nil,
        name: "Implantable defibrillator",
        patient_dfn: "1"
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_patient_returns_devices
    results = RpmsRpc::Device.for_patient("1")

    assert_equal 2, results.length
    device = results.first
    assert_equal "101", device[:ien]
    assert_equal "UDI-101", device[:udi]
    assert_equal "DEV-101", device[:device_identifier]
    assert_equal "Pacemaker", device[:name]
    assert_equal "Acme Medical", device[:manufacturer]
    assert_equal "PM-100", device[:model_number]
    assert_equal "SN101", device[:serial_number]
    assert_equal "LOT101", device[:lot_number]
    assert_equal Date.new(2021, 2, 3), device[:manufacture_date]
    assert_equal Date.new(2031, 2, 3), device[:expiration_date]
    assert_equal "14106009", device[:snomed_code]
    assert_equal "Cardiac pacemaker", device[:device_type]
    assert_equal "DIST-101", device[:distinct_id]
  end

  def test_for_patient_defaults_blank_status_to_active
    results = RpmsRpc::Device.for_patient("1")

    assert_equal "active", results.last[:status]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Device.for_patient(nil)
    assert_equal [], RpmsRpc::Device.for_patient("")
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::Device.for_patient("99999")
  end

  def test_find_returns_device_detail_with_ien_from_param
    device = RpmsRpc::Device.find("101")

    refute_nil device
    assert_equal "101", device[:ien]
    assert_equal "UDI-101", device[:udi]
    assert_equal "DEV-101", device[:device_identifier]
    assert_equal "inactive", device[:status]
    assert_equal "Pacemaker", device[:name]
    assert_equal "1", device[:patient_dfn]
  end

  def test_find_defaults_blank_status_to_active
    device = RpmsRpc::Device.find("102")

    assert_equal "active", device[:status]
  end

  def test_find_returns_nil_for_invalid_ien
    assert_nil RpmsRpc::Device.find(nil)
    assert_nil RpmsRpc::Device.find("")
  end

  def test_find_returns_nil_for_unknown_ien
    assert_nil RpmsRpc::Device.find("99999")
  end

  def test_find_uses_first_line_from_multi_line_detail_response
    RpmsRpc.client.seed_text(:device_detail, "201",
      "UDI-201^DEV-201^^Neurostimulator^Acme Medical^^^^^^^^^^^^1\n" \
      "ignored continuation line")

    device = RpmsRpc::Device.find("201")

    assert_equal "201", device[:ien]
    assert_equal "UDI-201", device[:udi]
    assert_equal "Neurostimulator", device[:name]
    assert_equal "active", device[:status]
  end
end
