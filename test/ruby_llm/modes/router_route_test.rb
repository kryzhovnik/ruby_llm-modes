# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::RouterRouteTest < Minitest::Test
  Decision = RubyLLM::Modes::Decision
  ContractError = RubyLLM::Modes::ContractError

  class ThresholdRouter < RubyLLM::Modes::Router
    inputs :showtime_enabled

    mode TutorAgent
    mode ShowtimeAgent, if: -> { showtime_enabled }
    mode ManageCardsAgent, as: :card

    fallback TutorAgent, below_confidence: 0.6
    classify_with FakeClassifier.deciding(mode_name: "card", confidence: 0.9, reason: "asked for a card")
  end

  class OpenRouter < ThresholdRouter
    fallback TutorAgent
  end

  def route(classifier = nil, router: ThresholdRouter, message: "add it", history: [], showtime_enabled: true)
    router.new(showtime_enabled:).route(conversation(message, history:), classifier:)
  end

  # Row 0: force

  def test_routes_carry_the_router_inputs
    assert_equal({ showtime_enabled: true }, route.inputs)
    assert_equal({ showtime_enabled: false }, ThresholdRouter.new(showtime_enabled: false).force(:tutor, chat: conversation).inputs)
  end

  def test_routes_carry_the_chat
    chat = conversation
    assert_same chat, ThresholdRouter.new(showtime_enabled: true).route(chat).chat
    assert_same chat, ThresholdRouter.new(showtime_enabled: true).force(:tutor, chat:).chat
  end

  def test_forced_route
    route = ThresholdRouter.new(showtime_enabled: true).force(:showtime, chat: conversation)
    assert_equal ShowtimeAgent, route.mode_class
    assert_equal "showtime", route.mode_name
    assert_equal :caller, route.decided_by
    assert_equal "Mode requested by caller", route.reason
    assert_nil route.decision
    assert_nil route.classifier
    assert_nil route.duration_ms
  end

  def test_force_respects_availability
    error = assert_raises(RubyLLM::Modes::UnknownMode) do
      ThresholdRouter.new(showtime_enabled: false).force("showtime", chat: conversation)
    end
    assert_kind_of KeyError, error
    assert_equal "showtime", error.key
  end

  def test_force_unknown_name
    assert_raises(RubyLLM::Modes::UnknownMode) { ThresholdRouter.new(showtime_enabled: true).force("nope", chat: conversation) }
  end

  # Row 1: only the fallback is available

  class LonelyRouter < RubyLLM::Modes::Router
    inputs :flag
    mode TutorAgent
    mode ShowtimeAgent, if: -> { flag }
    fallback TutorAgent
    classify_with FakeClassifier.deciding(mode_name: "showtime")
  end

  def test_fallback_only_shortcut_skips_the_classifier
    classifier = FakeClassifier.deciding(mode_name: "showtime")
    route = LonelyRouter.new(flag: false).route(conversation("hi"), classifier: classifier)

    refute classifier.called?
    assert_equal TutorAgent, route.mode_class
    assert_equal :fallback, route.decided_by
    assert_equal "No other mode available", route.reason
    assert_nil route.decision
    assert_nil route.classifier
    assert_equal 0, route.duration_ms
  end

  def test_fallback_only_shortcut_does_not_apply_when_another_mode_is_available
    classifier = FakeClassifier.deciding(mode_name: "showtime", confidence: 1.0)
    route = LonelyRouter.new(flag: true).route(conversation("hi"), classifier: classifier)
    assert classifier.called?
    assert_equal ShowtimeAgent, route.mode_class
  end

  # Row 2: classifier raised or violated the contract

  def test_classifier_raised
    route = route(FakeClassifier.new { raise IOError, "network" })
    assert_equal TutorAgent, route.mode_class
    assert_equal :fallback, route.decided_by
    assert_equal "Classifier failed: IOError: network", route.reason
    assert_nil route.decision
    assert_instance_of IOError, route.error
    assert_equal({ with: "custom", model: nil }, route.classifier)
  end

  def test_reason_is_the_class_alone_when_the_message_is_the_default
    assert_equal "Classifier failed: IOError", route(FakeClassifier.new { raise IOError }).reason
    assert_equal "Classifier failed: IOError", route(FakeClassifier.new { raise IOError, "" }).reason
  end

  def test_reason_keeps_the_first_line_of_the_message_only
    route = route(FakeClassifier.new { raise IOError, "  first line  \nsecond line" })
    assert_equal "Classifier failed: IOError: first line", route.reason
  end

  def test_reason_carries_the_provider_message
    response = Struct.new(:status, :body).new(400, '{"detail":{"error_type":"max_tokens_exceeded"}}')
    route = route(FakeClassifier.new { raise RubyLLM::BadRequestError.new(response:) })
    assert_equal 'Classifier failed: RubyLLM::BadRequestError: {"detail":{"error_type":"max_tokens_exceeded"}}', route.reason
  end

  def test_reason_cuts_a_long_message
    route = route(FakeClassifier.new { raise IOError, "x" * 500 })
    assert_equal "Classifier failed: IOError: #{"x" * 200}", route.reason
  end

  def test_classifier_returned_a_non_decision
    route = route(FakeClassifier.new { { mode: "card" } })
    assert_equal "Classifier failed: RubyLLM::Modes::ContractError: classifier returned Hash, expected a Decision", route.reason
    assert_instance_of ContractError, route.error
  end

  def test_nan_confidence_is_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: Float::NAN))
    assert_equal :fallback, route.decided_by
    assert_instance_of ContractError, route.error
  end

  def test_confidence_above_one_is_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 1.5))
    assert_instance_of ContractError, route.error
  end

  def test_negative_confidence_is_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: -0.1))
    assert_instance_of ContractError, route.error
  end

  def test_non_string_mode_name_is_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: :card, confidence: 0.9))
    assert_instance_of ContractError, route.error
  end

  def test_non_string_reason_is_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.9, reason: :because))
    assert_instance_of ContractError, route.error
  end

  def test_malformed_probabilities_are_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.9, probabilities: "invalid"))
    assert_instance_of ContractError, route.error

    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.9, probabilities: { "card" => "high" }))
    assert_instance_of ContractError, route.error
  end

  def test_accepted_decision_serialises
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.9, probabilities: { card: 0.9, tutor: 0.1 }))
    assert_equal :classifier, route.decided_by
    assert_equal({ "card" => 0.9, "tutor" => 0.1 }, route.to_h.dig("decision", "probabilities"))
  end

  def test_on_error_receives_every_classifier_exception
    seen = []
    router_class = Class.new(ThresholdRouter) { on_error { |error| seen << error } }
    route(FakeClassifier.new { raise "boom" }, router: router_class)
    route(FakeClassifier.deciding(mode_name: "card", confidence: 2.0), router: router_class)
    assert_equal [ RuntimeError, ContractError ], seen.map(&:class)
  end

  def test_on_error_runs_on_the_router_instance
    seen = nil
    router_class = Class.new(ThresholdRouter) { on_error { |_error| seen = showtime_enabled } }
    route(FakeClassifier.new { raise "boom" }, router: router_class, showtime_enabled: :yes)
    assert_equal :yes, seen
  end

  # Row 3: unknown or unavailable mode

  def test_unknown_mode_name
    decision = Decision.new(mode_name: "ghost", confidence: 0.9, reason: "spooky")
    route = route(FakeClassifier.new(decision))
    assert_equal TutorAgent, route.mode_class
    assert_equal :fallback, route.decided_by
    assert_equal "Unknown mode ghost", route.reason
    assert_equal decision, route.decision
  end

  def test_unavailable_mode_name
    route = route(FakeClassifier.deciding(mode_name: "showtime", confidence: 0.9), showtime_enabled: false)
    assert_equal "Unknown mode showtime", route.reason
    assert_equal "showtime", route.decision.mode_name
  end

  def test_nil_mode_name
    route = route(FakeClassifier.deciding(mode_name: nil, confidence: 0.9))
    assert_equal "Unknown mode nil", route.reason
  end

  # Row 4: threshold on, confidence nil

  def test_confidence_not_scored
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: nil, reason: "unscored"))
    assert_equal TutorAgent, route.mode_class
    assert_equal :fallback, route.decided_by
    assert_equal "Confidence not scored", route.reason
    assert_equal "card", route.decision.mode_name
  end

  # Row 5: threshold on, confidence below it

  def test_below_confidence_threshold
    route = route(FakeClassifier.deciding(mode_name: "showtime", confidence: 0.42, reason: "maybe"))
    assert_equal TutorAgent, route.mode_class
    assert_equal "tutor", route.mode_name
    assert_equal :fallback, route.decided_by
    assert_equal "Below confidence threshold", route.reason
    assert_equal "showtime", route.decision.mode_name
    assert_equal 0.42, route.decision.confidence
  end

  def test_confidence_equal_to_threshold_passes
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.6))
    assert_equal :classifier, route.decided_by
  end

  # Row 6: classifier accepted

  def test_classifier_route
    route = route()
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal "card", route.mode_name
    assert_equal :classifier, route.decided_by
    assert_equal "asked for a card", route.reason
    assert_equal 0.9, route.decision.confidence
    assert_kind_of Integer, route.duration_ms
    assert_equal({ with: "custom", model: nil }, route.classifier)
  end

  def test_declared_classifier_is_used_when_no_override_is_given
    assert_equal :classifier, route.decided_by
    assert_equal "card", route.mode_name
  end

  # Threshold off

  def test_threshold_off_accepts_nil_confidence
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: nil), router: OpenRouter)
    assert_equal :classifier, route.decided_by
  end

  def test_threshold_off_accepts_low_confidence
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.01), router: OpenRouter)
    assert_equal :classifier, route.decided_by
  end

  def test_threshold_off_still_rejects_unknown_modes
    route = route(FakeClassifier.deciding(mode_name: "ghost"), router: OpenRouter)
    assert_equal "Unknown mode ghost", route.reason
  end

  # Every mode a Route returns is available for that call

  def test_routes_only_to_available_modes
    [ true, false ].each do |enabled|
      route = route(FakeClassifier.deciding(mode_name: "showtime", confidence: 1.0), showtime_enabled: enabled)
      assert_includes ThresholdRouter.new(showtime_enabled: enabled).modes.map(&:klass), route.mode_class
    end
  end

  # What the classifier receives

  def test_classifier_receives_the_contract_arguments
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, message: "add it", showtime_enabled: false)
    call = classifier.last_call
    assert_equal "add it", call[:message]
    assert_equal [], call[:history]
    assert_equal [ TutorAgent, ManageCardsAgent ], call[:modes].map(&:klass)
    assert_equal %w[tutor card], call[:modes].map(&:name)
    assert_equal [ TutorAgent.description, ManageCardsAgent.description ], call[:modes].map(&:description)
    assert_nil call[:instructions]
    assert_equal({ showtime_enabled: false }, call[:inputs])
  end

  class GuidedRouter < ThresholdRouter
    instructions { showtime_enabled ? "Showtime is on." : "Showtime is off." }
  end

  def test_instructions_block_sees_inputs
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: GuidedRouter, showtime_enabled: false)
    assert_equal "Showtime is off.", classifier.last_call[:instructions]
  end

  def test_instructions_string
    router_class = Class.new(ThresholdRouter) { instructions "  Plain text.\n" }
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: router_class)
    assert_equal "Plain text.", classifier.last_call[:instructions]
  end

  def test_blank_instructions_are_nil
    router_class = Class.new(ThresholdRouter) { instructions { "" } }
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: router_class)
    assert_nil classifier.last_call[:instructions]
  end

  # The conversation: what is routed and what is history

  def test_explicit_messages_replace_the_chat_transcript_and_keep_the_agent_bound_to_chat
    chat = RubyLLM.chat.ask_later("a later user message")
    def chat.each = raise("the stored conversation must not be read")
    classifier = FakeClassifier.deciding(mode_name: "card", confidence: 0.9)
    transcript = Conversation.new([
      { role: :assistant, content: "Add a card? Mode: tutor. UI: card offer." },
      { role: :user, content: "yes" }
    ])

    result = ThresholdRouter.new(showtime_enabled: true).route(chat, messages: transcript, classifier:)

    assert_equal "yes", classifier.last_call[:message]
    assert_equal [
      { role: :assistant, content: "Add a card? Mode: tutor. UI: card offer." }
    ], classifier.last_call[:history]
    assert_equal :classifier, result.decided_by
    assert_same chat, result.chat
    assert_same chat, result.mode.chat
    assert_equal "a later user message", chat.messages.last.content
  end

  def test_explicit_messages_work_with_the_declared_classifier
    classifier = FakeClassifier.deciding(mode_name: "card", confidence: 0.9)
    router_class = Class.new(ThresholdRouter) { classify_with classifier }
    chat = Object.new

    result = router_class.new(showtime_enabled: true).route(chat, messages: [ { role: :user, content: "yes" } ])

    assert_equal "yes", classifier.last_call[:message]
    assert_equal :classifier, result.decided_by
    assert_same chat, result.chat
  end

  def test_explicit_messages_keep_fallback_routes_bound_to_chat
    chat = RubyLLM.chat
    classifiers = [
      FakeClassifier.deciding(mode_name: "unknown", confidence: 0.9),
      FakeClassifier.new { raise IOError, "network" }
    ]
    classifiers.each do |classifier|
      result = ThresholdRouter.new(showtime_enabled: true).route(chat, messages: conversation, classifier:)
      assert_equal :fallback, result.decided_by
      assert_same chat, result.chat
      assert_same chat, result.mode.chat
    end

    result = LonelyRouter.new(flag: false).route(chat, messages: conversation)
    assert_equal :fallback, result.decided_by
    assert_same chat, result.chat
  end

  def test_invalid_explicit_messages_do_not_fall_back_to_reading_chat
    router = ThresholdRouter.new(showtime_enabled: true)
    chat = conversation
    [ nil, "text", [], [ { role: :system, content: "Base." } ],
      [ { role: :assistant, content: "hello" } ], [ "bare string" ], [ 42 ] ].each do |messages|
      assert_raises(ArgumentError) { router.route(chat, messages:) }
    end
  end

  def test_force_does_not_read_messages
    chat = Object.new
    def chat.each = raise("force must not read messages")

    result = ThresholdRouter.new(showtime_enabled: true).force(:tutor, chat:)
    assert_same chat, result.chat
    assert_equal :caller, result.decided_by
  end

  def test_the_latest_user_message_is_routed_and_the_rest_is_history
    classifier = FakeClassifier.deciding(mode_name: "card")
    history = [
      { role: :user, content: "one" },
      { "role" => "assistant", "content" => "two" },
      RubyLLM::Message.new(role: :user, content: "three"),
      "four"
    ]
    route(classifier, message: "add it", history: history)
    assert_equal "add it", classifier.last_call[:message]
    assert_equal [
      { role: :user, content: "one" },
      { role: :assistant, content: "two" },
      { role: :user, content: "three" },
      { role: nil, content: "four" }
    ], classifier.last_call[:history]
  end

  def test_system_messages_are_left_out
    classifier = FakeClassifier.deciding(mode_name: "card")
    chat = Conversation.new([
      { role: :system, content: "You are Duck." },
      { role: :user, content: "hi" },
      { role: :assistant, content: "hello" },
      RubyLLM::Message.new(role: :system, content: "Appended by a mode."),
      { role: :user, content: "add it" }
    ])
    ThresholdRouter.new(showtime_enabled: true).route(chat, classifier: classifier)
    assert_equal "add it", classifier.last_call[:message]
    assert_equal [ { role: :user, content: "hi" }, { role: :assistant, content: "hello" } ], classifier.last_call[:history]
  end

  def test_the_routed_message_is_the_message_content_as_a_string
    classifier = FakeClassifier.deciding(mode_name: "card")
    chat = Conversation.new([ RubyLLM::Message.new(role: :user, content: "add it") ])
    ThresholdRouter.new(showtime_enabled: true).route(chat, classifier: classifier)
    assert_equal "add it", classifier.last_call[:message]
  end

  def test_tool_results_and_empty_calls_do_not_displace_text_history
    router_class = Class.new(ThresholdRouter) { history last: 2 }
    classifier = FakeClassifier.deciding(mode_name: "card")
    chat = RubyLLM.chat
    tool_calls = { "lookup" => RubyLLM::ToolCall.new(id: "lookup", name: "find_order", arguments: { id: 42 }) }
    chat.add_message(role: :user, content: "Find my order")
    chat.add_message(role: :assistant, content: "Checking your order.", tool_calls:)
    chat.add_message(role: :tool, content: "Order shipped", tool_call_id: "lookup")
    chat.add_message(role: :assistant, content: nil, tool_calls:)
    chat.add_message(role: :tool, content: "Tracking details", tool_call_id: "lookup")
    chat.ask_later("Can I cancel it?")
    original_messages = chat.messages.dup

    router_class.new(showtime_enabled: true).route(chat, classifier:)

    assert_equal "Can I cancel it?", classifier.last_call[:message]
    assert_equal [
      { role: :user, content: "Find my order" },
      { role: :assistant, content: "Checking your order." }
    ], classifier.last_call[:history]
    assert_equal original_messages, chat.messages
  end

  def test_explicit_history_keeps_nonblank_dialogue_and_plain_text_context
    classifier = FakeClassifier.deciding(mode_name: "card")
    transcript = [
      { role: :user, content: "  Show options  " },
      { "role" => "assistant", "content" => "Choose a card." },
      { role: :tool, content: "Internal result" },
      { role: :developer, content: "Internal instruction" },
      { role: :assistant, content: nil },
      { role: :user, content: " \n\t" },
      "",
      " \n",
      "Visible cards: first, second",
      { role: :user, content: "The second one" }
    ]

    ThresholdRouter.new(showtime_enabled: true).route(conversation, messages: transcript, classifier:)

    assert_equal "The second one", classifier.last_call[:message]
    assert_equal [
      { role: :user, content: "  Show options  " },
      { role: :assistant, content: "Choose a card." },
      { role: nil, content: "Visible cards: first, second" }
    ], classifier.last_call[:history]
  end

  def test_messages_accept_records_responding_to_to_llm
    record = Struct.new(:to_llm).new(RubyLLM::Message.new(role: :assistant, content: "hello"))
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, history: [ record ])
    assert_equal [ { role: :assistant, content: "hello" } ], classifier.last_call[:history]
  end

  def test_messages_reject_other_objects
    assert_raises(ArgumentError) { route(FakeClassifier.deciding(mode_name: "card"), history: [ 42 ]) }
  end

  def test_route_reads_the_chat_with_each_only
    chat = Object.new
    def chat.each(&) = [ { role: :user, content: "add it" } ].each(&)
    classifier = FakeClassifier.deciding(mode_name: "card")
    ThresholdRouter.new(showtime_enabled: true).route(chat, classifier: classifier)
    assert_equal "add it", classifier.last_call[:message]
  end

  def test_route_reads_a_ruby_llm_chat_and_a_rails_style_record_alike
    chat = RubyLLM.chat(model: "gemini-3.5-flash-lite").with_instructions("Base.").ask_later("add it")
    record = Object.new
    record.define_singleton_method(:each) { |&block| chat.each(&block) }
    record.define_singleton_method(:messages) { raise "the bare association must not be read" }

    classifier = FakeClassifier.deciding(mode_name: "card")
    ThresholdRouter.new(showtime_enabled: true).route(record, classifier: classifier)
    assert_equal "add it", classifier.last_call[:message]
    assert_equal [], classifier.last_call[:history]
  end

  def test_route_rejects_an_object_without_each
    error = assert_raises(ArgumentError) { ThresholdRouter.new(showtime_enabled: true).route("add it") }
    assert_match(/the conversation must respond to each/, error.message)
  end

  def test_route_rejects_a_chat_with_no_message
    router = ThresholdRouter.new(showtime_enabled: true)
    assert_raises(ArgumentError) { router.route(Conversation.new([])) }
    assert_raises(ArgumentError) { router.route(Conversation.new([ { role: :system, content: "Base." } ])) }
  end

  def test_route_rejects_a_chat_whose_latest_message_is_not_from_the_user
    router = ThresholdRouter.new(showtime_enabled: true)
    chat = Conversation.new([ { role: :user, content: "hi" }, { role: :assistant, content: "hello" } ])
    error = assert_raises(ArgumentError) { router.route(chat) }
    assert_match(/latest message must be a user message, got role :assistant/, error.message)
    assert_raises(ArgumentError) { router.route(Conversation.new([ "a bare string" ])) }
  end

  def test_history_last_keeps_the_last_entries
    router_class = Class.new(ThresholdRouter) { history last: 2 }
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: router_class, history: %w[a b c d])
    assert_equal %w[c d], classifier.last_call[:history].map { |entry| entry[:content] }
  end

  def test_history_all_undoes_an_inherited_limit
    limited = Class.new(ThresholdRouter) { history last: 2 }
    router_class = Class.new(limited) { history :all }
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: router_class, history: %w[a b c d])
    assert_equal %w[a b c d], classifier.last_call[:history].map { |entry| entry[:content] }
  end

  def test_history_rejects_other_declarations
    assert_raises(ArgumentError) { Class.new(ThresholdRouter) { history 6 } }
    assert_raises(ArgumentError) { Class.new(ThresholdRouter) { history :all, last: 6 } }
    assert_raises(ArgumentError) { Class.new(ThresholdRouter) { history :some } }
  end

  def test_history_last_takes_a_positive_integer
    assert_raises(ArgumentError) { Class.new(ThresholdRouter) { history last: 0 } }
    assert_raises(ArgumentError) { Class.new(ThresholdRouter) { history last: -1 } }
    assert_raises(ArgumentError) { Class.new(ThresholdRouter) { history last: "6" } }
  end

  # Tracing

  def test_override_is_traced_for_the_object_actually_used
    router_class = Class.new(ThresholdRouter) { classify_with :chat, model: "gemini-3.5-flash-lite" }
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.9), router: router_class)
    assert_equal({ with: "custom", model: nil }, route.classifier)
  end
end

# The caps on what reaches the classifier.
class RubyLLM::Modes::RouterTruncationTest < Minitest::Test
  Router = RubyLLM::Modes::Router
  Truncation = RubyLLM::Modes::Truncation

  class CappedRouter < Router
    mode TutorAgent
    mode ManageCardsAgent, as: :card
    fallback TutorAgent
    truncate message: 100, history_entry: 20
    classify_with FakeClassifier.deciding(mode_name: "card", confidence: 0.9)
  end

  class UncappedRouter < CappedRouter
    truncate message: nil, history_entry: nil
  end

  def test_defaults
    assert_equal 30_000, Router::MESSAGE_LIMIT
    assert_equal 2_000, Router::HISTORY_ENTRY_LIMIT
    router_class = Class.new(Router)
    assert_equal 30_000, router_class.message_limit
    assert_equal 2_000, router_class.history_entry_limit
  end

  def test_truncate_changes_only_the_caps_given
    router_class = Class.new(Router) { truncate history_entry: 50 }
    assert_equal 30_000, router_class.message_limit
    assert_equal 50, router_class.history_entry_limit
  end

  def test_truncate_is_inherited_and_replaced
    assert_equal 100, CappedRouter.message_limit
    assert_equal 20, CappedRouter.history_entry_limit
    assert_nil UncappedRouter.message_limit
    assert_nil UncappedRouter.history_entry_limit
  end

  def test_truncate_rejects_anything_but_a_positive_integer_or_nil
    [ 0, -1, "100", 1.5 ].each do |value|
      error = assert_raises(ArgumentError) { Class.new(Router) { truncate message: value } }
      assert_match(/truncate message: takes a positive Integer or nil/, error.message)
    end
    assert_raises(ArgumentError) { Class.new(Router) { truncate history_entry: 0 } }
  end

  def test_a_message_within_the_cap_is_passed_as_given
    classifier = FakeClassifier.deciding(mode_name: "card")
    CappedRouter.new.route(conversation("a" * 100), classifier: classifier)
    assert_equal "a" * 100, classifier.last_call[:message]
  end

  def test_a_long_message_keeps_its_head_and_tail
    classifier = FakeClassifier.deciding(mode_name: "card")
    message = "make cards from this article: " + ("x" * 500) + " and only the nouns"
    CappedRouter.new.route(conversation(message), classifier: classifier)

    sent = classifier.last_call[:message]
    assert_equal Truncation.head_and_tail(message, 100), sent
    assert sent.start_with?("make cards from this article: ")
    assert sent.end_with?(" and only the nouns")
    assert_includes sent, "\n[... #{message.size - 100} characters omitted ...]\n"
  end

  def test_each_history_entry_keeps_its_head
    classifier = FakeClassifier.deciding(mode_name: "card")
    history = [ { role: :user, content: "short" }, { role: :assistant, content: "y" * 60 }, "z" * 30 ]
    CappedRouter.new.route(conversation("hi", history:), classifier: classifier)

    assert_equal [
      { role: :user, content: "short" },
      { role: :assistant, content: ("y" * 20) + "\n[... 40 characters omitted ...]\n" },
      { role: nil, content: ("z" * 20) + "\n[... 10 characters omitted ...]\n" }
    ], classifier.last_call[:history]
  end

  def test_nil_disables_a_cap
    classifier = FakeClassifier.deciding(mode_name: "card")
    UncappedRouter.new.route(conversation("m" * 500, history: [ "h" * 500 ]), classifier: classifier)
    assert_equal "m" * 500, classifier.last_call[:message]
    assert_equal "h" * 500, classifier.last_call[:history].first[:content]
  end

  def test_history_last_applies_before_the_entry_cap
    router_class = Class.new(CappedRouter) { history last: 1 }
    classifier = FakeClassifier.deciding(mode_name: "card")
    router_class.new.route(conversation("hi", history: [ "first", "second " + ("s" * 30) ]), classifier: classifier)
    assert_equal [ { role: nil, content: "second " + ("s" * 13) + "\n[... 17 characters omitted ...]\n" } ], classifier.last_call[:history]
  end

  def test_explicit_messages_use_history_and_truncation_limits_without_changing_the_transcript
    router_class = Class.new(CappedRouter) { history last: 1 }
    classifier = FakeClassifier.deciding(mode_name: "card")
    transcript = [
      { role: :user, content: "old" }.freeze,
      { role: :assistant, content: "h" * 30 }.freeze,
      { role: :user, content: "m" * 120 }.freeze
    ].freeze

    router_class.new.route(Object.new, messages: transcript, classifier:)

    assert_equal ("m" * 50) + "\n[... 20 characters omitted ...]\n" + ("m" * 50), classifier.last_call[:message]
    assert_equal [ { role: :assistant, content: ("h" * 20) + "\n[... 10 characters omitted ...]\n" } ], classifier.last_call[:history]
    assert_equal "h" * 30, transcript[1][:content]
    assert_equal "m" * 120, transcript[2][:content]
  end
end
