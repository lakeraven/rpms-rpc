# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "rpms_rpc/conformance/fingerprint"

class RpmsRpc::Conformance::FingerprintTest < Minitest::Test
  FULL_HASH = {
    "backend" => "iris_rpms",
    "lineage" => "rpms",
    "release" => "bcer-8.0",
    "source" => {
      "kind" => "broker_dump",
      "captured_at" => "2026-06-07",
      "note" => "file 8994 export from staging"
    },
    "rpcs" => {
      "XWB ECHO STRING" => { "tag" => "ECHO1", "routine" => "XWBZ1", "return_type" => "P" },
      "DDR LISTER" => { "tag" => "LISTC", "routine" => "DDR", "return_type" => "R" }
    },
    "packages" => { "PHARMACY" => "7.0" },
    "patches" => [ "APSP*1.0*70" ],
    "bmw_tables" => { "BMW.PATIENT" => %w[NAME DOB] }
  }.freeze

  def test_from_h_populates_all_faces
    fp = RpmsRpc::Conformance::Fingerprint.from_h(FULL_HASH)

    assert_equal "iris_rpms", fp.backend
    assert_equal "rpms", fp.lineage
    assert_equal "bcer-8.0", fp.release
    assert_equal "broker_dump", fp.source["kind"]
    assert_equal "2026-06-07", fp.source["captured_at"]
    assert_equal 2, fp.rpcs.size
    assert_equal "ECHO1", fp.rpcs["XWB ECHO STRING"]["tag"]
    assert_equal({ "PHARMACY" => "7.0" }, fp.packages)
    assert_equal [ "APSP*1.0*70" ], fp.patches
    assert_equal({ "BMW.PATIENT" => %w[NAME DOB] }, fp.bmw_tables)
  end

  def test_optional_faces_default_empty
    fp = RpmsRpc::Conformance::Fingerprint.from_h(
      "backend" => "yottadb_vista",
      "lineage" => "vista",
      "rpcs" => { "XWB ECHO STRING" => { "tag" => "ECHO1" } }
    )

    assert_nil fp.release
    assert_equal({}, fp.packages)
    assert_equal [], fp.patches
    assert_equal({}, fp.bmw_tables)
    assert_equal({}, fp.source)
  end

  def test_rpcs_default_empty_and_nil_metadata_normalized
    fp = RpmsRpc::Conformance::Fingerprint.from_h("backend" => "iris_rpms")
    assert_equal({}, fp.rpcs)
    assert fp.rpc_names.empty?

    seeded = RpmsRpc::Conformance::Fingerprint.from_h(
      "rpcs" => { "GMTS PWH REPORT" => nil }
    )
    assert_equal({}, seeded.rpcs["GMTS PWH REPORT"])
  end

  def test_rpc_names_returns_a_set_of_names
    fp = RpmsRpc::Conformance::Fingerprint.from_h(FULL_HASH)

    assert_instance_of Set, fp.rpc_names
    assert_equal Set["XWB ECHO STRING", "DDR LISTER"], fp.rpc_names
  end

  def test_package_versions_normalizes_to_string_keys_and_values
    fp = RpmsRpc::Conformance::Fingerprint.from_h(
      "packages" => { "IHS KERNEL MENU OPTIONS" => 2, "IHS PATIENT REGISTRATION" => 7.2 }
    )

    assert_equal(
      { "IHS KERNEL MENU OPTIONS" => "2", "IHS PATIENT REGISTRATION" => "7.2" },
      fp.package_versions
    )
  end

  def test_package_versions_is_empty_when_packages_face_is_empty
    assert_equal({}, RpmsRpc::Conformance::Fingerprint.from_h({}).package_versions)
  end

  def test_packages_round_trip_through_to_h_and_load
    fp = RpmsRpc::Conformance::Fingerprint.from_h(FULL_HASH)
    assert_equal({ "PHARMACY" => "7.0" }, fp.package_versions)

    reloaded = RpmsRpc::Conformance::Fingerprint.from_h(fp.to_h)
    assert_equal fp.packages, reloaded.packages
    assert_equal({ "PHARMACY" => "7.0" }, reloaded.package_versions)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "fp.yml")
      File.write(path, YAML.dump(fp.to_h))
      assert_equal({ "PHARMACY" => "7.0" }, RpmsRpc::Conformance::Fingerprint.load(path).package_versions)
    end
  end

  def test_to_h_round_trips_through_from_h
    fp = RpmsRpc::Conformance::Fingerprint.from_h(FULL_HASH)

    assert_equal FULL_HASH, fp.to_h
    assert_equal fp.to_h, RpmsRpc::Conformance::Fingerprint.from_h(fp.to_h).to_h
  end

  def test_load_reads_a_yaml_fixture
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fp.yml")
      File.write(path, YAML.dump(FULL_HASH))

      fp = RpmsRpc::Conformance::Fingerprint.load(path)

      assert_equal "bcer-8.0", fp.release
      assert_equal Set["XWB ECHO STRING", "DDR LISTER"], fp.rpc_names
    end
  end
end
