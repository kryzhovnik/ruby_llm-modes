# frozen_string_literal: true

module RubyLLM
  module Modes
    # What the router decided, with the classifier's decision attached.
    #
    # mode:        the agent class
    # mode_name:   its registration name
    # decided_by:  "caller", "classifier", or "fallback"
    # reason:      why this mode
    # decision:    Decision, or nil when no classifier ran
    # duration_ms: Integer, nil on caller-decided routes
    # classifier:  { with: "chat" | "judge" | "custom", model: String | nil },
    #              or nil when no backend was called
    # error:       the exception a failed classifier raised, or nil
    Route = Data.define(:mode, :mode_name, :decided_by, :reason, :decision, :duration_ms, :classifier, :error) do
      def initialize(mode:, mode_name:, decided_by:, reason:, decision: nil, duration_ms: nil, classifier: nil, error: nil)
        super
      end

      # The fields with string keys, for logs. Drops the mode class and the
      # error; the nested decision and classifier trace get string keys too.
      def to_h
        super.except(:mode, :error).transform_keys(&:to_s).tap do |hash|
          hash["decision"] = decision&.to_h
          hash["classifier"] = classifier&.transform_keys(&:to_s)
        end
      end
    end
  end
end
