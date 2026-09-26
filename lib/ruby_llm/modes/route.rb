# frozen_string_literal: true

module RubyLLM
  module Modes
    # What the router decided for one chat, with the classifier's
    # decision attached.
    #
    # mode_class:  the agent class
    # mode_name:   its registration name
    # decided_by:  "caller", "classifier", or "fallback"
    # reason:      why this mode
    # decision:    Decision, or nil when no classifier ran
    # duration_ms: Integer, nil on caller-decided routes
    # classifier:  { with: "chat" | "judge" | "custom", model: String | nil },
    #              or nil when no backend was called
    # error:       the exception a failed classifier raised, or nil
    # chat:        the chat the route was decided for
    # inputs:      the router's inputs, handed to the mode's agent
    Route = Data.define(:mode_class, :mode_name, :decided_by, :reason, :decision, :duration_ms, :classifier, :error,
                        :chat, :inputs) do
      def initialize(mode_class:, mode_name:, decided_by:, reason:, decision: nil, duration_ms: nil, classifier: nil,
                     error: nil, chat: nil, inputs: {})
        super
      end

      # The mode as an agent on the route's chat: Agent.new applies the
      # mode's configuration to the chat and returns the agent wrapping
      # it, so call this once per turn. The router's inputs are the
      # agent's +inputs:+; the agent takes the names it declared and
      # ignores the rest. Extra keywords go to Agent.new as given, except
      # +chat:+: the route was decided for its own chat.
      def mode(**options)
        raise ArgumentError, "the route is bound to its chat; mode takes no chat:" if options.key?(:chat)

        mode_class.new(chat:, inputs:, **options)
      end

      # The fields with string keys, for logs. Drops the mode class, the
      # error, the chat, and the inputs; the nested decision and classifier
      # trace get string keys too.
      def to_h
        super.except(:mode_class, :error, :chat, :inputs).transform_keys(&:to_s).tap do |hash|
          hash["decision"] = decision&.to_h
          hash["classifier"] = classifier&.transform_keys(&:to_s)
        end
      end
    end
  end
end
