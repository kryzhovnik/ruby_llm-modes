# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::ModeSwitchTest < Minitest::Test
  class CreateCard < RubyLLM::Tool
    description "Creates a flashcard"
    parameter :front, description: "The word"

    def execute(front:)
      { created: front }
    end
  end

  class ManageAgent < RubyLLM::ModeAgent
    description "Manages flashcards."
    instructions "Manage the learner's flashcards."
    tools CreateCard
    thinking effort: :high
    schema do
      string :summary
    end
  end

  class ClarifyAgent < RubyLLM::ModeAgent
    description "Asks a clarifying question."
    instructions "Ask one short clarifying question."
    thinking effort: :low
  end

  class Router < RubyLLM::Modes::Router
    mode ManageAgent, as: :manage
    mode ClarifyAgent, as: :clarify
    fallback ClarifyAgent
    classify_with FakeClassifier.deciding(mode_name: "manage", confidence: 1.0)
  end

  def test_switching_modes_on_a_reused_chat_keeps_history_and_resets_configuration
    chat = RubyLLM.chat(model: "gemini-3.5-flash-lite").with_instructions("Base.")
    StubProvider.stub(chat) { "Which card?" }
    router = Router.new

    first = router.route(chat.ask_later("add a card"))
    first.mode.complete

    assert_equal [ "Base.", "Manage the learner's flashcards." ], system_contents(chat)
    assert_equal [ CreateCard.new.name.to_sym ], chat.tools.keys
    refute_nil chat.schema
    assert_equal({ effort: :high }, chat.thinking)

    chat.with_instructions("Base.").with_tools(nil).with_schema(nil)
    second = router.route(chat.ask_later("the other one"), classifier: FakeClassifier.deciding(mode_name: "clarify", confidence: 1.0))
    second.mode.complete

    assert_equal [ "Base.", "Ask one short clarifying question." ], system_contents(chat)
    assert_empty chat.tools
    assert_nil chat.schema
    assert_equal({ effort: :low }, chat.thinking)
    assert_equal %i[user assistant user assistant], chat.messages.reject { |message| message.role == :system }.map(&:role)
  end

  private

  def system_contents(chat)
    chat.messages.select { |message| message.role == :system }.map(&:content)
  end
end
