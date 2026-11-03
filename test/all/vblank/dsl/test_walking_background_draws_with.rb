# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND THAT WALKS BETWEEN AREAS, DRAWN FOR A WHILE WITH ANOTHER LIST OF COLOURS. Each
# area has its own tiles and its own list, and the game borrows another list for the area that
# is up: a room loaded under the last area's colours, a cave gone dark, a flash. `draw_with` names
# the area's own list and the list it borrows, and `draw_with :own` gives the area its colours back.
#
# Two areas of one room each. The shrine's floor is drawn from :shrine_own, the clearing's grass
# from :clearing_own; each tile is its list's first place on the left half and its second on the
# right, so a borrowed list shows at a known place.
class TestWalkingBackgroundDrawsWith < Minitest::Test
  include Differential

  FLOOR = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze
  GRASS = Array.new(64) { |i| (i % 8) < 4 ? :blue : :white }.freeze
  LEFT = [1, 1].freeze
  RIGHT = [5, 1].freeze

  private def two_areas(&loop_body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :shrine_own, %i[transparent red green]
      colors :clearing_own, %i[transparent blue white]
      colors :shrine_dark, %i[transparent yellow cyan]
      colors :clearing_dark, %i[transparent magenta orange]
      colors :meadow, %i[transparent white white]
      image :floor, width: 8, height: 8, data: FLOOR, colors: :shrine_own
      image :grass, width: 8, height: 8, data: GRASS, colors: :clearing_own
      tiles :shrine, "#" => :floor
      tiles :clearing, "#" => :grass
      grid = Array.new(20) { "#" * 30 }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: grid }, clearing: { glade: grid } }
      instance_exec(ground, &loop_body)
    end
    builder.finalize_program
    builder.program
  end

  # In the shrine: the dark list borrowed on the third pass, and the shrine's own back on the sixth.
  private def borrowed_and_given_back
    two_areas do |ground|
      tick = var :tick, 0
      game_loop do
        tick += 1
        ground.draw_with({ shrine_own: :shrine_dark }) if tick == 3
        ground.draw_with :own if tick == 6
        ground.show_map 0
      end
    end
  end

  private def colors_at(prog, frames)
    screen = game_player.run(prog, frames: frames).screen
    [screen.pixel(*LEFT), screen.pixel(*RIGHT)]
  end

  private def shown_pair(*names) = names.map { |name| shown(name) }

  def test_the_area_up_shows_a_borrowed_list_and_then_its_own_again
    prog = borrowed_and_given_back

    assert_equal shown_pair(:red, :green), colors_at(prog, 2), "the shrine as drawn"
    assert_equal shown_pair(:yellow, :cyan), colors_at(prog, 5), "the shrine with :shrine_dark"
    assert_equal shown_pair(:red, :green), colors_at(prog, 8), "the shrine's own colours again"
  end

  def test_the_console_borrows_and_gives_back_the_same_way
    assert_backends_agree(borrowed_and_given_back, frames: [2, 4, 5, 7, 8], name: "AREADW")
  end

  # The shrine borrows its dark list on the third pass and the game walks into the clearing on the
  # sixth, with the dark list still said: the clearing shows its own colours. On the tenth the
  # clearing borrows its own dark list. On the thirteenth the game walks back to the shrine and
  # borrows the shrine's dark list in the same pass, which is how a room is loaded under the last
  # area's colours: the shrine arrives dark.
  private def walking_while_borrowed
    two_areas do |ground|
      tick = var :tick, 0
      room = var :room, 0
      game_loop do
        tick += 1
        ground.draw_with({ shrine_own: :shrine_dark }) if tick == 3
        room = 1 if tick == 6
        ground.draw_with({ clearing_own: :clearing_dark }) if tick == 10
        if tick == 13
          room = 0
          ground.draw_with({ shrine_own: :shrine_dark })
        end
        ground.show_map room
      end
    end
  end

  def test_walking_into_another_area_shows_that_areas_own_colours
    assert_equal shown_pair(:blue, :white), colors_at(walking_while_borrowed, 8)
  end

  def test_the_area_walked_into_can_borrow_a_list_of_its_own
    assert_equal shown_pair(:magenta, :orange), colors_at(walking_while_borrowed, 12)
  end

  def test_an_area_walked_into_with_a_borrowed_list_said_in_the_same_pass_arrives_with_it
    assert_equal shown_pair(:yellow, :cyan), colors_at(walking_while_borrowed, 16)
  end

  def test_the_console_walks_while_borrowing_the_same_way
    assert_backends_agree(walking_while_borrowed, frames: [5, 7, 8, 12, 14, 16], name: "AREADWW")
  end

  def test_a_list_none_of_the_areas_draws_from_is_refused
    error = assert_raises(ArgumentError) do
      two_areas { |ground| ground.draw_with({ meadow: :shrine_dark }) }
    end

    assert_match(/No tile of its areas is drawn from :meadow/, error.message)
    assert_match(/:shrine_own/, error.message)
    assert_match(/:clearing_own/, error.message)
  end
end
