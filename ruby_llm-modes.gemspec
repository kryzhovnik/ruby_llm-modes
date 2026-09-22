# frozen_string_literal: true

require_relative "lib/ruby_llm/modes/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby_llm-modes"
  spec.version       = RubyLLM::Modes::VERSION
  spec.authors       = [ "Andrey Samsonov" ]
  spec.email         = [ "me@samsonov.io" ]

  spec.summary       = "Route one conversation between RubyLLM agents, one traced decision per turn"
  spec.description   = "Declare modes (RubyLLM agents with a routing description), a fallback, and a classifier; every turn returns a Route that says which mode handles the message, why, and what the classifier actually said."
  spec.homepage      = "https://github.com/kryzhovnik/ruby_llm-modes"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*",
    "README.md",
    "CHANGELOG.md",
    "LICENSE*",
    "ruby_llm-modes.gemspec"
  ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "ruby_llm",   ">= 2.0.0", "< 3"
  spec.add_dependency "schematist", "~> 1.1"
end
