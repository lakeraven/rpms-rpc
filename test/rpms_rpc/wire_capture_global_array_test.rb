# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "rpms_rpc/wire_capture"

# Issue #562: AGG LOOKUP PATIENTS and other GLOBAL ARRAY replies use $C(30)/$C(31),
# not newlines. WireCapture.data_rows must split them for capture grading.
class RpmsRpc::WireCaptureGlobalArrayTest < Minitest::Test
  RS = "\x1e".b
  US = "\x1f".b

  AGG_LOOKUP_HEADER =
    "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"

  AGG_LOOKUP_ROW = "2^USER,TEST^123456-DIC^^MAY 5,1985^^NO^^N"

  AGG_LOOKUP_RAW =
    ("6\x00#{AGG_LOOKUP_HEADER}#{RS}#{AGG_LOOKUP_ROW}#{RS}#{US}").b

  AGG_LOOKUP_HEADER_ONLY =
    ("5\x00#{AGG_LOOKUP_HEADER}#{RS}#{US}").b

  NEWLINE_RAW = "17^TMP^98.6^3260901.1436^98.6 F^(37.0 C)^ORAL\n" \
                "18^BP^120/80^3260901.1436^120/80^^"

  def test_data_rows_splits_global_array_records_and_drops_typed_header
    rows = RpmsRpc::WireCapture.data_rows(AGG_LOOKUP_RAW)
    assert_equal [ AGG_LOOKUP_ROW ], rows
  end

  def test_global_array_header_only_reply_has_no_data_rows
    assert_empty RpmsRpc::WireCapture.data_rows(AGG_LOOKUP_HEADER_ONLY)
  end

  def test_newline_separated_replies_keep_existing_data_rows
    framed = "6\x00#{NEWLINE_RAW}"
    rows = RpmsRpc::WireCapture.data_rows(framed)
    assert_equal NEWLINE_RAW.split("\n"), rows
  end

  def test_error_reply_stays_true_for_access_denied_ack_byte
    assert RpmsRpc::WireCapture.error_reply?("6\x01Access denied for remote procedure.")
  end
end
