# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::RouterDeclarationTest < Minitest::Test
  DeclarationError = RubyLLM::Modes::DeclarationError

  class BaseRouter < RubyLLM::Modes::Router
    inputs :user, :card

    mode TutorAgent
    mode ClarifyAgent
    mode ManageCardsAgent, "Manages flashcards"
    mode ShowtimeAgent, if: -> { user[:showtime] }
    mode Chat::ReviewAgent, as: :review
    mode PlainAgent, "A plain agent"

    guidance { card ? "A card is open." : "No card." }
    history 6
    fallback TutorAgent, below_confidence: 0.6
    classify with: FakeClassifier.new
  end

  def user(showtime: true)
    { showtime: showtime }
  end

  def test_modes_in_declaration_order_with_resolved_names
    router = BaseRouter.new(user: user, card: nil)
    assert_equal %w[tutor clarify manage_cards showtime review plain], router.modes.map(&:name)
    assert_equal [ TutorAgent, ClarifyAgent, ManageCardsAgent, ShowtimeAgent, Chat::ReviewAgent, PlainAgent ],
                 router.modes.map(&:klass)
  end

  def test_inline_description_wins_over_mode_description
    registration = BaseRouter.registrations.find { |r| r.klass == ManageCardsAgent }
    assert_equal "Manages flashcards", registration.description
  end

  def test_description_comes_from_mode_description_by_default
    registration = BaseRouter.registrations.find { |r| r.klass == TutorAgent }
    assert_equal TutorAgent.mode_description, registration.description
  end

  def test_as_sets_the_registration_name
    assert_includes BaseRouter.registrations.map(&:name), "review"
  end

  def test_plain_agent_name_is_derived
    assert_includes BaseRouter.registrations.map(&:name), "plain"
  end

  def test_if_is_evaluated_per_call_on_the_router_instance
    assert_includes BaseRouter.new(user: user(showtime: true), card: nil).modes.map(&:name), "showtime"
    refute_includes BaseRouter.new(user: user(showtime: false), card: nil).modes.map(&:name), "showtime"
  end

  def test_declared_inputs_are_methods_on_the_instance
    router = BaseRouter.new(user: user, card: :card)
    assert_equal :card, router.card
    assert_equal({ user: user, card: :card }, router.inputs)
  end

  def test_missing_input_raises_argument_error
    error = assert_raises(ArgumentError) { BaseRouter.new(user: user) }
    assert_match(/missing input\(s\): card/, error.message)
  end

  def test_nil_input_counts_as_passed
    assert BaseRouter.new(user: user, card: nil)
  end

  def test_unknown_input_raises_argument_error
    error = assert_raises(ArgumentError) { BaseRouter.new(user: user, card: nil, extra: 1) }
    assert_match(/unknown input\(s\): extra/, error.message)
  end

  def test_classify_model_alone_means_chat
    router_class = Class.new(RubyLLM::Modes::Router) do
      mode TutorAgent
      fallback TutorAgent
      classify model: "gemini-3.5-flash-lite"
    end
    assert_equal :chat, router_class.classifier_spec[:with]
    assert_instance_of RubyLLM::Modes::Classifiers::Chat, router_class.new.classifier
    assert_equal "gemini-3.5-flash-lite", router_class.new.classifier.model
  end

  def test_no_classify_defaults_to_chat
    router_class = Class.new(RubyLLM::Modes::Router) do
      mode TutorAgent
      fallback TutorAgent
    end
    assert_instance_of RubyLLM::Modes::Classifiers::Chat, router_class.new.classifier
    assert_nil router_class.new.classifier.model
  end

  # Inheritance

  class SubRouter < BaseRouter
    mode Class.new(RubyLLM::ModeAgent) { mode_description "Extra" }, as: :extra
    fallback ClarifyAgent
    history 2
    guidance "Sub guidance"
  end

  def test_subclass_appends_modes
    assert_equal BaseRouter.registrations.map(&:name) + [ "extra" ], SubRouter.registrations.map(&:name)
  end

  def test_subclass_replaces_scalar_declarations
    assert_equal ClarifyAgent, SubRouter.fallback_class
    assert_nil SubRouter.below_confidence
    assert_equal 2, SubRouter.history_limit
    assert_equal "Sub guidance", SubRouter.guidance_source
  end

  def test_subclass_changes_never_touch_the_parent
    assert_equal 6, BaseRouter.registrations.size
    assert_equal TutorAgent, BaseRouter.fallback_class
    assert_equal 0.6, BaseRouter.below_confidence
    assert_equal 6, BaseRouter.history_limit
    assert_kind_of Proc, BaseRouter.guidance_source
  end

  def test_subclass_inherits_inputs_and_classifier
    assert_equal %i[user card], SubRouter.input_names
    assert_equal BaseRouter.classifier_spec, SubRouter.classifier_spec
  end

  # DeclarationError, one test per rule. Validation runs in new.

  def declaration(&block)
    Class.new(RubyLLM::Modes::Router, &block)
  end

  def assert_declaration_error(pattern, &block)
    router_class = declaration(&block)
    error = assert_raises(DeclarationError) { router_class.new }
    assert_match pattern, error.message
  end

  def test_no_fallback
    assert_declaration_error(/no fallback/) { mode TutorAgent }
  end

  def test_fallback_not_registered
    assert_declaration_error(/not registered/) do
      mode TutorAgent
      fallback ClarifyAgent
    end
  end

  def test_fallback_with_condition
    assert_declaration_error(/must not have an if/) do
      mode TutorAgent, if: -> { true }
      fallback TutorAgent
    end
  end

  def test_duplicate_registration_names
    assert_declaration_error(/duplicate registration name "tutor"/) do
      mode TutorAgent
      mode ClarifyAgent, as: :tutor
      fallback TutorAgent
    end
  end

  def test_mode_without_description
    assert_declaration_error(/plain has no description/) do
      mode TutorAgent
      mode PlainAgent
      fallback TutorAgent
    end
  end

  def test_mode_without_a_name
    assert_declaration_error(/no registration name/) do
      mode TutorAgent
      mode Class.new(RubyLLM::ModeAgent) { mode_description "Anonymous" }
      fallback TutorAgent
    end
  end

  def test_mode_that_is_not_an_agent
    assert_declaration_error(/not a RubyLLM::Agent subclass/) do
      mode TutorAgent
      mode String, "Not an agent"
      fallback TutorAgent
    end
  end

  def test_judge_backend_not_available
    refute defined?(RubyLLM::Judge), "this suite assumes the released gem has no Judge"
    assert_declaration_error(/RubyLLM::Judge not available/) do
      mode TutorAgent
      fallback TutorAgent
      classify with: :judge
    end
  end

  def test_prompt_with_judge
    assert_declaration_error(/prompt cannot be declared with the :judge backend/) do
      mode TutorAgent
      fallback TutorAgent
      prompt { "custom" }
      classify with: :judge
    end
  end

  def test_same_class_registered_twice
    assert_declaration_error(/TutorAgent is registered twice/) do
      mode TutorAgent
      mode TutorAgent, as: :again
      fallback TutorAgent
    end
  end

  def test_unknown_backend_symbol
    assert_declaration_error(/unknown classifier backend :magic/) do
      mode TutorAgent
      fallback TutorAgent
      classify with: :magic
    end
  end

  def test_classifier_object_must_respond_to_call
    assert_declaration_error(/does not respond to call/) do
      mode TutorAgent
      fallback TutorAgent
      classify with: Object.new
    end
  end

  def test_classifier_class_is_not_instantiated_implicitly
    assert_declaration_error(/does not respond to call/) do
      mode TutorAgent
      fallback TutorAgent
      classify with: FakeClassifier
    end
  end

  def test_classifier_class_responding_to_call_is_accepted
    callable_class = Class.new do
      def self.call(message:, history:, modes:, guidance:, inputs:)
        RubyLLM::Modes::Decision.new(mode_name: "tutor")
      end
    end
    router_class = declaration do
      mode TutorAgent
      fallback TutorAgent
      classify with: callable_class
    end
    assert_equal callable_class, router_class.new.classifier
  end

  def test_validation_does_not_run_at_class_definition
    router_class = declaration { mode PlainAgent }
    assert router_class
    assert_raises(DeclarationError) { router_class.new }
  end
end
