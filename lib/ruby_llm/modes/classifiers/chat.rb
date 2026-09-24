# frozen_string_literal: true

module RubyLLM
  module Modes
    module Classifiers
      # The +:chat+ backend: one structured-output turn on a RubyLLM chat.
      #
      # The system prompt is the built-in frame (Chat.prompt): the router's
      # instructions, the modes, and the conversation.
      # +chat_factory:+ replaces RubyLLM.chat; it is called with +model:+
      # and must return a chat. +confidence+ is the model's self-report.
      #
      # Any object with the same +call+ signature is a valid classifier:
      #
      #   call(message:, history:, modes:, instructions:, inputs:) # => Decision
      #
      class Chat
        FRAME_HEAD = <<~TEXT.strip
          You route the latest user message to one of the modes below.
          Choose exactly one. Use the conversation only to understand what the
          latest message refers to. Do not answer the user.
        TEXT

        FRAME_TAIL = "Return the structured selection: mode, confidence from 0 to 1, reason."

        attr_reader :model, :chat_factory

        def initialize(model: nil, chat_factory: nil)
          @model = model
          @chat_factory = chat_factory
        end

        def call(message:, history:, modes:, instructions:, inputs:)
          @resolved_model = nil
          text = self.class.prompt(message:, history:, modes:, instructions:)
          chat = build_chat
          response = chat.with_instructions(text).with_schema(self.class.schema_for(modes)).ask(message)
          decision_from(response)
        end

        # What ran, for Route#classifier: the resolved model id once a chat
        # was built, else the declared model.
        def trace
          { with: "chat", model: @resolved_model || model }
        end

        # The system prompt for +modes+ (Registration values) and the
        # normalised +history+, with the router's +instructions+ between
        # the frame and the modes. The latest +message+ is the user turn,
        # so it is not repeated here.
        def self.prompt(message:, history:, modes:, instructions: nil)
          sections = [ FRAME_HEAD ]
          sections << instructions unless instructions.nil? || instructions.empty?
          sections << "Modes:\n#{modes.map { |mode| "- #{mode.name}: #{indent(mode.description)}" }.join("\n")}"
          sections << "Conversation:\n#{history.map { |entry| transcript_line(entry) }.join("\n")}" if history.any?
          sections << FRAME_TAIL
          sections.join("\n\n")
        end

        # The selection schema: +mode+ is an enum of the available names.
        def self.schema_for(modes)
          names = modes.map(&:name)
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

        # The trace is plain data for logs, so only a String model id is
        # kept: a stand-in chat that answers every message with itself must
        # not end up serialised into a route.
        def build_chat
          chat = chat_factory ? chat_factory.call(model: model) : RubyLLM.chat(model: model)
          resolved = chat.model.id if chat.respond_to?(:model) && chat.model.respond_to?(:id)
          @resolved_model = resolved if resolved.is_a?(String)
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
