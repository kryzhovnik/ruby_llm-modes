# frozen_string_literal: true

module RubyLLM
  module Modes
    # Extend into an Agent class to make it routable.
    #
    #   class TutorAgent < RubyLLM::Agent
    #     extend RubyLLM::Modes::Mode
    #     description "Explains words and grammar."
    #     mode_name "tutor"   # optional
    #   end
    #
    # Neither value is inherited. A subclass declares its own description,
    # and its name is derived from its own class name unless overridden.
    #
    # A mode takes one turn of a chat that already has its own system
    # prompt, so its +instructions+ default to <tt>append: true</tt> (added
    # after the chat's prompt) and <tt>persist: false</tt> (kept out of a
    # Rails record's history). Declare either option to override.
    module Mode
      # Agent's +instructions+ with mode defaults: <tt>append: true</tt> and
      # <tt>persist: false</tt>. Everything else, including the getter form
      # and prompt locals, is Agent's.
      def instructions(text = nil, append: true, persist: false, **options, &block)
        super
      end

      # Tells the router what the mode does and when to pick it, as a
      # Tool's +description+ tells the model when to call the tool. Sets
      # the text, or returns this class's own one. Multi-line text is fine;
      # surrounding whitespace is removed.
      def description(text = nil)
        return @description if text.nil?

        @description = text.to_s.strip
      end

      # Sets the registration name, or returns it: the override declared on
      # this class, else the name derived from the class name (see
      # Mode.derive_name).
      def mode_name(name = nil)
        return @mode_name || Mode.derive_name(self) if name.nil?

        @mode_name = name.to_s
      end

      # Derives a registration name from a class name: the trailing "Agent"
      # removed (a segment that is only "Agent" stays), namespaces kept as
      # path segments, the rest underscored.
      #
      #   TutorAgent       -> "tutor"
      #   Chat::TutorAgent -> "chat/tutor"
      #   TutorModeAgent   -> "tutor_mode"
      #
      # Returns nil for an anonymous class.
      def self.derive_name(klass)
        return if klass.name.nil?

        base = klass.name.sub(/(?<=\w)Agent\z/, "")
        RubyLLM::Support::Utils.underscore(base.gsub("::", "/"))
      end
    end
  end
end
