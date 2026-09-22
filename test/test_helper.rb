# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ruby_llm/modes"
require "minitest/autorun"

# The classifier backend builds real RubyLLM chats. A provider refuses to
# build without a key, so give it a dummy one; no request ever leaves the
# process because every test stubs the provider call.
RubyLLM.configure do |config|
  config.gemini_api_key = "test-key"
end
