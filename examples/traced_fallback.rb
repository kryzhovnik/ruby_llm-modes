# frozen_string_literal: true

# Acceptance example 3: a custom classifier with a traced fallback.
#
# The classifier picks "showtime" at 0.42 confidence. The router's
# threshold is 0.6, so the route falls back to the tutor, and the Route
# still carries the classifier's decision for logs.
#
#   bundle exec ruby examples/traced_fallback.rb

require_relative "support/setup"

module Examples
  module TracedFallback
    class TutorAgent < RubyLLM::ModeAgent
      description "Explains words and grammar, corrects the learner, keeps the conversation going."
    end

    class ShowtimeAgent < RubyLLM::ModeAgent
      description "Runs a timed review session when the learner asks to start one."
    end

    # Any object with this +call+ is a classifier.
    class HesitantClassifier
      def call(message:, history:, modes:, instructions:, inputs:)
        RubyLLM::Modes::Decision.new(mode_name: "showtime", confidence: 0.42, reason: "might be asking for a session")
      end
    end

    class Router < RubyLLM::Modes::Router
      mode TutorAgent, as: :tutor
      mode ShowtimeAgent, as: :showtime

      fallback TutorAgent, below_confidence: 0.6
      classify_with HesitantClassifier.new
    end

    def self.run
      Router.new.call("let's go", history: [ "hi", "hello, what shall we do today?" ])
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  route = Examples::TracedFallback.run
  puts "mode_class: #{route.mode_class}"
  puts "decided_by: #{route.decided_by}"
  puts "reason:     #{route.reason}"
  puts "to_h:       #{route.to_h.inspect}"
end
