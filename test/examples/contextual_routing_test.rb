# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/contextual_routing"

class Examples::ContextualRoutingTest < Minitest::Test
  SENTENCE = Examples::ContextualRouting::CARD_SENTENCE

  def setup
    @results = Examples::ContextualRouting.run
  end

  def test_chat_backend_prompt_mentions_the_card_only_when_given
    assert_includes @results[:chat][:with_card], SENTENCE
    refute_includes @results[:chat][:without_card], SENTENCE
  end

  def test_chat_backend_prompt_keeps_the_frame_around_the_instructions
    prompt = @results[:chat][:with_card]
    assert_match(/\ADo not answer the user\.|You route the latest user message/, prompt)
    assert_includes prompt, "Route by the learner's intended action.\n#{SENTENCE}\n\nModes:\n- tutor:"
    refute_includes prompt, "add it to my cards"
  end

  def test_custom_classifier_receives_the_instructions_with_the_card_only_when_given
    assert_includes @results[:custom][:with_card], SENTENCE
    refute_includes @results[:custom][:without_card], SENTENCE
  end

  def test_both_backends_receive_the_same_resolved_instructions
    assert_includes @results[:chat][:with_card], @results[:custom][:with_card]
    assert_includes @results[:chat][:without_card], @results[:custom][:without_card]
  end
end
