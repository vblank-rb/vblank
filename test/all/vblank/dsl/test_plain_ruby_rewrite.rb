# frozen_string_literal: true

require "test_helper"

# A few sanity checks on what a game block is rewritten into. What a game does is checked in
# test_plain_ruby.rb; these look only at the choices a person would want to see made: which
# names become `var`, which stay plain, and that every line keeps its number.
class TestPlainRubyRewrite < Minitest::Test
  private def rewritten(&block) = VBlank::DSL::PlainRuby.rewritten_source(block)

  def test_a_number_changed_in_game_code_is_declared_with_var
    source = rewritten do
      hp = 5
      game_loop { hp -= 1 }
    end

    assert_includes source, ":hp, 5)"
  end

  def test_a_number_never_changed_stays_a_plain_number
    source = rewritten do
      speed = 2
      hp = 5
      game_loop { hp -= speed }
    end

    assert_includes source, "speed = 2"
    refute_includes source, ":speed"
  end

  def test_a_number_changed_only_outside_game_code_stays_a_plain_number
    source = rewritten do
      count = 0
      8.times { count += 1 }
      game_loop { pixel count, 0, :red }
    end

    refute_includes source, "variable_with_no_var_line"
  end

  def test_the_same_name_in_two_routines_gets_two_variable_names
    source = rewritten do
      func(:one) { x = 1; x += 1 }
      func(:two) { x = 2; x += 1 }
    end

    assert_includes source, ":x, 1)"
    assert_includes source, ":x_2, 2)"
  end

  def test_two_blocks_on_one_line_are_told_apart
    first, second = proc { one = 1 }, proc { two = 2 }

    assert_includes VBlank::DSL::PlainRuby.rewritten_source(first), "one = 1"
    assert_includes VBlank::DSL::PlainRuby.rewritten_source(second), "two = 2"
  end

  private def arrow_from_one_line_method = ->(one) { one }

  def test_a_lambda_on_a_line_with_a_method_is_found
    assert_predicate VBlank::DSL::PlainRuby.rewrite(arrow_from_one_line_method, checked: false), :lambda?
  end

  def test_a_lambda_is_rewritten_and_stays_a_lambda
    arrow = VBlank::DSL::PlainRuby.rewrite(->(one) { one }, checked: false)
    word = VBlank::DSL::PlainRuby.rewrite(lambda { |one| one }, checked: false)
    plain = VBlank::DSL::PlainRuby.rewrite(proc { |one| one }, checked: false)

    assert_predicate arrow, :lambda?
    assert_predicate word, :lambda?
    refute_predicate plain, :lambda?
  end

  def test_a_number_changed_by_a_menu_row_is_declared_with_var
    source = rewritten do
      picked = 0
      game_loop { menu(:main, at: [40, 40]) { |rows| rows.item("GO") { picked = 1 } } }
    end

    assert_includes source, ":picked, 0)"
  end

  def test_every_line_keeps_its_number
    source = rewritten do
      hp = 5
      if hp > 0
        # a comment
        hp -= 1
      elsif hp < 0
        hp = 2
      else
        hp = 3
      end
      unless hp == 1 then hp = 4 end
      while hp > 9
        hp -= 1
      end
      x = hp > 0 ? 1 : 2
      game_loop { hp += x }
    end

    assert_equal 16, source.count("\n"), source
  end

  # A `case` standing alone whose arms each call a scene may be the scene dispatch, asked as its
  # line runs (Builder::Scenes#scene_case?).
  def test_a_case_standing_alone_that_calls_scenes_may_be_the_scene_dispatch
    source = rewritten do
      game_loop do
        case state
        when 0 then call :title
        end
      end
    end

    assert_includes source, "scene_case?"
  end

  # A `case` whose value is read stays the chain of tests, which hands back the value Ruby would.
  def test_a_case_whose_value_is_read_is_never_the_scene_dispatch
    picks = [
      rewritten { game_loop { picked = (case state; when 0 then call :title; end) } },
      rewritten { game_loop { picked = begin; case state; when 0 then call :title; end; end } },
      rewritten { game_loop { picked = state > 1 ? (case state; when 0 then call :title; end) : 0 } },
      rewritten do
        def pick
          case state
          when 0 then call :title
          end
        end
      end,
    ]

    picks.each { |source| refute_includes source, "scene_case?" }
  end
end
