# frozen_string_literal: true

module RubyLLM
  module Modes
    # What the router decided, with the classifier's decision attached.
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
    # inputs:      the router's inputs, handed to the mode's agent
    Route = Data.define(:mode_class, :mode_name, :decided_by, :reason, :decision, :duration_ms, :classifier, :error,
                        :inputs) do
      def initialize(mode_class:, mode_name:, decided_by:, reason:, decision: nil, duration_ms: nil, classifier: nil,
                     error: nil, inputs: {})
        super
      end

      # The mode as an agent on +chat+. The router's inputs are the agent's
      # +inputs:+; the agent takes the names it declared and ignores the
      # rest. Without +chat:+ the agent builds a fresh chat, as Agent.new
      # does. Extra keywords go to Agent.new as given.
      def mode(chat: nil, **options)
        mode_class.new(chat:, inputs:, **options)
      end

      # The fields with string keys, for logs. Drops the mode class, the
      # error, and the inputs; the nested decision and classifier trace get
      # string keys too.
      def to_h
        super.except(:mode_class, :error, :inputs).transform_keys(&:to_s).tap do |hash|
          hash["decision"] = decision&.to_h
          hash["classifier"] = classifier&.transform_keys(&:to_s)
        end
      end
    end
  end
end
