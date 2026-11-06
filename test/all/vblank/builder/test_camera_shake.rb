# frozen_string_literal: true

require "test_helper"

# The games these tests play, kept once for the shake read back on the Advance's cartridge too
# (test/lowering/gba/vblank/builder/test_camera_shake_cartridge.rb).
module CameraShakeGames
  include SharedConstants

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A blue screen with a red block at (100, 70), and a shake fired on frame 3.
  # Halting after +frames+ lets each test look at one exact moment.
  private def shaking_game(frames:, intensity: 4, length: 3)
    program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      frame = var :frame, 0
      game_loop do
        frame += 1
        shake_screen intensity: intensity, frames: length if frame == 3
        halt if frame >= frames
      end
    end
  end

  # The same on a tiled screen: a background of red and blue stripes, 4 pixels each, and a
  # green sprite at (100, 60), with a shake fired on frame 3.
  private def tiled_shaking_game(frames:, intensity: 2, length: 3)
    program do
      screen :tiled
      image(:stripe, "#" => :red, "." => :blue) { (["####...."] * 8).join("\n") }
      tiles :ground, "#" => :stripe
      background :field, tiles: :ground, map: (["#" * 32] * 20)
      image(:hero, "#" => :green) { (["########"] * 8).join("\n") }
      sprite :hero, at: [100, 60]
      frame = var :frame, 0
      game_loop do
        frame += 1
        shake_screen intensity: intensity, frames: length if frame == 3
        halt if frame >= frames
      end
    end
  end
end

# The camera — moving the visible window over the whole picture — and the screen
# shake built on top of it.
#
# The camera does not redraw anything. The picture stays exactly where it was drawn
# and the WINDOW moves, which is what makes a shake cost almost nothing: a game
# under a shake draws precisely what it drew before. So the thing to assert is that
# the same drawing SHOWS somewhere else while the shake runs, and shows back in its
# original place once it ends.
class TestCameraShake < Minitest::Test
  include CameraShakeGames

  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  WHITE = VBlank::Graphics::Color.resolve(:white)

  # --- the camera on its own ---

  def test_the_camera_moves_what_is_shown_without_moving_what_was_drawn
    prog = program do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      camera 10, 0
      halt
    end
    i = game_player.run(prog)

    # The block was drawn across x 100..139.
    assert_equal RED, i.screen.stored_pixel(100, 70), "the drawing itself does not move"
    assert_equal RED, i.screen.pixel(90, 70), "with the window 10px right, the block shows 10px left"
    assert_equal BLUE, i.screen.pixel(132, 70),
                 "and its right edge has slid off, so that spot shows what was drawn beyond it"
  end

  # --- the shake ---

  def test_the_picture_is_off_centre_while_the_shake_runs
    i = game_player.run(shaking_game(frames: 4))

    refute_equal [0, 0], [i.screen.camera_x, i.screen.camera_y],
                 "the shake should have the camera off centre mid-shake"
  end

  def test_the_shake_alternates_direction_so_it_reads_as_a_jitter
    a = game_player.run(shaking_game(frames: 4)).screen.camera_x
    b = game_player.run(shaking_game(frames: 5)).screen.camera_x

    assert_equal(-a, b, "consecutive shake frames move opposite ways")
    refute_equal 0, a
  end

  def test_intensity_is_how_far_the_picture_moves
    gentle = game_player.run(shaking_game(frames: 4, intensity: 2)).screen.camera_x
    hard = game_player.run(shaking_game(frames: 4, intensity: 8)).screen.camera_x

    assert_equal 2, gentle.abs
    assert_equal 8, hard.abs
  end

  # The one that matters most: a shake that does not put the picture back leaves the
  # whole game off centre with a stripe of backdrop down one edge, forever.
  def test_the_picture_goes_back_exactly_where_it_was
    i = game_player.run(shaking_game(frames: 12))

    assert_equal 0, i.screen.camera_x
    assert_equal 0, i.screen.camera_y
    assert_equal RED, i.screen.pixel(100, 70), "the block is back in its original place"
  end

  def test_the_shake_lasts_as_long_as_it_was_asked_to
    settled = game_player.run(shaking_game(frames: 8, length: 3))
    still_going = game_player.run(shaking_game(frames: 5, length: 20))

    assert_equal 0, settled.screen.camera_x, "a 3-frame shake is over well before frame 8"
    refute_equal 0, still_going.screen.camera_x, "a 20-frame shake is not"
  end

  def test_duration_in_seconds_is_the_same_as_the_frames_it_works_out_to
    seconds = program do
      screen :bitmap
      game_loop { shake_screen intensity: 3, duration: 0.2 }
    end
    frames = program do
      screen :bitmap
      game_loop { shake_screen intensity: 3, frames: 12 }
    end

    assert_equal frames.to_h, seconds.to_h, "0.2s at 60fps is 12 frames"
  end

  # --- friendly errors ---

  def test_frames_and_duration_together_is_an_error
    err = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { shake_screen intensity: 2, frames: 4, duration: 1 } }
    end
    assert_match(/not both/, err.message)
  end

  def test_a_nonsense_length_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { shake_screen intensity: 2, frames: 0 } }
    end
    assert_match(/positive/, err.message)
  end

  def test_a_nonsense_intensity_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      program { screen :bitmap; game_loop { shake_screen intensity: 0 } }
    end
    assert_match(/positive/, err.message)
  end

  # --- on a tiled screen ---
  #
  # A tiled screen has no one picture to slide: it is backgrounds and sprites, each placed by
  # the console. So the camera moves all of them by the same amount, on top of wherever the
  # game scrolled each background. The thing to assert is that a background and a sprite show
  # moved by the same amount on the same frame, and both back in place once the shake ends.

  # Where the sprite's green square shows, as [x, y]: drawn at (100, 60).
  private def sprite_corner(screen)
    (50..70).each do |y|
      (90..110).each { |x| return [x, y] if screen.pixel(x, y) == GREEN }
    end
    nil
  end

  # How far the background's red and blue stripes, 4 pixels each, show moved to the left:
  # 0 to 7, read off the first red pixel after a blue one on row +y+.
  private def stripes_moved(screen, y)
    x = (1..20).find { |at| screen.pixel(at, y) == RED && screen.pixel(at - 1, y) == BLUE }
    (8 - x) % 8
  end

  def test_a_shake_moves_a_tiled_background_and_its_sprites_together
    i = game_player.run(tiled_shaking_game(frames: 10, length: 20))

    corner = sprite_corner(i.screen)
    refute_nil corner, "the sprite is on screen"
    across, down = corner.zip([100, 60]).map { |seen, drawn| drawn - seen }

    refute_equal 0, across, "mid-shake the sprite is off its place"
    assert_equal across, down, "a shake moves the picture the same way across and down"
    assert_equal across % 8, stripes_moved(i.screen, 30), "the background moved as far as the sprite, the same frame"
  end

  def test_a_tiled_shake_puts_the_picture_back_exactly_where_it_was
    i = game_player.run(tiled_shaking_game(frames: 14, length: 3))

    assert_equal [100, 60], sprite_corner(i.screen)
    assert_equal 0, stripes_moved(i.screen, 30)
  end

  # A game with no game loop has no gap between frames, so the camera moves the background where
  # it is written.
  def test_the_camera_moves_a_tiled_screen_with_no_game_loop
    prog = program do
      screen :tiled
      image(:stripe, "#" => :red, "." => :blue) { (["####...."] * 8).join("\n") }
      tiles :ground, "#" => :stripe
      background :field, tiles: :ground, map: (["#" * 32] * 20)
      camera 2, 0
      halt
    end
    i = game_player.run(prog)

    assert_equal 2, stripes_moved(i.screen, 30)
  end

  # The score is the part of the screen that stays still, as a status bar does: its letters are
  # where they were written, whatever the camera does.
  def test_the_camera_leaves_tiled_text_where_it_was_written
    moved, still = [2, 0].map do |across|
      prog = program do
        screen :tiled
        image(:stripe, "#" => :red, "." => :blue) { (["####...."] * 8).join("\n") }
        tiles :ground, "#" => :stripe
        background :field, tiles: :ground, map: (["#" * 32] * 20)
        draw_text "SCORE", 40, 100, :white
        game_loop { camera across, 0 }
      end
      screen = game_player.run(prog, frames: 4).screen
      (40...80).flat_map { |x| (100...108).map { |y| screen.pixel(x, y) == WHITE } }
    end

    assert_includes still, true, "the text is on screen"
    assert_equal still, moved
  end

  # The camera on its own: the whole picture, on top of the game's own scroll.
  def test_the_camera_moves_a_scrolled_tiled_screen_further
    prog = program do
      screen :tiled
      image(:stripe, "#" => :red, "." => :blue) { (["####...."] * 8).join("\n") }
      tiles :ground, "#" => :stripe
      field = background :field, tiles: :ground, map: (["#" * 32] * 20)
      image(:hero, "#" => :green) { (["########"] * 8).join("\n") }
      sprite :hero, at: [100, 60]
      game_loop do
        field.scroll_to 1, 0
        camera 2, 0
      end
    end
    i = game_player.run(prog, frames: 4)

    assert_equal [98, 60], sprite_corner(i.screen), "the sprite moves with the camera alone"
    assert_equal 3, stripes_moved(i.screen, 30), "the background moves by its scroll and the camera together"
  end

  # --- the guardrail ---

  # A shake needs frames to happen on. With no game loop the routine is never
  # reached, so the counter is set and the screen sits perfectly still — silently.
  def test_a_shake_with_no_game_loop_is_caught
    prog = program do
      screen :bitmap
      clear_screen :blue
      shake_screen intensity: 4, frames: 8
      halt
    end

    findings = VBlank::Effects::Packs::ScreenShake::NeedsGameLoop.new.detect(prog)

    assert_equal 1, findings.size
    assert_match(/game_loop/, findings.first.message)
    assert_equal :__shake_left, findings.first.node.var,
                 "it blames the line where shake_screen was written"
  end

  def test_a_shake_inside_a_game_loop_is_not_flagged
    assert_empty VBlank::Effects::Packs::ScreenShake::NeedsGameLoop.new.detect(shaking_game(frames: 6))
  end

  def test_a_game_that_never_shakes_is_not_flagged
    prog = program { screen :bitmap; clear_screen :blue; halt }

    assert_empty VBlank::Effects::Packs::ScreenShake::NeedsGameLoop.new.detect(prog)
  end

  # The shake moving the picture on the Advance's cartridge and putting it back, read in the
  # emulator, is in test/lowering/gba/vblank/builder/test_camera_shake_cartridge.rb.
end
