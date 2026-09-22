# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ruby_llm/modes"
require "minitest/autorun"
require_relative "../examples/support/stub_provider"

# The classifier backend builds real RubyLLM chats. A provider refuses to
# build without a key, so give it a dummy one; no request ever leaves the
# process because every test stubs the provider call.
RubyLLM.configure do |config|
  config.gemini_api_key = "test-key"
  config.default_model = "gemini-3.5-flash-lite"
end

# Fixture modes shared across the suite.
class TutorAgent < RubyLLM::ModeAgent
  mode_description "Explains words and grammar, corrects the learner, keeps the conversation going."
end

class ClarifyAgent < RubyLLM::ModeAgent
  mode_description "Asks one short question when the request is ambiguous."
end

class ManageCardsAgent < RubyLLM::ModeAgent
  mode_description "Creates, edits, or deletes flashcards."
end

class ShowtimeAgent < RubyLLM::ModeAgent
  mode_description "Runs a timed review session."
end

module Chat
  class ReviewAgent < RubyLLM::ModeAgent
    mode_description "Reviews the learner's writing."
  end
end

# A plain agent with no Mode extension: the router derives its name and
# needs an inline description.
class PlainAgent < RubyLLM::Agent; end

# A classifier that satisfies the §5 contract and records every call.
class FakeClassifier
  attr_reader :calls

  def initialize(decision = nil, &block)
    @decision = decision
    @block = block
    @calls = []
  end

  def self.deciding(mode_name:, confidence: nil, reason: nil, probabilities: nil)
    new(RubyLLM::Modes::Decision.new(mode_name:, confidence:, reason:, probabilities:))
  end

  def call(message:, history:, modes:, guidance:, inputs:)
    @calls << { message:, history:, modes:, guidance:, inputs: }
    @block ? @block.call(message:, history:, modes:, guidance:, inputs:) : @decision
  end

  def called?
    @calls.any?
  end

  def last_call
    @calls.last
  end
end
