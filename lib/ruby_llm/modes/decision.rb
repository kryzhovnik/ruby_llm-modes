# frozen_string_literal: true

module RubyLLM
  module Modes
    # What the classifier said, untouched.
    #
    # mode_name:     String or nil
    # confidence:    Float 0..1, or nil for "not scored"
    # reason:        String or nil
    # probabilities: { name => Float } or nil
    Decision = Data.define(:mode_name, :confidence, :reason, :probabilities) do
      def initialize(mode_name: nil, confidence: nil, reason: nil, probabilities: nil)
        super
      end

      # String-keyed hash for logs and serialisation. "probabilities" is
      # present only when the classifier set them.
      def to_h
        hash = { "mode" => mode_name, "confidence" => confidence, "reason" => reason }
        hash["probabilities"] = probabilities.transform_keys(&:to_s) if probabilities
        hash
      end
    end
  end
end
