# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/xwb_cipher"
require "rpms_rpc/client"

class XwbCipherTest < Minitest::Test
  def test_table_shape
    assert_equal 20, RpmsRpc::XwbCipher::TABLE.length
    RpmsRpc::XwbCipher::TABLE.each { |row| assert_equal 94, row.length }
  end

  def test_each_row_is_a_permutation_of_the_same_charset
    charsets = RpmsRpc::XwbCipher::TABLE.map { |row| row.chars.sort }
    charsets.each { |cs| assert_equal charsets.first, cs }
    assert_equal 94, charsets.first.uniq.length, "no duplicate chars within a row"
  end

  def test_encrypt_wraps_body_with_row_index_chars
    encrypted = RpmsRpc::XwbCipher.encrypt("HELLO")
    assert_equal 7, encrypted.length
    assert_includes 32..51, encrypted[0].ord
    assert_includes 32..51, encrypted[-1].ord
    refute_equal encrypted[0], encrypted[-1], "row pair must be distinct"
  end

  def test_encrypt_decrypt_round_trip
    [ "HELLO", "secret-code", "PROV123;PROV123!!", "Aa1!~`\\\"' ^&" ].each do |plain|
      50.times do
        assert_equal plain, RpmsRpc::XwbCipher.decrypt(RpmsRpc::XwbCipher.encrypt(plain)),
                     "round trip failed for #{plain.inspect}"
      end
    end
  end

  def test_chars_outside_the_table_pass_through
    encrypted = RpmsRpc::XwbCipher.encrypt("\tA\n")
    assert_includes encrypted, "\t"
    assert_includes encrypted, "\n"
    assert_equal "\tA\n", RpmsRpc::XwbCipher.decrypt(encrypted)
  end

  def test_decrypt_rejects_malformed_input
    assert_equal "", RpmsRpc::XwbCipher.decrypt(nil)
    assert_equal "", RpmsRpc::XwbCipher.decrypt("")
    assert_equal "", RpmsRpc::XwbCipher.decrypt("X")
    assert_equal "", RpmsRpc::XwbCipher.decrypt("\x7fAB\x7f") # row index out of range
  end

  def test_client_xwb_encrypt_delegates_to_cipher
    client = RpmsRpc::Client.allocate
    encrypted = client.xwb_encrypt("HELLO")
    assert_equal "HELLO", RpmsRpc::XwbCipher.decrypt(encrypted)
    assert_equal RpmsRpc::XwbCipher::TABLE, RpmsRpc::Client::CIPHER_TABLE
  end

  # GATE for the BMX one-parameter guarantee (and the CVC "^"-joined framing
  # on every transport): ciphertext of a caret-free plaintext can NEVER
  # contain "^", because
  #   * every TABLE row is exactly the 95 printable ASCII characters MINUS
  #     "^" — the one printable deliberately absent from all twenty rows
  #     (its absence is what makes "^" safe as the protocol delimiter), and
  #   * the two framing bytes are chr(row + 32) for rows 0..19, i.e.
  #     " ".."3" — all below "^" (94).
  # If either property is ever broken, encrypted values would split on the
  # BMX caret-join and inside CVC's caret-framed triple.
  def test_cipher_output_alphabet_excludes_the_protocol_delimiter
    printables_minus_caret = ((32..126).map(&:chr) - [ "^" ])

    RpmsRpc::XwbCipher::TABLE.each_with_index do |row, i|
      assert_equal printables_minus_caret.sort, row.chars.sort,
        "TABLE row #{i} is not the 95 printables minus '^' — encrypted " \
        "values could now contain (or fail to cover) the protocol delimiter"
    end

    100.times do
      plaintext = "PROV#{rand(10_000)};VC#{rand(10_000)}!*"
      refute_includes RpmsRpc::XwbCipher.encrypt(plaintext), "^"
    end

    # The converse, documented: "^" in the PLAINTEXT passes through (it is in
    # no row, so substitution skips it). Valid access/verify codes exclude
    # "^" (AVHLPTXT^XUS2); BmxClient rejects caret-bearing params anyway.
    assert_includes RpmsRpc::XwbCipher.encrypt("A^B"), "^"
  end
end
