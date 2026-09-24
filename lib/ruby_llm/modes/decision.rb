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

      # The fields with string keys, for logs and serialisation.
      # "probabilities" is present only when the classifier set them.
      def to_h
        hash = super.transform_keys(&:to_s)
        probabilities ? hash.merge("probabilities" => probabilities.transform_keys(&:to_s)) : hash.except("probabilities")
      end
    end
  end
end
