# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rpms_rpc/conformance/package_dump"

class RpmsRpc::Conformance::PackageDumpTest < Minitest::Test
  # Real capture shape (rpms-ops bin/capture.sh): the M loop writes
  # PREFIX^NAME^VERSION per PACKAGE #9.4 entry, wrapped in session noise —
  # blank lines and bare "RPMS>" prompts.
  DUMP = <<~DUMP

    RPMS>
    %Z^UTILITIES^
    AKMO^IHS KERNEL MENU OPTIONS^2
    AG^IHS PATIENT REGISTRATION^7.2
    DPTD^PATIENT MERGE^.5
    XM^MAILMAN^8.0

    RPMS>
  DUMP

  def test_parses_prefix_name_version_lines_into_name_to_version
    packages = RpmsRpc::Conformance::PackageDump.parse(DUMP)

    assert_equal "2", packages["IHS KERNEL MENU OPTIONS"]
    assert_equal "7.2", packages["IHS PATIENT REGISTRATION"]
    assert_equal ".5", packages["PATIENT MERGE"]
    assert_equal "8.0", packages["MAILMAN"]
  end

  def test_skips_blank_lines_and_prompt_noise
    packages = RpmsRpc::Conformance::PackageDump.parse(DUMP)

    refute packages.key?("RPMS>")
    refute packages.key?("")
    assert_equal 5, packages.size
  end

  def test_missing_version_is_tolerated_as_empty_string
    packages = RpmsRpc::Conformance::PackageDump.parse(DUMP)

    assert packages.key?("UTILITIES")
    assert_equal "", packages["UTILITIES"]
  end

  def test_output_is_sorted_by_package_name
    packages = RpmsRpc::Conformance::PackageDump.parse(DUMP)

    assert_equal packages.keys.sort, packages.keys
  end

  def test_parse_file_reads_a_dump_from_disk
    Dir.mktmpdir do |dir|
      path = File.join(dir, "packages_9_4.txt")
      File.write(path, DUMP)

      packages = RpmsRpc::Conformance::PackageDump.parse_file(path)

      assert_equal "7.2", packages["IHS PATIENT REGISTRATION"]
    end
  end

  def test_lines_without_a_name_field_are_skipped
    packages = RpmsRpc::Conformance::PackageDump.parse("XX^^1.0\n^\nAG^IHS PATIENT REGISTRATION^7.2\n")

    assert_equal({ "IHS PATIENT REGISTRATION" => "7.2" }, packages)
  end
end
