# frozen_string_literal: true

# Acceptance example 2: a tool mode followed by a clarification mode on
# one RubyLLM::Chat object reused for both turns.
#
# A Rails app loads the chat record per turn and needs no reset; a
# script or a job that runs two modes on one chat object does, because
# Agent's constructor only adds configuration. The chat starts with base
# instructions. The router sends "add reluctant to my cards" to
# ManageCardsAgent, which adds tools, a schema, and high-effort thinking.
# Before the next turn the app applies the reset: base instructions back
# (which drops the appended mode instructions), tools and schema
# cleared. Thinking enabled by a mode stays on until the next
# with_thinking; add with_thinking(false) when the model has an off
# control in RubyLLM's registry. The router then sends "the other one" to
# ClarifyAgent, which adds its own instructions and low-effort thinking.
#
# Only the provider request and the classifier are stubbed; the chat is
# a real RubyLLM::Chat.
#
#   bundle exec ruby examples/tool_mode_to_clarification.rb

require_relative "support/setup"

module Examples
  module ToolModeToClarification
    BASE_INSTRUCTIONS = "You are Duck, an English tutor. Keep answers short."
    MANAGE_CARDS_INSTRUCTIONS = "Manage the learner's flashcards with the tools. Confirm what you did."
    CLARIFY_INSTRUCTIONS = "Ask one short question to resolve the ambiguity. Do not answer yet."

    class CreateCard < RubyLLM::Tool
      description "Creates a flashcard"
      parameter :front, description: "The word or phrase"
      parameter :back, description: "Its meaning"

      def execute(front:, back:)
        { created: front }
      end
    end

    class ManageCardsAgent < RubyLLM::ModeAgent
      description "Creates, edits, or deletes flashcards."

      instructions MANAGE_CARDS_INSTRUCTIONS
      tools CreateCard
      thinking effort: :high
      schema do
        string :summary
      end
    end

    class ClarifyAgent < RubyLLM::ModeAgent
      description "Asks one short question when the request is ambiguous."

      instructions CLARIFY_INSTRUCTIONS
      thinking effort: :low
    end

    # Decides by a keyword instead of a model, so the example runs offline.
    class KeywordClassifier
      def call(message:, history:, modes:, instructions:, inputs:)
        name = message.include?("cards") ? "manage_cards" : "clarify"
        RubyLLM::Modes::Decision.new(mode_name: name, confidence: 1.0, reason: "keyword")
      end
    end

    class Router < RubyLLM::Modes::Router
      mode ManageCardsAgent, as: :manage_cards
      mode ClarifyAgent, as: :clarify
      fallback ClarifyAgent
      classify_with KeywordClassifier.new
    end

    Snapshot = Struct.new(:mode_name, :system_messages, :tools, :schema, :thinking, keyword_init: true)

    # Returns the chat's configuration after each mode: +after_manage_cards+
    # and +after_clarify+.
    def self.run
      chat = RubyLLM.chat(model: "gemini-3.5-flash-lite")
      StubProvider.stub(chat) { |_messages, **_options| "Which deck should it go to?" }
      chat.with_instructions(BASE_INSTRUCTIONS)
      router = Router.new

      route = router.route(chat.ask_later("add reluctant to my cards"))
      route.mode.complete
      after_manage_cards = snapshot(chat, route)

      reset(chat)
      route = router.route(chat.ask_later("the other one"))
      route.mode.complete
      after_clarify = snapshot(chat, route)

      { after_manage_cards:, after_clarify: }
    end

    # The reset for a chat object reused across turns.
    def self.reset(chat)
      chat.with_instructions(BASE_INSTRUCTIONS)
          .with_tools(nil)
          .with_schema(nil)
    end

    def self.snapshot(chat, route)
      Snapshot.new(
        mode_name: route.mode_name,
        system_messages: chat.messages.select { |message| message.role == :system }.map(&:content),
        tools: chat.tools.keys,
        schema: chat.schema,
        thinking: chat.thinking
      )
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Examples::ToolModeToClarification.run.each do |stage, snapshot|
    puts "#{stage} (mode #{snapshot.mode_name}):"
    puts "  system messages: #{snapshot.system_messages.inspect}"
    puts "  tools:           #{snapshot.tools.inspect}"
    puts "  schema:          #{snapshot.schema.nil? ? "nil" : "set"}"
    puts "  thinking:        #{snapshot.thinking.inspect}"
  end
end
