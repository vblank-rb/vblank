# frozen_string_literal: true

# SMALL BITMAP GAMES WITH A SPRITE SHOWN OVER THE PICTURE (`sprite ..., over_picture: true`), for
# the verb's tests through `game_player` (test/all/vblank/builder/test_sprite_over_picture.rb) and the
# Advance cartridge's own (test/lowering/gba/vblank/builder/test_sprite_over_picture_cartridge.rb).
# Each game paints its whole picture again on every pass, as a game drawing a 3D view does.
module SpriteOverPictureGames
  # An 8x8 sprite in bands of two rows, three colours and see-through last (what every console's
  # sprite can hold): a wrong copy shows as a wrong band, and the last band shows the picture.
  STRIPES = "RRRRRRRR\nRRRRRRRR\nGGGGGGGG\nGGGGGGGG\nBBBBBBBB\nBBBBBBBB\n........\n........"
  STRIPE_COLORS = { "R" => :red, "G" => :green, "B" => :blue, "." => :transparent }.freeze
  STRIPE_ROWS = %i[red green blue].freeze
  FIELD = :cyan # every channel full or empty, so each console shows it as it is
  START = [100, 60].freeze

  # A 16x16 sprite, red on its top half and blue on its bottom, for a turn or a size: its middle
  # stays where it is and the colours move round it.
  HALVES = Ractor.make_shareable(((["RRRRRRRRRRRRRRRR"] * 8) + (["BBBBBBBBBBBBBBBB"] * 8)).join("\n"))
  HALVES_AT = [100, 60].freeze

  # A field painted every pass, a yellow bar painted under the sprite's place every pass, and the
  # sprite over both, moved +step+ pixels right a pass. +tear_free+ asks for the two-page screen.
  private def over_picture_program(step: 0, tear_free: false)
    builder = VBlank::Builder.new
    builder.instance_eval do
      tear_free ? screen(:bitmap, tear_free: true) : screen(:bitmap)
      image(:stripes, STRIPE_COLORS) { STRIPES }
      gun = sprite :stripes, at: START, over_picture: true
      game_loop do
        clear_screen FIELD
        fill_rect 90, 58, 40, 12, :yellow
        gun.x += step if step.positive?
      end
    end
    builder.finalize_program
    builder.program
  end

  # An 8x8 ship over a painted field, left half the first colour of its list and right half the
  # second, told to draw with another list.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze
  SHIP_COLORS = %i[transparent red green].freeze
  HURT_COLORS = %i[transparent yellow white].freeze

  private def recolored_program
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      image :ship, width: 8, height: 8, data: SHIP, colors: SHIP_COLORS
      colors :hurt, HURT_COLORS
      ship = sprite :ship, at: [40, 40], over_picture: true
      game_loop do
        clear_screen FIELD
        ship.draw_with :hurt
      end
    end
    builder.finalize_program
    builder.program
  end

  # The halves sprite over a field painted every pass, told +change+ (a block given the sprite)
  # once, before the loop: a turn or a size.
  private def changed_program(tear_free: false, &change)
    builder = VBlank::Builder.new
    builder.instance_eval do
      tear_free ? screen(:bitmap, tear_free: true) : screen(:bitmap)
      image(:halves, "R" => :red, "B" => :blue) { HALVES }
      gun = sprite :halves, at: HALVES_AT, over_picture: true
      instance_exec(gun, &change)
      game_loop do
        clear_screen FIELD
      end
    end
    builder.finalize_program
    builder.program
  end
end
