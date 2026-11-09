# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/ddr_fileman"
require_relative "../captured_replies"

# rpms-rpc#612: under FLAGS "I", GETSC^DDR2 writes every non-word-processing
# row as FILE^IENS^FIELD^internal^ with an empty fifth piece (DDR2.m:42: only
# DDRRSLT(...,"I") is set). gets_entry held only the five comment fields to
# that shape; every non-word-processing row is now held to it, so a
# four-piece row, or one with a non-empty external, sets :stray.
#
# Evidence: test/fixtures/captured_replies/ddr-gets-entry-data-flags-i.yml,
# captured live after the Wellness live spec filed BH visit 1. The malformed
# replies are those captured bytes with one row changed.
class RpmsRpc::DdrGetsFlagsIRowShapeTest < Minitest::Test
  SLUG = "ddr-gets-entry-data-flags-i"
  BH_FIELDS = ".08;1112;1401;1402;1403;1404;1405;1406;1407;1408;1409;1410;1501;1601;1701;1901;2001"

  def teardown
    RpmsRpc.reset!
  end

  def read(raw, file: "9002011", iens: "1,", fields: BH_FIELDS, flags: "I")
    RpmsRpc.configure { |cfg| cfg.client = CapturedReplies::ReplayCiaClient.new("DDR GETS ENTRY DATA" => [ raw ]) }
    RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: flags)
  end

  def bh_raw = CapturedReplies.raw(SLUG, "bh_visit_screening_fields")
  def patient_raw = CapturedReplies.raw(SLUG, "patient_fields")

  # The captured row for a field, and the same bytes with that row replaced.
  def with_row(raw, field, replacement)
    row = raw.split("\r").find { |line| line.split("^", -1)[2] == field }
    flunk "the capture has no row for field #{field}" unless row
    raw.sub("\r#{row}\r".b, "\r#{replacement}\r".b)
  end

  def test_the_captured_bh_visit_reads_clean
    parsed = read(bh_raw)

    refute parsed[:stray], "a reply exactly as GETSC^DDR2 wrote it is not stray"
    refute parsed[:error]
    assert_equal "990045", parsed[:fields][".08"][:internal]
    assert_equal "N", parsed[:fields]["1403"][:internal]
    assert_equal "P", parsed[:fields]["1405"][:internal]
  end

  def test_the_captured_patient_read_reads_clean
    parsed = read(patient_raw, file: "2", iens: "2,", fields: ".01;.02;.03;.09;.301;1901")

    refute parsed[:stray]
    assert_equal "USER,TEST", parsed[:fields][".01"][:internal]
  end

  %w[.08 1112 1403 1405].each do |field|
    define_method("test_a_four_piece_#{field.delete('.')}_row_is_stray") do
      row = bh_raw.split("\r").find { |line| line.split("^", -1)[2] == field }
      parsed = read(with_row(bh_raw, field, row.delete_suffix("^")))

      assert parsed[:stray], "field #{field} without the empty fifth piece is not the FLAGS I shape"
    end
  end

  def test_a_result_row_with_an_external_piece_is_stray
    parsed = read(with_row(bh_raw, "1403", "9002011^1^1403^N^NEGATIVE"))

    assert parsed[:stray], "under FLAGS I the external piece is empty"
  end

  def test_a_patient_date_row_without_the_fifth_piece_is_stray
    raw = with_row(patient_raw, ".03", "2^2^.03^2850505")

    assert read(raw, file: "2", iens: "2,", fields: ".01;.02;.03;.09;.301;1901")[:stray]
  end

  def test_the_captured_provider_read_reads_clean_and_a_filled_external_is_stray
    raw = CapturedReplies.raw(SLUG, "provider_name")
    args = { file: "200", iens: "204,", fields: ".01" }

    refute read(raw, **args)[:stray]
    assert_equal "PROFILE,MA", read(raw, **args)[:fields][".01"][:internal]
    assert read(with_row(raw, ".01", "200^204^.01^PROFILE,MA^PROFILE,MA"), **args)[:stray],
           "a FLAGS I row never carries the external; one that does is not what GETSC^DDR2 wrote"
  end

  def test_the_comment_fields_keep_their_rule
    parsed = read(bh_raw)

    assert_equal "Synthetic live alcohol screening note", parsed[:fields]["1601"][:internal]
    assert read(with_row(bh_raw, "1601", "9002011^1^1601^Synthetic live alcohol screening note"))[:stray]
  end

  def test_without_flags_i_a_four_piece_row_is_not_held_to_the_shape
    raw = with_row(bh_raw, "1403", "9002011^1^1403^N")

    refute read(raw, flags: "")[:stray], "the rule is the FLAGS I shape only"
  end
end
