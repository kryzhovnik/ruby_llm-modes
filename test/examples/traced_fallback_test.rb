# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/traced_fallback"

class Examples::TracedFallbackTest < Minitest::Test
  Example = Examples::TracedFallback

  def setup
    @route = Example.run
  end

  def test_falls_back_to_the_tutor_below_the_threshold
    assert_equal Example::TutorAgent, @route.mode
    assert_equal "tutor", @route.mode_name
    assert_equal "fallback", @route.decided_by
    assert_equal "Below confidence threshold", @route.reason
  end

  def test_keeps_the_classifier_decision
    assert_equal "showtime", @route.decision.mode_name
    assert_equal 0.42, @route.decision.confidence
    assert_equal({ with: "custom", model: nil }, @route.classifier)
    assert_kind_of Integer, @route.duration_ms
  end

  def test_to_h_carries_the_route_and_the_decision
    hash = @route.to_h
    assert_equal "tutor", hash["mode_name"]
    assert_equal "fallback", hash["decided_by"]
    assert_equal "Below confidence threshold", hash["reason"]
    assert_equal({ "with" => "custom", "model" => nil }, hash["classifier"])
    assert_equal({ "mode_name" => "showtime", "confidence" => 0.42, "reason" => "might be asking for a session" }, hash["decision"])
  end
end
