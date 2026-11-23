# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/pov"
require_relative "../captured_replies"

# Pov.for_visit names each BGOVPOV GET piece for what GET^BGOVPOV puts in it
# (rpms-rpc#927). The row is built at BGOVPOV.m:191-192 on
# bcer-9.0-20261119-f67498c-ydb:
#
#   IEN ^ VDATE ^ FAC ^ FACNAM ^ ICD ^ EPIS ^ PNAR ^ MOD ^ ONSET ^ STAGE ^
#   REVISIT ^ CAUSE ^ IDT ^ ICAU ^ IPL ^ PRIM ^ PRV ^ VIEN ^ LOCKED ^ CONTROL ^
#   SNOMEDTX ^ PROVTEXT ^ QUAL ^ PROB ^ ICCODE ^ ICDNAME ^ POV ^ NORM ^
#   LATEXT ^ FRACTXT|FRAC
#
# Piece 21 is SNOMEDTX, piece 4 of $$CONC^BSTSAPI: the concept's
# description, not its ID (V POV 1101). The concept ID is not in the row.
# The reply is the build's, recorded in encounter-save.yml (save/6): the
# V POV BEHOENPC SAVE filed for SNOMED 35489007 on visit 119.
class PovGetPiecesTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def captured_row
    client = CapturedReplies::ReplayCiaClient.new("BGOVPOV GET" => [ CapturedReplies.raw("encounter-save", "save/6") ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    rows = RpmsRpc::Pov.for_visit(119)
    assert_equal 1, rows.size, rows.inspect
    rows.first
  end

  def test_piece_21_is_the_snomed_description
    row = captured_row

    assert_equal "Depressive disorder", row[:snomed_description]
    refute row.key?(:snomed_ct), "no field is named for a SNOMED concept ID the row does not carry: #{row.inspect}"
  end

  def test_the_captured_row_parses_to_its_real_fields
    row = captured_row

    assert_equal 204, row[:ien]
    assert_equal "F32.9", row[:icd_code]
    assert_equal "Depressive disorder | SYNTH CAPTURE depressive disorder", row[:narrative]
    assert_equal "PRIMARY", row[:primary_or_secondary]
    assert_equal "PROFILE,MD", row[:provider_name]
    assert_equal 119, row[:visit_ien]
    assert_equal " SYNTH CAPTURE depressive disorder", row[:provider_text]
    assert_equal "||", row[:qualifiers]
    assert_equal "152", row[:problem_ien]
    assert_equal "Major depressive disorder, single episode, unspecified", row[:icd_name]
    assert_equal 504_091, row[:icd_ien]
    assert_equal "", row[:laterality].to_s
    assert_equal "|", row[:fracture], "piece 30 is FRACTXT|FRAC, empty halves when none is filed"
  end
end
