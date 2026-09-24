# frozen_string_literal: true

require "test_helper"

class RubyLLM::Modes::TruncationTest < Minitest::Test
  Truncation = RubyLLM::Modes::Truncation

  def test_head_keeps_text_within_the_limit
    assert_equal "hello", Truncation.head("hello", 5)
    assert_equal "hello", Truncation.head("hello", nil)
  end

  def test_head_keeps_the_first_characters_and_says_how_many_were_cut
    assert_equal "hel\n[... 2 characters omitted ...]\n", Truncation.head("hello", 3)
  end

  def test_head_and_tail_keeps_text_within_the_limit
    assert_equal "hello", Truncation.head_and_tail("hello", 5)
    assert_equal "hello", Truncation.head_and_tail("hello", nil)
  end

  def test_head_and_tail_keeps_both_ends
    text = "make cards from " + ("x" * 100) + " please"
    assert_equal "make\n[... 114 characters omitted ...]\nlease", Truncation.head_and_tail(text, 9)
    assert_equal "make\n[... 115 characters omitted ...]\nease", Truncation.head_and_tail(text, 8)
  end

  def test_counts_characters_not_bytes
    text = "привет мир"
    assert_equal "прив\n[... 6 characters omitted ...]\n", Truncation.head(text, 4)
    assert_equal "пр\n[... 6 characters omitted ...]\nир", Truncation.head_and_tail(text, 4)
  end
end
