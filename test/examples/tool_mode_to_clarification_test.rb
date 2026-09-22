# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/tool_mode_to_clarification"

class Examples::ToolModeToClarificationTest < Minitest::Test
  Example = Examples::ToolModeToClarification

  def setup
    @results = Example.run
  end

  def test_manage_cards_adds_its_configuration_on_top_of_the_base
    snapshot = @results[:after_manage_cards]
    assert_equal [ Example::BASE_INSTRUCTIONS, Example::MANAGE_CARDS_INSTRUCTIONS ], snapshot.system_messages
    assert_equal [ Example::CreateCard.new.name.to_sym ], snapshot.tools
    refute_nil snapshot.schema
    assert_equal({ effort: :high }, snapshot.thinking)
  end

  def test_after_the_reset_clarify_holds_only_base_and_its_own_configuration
    snapshot = @results[:after_clarify]
    assert_equal [ Example::BASE_INSTRUCTIONS, Example::CLARIFY_INSTRUCTIONS ], snapshot.system_messages
    assert_empty snapshot.tools
    assert_nil snapshot.schema
    assert_equal({ effort: :low }, snapshot.thinking)
  end
end
