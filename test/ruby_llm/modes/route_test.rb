# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::RouteTest < Minitest::Test
  Route = RubyLLM::Modes::Route
  Decision = RubyLLM::Modes::Decision

  class TutorAgent < RubyLLM::ModeAgent; end

  def test_optional_members_default_to_nil
    route = Route.new(mode: TutorAgent, mode_name: "tutor", level: "explicit", reason: "Explicit mode requested")
    assert_nil route.decision
    assert_nil route.routing_ms
    assert_nil route.classifier
    assert_nil route.error
  end

  def test_to_h_drops_mode_class_and_error_and_uses_string_keys
    decision = Decision.new(mode_name: "showtime", confidence: 0.42, reason: "looks like a show")
    route = Route.new(
      mode: TutorAgent, mode_name: "tutor", level: "fallback", reason: "Below confidence threshold",
      decision: decision, routing_ms: 812, classifier: { with: "chat", model: "gemini-3.5-flash-lite" },
      error: RuntimeError.new("boom")
    )

    assert_equal(
      {
        "mode" => "tutor",
        "level" => "fallback",
        "reason" => "Below confidence threshold",
        "duration_ms" => 812,
        "classifier" => { "with" => "chat", "model" => "gemini-3.5-flash-lite" },
        "decision" => { "mode" => "showtime", "confidence" => 0.42, "reason" => "looks like a show" }
      },
      route.to_h
    )
  end

  def test_to_h_keeps_nil_slots
    route = Route.new(mode: TutorAgent, mode_name: "tutor", level: "explicit", reason: "Explicit mode requested")
    assert_equal(
      { "mode" => "tutor", "level" => "explicit", "reason" => "Explicit mode requested",
        "duration_ms" => nil, "classifier" => nil, "decision" => nil },
      route.to_h
    )
  end
end
