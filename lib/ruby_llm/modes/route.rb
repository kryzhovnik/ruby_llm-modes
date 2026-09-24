# frozen_string_literal: true

module RubyLLM
  module Modes
    # What the router decided, with the classifier's decision attached.
    #
    # mode:       the agent class
    # mode_name:  its registration name
    # decided_by: "caller", "classifier", or "fallback"
    # reason:     why this mode
    # decision:   Decision, or nil when no classifier ran
    # routing_ms: Integer, nil on explicit routes
    # classifier: { with: "chat" | "judge" | "custom", model: String | nil },
    #             or nil when no backend was called
    # error:      the exception a failed classifier raised, or nil
    Route = Data.define(:mode, :mode_name, :decided_by, :reason, :decision, :routing_ms, :classifier, :error) do
      def initialize(mode:, mode_name:, decided_by:, reason:, decision: nil, routing_ms: nil, classifier: nil, error: nil)
        super
      end

      # String-keyed hash for logs. Drops the mode class and the error.
      def to_h
        {
          "mode" => mode_name,
          "decided_by" => decided_by,
          "reason" => reason,
          "duration_ms" => routing_ms,
          "classifier" => classifier&.transform_keys(&:to_s),
          "decision" => decision&.to_h
        }
      end
    end
  end
end
