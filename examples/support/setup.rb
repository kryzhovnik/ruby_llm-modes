# frozen_string_literal: true

# Shared setup for the example programs: load the gem from lib/, give the
# provider a dummy key (no request ever leaves the process; every example
# stubs the provider call), and load the stub helper.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "ruby_llm/modes"
require "json"
require_relative "stub_provider"

RubyLLM.configure do |config|
  config.gemini_api_key ||= "example-key"
  config.default_model = "gemini-3.5-flash-lite"
end
