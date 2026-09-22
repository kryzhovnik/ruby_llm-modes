# frozen_string_literal: true

module RubyLLM
  # A RubyLLM::Agent that is routable: subclass it and declare
  # mode_description. Apps with their own agent base class extend
  # RubyLLM::Modes::Mode into that base instead.
  class ModeAgent < Agent
    extend Modes::Mode
  end
end
