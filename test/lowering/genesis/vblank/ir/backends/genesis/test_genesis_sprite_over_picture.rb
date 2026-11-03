# frozen_string_literal: true

require "test_helper"

# A SPRITE OVER A PAINTED PICTURE ON A GENESIS (`sprite ..., over_picture: true`): a sprite of the tiled
# screen's kind, placed over the plane the painted picture is on (Genesis::Runtime::Paint). The picture
# keeps the first palette and most of video RAM, so the sprites have the other three palettes and the
# tiles between the picture's and the scroll table. What the sprite does, asked of every run, is in
# test/all/vblank/builder/test_sprite_over_picture.rb.
class TestGenesisSpriteOverPicture < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  STRIPES = "RRRRRRRR\nRRRRRRRR\nGGGGGGGG\nGGGGGGGG\nBBBBBBBB\nBBBBBBBB\n........\n........"

  # A fade darkens the sprite's palette with the picture's, and moving the view over the picture leaves
  # the sprite where it is on the screen. The checked run compares the picture on every pass.
  def test_a_fade_reaches_the_sprite_and_the_camera_leaves_it_still
    program = program_of do
      image(:stripes, "R" => :red, "G" => :green, "B" => :blue, "." => :transparent) { STRIPES }
      sprite :stripes, at: [100, 60], over_picture: true
      level = var :level, 0
      game_loop do
        clear_screen :cyan
        fill_rect 96, 56, 40, 40, :yellow
        level += 4
        fade :black, level
        camera 12, 6
      end
    end

    Genesis::CheckedRun.new.run(program, frames: 20)
  end

  # The painted picture takes tiles 1 to 1120 of video RAM, so the sprites' pictures have 350 tiles, not
  # the 1471 a tiled screen gives them: more stops the build in plain words.
  def test_sprite_pictures_past_the_room_beside_a_painted_screen_stop_the_build
    error = assert_raises(Genesis::LoweringError) { Genesis.new.build(too_much_over_picture) }

    assert_match(/painted screen/, error.message)
    assert_match(/350/, error.message)
  end

  # A Genesis cannot turn or resize a sprite, over a painted picture as anywhere.
  def test_a_sprite_over_the_picture_turned_is_refused_in_words
    said = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("TURNED", console: :genesis, out: said, err: said) do
        screen :bitmap
        image(:stripes, "R" => :red, "G" => :green, "B" => :blue, "." => :transparent) { STRIPES }
        gun = sprite :stripes, at: [100, 60], over_picture: true
        gun.face_angle(90)
        game_loop { clear_screen :cyan }
      end
    end

    assert_match(/turns or resizes .* Sega Genesis cannot/, said.string)
  end

  private

  # Twelve 64x64 pictures in one list of colours, every 8×8 square of them different: 768 tiles. Each
  # square spells its own number in its first pixels, a colour for each two bits.
  def too_much_over_picture
    program_of do
      colors :art, %i[transparent red green blue white]
      12.times do |k|
        places = Array.new(64 * 64) do |at|
          x = at % 64
          y = at / 64
          square = (k * 64) + ((y / 8) * 8) + (x / 8)
          1 + ((square >> (2 * ((((y % 8) * 8) + (x % 8)) % 5))) & 3)
        end
        image(:"big#{k}", width: 64, height: 64, colors: :art, places: places)
        sprite :"big#{k}", at: [k * 4, 0], over_picture: true
      end
      game_loop { clear_screen :black }
    end
  end

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
