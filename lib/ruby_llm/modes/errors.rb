# frozen_string_literal: true

module RubyLLM
  module Modes
    # Base class for the gem's own errors.
    class Error < StandardError; end

    # A router declaration is invalid. Raised by Router.new.
    class DeclarationError < Error; end

    # Router#force was asked for a name that is not registered or not
    # available for this call.
    class UnknownMode < KeyError; end

    # A classifier returned something outside the contract of §5: not a
    # Decision, or a confidence that is NaN or outside 0..1.
    class ContractError < Error; end
  end
end
