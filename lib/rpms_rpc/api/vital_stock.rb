# frozen_string_literal: true

require_relative "../shape"
require_relative "../server_clock"
require_relative "../fileman_date_parser"

module RpmsRpc
  # Stock VistA vitals save over GMV ADD VM (#458). Kept apart from the
  # IHS BEHOVM path in vital.rb, with no IHS helper, so it can move to
  # vista-rpc unchanged.
  module Vital
    # GMV abbreviation (FILE 120.51 "C" index) => FILE 120.51 NAME, and
    # the check GMVDCCHK applies to a US-unit reading (GMVDCCHK.m line
    # cited per type). Readings are filed in US units (GMVDCSAV.m:52).
    STOCK_TYPES = {
      "BP"  => [ "BLOOD PRESSURE", lambda { |v|
        # BP^GMVDCCHK, GMVDCCHK.m:38-42
        v.match?(%r{\A\d{1,3}(/\d{1,3}){0,2}\z}) && v.split("/").all? { |n| n.to_i.between?(0, 300) } &&
          (!v.include?("/") || v.split("/").first.to_i > v.split("/").last.to_i)
      } ],
      "T"   => [ "TEMPERATURE", ->(v) { number?(v, 2) && v.to_f.between?(45, 120) } ],          # GMVDCCHK.m:101
      "P"   => [ "PULSE", ->(v) { integer?(v) && v.to_i.between?(0, 300) } ],                     # GMVDCCHK.m:84
      "R"   => [ "RESPIRATION", ->(v) { integer?(v) && v.to_i.between?(0, 100) } ],               # GMVDCCHK.m:96
      "HT"  => [ "HEIGHT", ->(v) { number?(v, 2) && v.to_f.between?(1, 100) } ],                  # GMVDCCHK.m:80
      "WT"  => [ "WEIGHT", ->(v) { number?(v, 2) && v.to_f > 0 && v.to_f <= 1500 } ],             # GMVDCCHK.m:121
      "PN"  => [ "PAIN", ->(v) { %w[0 1 2 3 4 5 6 7 8 9 10 99].include?(v) } ],                   # GMVDCCHK.m:88
      "PO2" => [ "PULSE OXIMETRY", ->(v) { integer?(v) && v.to_i.between?(0, 100) } ],            # GMVDCCHK.m:92
      "CG"  => [ "CIRCUMFERENCE/GIRTH", ->(v) { number?(v, 2) && v.to_f.between?(0, 200) } ],     # GMVDCCHK.m:47
      "CVP" => [ "CENTRAL VENOUS PRESSURE", ->(v) { number?(v, 1, signed: true) && v.to_f.between?(-13.6, 136) } ] # GMVDCCHK.m:52
    }.freeze

    # US units each type is filed in; any other units are refused, since
    # GMV ADD VM converts nothing.
    STOCK_UNITS = { "T" => %w[F], "HT" => %w[in], "WT" => %w[lb], "CG" => %w[in], "CVP" => %w[cmH2O] }.freeze

    # Seconds after taken_at in which a saved row may land: CHKDT moves the
    # time forward a second at a time past readings already filed then
    # (GMVDCSAV.m:66-75), and a midnight time gains one (GMVDCSAV.m:42-44).
    STOCK_READ_BACK_WINDOW = 60

    # Saves each measurement through stock VistA GMV ADD VM, one RPC per
    # measurement, then reads it back with GMV EXTRACT REC.
    #
    #   add_stock(dfn, [{ abbreviation: "BP", value: "120/80" },
    #                   { abbreviation: "WT", value: 180, units: "lb", qualifier_iens: [ 2 ] }],
    #             location_ien: 67, entered_by_duz: 87)
    #   => { success: bool, saved: [ {abbreviation:, value:, vital_ien:} ], errors: [ ... ] }
    #
    # abbreviation is the GMV one (FILE 120.51 "C" index: BP, T, P, R, HT,
    # WT, PN, PO2, CG, CVP); units default to the type's US units. A value
    # GMVDCCHK would refuse, unknown type or other units raises
    # ArgumentError before any RPC is sent.
    #
    # Success is read back (owner decision on #458): for each measurement
    # the type's rows in [taken_at, taken_at + 60s] are listed before and
    # after the save, and it counts only when a new row carrying the value
    # appears. An "ERROR:" reply, an empty read-back or no new row is a
    # failure. This costs three RPCs per measurement (type IEN, save, two
    # reads) and is not atomic: an earlier measurement stays filed when a
    # later one fails, and saved says which were filed.
    def add_stock(dfn, measurements, location_ien:, entered_by_duz:, taken_at: nil)
      raise ArgumentError, "dfn must be a positive IEN" unless dfn.to_s.match?(/\A[1-9]\d*\z/)
      raise ArgumentError, "location_ien must be a positive IEN" unless location_ien.to_s.match?(/\A[1-9]\d*\z/)
      raise ArgumentError, "entered_by_duz must be a positive DUZ" unless entered_by_duz.to_s.match?(/\A[1-9]\d*\z/)

      list = measurements.is_a?(Array) ? measurements : [ measurements ]
      raise ArgumentError, "no measurements given" if list.empty?

      list = list.map { |m| stock_measurement(m) }
      taken_at ||= ServerClock.now
      start = FilemanDateParser.format_datetime(taken_at, seconds: true)
      finish = FilemanDateParser.format_datetime(taken_at + STOCK_READ_BACK_WINDOW, seconds: true)

      saved = []
      errors = []
      list.each do |m|
        result = stock_save_one(dfn, m, start, finish, location_ien, entered_by_duz)
        if result[:vital_ien]
          saved << { abbreviation: m[:abbreviation], value: m[:value], vital_ien: result[:vital_ien] }
        else
          errors << { abbreviation: m[:abbreviation], value: m[:value], error_message: result[:error] }
          break
        end
      end
      { success: errors.empty?, saved: saved, errors: errors }
    end
    shape :add_stock, resource: "vitals", verb: "POST", path: "/patients/{dfn}/vitals/stock"

    class << self
      private

      def integer?(v) = v.match?(/\A\d+\z/)

      def number?(v, decimals, signed: false)
        v.match?(signed ? /\A-?\d+(\.\d{1,#{decimals}})?\z/ : /\A\d+(\.\d{1,#{decimals}})?\z/)
      end
    end

    private

    def stock_measurement(m)
      abbreviation = m[:abbreviation].to_s.upcase
      type = STOCK_TYPES[abbreviation] or raise ArgumentError, "#{m[:abbreviation].inspect} is not a GMV vital type"
      value = m[:value].to_s.strip
      unless (units = m[:units].to_s).empty? || Array(STOCK_UNITS[abbreviation]).include?(units)
        raise ArgumentError, "#{abbreviation} is filed in #{Array(STOCK_UNITS[abbreviation]).join('/').then { |u| u.empty? ? 'no units' : u }}, not #{units}"
      end
      raise ArgumentError, "#{abbreviation} #{value.inspect} is out of range for GMV" unless type[1].call(value)

      qualifiers = Array(m[:qualifier_iens]).map(&:to_s)
      raise ArgumentError, "qualifier_iens must be positive IENs" unless qualifiers.all? { |q| q.match?(/\A[1-9]\d*\z/) }

      { abbreviation: abbreviation, name: type[0], value: value, qualifiers: qualifiers }
    end

    def stock_save_one(dfn, m, start, finish, location_ien, duz)
      type_ien = DataMapper.gmv_vital_type_ien.fetch_scalar(m[:name]).to_s
      return { error: "GMV GET VITAL TYPE IEN found no #{m[:name]}" } unless type_ien.match?(/\A[1-9]\d*\z/)

      before = stock_rows(dfn, m[:abbreviation], start, finish)
      return { error: "GMV EXTRACT REC gave no reply before the save" } if before.nil?

      data = "#{start}^#{dfn}^#{type_ien};#{m[:value]};^#{location_ien}^#{duz}*#{m[:qualifiers].join(':')}"
      reply = DataMapper.gmv_add_vm.fetch_many(data).map { |row| row[:message].to_s }
      refusal = reply.find { |line| line.start_with?("ERROR") }
      return { error: refusal.to_s.sub(/\AERROR:?\s*/, "") } if refusal

      after = stock_rows(dfn, m[:abbreviation], start, finish)
      return { error: "GMV EXTRACT REC gave no reply after the save" } if after.nil?

      new_rows = after.reject { |ien, _| before.key?(ien) }
      ien, = new_rows.find { |_, text| text.include?(m[:value]) }
      ien ? { vital_ien: ien } : { error: "No new #{m[:abbreviation]} #{m[:value]} row was read back after GMV ADD VM" }
    end

    # { ien => row text } for the type's rows in range; {} for the
    # "0^NO ..." row; nil for an empty or unparseable reply.
    def stock_rows(dfn, abbreviation, start, finish)
      rows = DataMapper.gmv_extract_rec.fetch_many_or_nil("#{dfn}^#{finish}^#{abbreviation}^#{start}")
      return nil if rows.nil? || rows.empty?

      rows.each_with_object({}) do |row, found|
        ien = row[:ien].to_s
        next if ien == "0"
        return nil unless ien.match?(/\A[1-9]\d*\z/)

        found[ien.to_i] = row[:text].to_s
      end
    end
  end
end
