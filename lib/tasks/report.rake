# frozen_string_literal: true

# Daily live report (rpms-rpc#365): the offline suite once and the live suite once per persona,
# against the latest bcer-*-ydb release of lakeraven/rpms-ops, summarised as one markdown file.
#
#   rake report:daily BROKER_HOST= BROKER_PORT=   a running broker (its build: BUILD=, or the local
#                                                container publishing that port)
#   rake report:daily FRESH=1 [IMAGE=]           a disposable container of the latest build, removed after
#   ... DRY_RUN=1                                print the plan, run nothing
#
# Env: PROV123_ACCESS/PROV123_VERIFY and SYS123_ACCESS/SYS123_VERIFY (PERSONAS= picks others), never
# printed or written; OUT= (a file) or OUT_DIR= (default rpc-coverage/daily/ in the sibling rpms-diffs
# checkout, which must exist). Exits 1 when any suite fails. See README "Daily live report".
namespace :report do
  desc "Run rake test + test:live per persona against the latest YottaDB build; write a markdown summary"
  task :daily do
    require File.expand_path("../../tools/daily_report/daily_report", __dir__)
    exit DailyReport::Run.new(ENV, File.expand_path("../..", __dir__)).call
  end
end
