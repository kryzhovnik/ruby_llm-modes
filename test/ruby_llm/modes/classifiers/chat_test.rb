# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::Classifiers::ChatTest < Minitest::Test
  include PromptRoot

  Chat = RubyLLM::Modes::Classifiers::Chat

  MODES = [
    RubyLLM::Modes::Registration.new(klass: nil, name: "tutor", condition: nil, description: "Explains words and grammar, corrects the learner, keeps the\nconversation going. A bare word or phrase is a request to explain it."),
    RubyLLM::Modes::Registration.new(klass: nil, name: "card", condition: nil, description: "Creates, edits, or deletes flashcards. Only when the learner asks\nfor it, never inferred from a word alone.")
  ].freeze

  HISTORY = [
    { role: :user, content: 'what does "reluctant" mean?' },
    { role: :assistant, content: "Reluctant means unwilling or hesitant ..." }
  ].freeze

  EXPECTED_PROMPT = <<~TEXT.strip
    You route the latest user message to one of the modes below.
    Choose exactly one. Use the conversation only to understand what the
    latest message refers to. Do not answer the user.

    Modes:
    - tutor: Explains words and grammar, corrects the learner, keeps the
      conversation going. A bare word or phrase is a request to explain it.
    - card: Creates, edits, or deletes flashcards. Only when the learner asks
      for it, never inferred from a word alone.

    Conversation:
    user: what does "reluctant" mean?
    assistant: Reluctant means unwilling or hesitant ...

    Return the structured selection: mode, confidence from 0 to 1, reason.
  TEXT

  def test_prompt_matches_the_two_mode_example
    assert_equal EXPECTED_PROMPT, Chat.prompt(message: "add it to my cards", history: HISTORY, modes: MODES)
  end

  def test_prompt_places_instructions_between_frame_and_modes
    text = Chat.prompt(message: "add it to my cards", history: HISTORY, modes: MODES, instructions: "Route by intent.")
    assert_equal EXPECTED_PROMPT.sub("Do not answer the user.\n\n", "Do not answer the user.\n\nRoute by intent.\n\n"), text
  end

  def test_prompt_without_history_has_no_conversation_section
    text = Chat.prompt(message: "hello", history: [], modes: MODES)
    refute_includes text, "Conversation:"
    refute_includes text, "hello"
  end

  def test_prompt_renders_role_less_entries_as_bare_lines
    text = Chat.prompt(message: "hello", history: [ { role: nil, content: "earlier" } ], modes: MODES)
    assert_includes text, "Conversation:\nearlier\n"
  end

  def test_schema_enumerates_the_mode_names
    schema = Chat.schema_for(MODES).new.to_json_schema
    assert_equal %w[tutor card], schema.dig("properties", "mode", "enum")
    assert_equal "number", schema.dig("properties", "confidence", "type")
    assert_equal "string", schema.dig("properties", "reason", "type")
    assert_equal %w[mode confidence reason], schema["required"]
  end

  # End to end on a real chat with the provider request stubbed.

  class CardRouter < RubyLLM::Modes::Router
    inputs :card

    mode TutorAgent
    mode ManageCardsAgent, as: :card

    instructions { "The learner has a flashcard open on screen." if card }
    fallback TutorAgent, below_confidence: 0.6
    classify_with :chat, model: "gemini-3.5-flash-lite"
  end

  def test_call_sends_the_frame_as_system_and_the_message_as_user
    factory = StubProvider::ChatFactory.new(mode: "card", confidence: 0.8, reason: "asked to add")
    route = CardRouter.new(card: nil).call("add it to my cards", history: HISTORY, classifier: Chat.new(model: "gemini-3.5-flash-lite", chat_factory: factory))

    request = factory.last_request
    assert_equal [ :system, :user ], request[:messages].map(&:role)
    assert_equal "add it to my cards", request[:messages].last.content
    assert_equal Chat.prompt(message: "add it to my cards", history: HISTORY, modes: CardRouter.new(card: nil).modes), factory.system_prompt
    assert_equal %w[tutor card], request[:schema].dig(:schema, :properties, :mode, :enum)

    assert_equal "classifier", route.decided_by
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal 0.8, route.decision.confidence
    assert_equal "asked to add", route.reason
    assert_equal({ with: "chat", model: "gemini-3.5-flash-lite" }, route.classifier)
  end

  def test_chat_factory_receives_the_model
    factory = StubProvider::ChatFactory.new(mode: "card")
    CardRouter.new(card: nil).call("hi", classifier: Chat.new(model: "gemini-3.5-flash-lite", chat_factory: factory))
    assert_equal [ { model: "gemini-3.5-flash-lite" } ], factory.calls
  end

  def test_instructions_are_part_of_the_system_prompt
    factory = StubProvider::ChatFactory.new(mode: "card")
    CardRouter.new(card: :open).call("hi", classifier: Chat.new(chat_factory: factory))
    assert_includes factory.system_prompt, "The learner has a flashcard open on screen."
  end

  def test_declared_chat_factory_option_reaches_the_backend
    factory = StubProvider::ChatFactory.new(mode: "card", confidence: 0.95)
    router_class = Class.new(CardRouter) { classify_with :chat, model: "gemini-3.5-flash-lite", chat_factory: factory }

    route = router_class.new(card: nil).call("add it")
    assert_equal "classifier", route.decided_by
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal({ with: "chat", model: "gemini-3.5-flash-lite" }, route.classifier)
  end

  def test_trace_records_the_resolved_default_model_when_none_is_declared
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) { classify_with :chat, chat_factory: factory }

    route = router_class.new(card: nil).call("add it")
    assert_equal "chat", route.classifier[:with]
    assert_equal RubyLLM.chat.model.id, route.classifier[:model]
  end

  def test_trace_does_not_keep_the_model_of_a_previous_call
    factory = StubProvider::ChatFactory.new(mode: "card")
    factory.define_singleton_method(:call) { |model:| super(model: "gemini-2.5-flash-lite") }
    classifier = Chat.new(model: "gemini-3.5-flash-lite", chat_factory: factory)
    CardRouter.new(card: nil).call("add it", classifier: classifier)
    assert_equal "gemini-2.5-flash-lite", classifier.trace[:model]

    factory.define_singleton_method(:call) { |model:| raise IOError, "down" }
    route = CardRouter.new(card: nil).call("add it", classifier: classifier)
    assert_equal "Classifier failed: IOError: down", route.reason
    assert_equal({ with: "chat", model: "gemini-3.5-flash-lite" }, route.classifier)
  end

  # A stand-in chat that answers every message with itself (a null object
  # in an app's tests) has a "model id" that is not a String.
  def test_trace_keeps_the_declared_model_when_the_chat_reports_no_string_id
    absorbing = Object.new
    def absorbing.method_missing(*, **) = self
    def absorbing.respond_to_missing?(*) = true
    classifier = Chat.new(model: "gemini-3.5-flash-lite", chat_factory: ->(model:) { absorbing })

    CardRouter.new(card: nil).call("add it", classifier: classifier)

    assert_equal({ with: "chat", model: "gemini-3.5-flash-lite" }, classifier.trace)
  end

  def test_trace_before_any_call_reports_the_declared_model
    assert_equal({ with: "chat", model: "m" }, Chat.new(model: "m").trace)
    assert_equal({ with: "chat", model: nil }, Chat.new.trace)
  end

  def test_instructions_template_renders_with_the_inputs
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) do
      def self.name = "Examples::CardRouter"
      classify_with :chat, model: "gemini-3.5-flash-lite", chat_factory: factory
      instructions
    end

    with_prompt_root("examples/card_router/instructions.txt.erb" => "TEMPLATE card=<%= card %>") do
      router_class.new(card: "c1").call("add it", history: HISTORY)
      assert_includes factory.system_prompt, "TEMPLATE card=c1\n\nModes:"
    end
  end

  def test_instructions_template_locals_run_on_the_router
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) do
      def self.name = "Examples::CardRouter"
      classify_with :chat, model: "gemini-3.5-flash-lite", chat_factory: factory
      instructions deck: -> { "#{card}-deck" }, level: "b2"
    end

    with_prompt_root("examples/card_router/instructions.txt.erb" => "<%= deck %> <%= level %>") do
      router_class.new(card: "c1").call("add it", history: HISTORY)
      assert_includes factory.system_prompt, "c1-deck b2\n\nModes:"
    end
  end

  def test_instructions_block_can_render_a_template_by_name
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) do
      def self.name = "Examples::CardRouter"
      classify_with :chat, model: "gemini-3.5-flash-lite", chat_factory: factory
      instructions { "#{prompt("routing", tone: "brief")} Card: #{card}." }
    end

    with_prompt_root("examples/card_router/routing.txt.erb" => "Be <%= tone %>, <%= card %>.") do
      router_class.new(card: "c1").call("add it", history: HISTORY)
      assert_includes factory.system_prompt, "Be brief, c1. Card: c1.\n\nModes:"
    end
  end

  def test_missing_template_is_a_declaration_error
    router_class = Class.new(CardRouter) do
      def self.name = "Examples::CardRouter"
      instructions
    end

    error = assert_raises(RubyLLM::Modes::DeclarationError) { router_class.new(card: nil) }
    assert_match %r{instructions template not found at .*examples/card_router/instructions\.txt\.erb}, error.message
  end

  def test_non_object_json_is_a_contract_error
    factory = StubProvider::ChatFactory.new(mode: "card")
    factory.instance_variable_set(:@selection, [ "card" ])
    route = CardRouter.new(card: nil).call("add it", classifier: Chat.new(chat_factory: factory))
    assert_instance_of RubyLLM::Modes::ContractError, route.error
  end
end
