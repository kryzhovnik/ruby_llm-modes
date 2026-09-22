# frozen_string_literal: true

module RubyLLM
  module Modes
    module Classifiers
      # The +:chat+ backend: one structured-output turn on a RubyLLM chat.
      class Chat
        attr_reader :model

        def initialize(model: nil, chat_factory: nil, prompt: nil)
          @model = model
          @chat_factory = chat_factory
          @prompt = prompt
        end

        def call(message:, history:, modes:, guidance:, inputs:)
          raise NotImplementedError
        end

        # What ran, for Route#classifier.
        def trace
          { with: "chat", model: model }
        end
      end
    end
  end
end
