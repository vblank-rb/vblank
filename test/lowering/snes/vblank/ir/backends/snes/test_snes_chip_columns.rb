# frozen_string_literal: true

require "test_helper"

# `draw_column_at` in a routine marked `on_chip: true`, on a Super FX cartridge: a first-person
# view's walls, a column of a picture stretched to a height for each column of the screen, drawn
# by the chip. Each game is played and checked against the interpreter on every frame, so a
# column the chip stretches, clips or leaves see-through differently fails at the first frame.
class TestSNESChipColumns < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  # A wall 64 pixels square in stripes: eight bands down, each its own colour, and every fourth
  # column across darker, so a texel read from the wrong row or the wrong column shows.
  BANDS = %i[red green blue white yellow cyan magenta orange].freeze
  WALL = Array.new(64 * 64) do |at|
    row = at / 64
    column = at % 64
    column % 4 == 3 ? :gray : BANDS[row / 8]
  end.freeze
  # A picture with see-through holes, which leave what is under them alone.
  GRATE = Array.new(16 * 16) { |at| (at / 16).even? ? :transparent : :green }.freeze
  # The striped wall with its darker columns black: black is the colour the chip paints from a place
  # of its own, since it leaves place 0 as it was.
  BLACK_STRIPED_WALL = WALL.map { |color| color == :gray ? :black : color }.freeze

  private def superfx_program(game) = game.program(console: :snes, variant: :superfx)

  # +columns+ wall columns a pass, their heights changing from pass to pass through tall ones that
  # run off the top and the bottom of the screen, short ones squashed below the picture's own
  # height, and nought and below.
  private def walls(columns:, area: false)
    VBlank.game("CHIP WALLS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      image :grate, width: 16, height: 16, data: GRATE, transparent: true
      step = var :step, 0
      tall = var :_tall, 0

      func :walls, on_chip: true do
        repeat(columns) do |col|
          tall = (((col * 37) + (step * 23)) % 400) - 20
          draw_column_at :wall, slice: (col * 3) + step, x: col * 2, top: 112 - (tall / 2), height: tall
        end
        draw_column_at :grate, slice: step, x: 200, top: step - 4, height: 40 + step, width: 3
        draw_column_at :wall, slice: 5, x: 255, top: 0, height: 30, width: 2
        draw_column_at :wall, slice: 70, x: -1, top: 0, height: 30, width: 2
      end

      game_loop do
        clear_screen :black
        step += 1
        if area
          inside(20, 30, 100, 120) { call :walls }
        else
          call :walls
        end
      end
    end
  end

  def test_walls_drawn_on_the_chip_look_as_on_the_interpreter
    run = game_player.run(superfx_program(walls(columns: 40)), frames: 30)

    assert_operator run[:step], :>=, 10, "ten passes or more were checked"
  end

  def test_walls_drawn_on_the_chip_inside_an_area_look_as_on_the_interpreter
    run = game_player.run(superfx_program(walls(columns: 40, area: true)), frames: 20)

    assert_operator run[:step], :>=, 5, "five passes or more were checked"
  end

  # A wall of columns of different heights side by side, as a first-person view draws them, with
  # see-through stripes over part of it: batches of eight columns whose tops and bottoms differ, a
  # batch short of eight at each end, and pixels left as they were.
  def test_ragged_walls_drawn_on_the_chip_look_as_on_the_interpreter
    game = VBlank.game("CHIP RAGGED", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: BLACK_STRIPED_WALL
      image :grate, width: 16, height: 16, data: GRATE, transparent: true
      step = var :step, 0
      tall = var :_tall, 0
      func :walls, on_chip: true do
        repeat(61) do |col|
          tall = 60 + (((col * 7) + (step * 5)) % 90)
          draw_column_at :wall, slice: col, x: col + 3, top: 112 - (tall / 2), height: tall
        end
        draw_column_at :grate, slice: step, x: 20, top: 90, height: 48, width: 13
      end
      game_loop do
        clear_screen :blue
        step += 1
        call :walls
      end
    end
    run = game_player.run(superfx_program(game), frames: 20)

    assert_operator run[:step], :>=, 5, "five passes or more were checked"
  end

  # A VIEW WITH BLACK ABOVE AND BELOW IT has the screen switched off there (Runtime::Letterbox),
  # and what is checked is that nobody can tell: a view 64 high whose top moves every pass, so the
  # lines kept on change with it, cleared to blue on some passes, where no line may go off, and
  # left uncleared on others, where the last pass's walls stay on the screen.
  def test_a_view_with_black_above_and_below_looks_as_on_the_interpreter
    game = VBlank.game("CHIP BARS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      step = var :step, 0
      top = var :top, 0
      func :walls, on_chip: true do
        repeat(60) { |col| draw_column_at :wall, slice: col + step, x: col * 2, top: top, height: 64 }
      end
      game_loop do
        step += 1
        top = 20 + ((step * 13) % 120)
        if step % 8 == 5
          clear_screen :blue
        elsif step % 8 != 2
          clear_screen :black
        end
        call :walls
      end
    end
    run = game_player.run(superfx_program(game), frames: 40)

    assert_operator run[:step], :>=, 20, "twenty passes or more were checked"
  end

  # Black above and below a view is only black while nothing colours it or moves it: a fade toward
  # white makes those lines grey, and a camera moved down brings the view into them. On the passes
  # with either, every line stays on.
  def test_a_faded_or_moved_view_with_black_above_and_below_looks_as_on_the_interpreter
    game = VBlank.game("CHIP FADED BARS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      step = var :step, 0
      func :walls, on_chip: true do
        repeat(40) { |col| draw_column_at :wall, slice: col + step, x: col * 3, top: 80, height: 64 }
      end
      game_loop do
        step += 1
        clear_screen :black
        call :walls
        fade :white, ((step / 4) % 3) * 30
        camera 0, ((step / 6) % 2) * 20
      end
    end
    run = game_player.run(superfx_program(game), frames: 40)

    assert_operator run[:step], :>=, 20, "twenty passes or more were checked"
  end

  # A view too big for one stretch of lines with the screen off, whose passes end at a different
  # line each time: the copy is cut wherever the lines run out, before the blank's interrupt and
  # after it, and no tile of it may be written once the screen is back on.
  def test_a_big_view_cut_at_any_line_looks_as_on_the_interpreter
    game = VBlank.game("CHIP CUTS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      step = var :step, 0
      spent = var :_spent, 0
      game_loop do
        step += 1
        clear_screen :black
        repeat(28) do |col|
          if (step + col) % 2 == 1
            draw_rect_at col * 8, 0, 8, 96 + (col % 8), :white
          else
            draw_rect_at col * 8, 0, 8, 96 + (col % 8), :green
          end
        end
        repeat((step * 29) % 240) { spent += step }
      end
    end
    run = game_player.run(superfx_program(game), frames: 70)

    assert_operator run[:step], :>=, 30, "thirty passes or more were checked"
  end

  # A view that stays where it is while what it shows changes: its copy starts as soon as the
  # screen goes off below it, on every pass, and every tile of it has to arrive.
  def test_a_view_that_stays_where_it_is_looks_as_on_the_interpreter
    run = game_player.run(square_of_walls(columns: 120, tall: 120, moves: true), frames: 16)

    assert_operator run[:step], :>=, 8, "eight passes or more were checked"
  end

  # A view that stays where it is: every frame the console draws is a whole pass's picture, the
  # one before or the one after, with the copy made where the screen is off. The one pass that is
  # seen arriving is the pass the lines are first switched off on, which is copied from the blank
  # on, with less room than the passes after it have.
  def test_a_view_with_black_above_and_below_is_not_seen_arriving
    run = SNES::HeadlessRun.new(watch_picture: true).run(square_of_walls(columns: 120, tall: 120, moves: true), frames: 12)

    assert_empty run.black_frames
    assert_operator run.torn_frames.size, :<=, 1, "no pass but the one that switches the lines off is seen arriving"
  end

  # The console's own routine for a column is carried only by a game that draws one outside the
  # chip's routines.
  def test_a_game_whose_columns_are_all_the_chips_carries_no_column_routine_of_the_consoles
    built = lambda do |on_chip|
      rom = VBlank.build("CHIP ONLY", console: :snes, variant: :superfx, out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        image :wall, width: 64, height: 64, data: WALL
        func :walls, on_chip: on_chip do
          repeat(8) { |col| draw_column_at :wall, slice: col, x: col, top: 80, height: 64 }
        end
        game_loop do
          clear_screen :black
          call :walls
        end
      end
      rom.built.code.keys
    end

    refute_includes built.call(true), "rt_paint_column"
    assert_includes built.call(false), "rt_paint_column"
  end

  # Walls across the whole width of the screen, so the right half's tile columns (x 128 and on, a
  # plot of their own on the chip) are drawn too, running down into the last row of tiles; and the
  # same inside an area that reaches the right edge and the bottom.
  [false, true].each do |area|
    define_method(:"test_walls_across_the_whole_width_#{area ? 'inside_an_area_' : ''}look_as_on_the_interpreter") do
      game = VBlank.game("CHIP WIDE", consoles: %i[snes], variants: { snes: :superfx }) do
        screen :bitmap
        image :wall, width: 64, height: 64, data: WALL
        step = var :step, 0
        tall = var :_tall, 0
        func :walls, on_chip: true do
          repeat(128) do |col|
            tall = 40 + (((col * 11) + (step * 7)) % 200)
            draw_column_at :wall, slice: col + step, x: col * 2, top: 224 - tall, height: tall, width: 2
          end
        end
        game_loop do
          clear_screen :black
          step += 1
          if area
            inside(90, 100, 166, 124) { call :walls }
          else
            call :walls
          end
        end
      end
      run = game_player.run(superfx_program(game), frames: 40)

      assert_operator run[:step], :>=, 4, "four passes or more were checked"
    end
  end

  # A game that paints 255 colours besides black, and draws black on the chip: the chip needs black
  # in a place of its own, and there is none left. The words say so, not that the game has too many.
  def test_black_on_the_chip_with_no_place_left_says_what_happened
    many = Array.new(255) { |n| n + 1 } + [:black]
    wall = Array.new(8 * 8) { |at| at.odd? ? :black : 1 + (at / 8) }
    game = VBlank.game("CHIP INKS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :many, width: 16, height: 16, data: many
      image :wall, width: 8, height: 8, data: wall
      func :walls, on_chip: true do
        draw_column_at :wall, slice: 3, x: 10, top: 10, height: 64
      end
      game_loop do
        clear_screen :black
        blit :many, 100, 100
        call :walls
      end
    end
    error = assert_raises(SNES::LoweringError) { game.build_rom(**SUPERFX_BUILD, out: nil, err: nil) }

    assert_match(/black/, error.message)
    refute_match(/more than 256/, error.message)
  end

  # Many small changes all over the screen, each tile on its own, so the copy to video RAM is many
  # runs of one tile; and passes that end at a different line each time, some of them late in the
  # blank, so a run is picked with little of it left. No tile may reach video RAM once the screen
  # is back on, which would leave it out of the picture.
  def test_many_one_tile_runs_picked_at_any_line_look_as_on_the_interpreter
    game = VBlank.game("CHIP DOTS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      step = var :step, 0
      spent = var :_spent, 0
      game_loop do
        step += 1
        repeat(14) do |across|
          repeat(14) do |down|
            if (step + across + down) % 2 == 0
              draw_rect_at (across * 16) + (step % 8), (down * 16) + (step % 5), 1, 1, :white
            else
              draw_rect_at (across * 16) + (step % 8), (down * 16) + (step % 5), 1, 1, :red
            end
          end
        end
        repeat((step * 37) % 300) { spent += step }
      end
    end
    run = game_player.run(superfx_program(game), frames: 60)

    assert_operator run[:step], :>=, 20, "twenty passes or more were checked"
  end

  # A list on the chip big enough to leave room for its numbers but not for the drawing's own
  # words: the game is told that drawing columns takes room in the chip's RAM, and how much.
  def test_a_list_that_leaves_no_room_for_drawing_on_the_chip_is_refused_naming_drawing
    error = assert_raises(SNES::LoweringError) { chip_list_beside_walls(capacity: 1000).build_rom(**SUPERFX_BUILD, out: nil, err: nil) }

    assert_match(/draw_column_at/, error.message)
    assert_match(/bytes/, error.message)
  end

  # The same list with no drawing on the chip fits, so the refusal above is the drawing's.
  def test_the_same_list_without_drawing_fits_on_the_chip
    chip_list_beside_walls(capacity: 1000, draws: false).build_rom(**SUPERFX_BUILD, out: nil, err: nil)
  end

  # The screen counts its clears in a number that turns over after 255 of them, and a tile the chip
  # draws keeps the count it was drawn in. Past the turn, with a fill by the console after the
  # chip's walls in the same pass and an area partly off the screen, every pass stays in step.
  def test_walls_drawn_on_the_chip_past_256_clears_look_as_on_the_interpreter
    game = VBlank.game("CHIP CLEARS", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      step = var :step, 0
      func :walls, on_chip: true do
        repeat(6) { |col| draw_column_at :wall, slice: col + step, x: (col * 9) + (step % 5), top: 70, height: 40 }
      end
      game_loop do
        clear_screen :black
        step += 1
        inside(-10, 60, 50, 60) { call :walls }
        fill_rect 20, 90, 8, 8, :white
      end
    end
    run = game_player.run(superfx_program(game), frames: 290)

    assert_operator run[:step], :>=, 260, "the clears turned over"
  end

  SUPERFX_BUILD = { console: :snes, variant: :superfx, profile: false }.freeze

  private def chip_list_beside_walls(capacity:, draws: true)
    VBlank.game("CHIP FULL", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      cells = list :cells, capacity: capacity, full_of: 0
      func :walls, on_chip: true do
        cells[3] = cells[2] + 1
        repeat(8) { |col| draw_column_at :wall, slice: col, x: col, top: 80, height: 64 } if draws
      end
      game_loop do
        clear_screen :black
        call :walls
      end
    end
  end

  # +columns+ columns of the striped wall, each +tall+ high, drawn from a routine on the chip.
  # +moves+ for a wall whose stripes move across every pass.
  private def square_of_walls(columns:, tall:, moves: false)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes, variant: :superfx))
    b.instance_eval do
      screen :bitmap
      image :wall, width: 64, height: 64, data: WALL
      step = var :step, 0
      func :walls, on_chip: true do
        repeat(columns) { |col| draw_column_at :wall, slice: col + step, x: col, top: 112 - (tall / 2), height: tall }
      end
      game_loop do
        clear_screen :black
        step += 1 if moves
        call :walls
      end
    end
    b.finalize_program
    b.program
  end

  # The passes a cost is measured over, past the first few, which set the screen up.
  MEASURED_PASSES = (6...18)

  # The frames a pass took, over MEASURED_PASSES: their mean, not rounded, and the most.
  private def frames_a_pass(program)
    run = SNES::HeadlessRun.new.run(program, frames: MEASURED_PASSES.end + 2)
    took = MEASURED_PASSES.map { |pass| run.frames_took(pass) }
    [took.sum.fdiv(took.size), took.max]
  end

  # The walls of a first-person view take no more frames a pass on the chip than these, 120 columns
  # 120 high and 40 columns 40 high, every pass of them. The 120's are sent to video RAM in the
  # lines above and below the view, where the screen is off (Runtime::Letterbox); the rest of its
  # time is the chip's painting. The console's processor drawing the same walls takes many times as long.
  MOST_FRAMES = { [120, 120] => 4, [40, 40] => 1 }.freeze

  MOST_FRAMES.each do |(columns, tall), most|
    define_method(:"test_#{columns}_columns_#{tall}_high_take_#{most}_frames_a_pass_on_the_chip") do
      mean, slowest = frames_a_pass(square_of_walls(columns: columns, tall: tall, moves: true))
      warn "#{columns}x#{tall}: #{mean} frames a pass on the chip, #{slowest} the slowest" if ENV["VBLANK_CHIP_FRAMES"]

      assert_operator mean, :<=, most, "#{columns} columns #{tall} high took #{most} frames a pass or fewer"
      assert_operator slowest, :<=, most, "no pass of #{columns} columns #{tall} high took more than #{most} frames"
    end
  end
end
