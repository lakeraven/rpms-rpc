# frozen_string_literal: true

require "date"
require_relative "agg"
require_relative "../shape"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # A patient's applications for coverage (Medicaid, Medicare), as AG's
  # Benefits Coordinator keeps them in PATIENT APPLICATIONS (#9000045,
  # ^AUPNAPPS): one entry per patient (.01 PATIENT NAME, found on the "B"
  # index the way AGEDBEB does), each application a DATE APPLICATION
  # OBTAINED sub-entry (#9000045.11), each submission of it a DATE
  # APPLICATION SUBMITTED sub-entry (#9000045.1101), and each status the
  # state sent back a STATUS DATE sub-entry under the submission
  # (#9000045.110101). The type points at PATIENT APPLICATION TYPES
  # (#9000048), which each site fills (rpms-ops#1053 seeds the demo's).
  #
  # AG edits these only in roll-and-scroll (AGEDBED, AGEDBEE), and no #8994
  # entry reads or files them (rpms-ops#1053). So this module reads with DDR
  # LISTER and files with DDR FILER, under the rules of rpms-rpc#549: inside
  # AG's edit lock (Agg.editing), read before write (a failed read files
  # nothing), what AG's screens do around the write done explicitly, and the
  # live spec reads every write back through FileMan.
  #
  # What AG's screens do, and so what this module does:
  # - AGEDBED NEWENTRY finds the patient's #9000045 entry, or adds it (LAYGO).
  # - It adds the application on its date (.01, not in the future: the
  #   field's %DT(0)=-DT), then asks the type (.02, required: DIE("NO^")),
  #   the overall status (.04) and the person receiving it (.03). .05 is the
  #   benefit coordinator case it was opened under (STUFCASE), when one is.
  # - AGEDBEE adds a submission (.01 date, .02 via, .03 reason, .04 by) and,
  #   under it, a status on a date (.01, .02).
  # - Each screen ends with UPDATE1^AGED(DUZ(2),DFN,3,""), which stamps IHS
  #   PATIENT (#9000001) .03 DATE OF LAST REG. UPDATE and .16 DATE OF LAST
  #   UPDATE with today and .12 USER-LAST UPDATE with DUZ. This module files
  #   those three in the same call. UPDATE1 also sets ^AGPATCH(now,site,dfn),
  #   AG's list of patients edited, which is not a FileMan file: that is the
  #   one part not done, and it is said so here.
  # - EDAPPDT: "DELETING APPLICATIONS DATA IS PROHIBITED!": an application
  #   recorded by mistake gets the status E ENTERED IN ERROR. This module
  #   deletes nothing.
  #
  # Each write is one DDR FILER ADD (UPDATE^DIE, internal values), which
  # also files fields of existing entries, so a write lands whole or not at
  # all. Every DDR call binds CIAV VUECENTRIC (as Registration's do).
  module PatientApplication
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"

    FILE = "9000045"
    APPLICATION_FILE = "9000045.11"
    SUBMISSION_FILE = "9000045.1101"
    STATUS_FILE = "9000045.110101"
    TYPE_FILE = "9000048"
    PATIENT_FILE = "9000001"

    # #9000045.11 .04 OVERALL STATUS OF APPLICATION, the set as the DD has it.
    OVERALL_STATUSES = {
      "P" => "PENDING", "A" => "APPROVED", "D" => "DENIED", "R" => "RE-SUBMITTED",
      "RE" => "REFUSED", "F" => "FOLLOW UP NEEDED", "E" => "ENTERED IN ERROR",
      "O" => "OVER INCOME", "S" => "SCREENING ONLY", "I" => "INELIGIBLE",
      "N" => "NON-COMPLIANCE", "FC" => "FAILURE TO COMPLY"
    }.freeze
    # #9000045.110101 .02 STATUS: a submission's status takes only these.
    SUBMISSION_STATUSES = {
      "P" => "PENDING", "A" => "APPROVED", "D" => "DENIED", "R" => "RE-SUBMITTED",
      "F" => "FOLLOW UP NEEDED", "E" => "ENTERED IN ERROR"
    }.freeze
    # #9000045.1101 .02 APPLICATION SUBMITTED VIA.
    SUBMITTED_VIA = {
      "F" => "FAX", "M" => "MAIL", "T" => "TELEPHONE", "O" => "ONLINE/INTERNET", "H" => "HAND DELIVERED"
    }.freeze
    # #9000045.1101 .03 REASON FOR SUBMISSION: K:$L(X)>45!($L(X)<3) X.
    REASON_LENGTH = (3..45)
    # How far the "B" walk reads past the DFN before it stops.
    HEADER_B_MAX = 20

    # The application types the site has (#9000048): [{ ien:, name: }],
    # by name. Raises Client::RpcError when the list could not be read.
    def types
      listed = in_context { DdrFileman.lister(file: TYPE_FILE, fields: "@;.01", flags: "IP") }
      raise Client::RpcError, "DDR LISTER gave no reply for ##{TYPE_FILE}" if listed.nil?
      raise Client::RpcError, "DDR LISTER refused ##{TYPE_FILE}" if listed[:error] || listed[:more]

      listed[:entries].map { |e| { ien: e[:ien].to_i, name: e[:pieces][0].to_s } }.sort_by { |t| t[:name] }
    end
    shape :types, resource: "patient-applications", verb: "GET", path: "/patient-applications/types"

    # The patient's applications, newest first:
    #   [{ ien:, obtained: Date, type: { ien:, name: } or nil, status: code or nil,
    #      status_name:, received_by: DUZ or nil, case: ien or nil,
    #      submissions: [{ ien:, date: Date, via: code or nil, reason:, submitted_by:,
    #                      statuses: [{ ien:, date: Date, status: code }] }] }]
    # [] when the patient has no #9000045 entry. Raises Client::RpcError when
    # any read fails, so a failed read is never "no applications".
    def for_patient(dfn)
      id = patient_dfn(dfn)
      raise ArgumentError, "a positive DFN is required" unless id

      in_context do
        header = header_ien(id)
        raise Client::RpcError, header[:message] if header.is_a?(Hash)
        next [] unless header

        applications(header).sort_by { |a| [ a[:obtained], a[:ien] ] }.reverse
      end
    end
    shape :for_patient, resource: "patient-applications", verb: "GET", path: "/patients/{dfn}/patient-applications"

    # Record an application (rpms-ux S-REG-03.3), as AGEDBED NEWENTRY does:
    # the patient's #9000045 entry (added when there is none), the
    # application on its date with its type, overall status (default P
    # PENDING), the person receiving it and the case, and, when submitted:
    # is given, its submission (date, via, reason, by). One DDR FILER ADD,
    # with the UPDATE1^AGED stamp on #9000001. Inside Agg.editing.
    #
    # Refused before any write (:invalid, nothing sent past the lock): a
    # date obtained in the future or not a Date, a type that is not on
    # #9000048 (read first), a status outside the set, a via outside the
    # set, a reason outside 3-45 characters or with "^", via or reason
    # without submitted:. An application already on file on that date (and
    # case) is :exists, with its ien: AG's lookup would select it to edit.
    # A failed read is :lookup_failed and files nothing.
    #
    # Returns { success: true, application: ien, submission: ien or nil },
    # a failure hash, or nil when DDR FILER gave no reply (outcome unknown).
    def add(dfn, obtained:, type:, status: "P", received_by: nil, submitted: nil, via: nil, reason: nil,
            submitted_by: nil, case_ien: nil)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id

      refusal = check_add(obtained: obtained, type: type, status: status, received_by: received_by,
                          submitted: submitted, via: via, reason: reason, submitted_by: submitted_by,
                          case_ien: case_ien)
      return refusal if refusal

      Agg.editing(dfn: id) do
        in_context do
          file_new_application(id, obtained: obtained, type: type, status: status, received_by: received_by,
                                    submitted: submitted, via: via, reason: reason&.strip,
                                    submitted_by: submitted_by, case_ien: case_ien)
        end
      end
    end
    shape :add, resource: "patient-applications", verb: "POST", path: "/patients/{dfn}/patient-applications"

    # Record the outcome of an application (rpms-ux S-REG-03.4, 03.5): its
    # overall status (.04, as APPSTAT^AGEDBED) and, when the status is one a
    # submission takes and the application has a submission, a status on
    # that date under its latest submission (as ADSUBSTA^AGEDBEE). E ENTERED
    # IN ERROR is how AG retires an application; nothing is deleted. One DDR
    # FILER ADD with the UPDATE1^AGED stamp, inside Agg.editing, after the
    # application is read (missing: :not_found; failed read: :lookup_failed).
    #
    # Returns { success: true, dated: true/false } (dated: whether a status
    # date was filed), a failure hash, or nil when DDR FILER gave no reply.
    def update_status(dfn, application:, status:, date: Date.today)
      id = patient_dfn(dfn)
      return invalid("a positive DFN is required") unless id
      return invalid("application must be a positive integer") unless positive_integer?(application)
      return invalid("status must be one of #{OVERALL_STATUSES.keys.join(', ')}") unless OVERALL_STATUSES.key?(status)
      return invalid("date must be a Date") unless date.instance_of?(Date)

      Agg.editing(dfn: id) { in_context { file_status(id, application, status, date) } }
    end
    shape :update_status, resource: "patient-applications", verb: "PUT",
          path: "/patients/{dfn}/patient-applications/status"

    private

    def check_add(obtained:, type:, status:, received_by:, submitted:, via:, reason:, submitted_by:, case_ien:)
      return invalid("obtained must be a Date") unless obtained.instance_of?(Date)
      return invalid("the date obtained cannot be in the future") if obtained > Date.today
      return invalid("type must be a positive integer") unless positive_integer?(type)
      return invalid("status must be one of #{OVERALL_STATUSES.keys.join(', ')}") unless OVERALL_STATUSES.key?(status)
      return invalid("submitted must be a Date") unless submitted.nil? || submitted.instance_of?(Date)
      return invalid("via must be one of #{SUBMITTED_VIA.keys.join(', ')}") unless via.nil? || SUBMITTED_VIA.key?(via)
      unless [ received_by, submitted_by, case_ien ].all? { |v| v.nil? || positive_integer?(v) }
        return invalid("received_by, submitted_by and case_ien must be positive integers")
      end
      if submitted.nil? && !(via.nil? && reason.nil? && submitted_by.nil?)
        return invalid("via, reason and submitted_by need a submitted date")
      end
      return nil if reason.nil?

      text = reason.to_s.strip
      return invalid("reason cannot contain ^ or a control character") if text.match?(/[\^[:cntrl:]]/)
      return invalid("reason must be #{REASON_LENGTH.min} to #{REASON_LENGTH.max} characters") unless REASON_LENGTH.cover?(text.length)

      nil
    end

    def file_new_application(id, obtained:, type:, status:, received_by:, submitted:, via:, reason:, submitted_by:,
                             case_ien:)
      type_read = DdrFileman.gets_entry(file: TYPE_FILE, iens: "#{type},", fields: ".01", flags: "I")
      return lookup_failed("DDR GETS ENTRY DATA gave no reply for ##{TYPE_FILE}") if type_read.nil?
      return invalid("application type #{type} is not on file") if type_read[:error] || type_read[:fields].empty?

      header = header_ien(id)
      return header if header.is_a?(Hash)

      day = fm(obtained)
      if header
        listed = application_rows(header)
        return listed if listed.is_a?(Hash)

        same = listed.find { |row| row[:pieces][0] == day && row[:pieces][5].to_s == case_ien.to_s }
        if same
          return { success: false, error: :exists, application: same[:ien].to_i,
                   message: "an application obtained on #{obtained} is already on file" }
        end
      end

      parent = header ? "#{header}," : "+1,"
      app = "+2,#{parent}"
      rows = []
      rows << row(FILE, ".01", "+1,", id) unless header
      rows << row(APPLICATION_FILE, ".01", app, day)
      rows << row(APPLICATION_FILE, ".02", app, type)
      rows << row(APPLICATION_FILE, ".03", app, received_by) if received_by
      rows << row(APPLICATION_FILE, ".04", app, status)
      rows << row(APPLICATION_FILE, ".05", app, case_ien) if case_ien
      if submitted
        sub = "+3,#{app}"
        rows << row(SUBMISSION_FILE, ".01", sub, fm(submitted))
        rows << row(SUBMISSION_FILE, ".02", sub, via) if via
        rows << row(SUBMISSION_FILE, ".03", sub, reason) if reason
        rows << row(SUBMISSION_FILE, ".04", sub, submitted_by) if submitted_by
      end
      stamp = stamp_rows(id)
      return stamp if stamp.is_a?(Hash)

      filed = DdrFileman.filer(mode: "ADD", rows: rows + stamp)
      return nil if filed.nil?
      return filer_failed(filed) unless filed[:success]

      { success: true, application: filed[:iens][2].to_i, submission: (submitted ? filed[:iens][3].to_i : nil) }
    end

    def file_status(id, application, status, date)
      header = header_ien(id)
      return header if header.is_a?(Hash)
      return not_found("the patient has no applications") unless header

      listed = application_rows(header)
      return listed if listed.is_a?(Hash)
      return not_found("no application #{application} for this patient") unless listed.any? { |r| r[:ien].to_i == application }

      app = "#{application},#{header},"
      subs = list(SUBMISSION_FILE, ",#{app}", "@;.01I")
      return subs if subs.is_a?(Hash)

      rows = [ row(APPLICATION_FILE, ".04", app, status) ]
      latest = subs.max_by { |s| [ s[:pieces][0].to_s, s[:ien].to_i ] }
      dated = !latest.nil? && SUBMISSION_STATUSES.key?(status)
      if dated
        node = "+1,#{latest[:ien]},#{app}"
        rows << row(STATUS_FILE, ".01", node, fm(date))
        rows << row(STATUS_FILE, ".02", node, status)
      end
      stamp = stamp_rows(id)
      return stamp if stamp.is_a?(Hash)

      filed = DdrFileman.filer(mode: "ADD", rows: rows + stamp)
      return nil if filed.nil?
      return filer_failed(filed) unless filed[:success]

      { success: true, dated: dated }
    end

    # UPDATE1^AGED's FileMan part: #9000001 .03 and .16 today, .12 DUZ.
    def stamp_rows(id)
      duz = signed_on_duz
      return invalid("a signed-on DUZ is required") unless duz

      today = fm(Date.today)
      [ row(PATIENT_FILE, ".03", "#{id},", today), row(PATIENT_FILE, ".12", "#{id},", duz),
        row(PATIENT_FILE, ".16", "#{id},", today) ]
    end

    # The patient's #9000045 entry, as AGEDBEB finds it ($O(^AUPNAPPS("B",DFN,""))):
    # the lowest ien whose .01 is this DFN, nil when none, or :lookup_failed.
    def header_ien(id)
      listed = DdrFileman.lister(file: FILE, fields: "@;.01I", flags: "IP", xref: "B",
                                 from: (id.to_i - 1).to_s, max: HEADER_B_MAX)
      return lookup_failed("DDR LISTER gave no reply for ##{FILE}") if listed.nil?
      return lookup_failed("DDR LISTER refused ##{FILE}") if listed[:error]

      rows = listed[:entries].select { |e| e[:pieces][0].to_s == id }
      if rows.empty? && listed[:more] && listed[:entries].all? { |e| e[:pieces][0].to_s.to_i <= id.to_i }
        return lookup_failed("DDR LISTER did not finish the ##{FILE} B index through DFN #{id}")
      end

      rows.map { |e| e[:ien].to_i }.min
    end

    def application_rows(header)
      list(APPLICATION_FILE, ",#{header},", "@;.01I;.02I;.02E;.03I;.04I;.05I")
    end

    def applications(header)
      rows = application_rows(header)
      raise Client::RpcError, rows[:message] if rows.is_a?(Hash)

      rows.map do |r|
        p = r[:pieces]
        app = "#{r[:ien]},#{header},"
        { ien: r[:ien].to_i, obtained: date(p[0]), type: p[1].to_s.empty? ? nil : { ien: p[1].to_i, name: p[2].to_s },
          status: blank(p[4]), status_name: OVERALL_STATUSES[p[4].to_s], received_by: int(p[3]), case: int(p[5]),
          submissions: submissions(app) }
      end
    end

    def submissions(app)
      rows = list(SUBMISSION_FILE, ",#{app}", "@;.01I;.02I;.04I;.03")
      raise Client::RpcError, rows[:message] if rows.is_a?(Hash)

      rows.map do |r|
        p = r[:pieces]
        sub = "#{r[:ien]},#{app}"
        statuses = list(STATUS_FILE, ",#{sub}", "@;.01I;.02I")
        raise Client::RpcError, statuses[:message] if statuses.is_a?(Hash)

        { ien: r[:ien].to_i, date: date(p[0]), via: blank(p[1]), submitted_by: int(p[2]), reason: blank(p[3..].join("^")),
          statuses: statuses.map { |s| { ien: s[:ien].to_i, date: date(s[:pieces][0]), status: blank(s[:pieces][1]) } } }
      end
    end

    # A whole multiple, or :lookup_failed. A MORE line means it was not read whole.
    def list(file, iens, fields)
      listed = DdrFileman.lister(file: file, iens: iens, fields: fields, flags: "IP")
      return lookup_failed("DDR LISTER gave no reply for ##{file}") if listed.nil?
      return lookup_failed("DDR LISTER refused ##{file}") if listed[:error]
      return lookup_failed("DDR LISTER did not finish ##{file} at #{iens}") if listed[:more]

      listed[:entries]
    end

    def row(file, field, iens, value) = { file: file, field: field, iens: iens, value: value.to_s }
    def fm(day) = FilemanDateParser.to_fileman(day)

    def date(value)
      FilemanDateParser.parse_date(value.to_s) || raise(Client::RpcError, "unreadable FileMan date #{value.inspect}")
    end

    def blank(value) = value.to_s.empty? ? nil : value.to_s
    def int(value) = value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : nil

    def signed_on_duz
      client = RpmsRpc.client
      return nil unless client.respond_to?(:duz)

      text = client.duz.to_s
      text.match?(/\A[1-9]\d*\z/) ? text : nil
    end

    def patient_dfn(dfn)
      text = dfn.to_s
      text.match?(/\A[1-9]\d*\z/) ? text : nil
    end

    def positive_integer?(value) = value.is_a?(Integer) && value.positive?
    def in_context(&) = ContextScope.scoped(RpmsRpc.client, CONTEXT, &)
    def invalid(message) = { success: false, error: :invalid, message: message }
    def lookup_failed(message) = { success: false, error: :lookup_failed, message: message }
    def not_found(message) = { success: false, error: :not_found, message: message }

    def filer_failed(filed)
      { success: false, error: :filer_failed, message: Array(filed[:errors]).join("\n") }
    end
  end
end
