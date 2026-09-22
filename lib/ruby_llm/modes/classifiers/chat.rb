# frozen_string_literal: true

module RubyLLM
  module Modes
    module Classifiers
      # The +:chat+ backend: one structured-output turn on a RubyLLM chat.
      #
      # The system prompt is the frame of the spec (Chat.prompt) unless the
      # router declares +prompt+, in which case +prompt:+ is a callable that
      # returns the full text. +chat_factory:+ replaces RubyLLM.chat; it is
      # called with +model:+ and must return a chat. +confidence+ is the
      # model's self-report.
      #
      # Any object with the same +call+ signature is a valid classifier:
      #
      #   call(message:, history:, modes:, guidance:, inputs:) # => Decision
      #
      class Chat
        FRAME_HEAD = <<~TEXT.strip
          You route the latest user message to one of the modes below.
          Choose exactly one. Use the conversation only to understand what the
          latest message refers to. Do not answer the user.
        TEXT

        FRAME_TAIL = "Return the structured selection: mode, confidence from 0 to 1, reason."

        attr_reader :model, :chat_factory

        def initialize(model: nil, chat_factory: nil, prompt: nil)
          @model = model
          @chat_factory = chat_factory
          @prompt = prompt
        end

        def call(message:, history:, modes:, guidance:, inputs:)
          text = system_prompt(message:, history:, modes:, guidance:, inputs:)
          chat = build_chat
          response = chat.with_instructions(text).with_schema(self.class.schema_for(modes)).ask(message)
          decision_from(response)
        end

        # What ran, for Route#classifier: the resolved model id once a chat
        # was built, else the declared model.
        def trace
          { with: "chat", model: @resolved_model || model }
        end

        # The built-in system prompt for +modes+ (pairs of name and
        # description), the normalised +history+, and the latest +message+.
        def self.prompt(message:, history:, modes:, guidance: nil)
          sections = [ FRAME_HEAD ]
          sections << guidance unless guidance.nil? || guidance.empty?
          sections << "Modes:\n#{modes.map { |name, description| "- #{name}: #{indent(description)}" }.join("\n")}"
          sections << "Conversation:\n#{history.map { |entry| transcript_line(entry) }.join("\n")}" if history.any?
          sections << "Latest message:\n#{message}"
          sections << FRAME_TAIL
          sections.join("\n\n")
        end

        # The selection schema: +mode+ is an enum of the available names.
        def self.schema_for(modes)
          names = modes.map { |name, _description| name }
          Schematist::Schema.create do
            string :mode, enum: names
            number :confidence, minimum: 0, maximum: 1
            string :reason
          end
        end

        def self.indent(description)
          description.to_s.lines.map(&:chomp).join("\n  ")
        end

        def self.transcript_line(entry)
          entry[:role] ? "#{entry[:role]}: #{entry[:content]}" : entry[:content].to_s
        end

        private_class_method :indent, :transcript_line

        private

        def system_prompt(message:, history:, modes:, guidance:, inputs:)
          return self.class.prompt(message:, history:, modes:, guidance:) unless @prompt

          @prompt.call(message:, history:, modes:, guidance:, inputs:).to_s
        end

        def build_chat
          chat = chat_factory ? chat_factory.call(model: model) : RubyLLM.chat(model: model)
          @resolved_model = chat.model.id if chat.respond_to?(:model) && chat.model.respond_to?(:id)
          chat
        end

        def decision_from(response)
          selection = response.parsed
          raise ContractError, "chat backend returned #{selection.class}, expected a JSON object" unless selection.is_a?(Hash)

          confidence = selection["confidence"]
          Decision.new(
            mode_name: selection["mode"]&.to_s,
            confidence: confidence.is_a?(Numeric) ? confidence.to_f : confidence,
            reason: selection["reason"]&.to_s,
            probabilities: nil
          )
        end
      end
    end
  end
end
