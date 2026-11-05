# frozen_string_literal: true

require_relative "../data_mapper"

module RpmsRpc
  module Mappings
    # AMHG SAVE SCREENING — SCREEN^AMHGSVF (AMHGSVF.m:307-341) calls
    # SCREEN^AMHGEVF (AMHGEVF.m:331-355). One pipe parameter, nineteen
    # pieces. Results are external set names; $$SCI^AMHGT (AMHGT.m:183-196)
    # converts an exact external match and returns blank for anything else,
    # and a blank files as a clear. All fifteen screening fields are filed
    # with FILE^DIE("K") (no input transforms). Pipe pieces 9 and 10
    # (AMHPP, AMHP) are read and not filed. The reply is a recordset whose
    # data row is the record IEN, or "0~Edit Screening" (AMHGSVF.m:337-340,
    # AMHGEVF.m:353-354). Wellness parses that reply itself.
    DataMapper.define(:amhg_save_screening) do |m|
      m.rpc "AMHG SAVE SCREENING"
      m.text_blob :body
    end

    # AMHG SAVE MEASUREMENTS — MSR^AMHGSVF (AMHGSVF.m:343-370) calls
    # MODMSR^AMHGEVF (AMHGEVF.m:411-427). One pipe parameter:
    # "MODE|REC|TYPE~~VALUE~PROV*...|DFN". ARRAY^AMHGU (AMHGU.m:22-32)
    # splits the third piece on "*" and turns "^" into a space. Mode "E"
    # then runs DELMSR^AMHGEVF (AMHGSVF.m:365, AMHGEVF.m:429-443) and
    # deletes measurements the call did not list. The reply data row is the
    # record IEN, or the last "0~Add Measurement" / "0~Edit Measurement"
    # (AMHGSVF.m:366-369); an earlier row may already have been filed.
    DataMapper.define(:amhg_save_measurements) do |m|
      m.rpc "AMHG SAVE MEASUREMENTS"
      m.text_blob :body
    end

    # AMHG GET VISIT MSR DATA ENTRY — MSR^AMHGDVF1 (AMHGDVF1.m:38-59).
    # One parameter, the visit IEN. The BMXIEN column is the measurement
    # TYPE ien (.01 "I"), not the measurement row IEN (AMHGDVF1.m:50-57).
    # Wellness parses the recordset itself so a row that is not a type IEN,
    # an integer value, and a provider IEN is not a confirmation.
    DataMapper.define(:amhg_visit_msr_data_entry) do |m|
      m.rpc "AMHG GET VISIT MSR DATA ENTRY"
      m.text_blob :body
    end
  end
end
