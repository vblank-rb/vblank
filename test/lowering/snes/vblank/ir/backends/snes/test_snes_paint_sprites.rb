# frozen_string_literal: true

require "test_helper"
require "stringio"

# SPRITES OVER A PAINTED SCREEN ON THE SUPER NINTENDO (Runtime::Paint, "SPRITES OVER THE PICTURE"):
# their tiles go in the last of video memory, which the painted screen leaves, their colours in
# places of the colour memory the painting keeps clear of, and the blank sends the sprite table
# with the map. What the sprite does on the screen is test/all/vblank/builder/test_sprite_over_picture.rb
# and test/console/snes/vblank/builder/test_sprite_over_picture_on_the_super_nintendo.rb.
class TestSNESPaintSprites < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  STRIPES = "RRRRRRRR\nRRRRRRRR\nGGGGGGGG\nGGGGGGGG\nBBBBBBBB\nBBBBBBBB\n........\n........"
  STRIPE_COLORS = { "R" => :red, "G" => :green, "B" => :blue, "." => :transparent }.freeze

  # A field cleared and a small box drawn every pass, as a game over a painted room does, and
  # +with_sprite+ a sprite over it that moves three pixels a pass.
  private def clear_and_draw_game(with_sprite:)
    VBlank.game(with_sprite ? "OVER SPRITE" : "OVER NONE", consoles: %i[snes]) do
      screen :bitmap
      image(:stripes, STRIPE_COLORS) { STRIPES }
      gun = sprite(:stripes, at: [40, 60], over_picture: true) if with_sprite
      x = var :x, 20
      game_loop do
        clear_screen :blue
        draw_rect_at x, 21, 30, 30, :yellow
        x += 1
        x.store!(20) if x > 200
        gun.x += 3 if with_sprite
      end
    end
  end

  # The sprite table goes with the map, so a pass that clears and draws a little, with a sprite
  # moving over it, still takes the one frame it takes on the interpreter, and no frame is black.
  def test_a_sprite_moving_over_a_pass_that_clears_takes_one_frame
    program = clear_and_draw_game(with_sprite: true).program(console: :snes)
    SNES::CheckedRun.new.run(program, frames: 8)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 8)

    assert_empty run.black_frames
    assert_equal [1] * 7, (2..8).map { |pass| run.frames_took(pass) }
  end

  FRAMES = 30

  private def awake_share(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, frames: FRAMES).idle_share
  end

  # THE BUDGET for a sprite over the picture is what a tiled screen spends on the same sprite, and
  # the sprite table sent in the blank, which a tiled screen sends whether it shows a sprite or not.
  # The sprite: placed in the table each pass and the row the last pass wrote hidden again, as on a
  # tiled screen (Runtime::Picture's rt_sprite_place), measured there as the same game on a tiled
  # screen with and without the sprite. The table: 544 bytes, which hold the processor while the
  # copying engine moves them, eight of the master clock's 1364 a line for each byte (fullsnes,
  # "SNES DMA"), so about three and a half of a frame's 262 lines. The two come to about the same,
  # and the budget is both with room for the blank's look at the line before the copy.
  MOST_SHARE_SPRITE_OVER_PICTURE = 0.03

  def test_a_sprite_over_the_picture_costs_its_table_in_the_blank
    none = awake_share(clear_and_draw_game(with_sprite: false))
    sprite = awake_share(clear_and_draw_game(with_sprite: true)) - none

    assert_operator sprite, :<, MOST_SHARE_SPRITE_OVER_PICTURE, "a sprite over the picture costs #{(sprite * 100).round(3)}% of a frame"
  end

  # +count+ colours painted, each a square, and +with_sprite+ a sprite of three colours over them.
  private def colourful(count, with_sprite:)
    program_of do
      screen :bitmap
      image(:stripes, STRIPE_COLORS) { STRIPES }
      sprite :stripes, at: [100, 200], over_picture: true if with_sprite
      game_loop do
        count.times { |i| fill_rect (i % 20) * 12, (i / 20) * 12, 12, 12, (i * 97) + 1 }
      end
    end
  end

  # The sprite's set of colours takes sixteen places of the 256, so 250 colours painted fit
  # without a sprite and are refused with one, in words that say why.
  def test_colours_past_what_the_sprites_leave_are_refused_in_plain_words
    SNES.new.build(colourful(250, with_sprite: false))
    error = assert_raises(SNES::LoweringError) { SNES.new.build(colourful(250, with_sprite: true)) }

    assert_match(/sprites over the picture take 16/, error.message)
  end

  # The painted screen leaves 124 sprite tiles: more different 8×8 squares stop the build in
  # words that name the room.
  def test_sprite_pictures_past_the_room_beside_a_painted_screen_stop_the_build
    error = assert_raises(SNES::LoweringError) { SNES.new.build(too_much_over_picture) }

    assert_match(/painted screen/, error.message)
    assert_match(/124/, error.message)
  end

  # A Super FX's painted screen does not carry the sprite table yet, and says so.
  def test_a_sprite_over_a_picture_on_the_super_fx_is_refused_in_plain_words
    program = clear_and_draw_game(with_sprite: true).program(console: :snes).tap { |game| game.variant = :superfx }
    error = assert_raises(SNES::LoweringError) { SNES.new.build(program) }

    assert_match(/Super FX/, error.message)
  end

  private

  # Three 48x48 pictures in one list of colours, every 8×8 square of them different: 108 tiles,
  # and a fourth of 32x32: 16 more, 124. One more square is past the room.
  def too_much_over_picture
    program_of do
      screen :bitmap
      colors :art, %i[transparent red green blue white]
      sizes = [48, 48, 48, 32, 8]
      sizes.each_with_index do |side, k|
        places = Array.new(side * side) do |at|
          x = at % side
          y = at / side
          square = (k * 64) + ((y / 8) * 8) + (x / 8)
          1 + ((square >> (2 * ((((y % 8) * 8) + (x % 8)) % 5))) & 3)
        end
        image(:"big#{k}", width: side, height: side, colors: :art, places: places)
        sprite :"big#{k}", at: [k * 40, 0], over_picture: true
      end
      game_loop { clear_screen :black }
    end
  end

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end
end
