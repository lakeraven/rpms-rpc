# frozen_string_literal: true

require "minitest/autorun"
require "vista_rpc/data_mapper"
require "rpms_rpc/coverage_matrix"

class RpmsRpc::CoverageMatrixTest < Minitest::Test
  def setup
    @registry = {}
    @registry[:coverage_va_patient] = VistaRpc::DataMapper.define(:coverage_va_patient) do |m|
      m.backend :vista
      m.source "ORWPT1.m"
      m.rpc "ORWPT SELECT"
      m.field 0, :name
    end
    @registry[:coverage_rpms_patient] = VistaRpc::DataMapper.define(:coverage_rpms_patient) do |m|
      m.backend :rpms
      m.rpc "BEHOPTCX PTINFO"
      m.field 0, :name
    end
  end

  def test_generates_markdown_table
    test_index = Set[ "coverage_va_patient", "ORWPT SELECT" ]
    matrix = RpmsRpc::CoverageMatrix.new(registry: @registry, test_index: test_index)
    output = matrix.generate

    assert_match(/# RPC Coverage Matrix/, output)
    assert_match(/ORWPT SELECT/, output)
    assert_match(/BEHOPTCX PTINFO/, output)
    assert_match(/ORWPT1\.m/, output)
    assert_match(/unverified/, output)
    assert_match(/tested/, output)
  end

  def test_classifies_backend
    matrix = RpmsRpc::CoverageMatrix.new(registry: @registry, test_index: Set.new)
    rows = matrix.send(:sorted_mappings).map { |name, m| matrix.send(:row_for, name, m) }

    va_row = rows.find { |r| r[1].include?("ORWPT") }
    rpms_row = rows.find { |r| r[1].include?("BEHOPTCX") }

    assert_equal "VA", va_row[5]
    assert_equal "RPMS", rpms_row[5]
  end
end
