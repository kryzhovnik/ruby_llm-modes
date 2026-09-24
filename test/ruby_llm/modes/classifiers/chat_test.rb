# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class RubyLLM::Modes::Classifiers::ChatTest < Minitest::Test
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

  def test_prompt_places_guidance_between_frame_and_modes
    text = Chat.prompt(message: "add it to my cards", history: HISTORY, modes: MODES, guidance: "Route by intent.")
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

    guidance { "The learner has a flashcard open on screen." if card }
    fallback TutorAgent, below_confidence: 0.6
    classify with: :chat, model: "gemini-3.5-flash-lite"
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

  def test_guidance_is_part_of_the_system_prompt
    factory = StubProvider::ChatFactory.new(mode: "card")
    CardRouter.new(card: :open).call("hi", classifier: Chat.new(chat_factory: factory))
    assert_includes factory.system_prompt, "The learner has a flashcard open on screen."
  end

  def test_declared_chat_factory_option_reaches_the_backend
    factory = StubProvider::ChatFactory.new(mode: "card", confidence: 0.95)
    router_class = Class.new(CardRouter) { classify with: :chat, model: "gemini-3.5-flash-lite", chat_factory: factory }

    route = router_class.new(card: nil).call("add it")
    assert_equal "classifier", route.decided_by
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal({ with: "chat", model: "gemini-3.5-flash-lite" }, route.classifier)
  end

  def test_trace_records_the_resolved_default_model_when_none_is_declared
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) { classify with: :chat, chat_factory: factory }

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
    assert_equal "Classifier failed: IOError", route.reason
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

  def test_prompt_block_replaces_the_frame_and_sees_locals_and_inputs
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) do
      classify with: :chat, model: "gemini-3.5-flash-lite", chat_factory: factory
      prompt do
        "CUSTOM card=#{card.inspect} guidance=#{guidance} modes=#{modes.map(&:name).join(",")} " \
          "history=#{history.size} message=#{message}"
      end
    end

    router_class.new(card: :open).call("add it", history: HISTORY)
    assert_equal "CUSTOM card=:open guidance=The learner has a flashcard open on screen. modes=tutor,card history=2 message=add it",
                 factory.system_prompt
  end

  def test_prompt_template_renders_through_render_prompt_with_the_locals
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) do
      classify with: :chat, model: "gemini-3.5-flash-lite", chat_factory: factory
      prompt "routers/card"
    end

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "routers"))
      File.write(File.join(dir, "routers/card.txt.erb"), "TEMPLATE <%= modes.map(&:name).join(',') %> <%= guidance %> <%= history.size %> <%= message %> <%= card %>")
      RubyLLM::Prompt.roots << dir

      router_class.new(card: "c1").call("add it", history: HISTORY)
      assert_equal "TEMPLATE tutor,card The learner has a flashcard open on screen. 2 add it c1", factory.system_prompt
    ensure
      RubyLLM::Prompt.roots.instance_variable_get(:@registered).delete_if { |root| root.to_s == dir }
    end
  end

  def test_missing_template_is_a_classifier_failure
    factory = StubProvider::ChatFactory.new(mode: "card")
    router_class = Class.new(CardRouter) do
      classify with: :chat, chat_factory: factory
      prompt "routers/missing"
    end

    route = router_class.new(card: nil).call("add it")
    assert_equal "fallback", route.decided_by
    assert_equal "Classifier failed: RubyLLM::PromptNotFoundError", route.reason
  end

  def test_non_object_json_is_a_contract_error
    factory = StubProvider::ChatFactory.new(mode: "card")
    factory.instance_variable_set(:@selection, [ "card" ])
    route = CardRouter.new(card: nil).call("add it", classifier: Chat.new(chat_factory: factory))
    assert_instance_of RubyLLM::Modes::ContractError, route.error
  end
end
