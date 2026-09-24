# frozen_string_literal: true

module RubyLLM
  module Modes
    # Cuts text down to a character limit before it reaches a classifier.
    # Every backend has an input limit (Jev rejects a request over roughly
    # 170k characters with a 400), and one oversized entry would otherwise
    # cost the whole turn its routing.
    module Truncation
      module_function

      # The first +limit+ characters of +text+, with a marker for the rest.
      # A history entry is cut this way: its opening says what the turn
      # was about.
      def head(text, limit)
        return text if limit.nil? || text.size <= limit

        text[0, limit] + marker(text.size - limit)
      end

      # The first and the last +limit / 2+ characters of +text+, with a
      # marker between them. The routed message is cut this way: the
      # intent of a long paste ("make cards from this article: ..." or
      # "... summarise the above") sits at one end or the other, never in
      # the middle.
      def head_and_tail(text, limit)
        return text if limit.nil? || text.size <= limit

        head_size = limit / 2
        tail_size = limit - head_size
        text[0, head_size] + marker(text.size - limit) + text[-tail_size, tail_size]
      end

      def marker(omitted)
        "\n[... #{omitted} characters omitted ...]\n"
      end

      private_class_method :marker
    end
  end
end
