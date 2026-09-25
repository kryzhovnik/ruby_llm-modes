# frozen_string_literal: true

module RubyLLM
  # A RubyLLM::Agent that is routable: subclass it and declare a
  # description. Its instructions append to the chat's system prompt
  # and are not persisted (see Modes::Mode). Apps with their own agent base
  # class extend RubyLLM::Modes::Mode into that base instead.
  class ModeAgent < Agent
    extend Modes::Mode
  end
end
