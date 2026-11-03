# frozen_string_literal: true

require "test_helper"
require "differential"

# SPRITE TILES THE GAME LOADS, AND POSES DRAWN FROM THEM — `sprite_tiles`, `image ... tiles_from:`
# and `copy_from`.
#
# A set is a few tiles in sprite memory. A pose is a picture made of some of them, each where the
# pose puts it. Loading tiles of the set from a picture in the cartridge changes every pose that
# draws them, in the picture of the pass that loaded them.
class TestSpriteTiles < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  WHITE = VBlank::Graphics::Color.resolve(:white)

  # Four tiles of 8×8 one under the other: red, green, white, and a tile whose top row is red,
  # green, white, red, ... so a load that copies the wrong rows or the wrong order shows.
  KINDS = [*([1] * 64), *([2] * 64), *([3] * 64), *([1, 2, 3, 1, 2, 3, 1, 2] + ([3] * 56))].freeze

  # A set of four tiles and two poses of two tiles side by side: :a draws tile 0 then tile 1,
  # :b tile 1 then tile 0. +body+ runs each pass with the set, the sprite and a frame counter.
  private def ball_game(&body)
    kinds = KINDS
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ball, %i[transparent red green white]
      image :kinds, width: 8, height: 32, colors: :ball, places: kinds
      set = sprite_tiles :ball_tiles, count: 4, colors: :ball
      image :a, tiles_from: :ball_tiles, pieces: [[0, 0, 0], [8, 0, 1]]
      image :b, tiles_from: :ball_tiles, pieces: [[0, 0, 1], [8, 0, 0]]
      ball = sprite :ball, at: [40, 20], facing: { a: :a, b: :b }
      frame = 0
      game_loop do
        frame += 1
        instance_exec(set, ball, frame, &body)
      end
    end
    b.finalize_program
    b.program
  end

  private def screen_after(program, frames) = game_player.run(program, frames: frames).screen

  # A load is in the picture of the pass that said it, as `changed now: true` is.
  def test_poses_show_the_tiles_loaded_into_the_set_in_that_pass
    program = ball_game do |set, _ball, frame|
      set.copy_from :kinds, at: 0, count: 2, to: 0 if frame == 2
    end

    assert_equal 0, screen_after(program, 1).pixel(40, 20), "see-through before the load"
    shown = screen_after(program, 2)
    assert_equal RED, shown.pixel(40, 20), "tile 0 took the source's first tile"
    assert_equal GREEN, shown.pixel(48, 27), "tile 1 took its second, every row of it"
  end

  def test_another_pose_draws_the_same_tiles_in_its_own_places
    program = ball_game do |set, ball, frame|
      set.copy_from :kinds, at: 0, count: 2, to: 0 if frame == 1
      ball.face :b if frame == 3
    end
    shown = screen_after(program, 3 + framework_drawing_lag)

    assert_equal GREEN, shown.pixel(40, 20), ":b draws tile 1 on the left"
    assert_equal RED, shown.pixel(48, 20), "...and tile 0 on the right"
  end

  def test_a_tile_loaded_again_changes_every_pose_that_draws_it
    program = ball_game do |set, ball, frame|
      set.copy_from :kinds, at: 0, count: 2, to: 0 if frame == 1
      set.copy_from :kinds, at: 3, count: 1, to: 1 if frame == 4
      ball.face :b if frame == 6
    end
    before = screen_after(program, 3)
    loaded = screen_after(program, 4)
    turned = screen_after(program, 6 + framework_drawing_lag)

    assert_equal GREEN, before.pixel(48, 20), "tile 1 green before the second load"
    assert_equal [RED, GREEN, WHITE, RED], (48..51).map { |x| loaded.pixel(x, 20) }, "pose :a shows the new tile 1"
    assert_equal WHITE, loaded.pixel(48, 21), "...all of it"
    assert_equal [RED, GREEN, WHITE, RED], (40..43).map { |x| turned.pixel(x, 20) }, "and so does pose :b"
  end

  def test_a_load_worked_out_as_the_game_runs
    program = ball_game do |set, _ball, frame|
      set.copy_from :kinds, at: frame - 1, count: 1, to: 1 if frame == 3 # the white tile
    end

    assert_equal WHITE, screen_after(program, 3 + framework_drawing_lag).pixel(48, 20)
  end

  def test_a_load_past_the_end_of_the_set_or_the_source_changes_nothing
    program = ball_game do |set, _ball, frame|
      set.copy_from :kinds, at: 0, count: 2, to: 0 if frame == 1
      set.copy_from :kinds, at: 2, count: 2, to: 3 if frame == 2 # past the set's four tiles
      set.copy_from :kinds, at: frame, count: 2, to: 0 if frame == 3 # past the source's four
    end
    shown = screen_after(program, 4 + framework_drawing_lag)

    assert_equal RED, shown.pixel(40, 20)
    assert_equal GREEN, shown.pixel(48, 20)
  end

  # Every pixel of the console's picture against the interpreter's, around a load, a second load
  # of a tile both poses draw, and a change of pose.
  def test_the_console_agrees_on_loads_and_poses
    program = ball_game do |set, ball, frame|
      set.copy_from :kinds, at: 0, count: 2, to: 0 if frame == 2
      set.copy_from :kinds, at: 3, count: 1, to: 1 if frame == 4
      ball.face :b if frame == 5
    end

    _, console, = backend_pictures(program, frames: 7)
    assert_equal [RED, GREEN, WHITE].sort, (console.uniq & [RED, GREEN, WHITE]).sort,
                 "the console drew the loaded tiles, so the comparison means something"
    assert_backends_agree(program, frames: [1, 2, 3, 4, 5, 6, 7])
  end

  # On a Color told its sprite pieces are 8x16, a tile at an even place and the next one under it
  # are one piece: the ball's shape, two tall pieces side by side.
  def test_a_pose_of_tall_pieces_draws_each_tile_where_it_says
    kinds = KINDS
    b = Builder.new(options: VBlank::Cartridge::Options.new(sprite_piece_size: { gbc: [8, 16] }))
    b.instance_eval do
      screen :tiled
      colors :ball, %i[transparent red green white]
      image :kinds, width: 8, height: 32, colors: :ball, places: kinds
      set = sprite_tiles :ball_tiles, count: 4, colors: :ball
      image :spin, tiles_from: :ball_tiles, pieces: [[0, 0, 2], [0, 8, 3], [8, 0, 0], [8, 8, 1]]
      sprite :ball, at: [40, 20], facing: { spin: :spin }
      frame = 0
      game_loop do
        frame += 1
        set.copy_from :kinds, at: 0, count: 4, to: 0 if frame == 1
      end
    end
    b.finalize_program
    shown = screen_after(b.program, 2 + framework_drawing_lag)

    assert_equal [WHITE, RED, GREEN, RED, GREEN],
                 [shown.pixel(40, 20), shown.pixel(40, 28), shown.pixel(41, 28), shown.pixel(48, 20), shown.pixel(48, 28)]
  end

  # A table of bytes the set loads from is still the game's table: read by index it holds the
  # numbers the game wrote, whatever form a console keeps the loaded tiles in.
  def test_a_table_loaded_from_still_reads_as_written
    kinds = KINDS
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ball, %i[transparent red green white]
      bytes = table :ball_bytes, kinds.each_slice(2).map { |near, far| near | (far << 4) }, width: :byte
      set = sprite_tiles :ball_tiles, count: 4, colors: :ball
      image :a, tiles_from: :ball_tiles, pieces: [[0, 0, 0], [8, 0, 1]]
      sprite :a, at: [40, 20]
      read = var :read, 0
      game_loop do
        set.copy_from bytes, at: 2, count: 2, to: 0
        # The index is worked out as the game runs, so the read is the console's, not the build's.
        at = 5 + (read & 0)
        read = bytes[at] + bytes[at + 35]
      end
    end
    b.finalize_program
    run = game_player.run(b.program, frames: 3)

    assert_equal 0x11 + 0x22, run[:read], "byte 5 is in the first tile and byte 40 in the second"
    assert_equal WHITE, run.screen.pixel(40, 20), "and the load took the white tile"
  end

  # A pass can load at most Nodes::LoadSpriteTiles::MOST_IN_A_PASS times, on every build: a console
  # copies the loads in the short gap after the pass. One more stops the game, saying so.
  def test_more_loads_in_a_pass_than_a_gap_holds_stop_the_game
    most = VBlank::IR::Nodes::LoadSpriteTiles::MOST_IN_A_PASS
    program = ball_game do |set, _ball, _frame|
      (most + 1).times { |k| set.copy_from :kinds, at: k % 4, count: 1, to: 0 }
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(program, frames: 3) }

    assert_includes error.message, "more than #{most} times in one pass"
    within = ball_game do |set, _ball, _frame|
      most.times { |k| set.copy_from :kinds, at: k % 4, count: 1, to: 0 }
    end
    game_player.run(within, frames: 3)
  end

  def test_mistakes_are_friendly_errors
    build = lambda do |&body|
      b = Builder.new
      b.instance_eval do
        screen :tiled
        colors :ball, %i[transparent red green white]
        instance_exec(&body)
      end
    end

    error = assert_raises(ArgumentError) { build.call { image :a, tiles_from: :nope, pieces: [[0, 0, 0]] } }
    assert_match(/no sprite_tiles has that name/, error.message)
    error = assert_raises(ArgumentError) { build.call { sprite_tiles :set, count: 0, colors: :ball } }
    assert_match(/count:/, error.message)
    error = assert_raises(ArgumentError) do
      build.call do
        sprite_tiles :set, count: 2, colors: :ball
        image :a, tiles_from: :set, pieces: [[4, 0, 0]]
      end
    end
    assert_match(/multiple of 8/, error.message)
    error = assert_raises(ArgumentError) do
      build.call do
        sprite_tiles :set, count: 2, colors: :ball
        image :a, tiles_from: :set, pieces: [[0, 0, 2]]
      end
    end
    assert_match(/tiles 0 to 1/, error.message)
    error = assert_raises(ArgumentError) do
      build.call do
        image :other, width: 8, height: 8, colors: %i[transparent blue], places: [1] * 64
        sprite_tiles(:set, count: 2, colors: :ball).copy_from :other, at: 0, count: 1, to: 0
      end
    end
    assert_match(/not drawn from the set's colours/, error.message)
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        sprite_tiles :set, count: 2, colors: %i[transparent red]
      end
    end
    assert_match(/bitmap screen/, error.message)
  end
end
