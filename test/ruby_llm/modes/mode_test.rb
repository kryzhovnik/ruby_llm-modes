# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::ModeTest < Minitest::Test
  class TutorAgent < RubyLLM::ModeAgent
    mode_description <<~TEXT
      Explains words and grammar.
    TEXT
  end

  class TutorModeAgent < RubyLLM::ModeAgent; end

  class HTTPProxyAgent < RubyLLM::ModeAgent; end

  class Agent < RubyLLM::ModeAgent; end

  module Chat
    class TutorAgent < RubyLLM::ModeAgent; end

    class ReviewAgent < RubyLLM::ModeAgent
      mode_name "review"
    end
  end

  class SubTutorAgent < TutorAgent; end

  class SubReviewAgent < Chat::ReviewAgent; end

  class PlainAgent < RubyLLM::Agent
    extend RubyLLM::Modes::Mode
    mode_description "Plain"
  end

  class AppendingAgent < RubyLLM::ModeAgent
    mode_description "Appends"
    instructions "Mode prompt."
  end

  class ReplacingAgent < RubyLLM::ModeAgent
    mode_description "Replaces"
    instructions "Mode prompt.", append: false, persist: true
  end

  class LocalsAgent < RubyLLM::ModeAgent
    mode_description "Locals"
    instructions display_name: -> { "Duck" }
  end

  def test_mode_agent_is_an_agent
    assert_operator RubyLLM::ModeAgent, :<, RubyLLM::Agent
  end

  def test_gem_adds_no_macros_to_agent
    refute_respond_to RubyLLM::Agent, :mode_description
    refute_respond_to RubyLLM::Agent, :mode_name
  end

  def test_mode_can_be_extended_into_any_agent
    assert_equal "Plain", PlainAgent.mode_description
    assert_equal "ruby_llm/modes/mode_test/plain", PlainAgent.mode_name
  end

  def test_name_drops_trailing_agent_and_keeps_namespaces
    assert_equal "ruby_llm/modes/mode_test/tutor", TutorAgent.mode_name
    assert_equal "ruby_llm/modes/mode_test/chat/tutor", Chat::TutorAgent.mode_name
  end

  def test_name_removes_only_the_trailing_agent
    assert_equal "ruby_llm/modes/mode_test/tutor_mode", TutorModeAgent.mode_name
  end

  def test_name_underscores_acronyms
    assert_equal "ruby_llm/modes/mode_test/http_proxy", HTTPProxyAgent.mode_name
  end

  def test_name_keeps_a_bare_agent_class_name
    assert_equal "ruby_llm/modes/mode_test/agent", Agent.mode_name
  end

  def test_name_is_nil_for_an_anonymous_class
    assert_nil Class.new(RubyLLM::ModeAgent).mode_name
  end

  def test_name_override
    assert_equal "review", Chat::ReviewAgent.mode_name
  end

  def test_name_override_is_not_inherited
    assert_equal "ruby_llm/modes/mode_test/sub_review", SubReviewAgent.mode_name
  end

  def test_description_is_stripped
    assert_equal "Explains words and grammar.", TutorAgent.mode_description
  end

  def test_description_is_not_inherited
    assert_nil SubTutorAgent.mode_description
    assert_nil RubyLLM::ModeAgent.mode_description
  end

  def test_instructions_default_to_append_and_not_persist
    declaration = AppendingAgent.instructions.fetch(0)

    assert_equal "Mode prompt.", declaration[:value]
    assert declaration[:append]
    refute declaration[:persist]
  end

  def test_instructions_options_can_be_overridden
    declaration = ReplacingAgent.instructions.fetch(0)

    refute declaration[:append]
    assert declaration[:persist]
  end

  def test_instructions_keeps_agent_getter_and_prompt_locals
    assert_equal [], TutorAgent.instructions

    declaration = LocalsAgent.instructions.fetch(0)
    assert_equal "instructions", declaration[:value][:prompt]
    assert_equal %i[display_name], declaration[:value][:locals].keys
    assert declaration[:append]
  end

  def test_mode_instructions_follow_the_chat_prompt
    chat = RubyLLM.chat(model: "gemini-3.5-flash-lite").with_instructions("Base.")
    AppendingAgent.new(chat:)

    assert_equal [ "Base.", "Mode prompt." ], system_contents(chat)
  end

  def test_explicit_append_false_replaces_the_chat_prompt
    chat = RubyLLM.chat(model: "gemini-3.5-flash-lite").with_instructions("Base.")
    ReplacingAgent.new(chat:)

    assert_equal [ "Mode prompt." ], system_contents(chat)
  end

  private

  def system_contents(chat)
    chat.messages.select { |m| m.role == :system }.map(&:content)
  end
end
