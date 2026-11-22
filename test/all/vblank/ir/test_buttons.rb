# frozen_string_literal: true

require "test_helper"

# How far a trigger is pulled when more than one thing pulls it (IR::Buttons.pulls): a key and a
# gamepad, or two gamepads, for one player. Every window keeps the same rule, the furthest given,
# a key or a button held as a name counting all the way.
class TestButtons < Minitest::Test
  BUTTONS = VBlank::IR::Buttons

  def test_two_part_pulls_of_one_trigger_keep_the_furthest
    assert_equal({ l2: 60 }, BUTTONS.pulls([{ l2: 60 }, { l2: 30 }]))
  end

  def test_a_trigger_held_as_a_name_is_pulled_all_the_way_whatever_a_part_pull_says
    assert_equal 100, BUTTONS.pull_among([:l2, { l2: 30 }], :l2, 1)
    assert_equal 100, BUTTONS.pull_among([{ p2_r2: 30 }, :p2_r2], :r2, 2)
  end

  def test_a_players_number_keeps_the_furthest_pull
    number = BUTTONS.player_mask([{ l2: 20 }, { l2: 70 }], 1)

    assert_equal 70, (number >> BUTTONS.pull_shift(:l2)) & ((1 << BUTTONS::PULL_BITS) - 1)
  end

  # Two players' numbers made one, as a match sends this machine's: the buttons together, and each
  # trigger's furthest pull rather than the bits of both run together.
  def test_numbers_made_one_keep_each_triggers_furthest_pull
    first = BUTTONS.player_mask([:a, { l2: 40 }], 1)
    second = BUTTONS.player_mask([:b, { l2: 25 }], 1)

    assert_equal BUTTONS.player_mask([:a, :b, { l2: 40 }], 1), BUTTONS.merged_number([first, second])
  end
end
