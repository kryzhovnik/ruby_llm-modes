# frozen_string_literal: true

module RubyLLM
  module Modes
    module Classifiers
      # The +:judge+ backend: one RubyLLM.judge call with a single +choice+
      # question over the available modes.
      #
      # The state is the routing input as data (instructions, conversation,
      # latest message); the mode descriptions are the choice options. The
      # answer carries a probability per mode and a +confidence+ reported
      # by the judgment model with it: how concentrated the distribution
      # is on one mode, not a self-report, and a different scale from the
      # chat backend's. It is passed through as is. There is no free text,
      # so +reason+ is always nil.
      #
      # +model+ is passed to RubyLLM.judge as given (nil selects RubyLLM's
      # default judgment model); +provider+ only when given. +judge:+ replaces
      # RubyLLM.judge; it is called with the same arguments and must return
      # a Judgment.
      #
      # RubyLLM.judge is not in every RubyLLM release. Without it the
      # backend cannot run, and the router says so when it is built.
      class Judge
        QUESTION = <<~TEXT.strip
          Which mode should answer the latest user message? Use the conversation
          only to understand what the latest message refers to.
        TEXT

        attr_reader :model, :provider

        def self.available?
          RubyLLM.respond_to?(:judge)
        end

        def initialize(model: nil, provider: nil, judge: nil)
          @model = model
          @provider = provider
          @judge = judge
        end

        def call(message:, history:, modes:, instructions:, inputs:)
          @resolved_model = nil
          state = self.class.state(message:, history:, instructions:)
          judgment = judge.call(state, questions: self.class.questions(modes), **model_options)
          decision_from(judgment)
        end

        # What ran, for Route#classifier: the model the provider reported
        # once a judgment came back, else the declared model.
        def trace
          { with: "judge", model: @resolved_model || model }
        end

        # The judgment state: +instructions+ when present, the normalised
        # +history+ as a conversation, and the latest +message+.
        def self.state(message:, history:, instructions: nil)
          state = {}
          state["instructions"] = instructions unless instructions.nil? || instructions.empty?
          state["conversation"] = history.map { |entry| transcript_entry(entry) } if history.any?
          state["latest_message"] = message.to_s
          state
        end

        # One choice question whose options are the modes (Registration
        # values), name to description.
        def self.questions(modes)
          { mode: { type: :choice, instructions: QUESTION, options: modes.to_h { |mode| [ mode.name.to_s, mode.description.to_s ] } } }
        end

        def self.transcript_entry(entry)
          entry[:role] ? { "role" => entry[:role].to_s, "content" => entry[:content].to_s } : entry[:content].to_s
        end

        private_class_method :transcript_entry

        private

        def judge
          return @judge if @judge
          raise DeclarationError, "RubyLLM.judge is not available in ruby_llm #{RubyLLM::VERSION}" unless self.class.available?

          RubyLLM.method(:judge)
        end

        def model_options
          options = { model: model }
          options[:provider] = provider if provider
          options
        end

        def decision_from(judgment)
          answer = judgment[:mode] if judgment.respond_to?(:[])
          unless answer.respond_to?(:choice) && answer.respond_to?(:probabilities) && answer.respond_to?(:confidence)
            raise ContractError, "judge backend returned #{answer.class} for the mode question, expected a choice answer"
          end

          resolved = judgment.model if judgment.respond_to?(:model)
          @resolved_model = resolved if resolved.is_a?(String)

          confidence = answer.confidence
          Decision.new(
            mode_name: answer.choice&.to_s,
            confidence: confidence.is_a?(Numeric) ? confidence.to_f : confidence,
            reason: nil,
            probabilities: answer.probabilities&.to_h&.transform_keys(&:to_s)
          )
        end
      end
    end
  end
end
