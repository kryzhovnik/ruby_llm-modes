# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::DecisionTest < Minitest::Test
  Decision = RubyLLM::Modes::Decision

  def test_every_member_defaults_to_nil
    decision = Decision.new
    assert_nil decision.mode_name
    assert_nil decision.confidence
    assert_nil decision.reason
    assert_nil decision.probabilities
  end

  def test_to_h_uses_string_keys
    decision = Decision.new(mode_name: "tutor", confidence: 0.9, reason: "asked to explain")
    assert_equal({ "mode" => "tutor", "confidence" => 0.9, "reason" => "asked to explain" }, decision.to_h)
  end

  def test_to_h_includes_probabilities_when_set
    decision = Decision.new(mode_name: "tutor", probabilities: { tutor: 0.7, card: 0.3 })
    assert_equal({ "tutor" => 0.7, "card" => 0.3 }, decision.to_h["probabilities"])
  end
end
