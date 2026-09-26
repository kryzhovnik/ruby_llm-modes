# frozen_string_literal: true

module RubyLLM
  module Modes
    # The declaration: modes, a fallback, a classifier, and instructions.
    #
    #   class ChatModeRouter < RubyLLM::Modes::Router
    #     inputs :user, :card
    #
    #     mode TutorAgent
    #     mode ManageCardsAgent, "Manages flashcards"
    #     mode ShowtimeAgent, if: -> { user.showtime_enabled? }
    #
    #     instructions { "The learner has a flashcard open." if card }
    #     history last: 6
    #     truncate message: 30_000, history_entry: 2_000
    #     fallback TutorAgent, below_confidence: 0.6
    #     classify_with :chat, model: "gemini-3.5-flash-lite"
    #   end
    #
    #   chat.ask_later(text)
    #   route = ChatModeRouter.new(user:, card:).route(chat)
    #   route.mode.complete
    #
    # Subclassing copies the declarations. +mode+ appends to the inherited
    # list; the other macros replace. Declarations are validated when a
    # router is built with +new+, not when the class is defined.
    class Router
      BACKENDS = %i[chat judge].freeze
      private_constant :BACKENDS

      # Default character caps on what reaches the classifier: the routed
      # message keeps its head and tail, each history entry its head.
      # Well under the smallest backend limit known (Jev: about 170k
      # characters per request) with a history of a few dozen entries.
      MESSAGE_LIMIT = 30_000
      HISTORY_ENTRY_LIMIT = 2_000

      # How much of a provider's message the fallback reason keeps.
      REASON_LIMIT = 200

      class << self
        def inherited(subclass) # :nodoc:
          super
          subclass.instance_variable_set(:@registrations, registrations.dup)
          subclass.instance_variable_set(:@input_names, input_names.dup)
          subclass.instance_variable_set(:@instructions_source, @instructions_source)
          subclass.instance_variable_set(:@history_limit, @history_limit)
          subclass.instance_variable_set(:@message_limit, message_limit)
          subclass.instance_variable_set(:@history_entry_limit, history_entry_limit)
          subclass.instance_variable_set(:@fallback_class, @fallback_class)
          subclass.instance_variable_set(:@below_confidence, @below_confidence)
          subclass.instance_variable_set(:@classifier_spec, @classifier_spec)
          subclass.instance_variable_set(:@error_handler, @error_handler)
        end

        # Declares runtime inputs. Every declared name must be passed to
        # +new+; each is then a method on the router instance, visible in
        # +if:+ and +instructions+ blocks. Called with no arguments,
        # returns the declared names.
        def inputs(*names)
          return input_names if names.empty?

          @input_names = names.flatten.map(&:to_sym)
        end

        # Registers a mode. +klass+ is a RubyLLM::Agent subclass. The inline
        # +description+ wins over +klass.description+. +as:+ sets the
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

        # The app's text for the classifier, ahead of the modes and the
        # conversation. Like Agent#instructions it accepts a string, a
        # block run on the router instance (inputs are methods, and
        # +prompt(name, **locals)+ renders a template next to the router's
        # own), or keyword locals for the conventional template
        # <tt>app/prompts/<router_path>/instructions.txt.erb</tt>, which a
        # bare +instructions+ also selects. Procs among the locals run on
        # the router instance. Every backend receives the same resolved
        # string.
        #
        #   instructions "Route by the learner's intended action."
        #   instructions { "The learner has a flashcard open." if card }
        #   instructions                                  # chat_mode_router/instructions.txt.erb
        #   instructions deck: -> { card.deck.name }      # the same template, with a local
        def instructions(text = nil, **locals, &block)
          @instructions_source = block || text || { prompt: "instructions", locals: locals }
        end

        # The directory under +app/prompts/+ for this router's templates:
        # +ChatModeRouter+ is +chat_mode_router+, +Duck::ChatRouter+ is
        # +duck/chat_router+.
        def prompt_path
          RubyLLM::Support::Utils.underscore((name || "router").gsub("::", "/"))
        end

        # How much of the conversation before the routed message reaches
        # the classifier. <tt>history last: 6</tt> keeps the last six
        # entries, any role but system; <tt>history :all</tt> keeps every
        # entry, which is the default and lets a subclass undo an
        # inherited limit.
        def history(scope = nil, last: nil)
          unless (scope == :all) ^ !last.nil?
            raise ArgumentError, "history takes :all or last: n, got #{[ scope, last ].compact.inspect}"
          end

          unless last.nil? || (last.is_a?(Integer) && last.positive?)
            raise ArgumentError, "history last: takes a positive Integer, got #{last.inspect}"
          end

          @history_limit = last
        end

        # Character caps on what reaches the classifier, whatever the
        # backend. The routed +message:+ keeps its first and last half
        # (the intent of a long paste is at one end); each +history_entry:+
        # keeps its head. A marker names how many characters were cut.
        # Defaults: MESSAGE_LIMIT and HISTORY_ENTRY_LIMIT; nil disables a
        # cap. Pass only the caps to change.
        #
        #   truncate message: 30_000, history_entry: 2_000
        #   truncate history_entry: nil
        def truncate(message: message_limit, history_entry: history_entry_limit)
          @message_limit = limit_value(:message, message)
          @history_entry_limit = limit_value(:history_entry, history_entry)
        end

        # The mode used when the classifier is ignored. +below_confidence:+
        # sets the threshold under which a decision is ignored; nil disables it.
        def fallback(klass, below_confidence: nil)
          @fallback_class = klass
          @below_confidence = below_confidence
        end

        # Picks the classifier: +:chat+, +:judge+, or any object responding
        # to +call+ (see Classifiers::Chat for the contract). Required.
        # Remaining options go to the built-in backend (+chat_factory:+ for
        # +:chat+; +provider:+ and +judge:+ for +:judge+).
        def classify_with(backend, model: nil, **options)
          @classifier_spec = { with: backend, model: model, options: options }
        end

        # Receives every exception a classifier raises, including
        # ContractError. Runs on the router instance. Default: nothing.
        def on_error(&block)
          @error_handler = block
        end

        def registrations = @registrations ||= []
        def input_names = @input_names ||= []
        def history_limit = @history_limit
        def message_limit = defined?(@message_limit) ? @message_limit : MESSAGE_LIMIT
        def history_entry_limit = defined?(@history_entry_limit) ? @history_entry_limit : HISTORY_ENTRY_LIMIT
        def fallback_class = @fallback_class
        def below_confidence = @below_confidence
        def classifier_spec = @classifier_spec
        def error_handler = @error_handler
        def instructions_source = @instructions_source

        # Checks the declaration; raises DeclarationError on the first problem.
        def validate!
          raise DeclarationError, "#{name}: no fallback declared" if fallback_class.nil?

          validate_inputs!
          registrations.each { |registration| validate_registration!(registration) }
          validate_uniqueness!
          validate_fallback!
          validate_classifier!
          validate_instructions!
        end

        private

        def limit_value(name, value)
          return value if value.nil? || (value.is_a?(Integer) && value.positive?)

          raise ArgumentError, "truncate #{name}: takes a positive Integer or nil, got #{value.inspect}"
        end

        def registration_name_for(klass)
          klass.respond_to?(:mode_name) ? klass.mode_name : Mode.derive_name(klass)
        end

        def description_for(klass)
          klass.description if klass.respond_to?(:description)
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
                "#{name}: mode #{registration.name} has no description; declare one on the class or pass it inline"
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

        # A conventional template is looked up here, not on the first call.
        def validate_instructions!
          return unless instructions_source.is_a?(Hash)

          template = RubyLLM::Prompt.new("#{prompt_path}/#{instructions_source[:prompt]}")
          return if File.exist?(template.path)

          raise DeclarationError, "#{name}: instructions template not found at #{template.path}"
        end

        def validate_classifier!
          raise DeclarationError, "#{name}: no classifier declared; add classify_with :chat, :judge, or an object" if classifier_spec.nil?

          backend = classifier_spec[:with]
          case backend
          when :chat
            nil
          when :judge
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

      # The Registration values available for this call, in declaration order.
      def modes
        self.class.registrations.select { |registration| registration.available_on?(self) }
      end

      # Routes the latest user message of +chat+: any object that yields
      # its messages with +each+, as RubyLLM::Chat, a Rails chat record,
      # and an Agent do. The entries are RubyLLM::Message objects, records
      # responding to +to_llm+, <tt>{ role:, content: }</tt> hashes, or
      # strings. System messages are left out; the last remaining entry
      # must be a user message (ArgumentError otherwise) and is the routed
      # message, the entries before it are the history. +classifier:+
      # replaces the declared backend for this call. Returns a Route
      # bound to +chat+.
      #
      # The message and the history entries are cut to the declared
      # +truncate+ caps first.
      def route(chat, classifier: nil)
        message, history = split_conversation(chat)
        available = modes
        return fallback_route(chat, "No other mode available", duration_ms: 0) if available.size == 1

        backend = classifier || self.classifier
        request = {
          message: truncate_message(message),
          history: limit_history(history),
          modes: available,
          instructions: resolved_instructions,
          inputs: inputs
        }

        started = monotonic_ms
        decision, error = run_classifier(backend, request)
        duration_ms = monotonic_ms - started
        trace = trace_for(backend)

        return fallback_route(chat, failure_reason(error), duration_ms:, classifier: trace, error:) if error

        resolve(chat, decision, available, duration_ms:, classifier: trace)
      end

      # Routes +chat+ to the mode registered as +name+ because the caller
      # chose it; no classifier runs and the conversation is not read.
      # Respects +if:+ and raises UnknownMode when the name is not
      # registered or not available now.
      def force(name, chat:)
        registration = modes.find { |candidate| candidate.name == name.to_s }
        raise UnknownMode.new("Unknown mode #{name}", receiver: self, key: name) unless registration

        Route.new(mode_class: registration.klass, mode_name: registration.name, chat:, inputs:, decided_by: :caller, reason: "Mode requested by caller")
      end

      private

      def resolve(chat, decision, available, duration_ms:, classifier:)
        common = { duration_ms:, classifier:, decision: }
        registration = available.find { |candidate| candidate.name == decision.mode_name }
        return fallback_route(chat, "Unknown mode #{decision.mode_name.nil? ? "nil" : decision.mode_name}", **common) unless registration

        threshold = self.class.below_confidence
        if threshold
          return fallback_route(chat, "Confidence not scored", **common) if decision.confidence.nil?
          return fallback_route(chat, "Below confidence threshold", **common) if decision.confidence < threshold
        end

        Route.new(mode_class: registration.klass, mode_name: registration.name, chat:, inputs:, decided_by: :classifier, reason: decision.reason, **common)
      end

      def fallback_route(chat, reason, **attributes)
        registration = self.class.registrations.find { |candidate| candidate.klass == self.class.fallback_class }
        Route.new(mode_class: registration.klass, mode_name: registration.name, chat:, inputs:, decided_by: :fallback, reason: reason, **attributes)
      end

      # "Classifier failed: <class>: <first line of the message>", so a
      # logged route says what the provider said (Jev's 400 body names
      # +max_tokens_exceeded+). The message is left out when it is only
      # the class name, Ruby's default.
      def failure_reason(error)
        reason = "Classifier failed: #{error.class}"
        line = error.message.to_s.lines.first.to_s.strip
        return reason if line.empty? || line == error.class.name

        "#{reason}: #{line[0, REASON_LIMIT]}"
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
          Classifiers::Chat.new(model: spec[:model], **spec[:options])
        when :judge
          Classifiers::Judge.new(model: spec[:model], **spec[:options])
        else
          spec[:with]
        end
      end

      def resolved_instructions
        source = self.class.instructions_source
        text = case source
        when Proc then instance_exec(&source)
        when Hash then prompt(source[:prompt], **source[:locals])
        else source
        end
        text = text&.to_s&.strip
        text unless text.nil? || text.empty?
      end

      # Renders <tt>app/prompts/<prompt_path>/<name>.txt.erb</tt> with the
      # inputs and +locals+; a Proc local runs on the router instance.
      def prompt(name, **locals)
        evaluated = locals.transform_values { |value| value.is_a?(Proc) ? instance_exec(&value) : value }
        RubyLLM.render_prompt("#{self.class.prompt_path}/#{name}", **inputs, **evaluated)
      end

      # The conversation of +chat+ without its system messages, as the
      # routed message (the content of the last entry, which must be a user
      # message) and the normalised entries before it. What the chat's
      # system prompt says is for the answering model; the classifier has
      # the router's own instructions.
      #
      # The messages are read with +each+, not +messages+: a Rails chat
      # record forwards +each+ to its RubyLLM::Chat, whose messages are
      # loaded in one go, while +messages+ is the bare association, under
      # whatever name +acts_as_chat+ gave it.
      def split_conversation(chat)
        raise ArgumentError, "route takes a chat responding to each, got #{chat.class}" unless chat.respond_to?(:each)

        entries = chat.each.map { |entry| normalize_entry(entry) }.reject { |entry| entry[:role] == :system }
        last = entries.last
        raise ArgumentError, "the chat has no message to route" if last.nil?
        raise ArgumentError, "the latest message must be a user message, got role #{last[:role].inspect}" unless last[:role] == :user

        [ last[:content], entries[0...-1] ]
      end

      # A message within the cap is passed to the classifier as given.
      def truncate_message(message)
        limit = self.class.message_limit
        return message if limit.nil? || message.size <= limit

        Truncation.head_and_tail(message, limit)
      end

      def limit_history(entries)
        limit = self.class.history_limit
        entries = entries.last(limit) if limit
        entries.each { |entry| entry[:content] = Truncation.head(entry[:content], self.class.history_entry_limit) }
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

          raise ArgumentError, "chat messages must be Hashes, RubyLLM::Messages, or Strings, got #{entry.class}"
        end
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end
