# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::RouterCallTest < Minitest::Test
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
    router.new(showtime_enabled:).call(message, history:, classifier:)
  end

  # Row 0: force

  def test_routes_carry_the_router_inputs
    assert_equal({ showtime_enabled: true }, route.inputs)
    assert_equal({ showtime_enabled: false }, ThresholdRouter.new(showtime_enabled: false).force(:tutor).inputs)
  end

  def test_forced_route
    route = ThresholdRouter.new(showtime_enabled: true).force(:showtime)
    assert_equal ShowtimeAgent, route.mode_class
    assert_equal "showtime", route.mode_name
    assert_equal "caller", route.decided_by
    assert_equal "Mode requested by caller", route.reason
    assert_nil route.decision
    assert_nil route.classifier
    assert_nil route.duration_ms
  end

  def test_force_respects_availability
    error = assert_raises(RubyLLM::Modes::UnknownMode) do
      ThresholdRouter.new(showtime_enabled: false).force("showtime")
    end
    assert_kind_of KeyError, error
    assert_equal "showtime", error.key
  end

  def test_force_unknown_name
    assert_raises(RubyLLM::Modes::UnknownMode) { ThresholdRouter.new(showtime_enabled: true).force("nope") }
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
    route = LonelyRouter.new(flag: false).call("hi", classifier: classifier)

    refute classifier.called?
    assert_equal TutorAgent, route.mode_class
    assert_equal "fallback", route.decided_by
    assert_equal "No other mode available", route.reason
    assert_nil route.decision
    assert_nil route.classifier
    assert_equal 0, route.duration_ms
  end

  def test_fallback_only_shortcut_does_not_apply_when_another_mode_is_available
    classifier = FakeClassifier.deciding(mode_name: "showtime", confidence: 1.0)
    route = LonelyRouter.new(flag: true).call("hi", classifier: classifier)
    assert classifier.called?
    assert_equal ShowtimeAgent, route.mode_class
  end

  # Row 2: classifier raised or violated the contract

  def test_classifier_raised
    route = route(FakeClassifier.new { raise IOError, "network" })
    assert_equal TutorAgent, route.mode_class
    assert_equal "fallback", route.decided_by
    assert_equal "Classifier failed: IOError", route.reason
    assert_nil route.decision
    assert_instance_of IOError, route.error
    assert_equal({ with: "custom", model: nil }, route.classifier)
  end

  def test_classifier_returned_a_non_decision
    route = route(FakeClassifier.new { { mode: "card" } })
    assert_equal "Classifier failed: RubyLLM::Modes::ContractError", route.reason
    assert_instance_of ContractError, route.error
  end

  def test_nan_confidence_is_a_contract_violation
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: Float::NAN))
    assert_equal "fallback", route.decided_by
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
    assert_equal "classifier", route.decided_by
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
    assert_equal "fallback", route.decided_by
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
    assert_equal "fallback", route.decided_by
    assert_equal "Confidence not scored", route.reason
    assert_equal "card", route.decision.mode_name
  end

  # Row 5: threshold on, confidence below it

  def test_below_confidence_threshold
    route = route(FakeClassifier.deciding(mode_name: "showtime", confidence: 0.42, reason: "maybe"))
    assert_equal TutorAgent, route.mode_class
    assert_equal "tutor", route.mode_name
    assert_equal "fallback", route.decided_by
    assert_equal "Below confidence threshold", route.reason
    assert_equal "showtime", route.decision.mode_name
    assert_equal 0.42, route.decision.confidence
  end

  def test_confidence_equal_to_threshold_passes
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.6))
    assert_equal "classifier", route.decided_by
  end

  # Row 6: classifier accepted

  def test_classifier_route
    route = route()
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal "card", route.mode_name
    assert_equal "classifier", route.decided_by
    assert_equal "asked for a card", route.reason
    assert_equal 0.9, route.decision.confidence
    assert_kind_of Integer, route.duration_ms
    assert_equal({ with: "custom", model: nil }, route.classifier)
  end

  def test_declared_classifier_is_used_when_no_override_is_given
    assert_equal "classifier", route.decided_by
    assert_equal "card", route.mode_name
  end

  # Threshold off

  def test_threshold_off_accepts_nil_confidence
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: nil), router: OpenRouter)
    assert_equal "classifier", route.decided_by
  end

  def test_threshold_off_accepts_low_confidence
    route = route(FakeClassifier.deciding(mode_name: "card", confidence: 0.01), router: OpenRouter)
    assert_equal "classifier", route.decided_by
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
    assert_equal [ TutorAgent.mode_description, ManageCardsAgent.mode_description ], call[:modes].map(&:description)
    assert_nil call[:guidance]
    assert_equal({ showtime_enabled: false }, call[:inputs])
  end

  class GuidedRouter < ThresholdRouter
    guidance { showtime_enabled ? "Showtime is on." : "Showtime is off." }
  end

  def test_guidance_block_sees_inputs
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: GuidedRouter, showtime_enabled: false)
    assert_equal "Showtime is off.", classifier.last_call[:guidance]
  end

  def test_guidance_string
    router_class = Class.new(ThresholdRouter) { guidance "  Plain text.\n" }
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: router_class)
    assert_equal "Plain text.", classifier.last_call[:guidance]
  end

  def test_blank_guidance_is_nil
    router_class = Class.new(ThresholdRouter) { guidance { "" } }
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, router: router_class)
    assert_nil classifier.last_call[:guidance]
  end

  # History normalisation

  def test_history_is_normalised_before_the_classifier_sees_it
    classifier = FakeClassifier.deciding(mode_name: "card")
    history = [
      { role: :user, content: "one" },
      { "role" => "assistant", "content" => "two" },
      RubyLLM::Message.new(role: :user, content: "three"),
      "four"
    ]
    route(classifier, history: history)
    assert_equal [
      { role: :user, content: "one" },
      { role: :assistant, content: "two" },
      { role: :user, content: "three" },
      { role: nil, content: "four" }
    ], classifier.last_call[:history]
  end

  def test_history_accepts_records_responding_to_to_llm
    record = Struct.new(:to_llm).new(RubyLLM::Message.new(role: :assistant, content: "hello"))
    classifier = FakeClassifier.deciding(mode_name: "card")
    route(classifier, history: [ record ])
    assert_equal [ { role: :assistant, content: "hello" } ], classifier.last_call[:history]
  end

  def test_history_rejects_other_objects
    assert_raises(ArgumentError) { route(FakeClassifier.deciding(mode_name: "card"), history: [ 42 ]) }
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
