# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::ErrorsTest < Minitest::Test
  def test_hierarchy
    assert_operator RubyLLM::Modes::DeclarationError, :<, RubyLLM::Modes::Error
    assert_operator RubyLLM::Modes::ContractError, :<, RubyLLM::Modes::Error
    assert_operator RubyLLM::Modes::Error, :<, StandardError
  end

  def test_unknown_mode_is_a_key_error
    assert_operator RubyLLM::Modes::UnknownMode, :<, KeyError
  end
end
