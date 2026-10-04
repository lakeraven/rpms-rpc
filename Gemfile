# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # bin/console; irb is a bundled gem, not a default gem, since Ruby 4.0
  gem "irb", require: false
  gem "minitest", "~> 5.0"
  gem "rake", "~> 13.0"
  gem "rubocop-rails-omakase", require: false
  # rake rpc:coverage_html draws the RPC coverage report with SimpleCov's HTML formatter
  gem "simplecov", "~> 0.22", require: false
end
