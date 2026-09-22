# frozen_string_literal: true

require "ruby_llm"
require "schematist"

require_relative "modes/version"
require_relative "modes/errors"
require_relative "modes/decision"
require_relative "modes/route"
require_relative "modes/classifiers/chat"
require_relative "modes/classifiers/judge"
require_relative "modes/router"
require_relative "modes/mode"
require_relative "mode_agent"

# Route one conversation between agents: one decision per turn, traced.
module RubyLLM
  module Modes
  end
end
