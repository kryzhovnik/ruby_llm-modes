# frozen_string_literal: true

# Acceptance example 2: a tool mode followed by a clarification mode on
# one long-lived chat.
#
# The chat starts with base instructions. ManageCardsAgent adds tools, a
# schema, and high-effort thinking. Before ClarifyAgent takes the next
# turn the app applies the reset of SPEC.md §8: base instructions back
# (which drops the appended mode instructions), tools and schema cleared.
# ClarifyAgent then adds its own instructions and low-effort thinking.
#
# Only the provider request is stubbed; the chat is a real RubyLLM::Chat.
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
      mode_description "Creates, edits, or deletes flashcards."

      instructions MANAGE_CARDS_INSTRUCTIONS
      tools CreateCard
      thinking effort: :high
      schema do
        string :summary
      end
    end

    class ClarifyAgent < RubyLLM::ModeAgent
      mode_description "Asks one short question when the request is ambiguous."

      instructions CLARIFY_INSTRUCTIONS
      thinking effort: :low
    end

    Snapshot = Struct.new(:system_messages, :tools, :schema, :thinking, keyword_init: true)

    # Returns the chat's configuration after each mode: +after_manage_cards+
    # and +after_clarify+.
    def self.run
      chat = RubyLLM.chat(model: "gemini-3.5-flash-lite")
      StubProvider.stub(chat) { |_messages, **_options| "Which deck should it go to?" }
      chat.with_instructions(BASE_INSTRUCTIONS)

      chat.add_message(role: :user, content: "add reluctant to my cards")
      ManageCardsAgent.new(chat:).complete
      after_manage_cards = snapshot(chat)

      reset(chat)
      chat.add_message(role: :user, content: "the other one")
      ClarifyAgent.new(chat:).complete
      after_clarify = snapshot(chat)

      { after_manage_cards:, after_clarify: }
    end

    # The reset of SPEC.md §8 for a long-lived in-memory chat.
    def self.reset(chat)
      chat.with_instructions(BASE_INSTRUCTIONS)
          .with_tools(nil)
          .with_schema(nil)
    end

    def self.snapshot(chat)
      Snapshot.new(
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
    puts "#{stage}:"
    puts "  system messages: #{snapshot.system_messages.inspect}"
    puts "  tools:           #{snapshot.tools.inspect}"
    puts "  schema:          #{snapshot.schema.nil? ? "nil" : "set"}"
    puts "  thinking:        #{snapshot.thinking.inspect}"
  end
end
