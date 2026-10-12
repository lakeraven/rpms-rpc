# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rpms_rpc/conformance/build_surface"

# BuildSurface's signatures walk (rpms-rpc#394, #395): M text that is Latin-1, and the walk's own counts.
class RpmsRpc::Conformance::BuildSurfaceTest < Minitest::Test
  Surface = RpmsRpc::Conformance::BuildSurface
  TAG = "bcer-0.0-20260101-abc1234-ydb"

  def load(signatures)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "#{TAG}-broker_8994.txt"), "XQ OPT^OPT^XQ^1\n")
      File.binwrite(File.join(dir, "#{TAG}-rpc_signatures.txt"), signatures)
      Surface.load(dir, TAG)
    end
  end

  def walk(*lines) = (lines.map { |l| l.b.tr("|", "\t") } + [ "" ]).join("\n".b)

  # bcer-9.0-20260930's XQ descriptions carry a \xB7 bullet: Latin-1, not UTF-8.
  def test_a_latin1_line_is_read_as_latin1
    rpc = load(walk("RPC|1|XQ OPT|OPT|XQ|1||||||||1|1|Y", "DESC|1|\xB7 no access".b, "DESC|1|café", "EXPLICIT SUCCESS: rpcs=1 parameters=0"))["XQ OPT"]
    assert_equal [ "· no access", "café" ], rpc.description
    assert(rpc.description.all? { |d| d.encoding == Encoding::UTF_8 && d.valid_encoding? })
  end

  def test_a_walk_whose_parameter_count_disagrees_is_refused
    e = assert_raises(Surface::Error) do
      load(walk("RPC|1|XQ OPT|OPT|XQ|1||||||||1|1|Y,A", "PARAM|1|1|A|1||0", "EXPLICIT SUCCESS: rpcs=1 parameters=2"))
    end
    assert_match(/1 parameters read, the walk reports parameters=2/, e.message)
    assert load(walk("RPC|1|XQ OPT|OPT|XQ|1||||||||1|1|Y,A", "PARAM|1|1|A|1||0", "EXPLICIT SUCCESS: rpcs=1 parameters=1"))["XQ OPT"]
  end
end
