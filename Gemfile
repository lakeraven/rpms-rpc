# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # bin/console; irb is a bundled gem, not a default gem, since Ruby 4.0
  gem "irb", require: false
  # rake openapi:* and test/openapi/ validate the generated documents against the OpenAPI 3.1 schema (#395)
  gem "json_schemer", "~> 2.4", require: false
  # regexp_parser 2.13.2 drops Regexp::Syntax::Base#implements, which json_schemer 2.5.0 calls at load
  # (NoMethodError in ecma_regexp.rb), so every OpenAPI document test errors. Lift when json_schemer catches up.
  gem "regexp_parser", "!= 2.13.2", require: false
  gem "minitest", "~> 5.0"
  gem "rake", "~> 13.0"
  gem "rubocop-rails-omakase", require: false
  # rake rpc:coverage_html draws the RPC coverage report with SimpleCov's HTML formatter
  gem "simplecov", "~> 0.22", require: false
end
