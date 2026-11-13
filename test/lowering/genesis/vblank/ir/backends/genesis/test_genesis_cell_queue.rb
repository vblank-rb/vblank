# frozen_string_literal: true

require "test_helper"
require "stringio"

# THE CELLS A PASS CHANGES ON A GENESIS, kept in a queue in work memory and written in the blank
# (Runtime::Tiles's rt_note_cell and the cells' part of rt_upload). A message box opening rewrites
# up to 30 by 8 cells in one pass, and a game doing that must lose no frame and stop for nothing.
class TestGenesisCellQueue < Minitest::Test
  Tiles = VBlank::IR::Backends::Genesis::Runtime::Tiles

  PASSES = 24

  # How much of a frame writing a whole box's cells may take. A cell is three writes to the video
  # chip and a count, so 240 of them are a small part of a frame.
  MOST_OF_A_FRAME = 0.10

  # A box of +across+ by +down+ cells over a field, every cell of it rewritten every pass, the
  # tiles taking turns pass by pass so each pass's picture differs from the last.
  def self.box_game(across, down)
    VBlank.game("CELL QUEUE", consoles: %i[genesis]) do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art
      field = background :field, tiles: :set, map: Array.new(28) { "#" * 40 }
      tick = 0
      game_loop do
        tick += 1
        row = 0
        while row < down
          column = 0
          while column < across
            if (tick & 1).zero?
              field.set_tile column, row, "#"
            else
              field.set_tile column, row, "."
            end
            column += 1
          end
          row += 1
        end
      end
    end
  end

  BOX = box_game(30, 8)

  def test_a_box_of_240_cells_changed_every_pass_shows_what_the_interpreter_shows
    game_player.run(BOX.program(console: :genesis), frames: 12)
  end

  def test_a_box_of_240_cells_changed_every_pass_takes_one_frame_a_pass
    rom = BOX.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: PASSES)
    cells = result.runtime.select { |spent| spent.routine.to_s.match?(/\Art_upload/) }.sum(&:share)

    assert_equal({ 1 => PASSES }, result.passes_by_frames, "every pass fits in one frame")
    assert_operator cells, :<=, MOST_OF_A_FRAME, "writing the cells takes #{(cells * 100).round(1)}% of each frame"
  end

  # More cells in a pass than the queue holds: the queue is written early, in the order the cells
  # were changed, and the game goes on.
  def test_more_cells_in_a_pass_than_the_queue_holds_are_written_early_in_order
    game_player.run(TestGenesisCellQueue.box_game(40, 20).program(console: :genesis), frames: 6)
  end

  # A scene taking over puts its background up, and its first pass then changes more cells than
  # the queue holds: the map goes up before the cells written early, so they land on it and are
  # not covered by it in the blank.
  def test_cells_written_early_land_on_a_map_put_up_before_them
    game = VBlank.game("CELL ORDER", consoles: %i[genesis]) do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art
      scene(:waiting) { nil }
      scene(:boxed) do
        room = background :room, tiles: :set, map: Array.new(28) { "." * 40 }
        row = 0
        while row < 10
          column = 0
          while column < 40
            room.set_tile column, row, "#"
            column += 1
          end
          row += 1
        end
      end
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        state = 1 if tick == 3
        case_var(:state) do
          when_val 0, :waiting
          when_val 1, :boxed
        end
      end
    end
    run = game_player.run(game.program(console: :genesis), frames: 3)

    assert_equal VBlank::Testing.shown(:red), run.screen.pixel(300, 70), "the last row changed, after the queue was written early"
    assert_equal VBlank::Testing.shown(:blue), run.screen.pixel(300, 100), "the map put up, under no change"
  end
end
