# frozen_string_literal: true

# Acceptance example 1: contextual routing.
#
# The router takes a +card+ input and its guidance block mentions the open
# card only when one is given. The resolved guidance reaches both the
# built-in chat backend (as part of the system prompt) and a custom
# classifier (as the +guidance:+ argument).
#
#   bundle exec ruby examples/contextual_routing.rb

require_relative "support/setup"

module Examples
  module ContextualRouting
    CARD_SENTENCE = "The learner has a flashcard open on screen."

    class TutorAgent < RubyLLM::ModeAgent
      mode_description "Explains words and grammar, corrects the learner, keeps the conversation going."
    end

    class ManageCardsAgent < RubyLLM::ModeAgent
      mode_description "Creates, edits, or deletes flashcards. Only when the learner asks for it."
    end

    class Router < RubyLLM::Modes::Router
      inputs :card

      mode TutorAgent, as: :tutor
      mode ManageCardsAgent, as: :card

      guidance do
        text = "Duck is an English-learning app. Route by the learner's intended action."
        text += "\n#{CARD_SENTENCE}" if card
        text
      end

      fallback TutorAgent, below_confidence: 0.6
      classify_with :chat, model: "gemini-3.5-flash-lite"
    end

    # A custom classifier that keeps the guidance it was given.
    class RecordingClassifier
      attr_reader :guidance

      def call(message:, history:, modes:, guidance:, inputs:)
        @guidance = guidance
        RubyLLM::Modes::Decision.new(mode_name: "card", confidence: 0.9, reason: "recorded")
      end
    end

    # Runs the router with and without a card against both backends.
    # Returns the system prompt the chat backend sent and the guidance the
    # custom classifier received, keyed by backend and by card presence.
    def self.run
      {
        chat: { with_card: chat_prompt(card: "reluctant"), without_card: chat_prompt(card: nil) },
        custom: { with_card: custom_guidance(card: "reluctant"), without_card: custom_guidance(card: nil) }
      }
    end

    def self.chat_prompt(card:)
      factory = StubProvider::ChatFactory.new(mode: "card", confidence: 0.9, reason: "asked to add")
      classifier = RubyLLM::Modes::Classifiers::Chat.new(model: "gemini-3.5-flash-lite", chat_factory: factory)
      Router.new(card:).call("add it to my cards", classifier: classifier)
      factory.system_prompt
    end

    def self.custom_guidance(card:)
      classifier = RecordingClassifier.new
      Router.new(card:).call("add it to my cards", classifier: classifier)
      classifier.guidance
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  results = Examples::ContextualRouting.run
  results.each do |backend, by_card|
    by_card.each do |situation, text|
      mentions = text.include?(Examples::ContextualRouting::CARD_SENTENCE)
      puts "#{backend} backend, #{situation}: card sentence #{mentions ? "present" : "absent"}"
    end
  end
  puts
  puts "Chat backend system prompt with a card open:"
  puts results[:chat][:with_card]
end
