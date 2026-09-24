# frozen_string_literal: true

module RubyLLM
  module Modes
    # The declaration: modes, a fallback, a classifier, and guidance.
    #
    #   class ChatModeRouter < RubyLLM::Modes::Router
    #     inputs :user, :card
    #
    #     mode TutorAgent
    #     mode ManageCardsAgent, "Manages flashcards"
    #     mode ShowtimeAgent, if: -> { user.showtime_enabled? }
    #
    #     guidance { "The learner has a flashcard open." if card }
    #     history 6
    #     fallback TutorAgent, below_confidence: 0.6
    #     classify with: :chat, model: "gemini-3.5-flash-lite"
    #   end
    #
    #   route = ChatModeRouter.new(user:, card:).call(message, history:)
    #   agent = route.mode.new(chat:, user:, card:)
    #   agent.complete
    #
    # Subclassing copies the declarations. +mode+ appends to the inherited
    # list; the other macros replace. Declarations are validated when a
    # router is built with +new+, not when the class is defined.
    class Router
      # One +mode+ declaration, resolved. +condition+ is the +if:+ lambda or nil.
      Registration = Data.define(:klass, :name, :description, :condition) do
        def available_on?(router)
          condition.nil? || !!router.instance_exec(&condition)
        end

        def to_pair
          [ name, description ]
        end
      end

      BACKENDS = %i[chat judge].freeze
      private_constant :BACKENDS

      class << self
        def inherited(subclass) # :nodoc:
          super
          subclass.instance_variable_set(:@registrations, registrations.dup)
          subclass.instance_variable_set(:@input_names, input_names.dup)
          subclass.instance_variable_set(:@guidance_source, @guidance_source)
          subclass.instance_variable_set(:@prompt_source, @prompt_source)
          subclass.instance_variable_set(:@history_limit, @history_limit)
          subclass.instance_variable_set(:@fallback_class, @fallback_class)
          subclass.instance_variable_set(:@below_confidence, @below_confidence)
          subclass.instance_variable_set(:@classifier_spec, @classifier_spec)
          subclass.instance_variable_set(:@error_handler, @error_handler)
        end

        # Declares runtime inputs. Every declared name must be passed to
        # +new+; each is then a method on the router instance, visible in
        # +if:+, +guidance+, and +prompt+ blocks. Called with no arguments,
        # returns the declared names.
        def inputs(*names)
          return input_names if names.empty?

          @input_names = names.flatten.map(&:to_sym)
        end

        # Registers a mode. +klass+ is a RubyLLM::Agent subclass. The inline
        # +description+ wins over +klass.mode_description+. +as:+ sets the
        # registration name (default: +klass.mode_name+, else the derivation
        # of Mode.derive_name). +if:+ is a lambda run on the router instance
        # that decides availability per call.
        def mode(klass, description = nil, as: nil, if: nil)
          condition = binding.local_variable_get(:if)
          registrations << Registration.new(
            klass: klass,
            name: as&.to_s || registration_name_for(klass),
            description: description&.to_s&.strip || description_for(klass),
            condition: condition
          )
        end

        # Cross-mode routing text, a string or a block run on the router
        # instance. Every backend receives the same resolved string.
        def guidance(text = nil, &block)
          @guidance_source = block || text
        end

        # Replaces the chat backend's built-in system prompt: a template name
        # rendered with RubyLLM.render_prompt, or a block returning the full
        # text. Both see +modes+, +guidance+, +history+, +message+, and the
        # inputs. Incompatible with the +:judge+ backend.
        def prompt(name = nil, &block)
          @prompt_source = block || name
        end

        # Keeps only the last +n+ history entries.
        def history(n)
          @history_limit = Integer(n)
        end

        # The mode used when the classifier is ignored. +below_confidence:+
        # sets the threshold under which a decision is ignored; nil disables it.
        def fallback(klass, below_confidence: nil)
          @fallback_class = klass
          @below_confidence = below_confidence
        end

        # Picks the classifier: +:chat+, +:judge+, or any object responding
        # to +call+ (see Classifiers::Chat for the contract). +classify model:
        # "..."+ alone means +:chat+. Remaining options go to the built-in
        # backend (+chat_factory:+ for +:chat+; +provider:+ and +judge:+ for
        # +:judge+).
        def classify(with: :chat, model: nil, **options)
          @classifier_spec = { with: with, model: model, options: options }
        end

        # Receives every exception a classifier raises, including
        # ContractError. Runs on the router instance. Default: nothing.
        def on_error(&block)
          @error_handler = block
        end

        def registrations = @registrations ||= []
        def input_names = @input_names ||= []
        def history_limit = @history_limit
        def fallback_class = @fallback_class
        def below_confidence = @below_confidence
        def classifier_spec = @classifier_spec || { with: :chat, model: nil, options: {} }
        def error_handler = @error_handler
        def guidance_source = @guidance_source
        def prompt_source = @prompt_source

        # Checks the declaration; raises DeclarationError on the first problem.
        def validate!
          raise DeclarationError, "#{name}: no fallback declared" if fallback_class.nil?

          validate_inputs!
          registrations.each { |registration| validate_registration!(registration) }
          validate_uniqueness!
          validate_fallback!
          validate_classifier!
        end

        private

        def registration_name_for(klass)
          klass.respond_to?(:mode_name) ? klass.mode_name : Mode.derive_name(klass)
        end

        def description_for(klass)
          klass.mode_description if klass.respond_to?(:mode_description)
        end

        # Inputs become methods on the router instance, so a name that the
        # router (or Object) already answers to would shadow it.
        def validate_inputs!
          taken = input_names.find { |input_name| method_defined?(input_name) || private_method_defined?(input_name) }
          raise DeclarationError, "#{name}: input #{taken.inspect} shadows a router method; pick another name" if taken
        end

        def validate_registration!(registration)
          klass = registration.klass
          unless klass.is_a?(Class) && klass < RubyLLM::Agent
            raise DeclarationError, "#{name}: #{klass.inspect} is not a RubyLLM::Agent subclass"
          end
          if registration.name.nil? || registration.name.empty?
            raise DeclarationError, "#{name}: #{klass.inspect} has no registration name; pass as: or set mode_name"
          end
          return unless registration.description.nil? || registration.description.empty?

          raise DeclarationError,
                "#{name}: mode #{registration.name} has no description; declare mode_description or pass one inline"
        end

        def validate_uniqueness!
          classes = registrations.map(&:klass)
          duplicate = classes.find { |klass| classes.count(klass) > 1 }
          raise DeclarationError, "#{name}: #{duplicate} is registered twice" if duplicate

          names = registrations.map(&:name)
          duplicate = names.find { |mode_name| names.count(mode_name) > 1 }
          raise DeclarationError, "#{name}: duplicate registration name #{duplicate.inspect}" if duplicate
        end

        def validate_fallback!
          registration = registrations.find { |candidate| candidate.klass == fallback_class }
          raise DeclarationError, "#{name}: fallback #{fallback_class} is not registered with mode" unless registration
          raise DeclarationError, "#{name}: fallback #{fallback_class} must not have an if: condition" if registration.condition
        end

        def validate_classifier!
          backend = classifier_spec[:with]
          case backend
          when :chat
            nil
          when :judge
            raise DeclarationError, "#{name}: prompt cannot be declared with the :judge backend" if prompt_source
            return if classifier_spec[:options][:judge] || Classifiers::Judge.available?

            raise DeclarationError, "#{name}: RubyLLM.judge is not available in ruby_llm #{RubyLLM::VERSION}; the :judge backend needs a release that ships RubyLLM::Judge"
          when Symbol
            raise DeclarationError, "#{name}: unknown classifier backend #{backend.inspect}"
          else
            raise DeclarationError, "#{name}: classifier #{backend.inspect} does not respond to call" unless backend.respond_to?(:call)
          end
        end
      end

      # Builds a router for one call. Every declared input must be present
      # as a keyword (a nil value counts); raises ArgumentError otherwise.
      # Raises DeclarationError when the class declaration is invalid.
      def initialize(**inputs)
        self.class.validate!

        missing = self.class.input_names - inputs.keys
        raise ArgumentError, "missing input(s): #{missing.join(", ")}" if missing.any?

        unknown = inputs.keys - self.class.input_names
        raise ArgumentError, "unknown input(s): #{unknown.join(", ")}" if unknown.any?

        @inputs = inputs.freeze
        @inputs.each { |input_name, value| define_singleton_method(input_name) { value } }
        @classifier = build_classifier
      end

      # The inputs passed to +new+.
      attr_reader :inputs

      # The declared classifier backend for this router instance.
      attr_reader :classifier

      # The registrations available for this call, in declaration order.
      def modes
        self.class.registrations.select { |registration| registration.available_on?(self) }
      end

      # Routes +message+. +history:+ entries are <tt>{ role:, content: }</tt>
      # hashes, RubyLLM::Message objects, or strings. +classifier:+ replaces
      # the declared backend for this call. Returns a Route.
      def call(message, history: [], classifier: nil)
        available = modes
        return fallback_route("No other mode available", duration_ms: 0) if available.size == 1

        backend = classifier || self.classifier
        request = {
          message: message,
          history: normalize_history(history),
          modes: available.map(&:to_pair),
          guidance: resolved_guidance,
          inputs: inputs
        }

        started = monotonic_ms
        decision, error = run_classifier(backend, request)
        duration_ms = monotonic_ms - started
        trace = trace_for(backend)

        return fallback_route("Classifier failed: #{error.class}", duration_ms:, classifier: trace, error:) if error

        resolve(decision, available, duration_ms:, classifier: trace)
      end

      # Routes to the mode registered as +name+ without a classifier. Raises
      # UnknownMode when the name is not registered or not available now.
      def explicit(name)
        registration = modes.find { |candidate| candidate.name == name.to_s }
        raise UnknownMode.new("Unknown mode #{name}", receiver: self, key: name) unless registration

        Route.new(mode: registration.klass, mode_name: registration.name, decided_by: "caller", reason: "Mode requested by caller")
      end

      private

      def resolve(decision, available, duration_ms:, classifier:)
        common = { duration_ms:, classifier:, decision: }
        registration = available.find { |candidate| candidate.name == decision.mode_name }
        return fallback_route("Unknown mode #{decision.mode_name.nil? ? "nil" : decision.mode_name}", **common) unless registration

        threshold = self.class.below_confidence
        if threshold
          return fallback_route("Confidence not scored", **common) if decision.confidence.nil?
          return fallback_route("Below confidence threshold", **common) if decision.confidence < threshold
        end

        Route.new(mode: registration.klass, mode_name: registration.name, decided_by: "classifier", reason: decision.reason, **common)
      end

      def fallback_route(reason, **attributes)
        registration = self.class.registrations.find { |candidate| candidate.klass == self.class.fallback_class }
        Route.new(mode: registration.klass, mode_name: registration.name, decided_by: "fallback", reason: reason, **attributes)
      end

      def run_classifier(backend, request)
        decision = backend.call(**request)
        validate_decision!(decision)
        [ decision, nil ]
      rescue StandardError => error
        handler = self.class.error_handler
        instance_exec(error, &handler) if handler
        [ nil, error ]
      end

      def validate_decision!(decision)
        raise ContractError, "classifier returned #{decision.class}, expected a Decision" unless decision.is_a?(Decision)

        mode_name = decision.mode_name
        unless mode_name.nil? || mode_name.is_a?(String)
          raise ContractError, "decision mode_name must be a String or nil, got #{mode_name.inspect}"
        end

        reason = decision.reason
        raise ContractError, "decision reason must be a String or nil, got #{reason.inspect}" unless reason.nil? || reason.is_a?(String)

        validate_confidence!(decision.confidence)
        validate_probabilities!(decision.probabilities)
      end

      def validate_confidence!(confidence)
        return if confidence.nil?
        return if confidence.is_a?(Numeric) && confidence.to_f.finite? && confidence.between?(0, 1)

        raise ContractError, "decision confidence must be nil or a number from 0 to 1, got #{confidence.inspect}"
      end

      def validate_probabilities!(probabilities)
        return if probabilities.nil?
        return if probabilities.is_a?(Hash) && probabilities.values.all? { |value| value.is_a?(Numeric) && value.to_f.finite? }

        raise ContractError, "decision probabilities must be nil or a Hash of name => number, got #{probabilities.inspect}"
      end

      def trace_for(backend)
        backend.respond_to?(:trace) ? backend.trace : { with: "custom", model: nil }
      end

      def build_classifier
        spec = self.class.classifier_spec
        case spec[:with]
        when :chat
          Classifiers::Chat.new(model: spec[:model], prompt: prompt_renderer, **spec[:options])
        when :judge
          Classifiers::Judge.new(model: spec[:model], **spec[:options])
        else
          spec[:with]
        end
      end

      def prompt_renderer
        source = self.class.prompt_source
        return if source.nil?

        lambda do |message:, history:, modes:, guidance:, inputs:|
          if source.is_a?(Proc)
            locals = inputs.merge(message:, history:, modes:, guidance:)
            context = Object.new
            locals.each { |local_name, value| context.define_singleton_method(local_name) { value } }
            context.instance_exec(&source)
          else
            RubyLLM.render_prompt(source, modes:, guidance:, history:, message:, **inputs)
          end
        end
      end

      def resolved_guidance
        source = self.class.guidance_source
        text = source.is_a?(Proc) ? instance_exec(&source) : source
        text = text&.to_s&.strip
        text unless text.nil? || text.empty?
      end

      def normalize_history(history)
        entries = history.map { |entry| normalize_entry(entry) }
        limit = self.class.history_limit
        limit ? entries.last(limit) : entries
      end

      def normalize_entry(entry)
        case entry
        when String then { role: nil, content: entry }
        when RubyLLM::Message then { role: entry.role, content: entry.content.to_s }
        when Hash
          role = entry[:role] || entry["role"]
          content = entry[:content] || entry["content"]
          { role: role&.to_sym, content: content.to_s }
        else
          return normalize_entry(entry.to_llm) if entry.respond_to?(:to_llm)

          raise ArgumentError, "history entries must be Hashes, RubyLLM::Messages, or Strings, got #{entry.class}"
        end
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end
