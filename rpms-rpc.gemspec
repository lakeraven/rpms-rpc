# frozen_string_literal: true

require_relative "lib/rpms_rpc/version"

Gem::Specification.new do |spec|
  spec.name        = "rpms-rpc"
  spec.version     = RpmsRpc::VERSION
  spec.authors     = [ "Lakeraven" ]
  spec.email       = [ "eng@lakeraven.com" ]
  spec.homepage    = "https://github.com/lakeraven/rpms-rpc"
  spec.summary     = "Pure Ruby RPC client for VistA/RPMS (CIA/XWB and BMX protocols)"
  spec.description = "Pure Ruby gem providing wire-level access to VistA/RPMS RPC brokers " \
                     "via the CIA/XWB and BMX protocols. Includes parameter encoding, " \
                     "response parsing, FileMan date helpers, and PHI sanitization. " \
                     "No Rails dependency."
  spec.license     = "MIT"
  spec.metadata    = {
    "homepage_uri"      => "https://github.com/lakeraven/rpms-rpc",
    "source_code_uri"   => "https://github.com/lakeraven/rpms-rpc",
    "changelog_uri"     => "https://github.com/lakeraven/rpms-rpc/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/lakeraven/rpms-rpc/tree/main/docs"
  }

  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{lib,docs}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end
  # rexml is a default gem in Ruby 3.4+ but must be declared so Bundler
  # adds it to the load path. Otherwise pure stdlib (socket, openssl).
  spec.add_dependency "rexml", "~> 3.2"
end
