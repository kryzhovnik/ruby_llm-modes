# frozen_string_literal: true

require_relative "lib/ruby_llm/modes/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby_llm-modes"
  spec.version       = RubyLLM::Modes::VERSION
  spec.authors       = [ "Andrey Samsonov" ]
  spec.email         = [ "me@samsonov.io" ]

  spec.summary       = "Declarative chat modes and automatic routing for RubyLLM"
  spec.description   = "Declaratively define multiple modes for a RubyLLM chat and automatically route each user message to the appropriate mode. Each mode has its own instructions, tools, model, and reasoning effort, while all modes share the conversation history. Configure mode availability and fallbacks, and inspect or test routing decisions independently of the response."
  spec.homepage      = "https://github.com/kryzhovnik/ruby_llm-modes"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*",
    "assets/**/*.svg",
    "README.md",
    "CHANGELOG.md",
    "LICENSE*",
    "ruby_llm-modes.gemspec"
  ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "ruby_llm",   ">= 2.0.0", "< 3"
  spec.add_dependency "schematist", "~> 1.1"
end
