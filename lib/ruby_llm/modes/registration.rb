# frozen_string_literal: true

module RubyLLM
  module Modes
    # One +mode+ declaration of a router, resolved. +klass+ is the agent
    # class, +name+ the registration name, +description+ the routing
    # description, and +condition+ the +if:+ lambda or nil.
    #
    # Router#modes returns the registrations available for a call, and a
    # classifier receives the same objects as +modes:+.
    Registration = Data.define(:klass, :name, :description, :condition) do
      def available_on?(router)
        condition.nil? || !!router.instance_exec(&condition)
      end
    end
  end
end
