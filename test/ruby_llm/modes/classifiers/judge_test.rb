# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::Classifiers::JudgeTest < Minitest::Test
  Judge = RubyLLM::Modes::Classifiers::Judge

  MODES = [
    RubyLLM::Modes::Registration.new(klass: nil, name: "tutor", description: "Explains words and grammar.", condition: nil),
    RubyLLM::Modes::Registration.new(klass: nil, name: "card", description: "Creates, edits, or deletes flashcards.", condition: nil)
  ].freeze

  HISTORY = [
    { role: :user, content: 'what does "reluctant" mean?' },
    { role: :assistant, content: "Reluctant means unwilling or hesitant ..." }
  ].freeze

  # A stand-in for RubyLLM.judge: records the call, answers with a fixed
  # choice shaped like a RubyLLM::Judgment holding a RubyLLM::Choice.
  class FakeJudge
    Answer = Data.define(:choice, :probabilities, :confidence)
    Judgment = Struct.new(:model, :answers) do
      def [](name) = answers[name.to_s]
    end

    attr_reader :calls

    def initialize(choice: "card", probabilities: { "tutor" => 0.1, "card" => 0.9 }, confidence: 0.8, model: "jev-1.13.0", answer: :choice)
      @answers = { "mode" => (answer == :choice ? Answer.new(choice:, probabilities:, confidence:) : answer) }
      @model = model
      @calls = []
    end

    def call(state, questions:, **options)
      @calls << { state:, questions:, options: }
      Judgment.new(@model, @answers)
    end

    def last_call = @calls.last
  end

  class CardRouter < RubyLLM::Modes::Router
    inputs :card

    mode TutorAgent
    mode ManageCardsAgent, as: :card

    instructions { "The learner has a flashcard open on screen." if card }
    fallback TutorAgent, below_confidence: 0.6
    classify_with :judge, model: "jev-latest", judge: FakeJudge.new
  end

  def test_state_carries_instructions_conversation_and_the_latest_message
    state = Judge.state(message: "add it to my cards", history: HISTORY, instructions: "Route by intent.")
    assert_equal({
      "instructions" => "Route by intent.",
      "conversation" => [
        { "role" => "user", "content" => 'what does "reluctant" mean?' },
        { "role" => "assistant", "content" => "Reluctant means unwilling or hesitant ..." }
      ],
      "latest_message" => "add it to my cards"
    }, state)
  end

  def test_state_omits_empty_instructions_and_history
    assert_equal({ "latest_message" => "hello" }, Judge.state(message: "hello", history: [], instructions: nil))
  end

  def test_state_renders_role_less_entries_as_bare_strings
    state = Judge.state(message: "hello", history: [ { role: nil, content: "earlier" } ])
    assert_equal [ "earlier" ], state["conversation"]
  end

  def test_questions_is_one_choice_over_the_modes
    questions = Judge.questions(MODES)
    assert_equal [ :mode ], questions.keys
    assert_equal :choice, questions[:mode][:type]
    assert_equal Judge::QUESTION, questions[:mode][:instructions]
    assert_equal({ "tutor" => "Explains words and grammar.", "card" => "Creates, edits, or deletes flashcards." }, questions[:mode][:options])
  end

  def test_call_judges_the_state_with_the_modes_as_options
    judge = FakeJudge.new
    route = CardRouter.new(card: :open).route(conversation("add it to my cards", history: HISTORY), classifier: Judge.new(model: "jev-latest", judge: judge))

    call = judge.last_call
    assert_equal Judge.state(message: "add it to my cards", history: HISTORY, instructions: "The learner has a flashcard open on screen."), call[:state]
    assert_equal %w[tutor card], call[:questions][:mode][:options].keys
    assert_equal ManageCardsAgent.description, call[:questions][:mode][:options]["card"]
    assert_equal({ model: "jev-latest" }, call[:options])

    assert_equal "classifier", route.decided_by
    assert_equal ManageCardsAgent, route.mode_class
    assert_nil route.reason
    assert_equal 0.8, route.decision.confidence
    assert_equal({ "tutor" => 0.1, "card" => 0.9 }, route.decision.probabilities)
    assert_equal({ with: "judge", model: "jev-1.13.0" }, route.classifier)
  end

  def test_declared_judge_option_reaches_the_backend
    route = CardRouter.new(card: nil).route(conversation("add it"))
    assert_equal "classifier", route.decided_by
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal({ "mode_name" => "card", "confidence" => 0.8, "reason" => nil, "probabilities" => { "tutor" => 0.1, "card" => 0.9 } }, route.decision.to_h)
  end

  def test_symbol_choice_becomes_a_string_mode_name
    judge = FakeJudge.new(choice: :card, probabilities: { tutor: 0.2, card: 0.8 })
    route = CardRouter.new(card: nil).route(conversation("add it"), classifier: Judge.new(judge: judge))
    assert_equal "card", route.decision.mode_name
    assert_equal({ "tutor" => 0.2, "card" => 0.8 }, route.decision.probabilities)
  end

  def test_low_concentration_falls_back
    judge = FakeJudge.new(confidence: 0.3, probabilities: { "tutor" => 0.45, "card" => 0.55 })
    route = CardRouter.new(card: nil).route(conversation("hmm"), classifier: Judge.new(judge: judge))
    assert_equal "fallback", route.decided_by
    assert_equal "Below confidence threshold", route.reason
    assert_equal "card", route.decision.mode_name
  end

  def test_a_declared_provider_is_passed_through
    judge = FakeJudge.new
    CardRouter.new(card: nil).route(conversation("add it"), classifier: Judge.new(model: "jev-latest", provider: :typesafe, judge: judge))
    assert_equal({ model: "jev-latest", provider: :typesafe }, judge.last_call[:options])
  end

  def test_trace_before_any_call_reports_the_declared_model
    assert_equal({ with: "judge", model: "jev-latest" }, Judge.new(model: "jev-latest").trace)
    assert_equal({ with: "judge", model: nil }, Judge.new.trace)
  end

  def test_trace_keeps_the_declared_model_when_the_judgment_reports_no_string_id
    judge = FakeJudge.new(model: nil)
    classifier = Judge.new(model: "jev-latest", judge: judge)
    CardRouter.new(card: nil).route(conversation("add it"), classifier: classifier)
    assert_equal({ with: "judge", model: "jev-latest" }, classifier.trace)
  end

  def test_trace_does_not_keep_the_model_of_a_previous_call
    judge = FakeJudge.new(model: "jev-1.13.0")
    classifier = Judge.new(model: "jev-latest", judge: judge)
    CardRouter.new(card: nil).route(conversation("add it"), classifier: classifier)
    assert_equal "jev-1.13.0", classifier.trace[:model]

    judge.define_singleton_method(:call) { |*, **| raise IOError, "down" }
    route = CardRouter.new(card: nil).route(conversation("add it"), classifier: classifier)
    assert_equal "Classifier failed: IOError: down", route.reason
    assert_equal({ with: "judge", model: "jev-latest" }, route.classifier)
  end

  def test_a_non_choice_answer_is_a_contract_error
    judge = FakeJudge.new(answer: 0.9)
    route = CardRouter.new(card: nil).route(conversation("add it"), classifier: Judge.new(judge: judge))
    assert_equal "fallback", route.decided_by
    assert_instance_of RubyLLM::Modes::ContractError, route.error
  end

  def test_a_missing_answer_is_a_contract_error
    judge = FakeJudge.new
    judge.instance_variable_set(:@answers, {})
    route = CardRouter.new(card: nil).route(conversation("add it"), classifier: Judge.new(judge: judge))
    assert_instance_of RubyLLM::Modes::ContractError, route.error
  end

  # RubyLLM.judge is the default only when the installed RubyLLM ships it.

  def test_calling_without_judge_support_is_a_declaration_error
    skip "this RubyLLM ships Judge" if Judge.available?

    error = assert_raises(RubyLLM::Modes::DeclarationError) do
      Judge.new.call(message: "hi", history: [], modes: MODES, instructions: nil, inputs: {})
    end
    assert_match(/RubyLLM.judge is not available/, error.message)
  end

  def test_the_default_judge_is_ruby_llm_judge
    judge = FakeJudge.new
    RubyLLM.define_singleton_method(:judge) { |*args, **options| judge.call(*args, **options) }

    router_class = Class.new(CardRouter) { classify_with :judge, model: "jev-latest" }
    route = router_class.new(card: nil).route(conversation("add it"))
    assert_equal ManageCardsAgent, route.mode_class
    assert_equal({ model: "jev-latest" }, judge.last_call[:options])
  ensure
    RubyLLM.singleton_class.remove_method(:judge)
  end
end
