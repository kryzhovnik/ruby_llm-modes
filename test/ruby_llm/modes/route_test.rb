# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::RouteTest < Minitest::Test
  Route = RubyLLM::Modes::Route
  Decision = RubyLLM::Modes::Decision

  class TutorAgent < RubyLLM::ModeAgent; end

  class GreetingAgent < RubyLLM::ModeAgent
    inputs :user
    instructions { "Tutor for #{user}." }
  end

  def route_with(inputs, chat: nil)
    Route.new(mode_class: GreetingAgent, mode_name: "greeting", decided_by: "caller", reason: "Mode requested by caller",
              chat:, inputs:)
  end

  def test_mode_builds_the_agent_on_the_route_chat_with_the_router_inputs
    chat = RubyLLM.chat(model: "gemini-3.5-flash-lite").with_instructions("Base.")
    agent = route_with({ user: "Kim", card: :ignored }, chat:).mode

    assert_kind_of GreetingAgent, agent
    assert_same chat, agent.chat
    assert_equal [ "Base.", "Tutor for Kim." ], chat.messages.select { |message| message.role == :system }.map(&:content)
  end

  def test_mode_without_a_chat_builds_a_fresh_one
    agent = route_with({ user: "Kim" }).mode

    assert_kind_of RubyLLM::Chat, agent.chat
    assert_equal [ "Tutor for Kim." ], agent.chat.messages.map(&:content)
  end

  def test_mode_rejects_a_chat_of_its_own
    route = route_with({ user: "Kim" }, chat: RubyLLM.chat(model: "gemini-3.5-flash-lite"))
    assert_raises(ArgumentError) { route.mode(chat: RubyLLM.chat(model: "gemini-3.5-flash-lite")) }
    assert_raises(ArgumentError) { route.mode(chat: nil) }
  end

  def test_mode_forwards_extra_keywords_to_the_agent
    chat = RubyLLM.chat(model: "gemini-3.5-flash-lite")
    agent = route_with({}, chat:).mode(user: "Lee")

    assert_equal [ "Tutor for Lee." ], agent.chat.messages.map(&:content)
  end

  def test_chat_and_inputs_default_and_stay_out_of_to_h
    route = Route.new(mode_class: TutorAgent, mode_name: "tutor", decided_by: "caller", reason: "Mode requested by caller")

    assert_nil route.chat
    assert_equal({}, route.inputs)
    keys = route_with({ user: "Kim" }, chat: Object.new).to_h.keys
    refute_includes keys, "inputs"
    refute_includes keys, "chat"
  end

  def test_optional_members_default_to_nil
    route = Route.new(mode_class: TutorAgent, mode_name: "tutor", decided_by: "caller", reason: "Mode requested by caller")
    assert_nil route.decision
    assert_nil route.duration_ms
    assert_nil route.classifier
    assert_nil route.error
  end

  def test_to_h_drops_mode_class_and_error_and_uses_string_keys
    decision = Decision.new(mode_name: "showtime", confidence: 0.42, reason: "looks like a show")
    route = Route.new(
      mode_class: TutorAgent, mode_name: "tutor", decided_by: "fallback", reason: "Below confidence threshold",
      decision: decision, duration_ms: 812, classifier: { with: "chat", model: "gemini-3.5-flash-lite" },
      error: RuntimeError.new("boom")
    )

    assert_equal(
      {
        "mode_name" => "tutor",
        "decided_by" => "fallback",
        "reason" => "Below confidence threshold",
        "duration_ms" => 812,
        "classifier" => { "with" => "chat", "model" => "gemini-3.5-flash-lite" },
        "decision" => { "mode_name" => "showtime", "confidence" => 0.42, "reason" => "looks like a show" }
      },
      route.to_h
    )
  end

  def test_to_h_keeps_nil_slots
    route = Route.new(mode_class: TutorAgent, mode_name: "tutor", decided_by: "caller", reason: "Mode requested by caller")
    assert_equal(
      { "mode_name" => "tutor", "decided_by" => "caller", "reason" => "Mode requested by caller",
        "duration_ms" => nil, "classifier" => nil, "decision" => nil },
      route.to_h
    )
  end
end
