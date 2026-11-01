# frozen_string_literal: true

require "test_helper"

# A STATUS BAR COVERING SPRITES ON THE COLOR (Runtime::Picture#emit_bar_covers). The display's sprite
# layer is switched off partway down each frame, and how that happens depends on what else the
# frame is doing. `test_status_bar.rb` plays the plain case on every lowering.
class TestGBCBarCoversSprites < Minitest::Test
  WHITE = 0x7FFF
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BAR_TOP = 128

  # A white sprite half over a green bar that covers it, on a field. +work+ is how many steps each
  # pass does; the block is handed the field.
  private def covering_bar(work: 0)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      image(:ball, "#" => :white) { Minitest::Test::SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      field = background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      yield field if block_given?
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: BAR_TOP
      sprite :ball, at: [40, BAR_TOP - 4]
      count = 0
      bar.covers_sprites = true
      game_loop { repeat(work) { count += 1 } if work.positive? }
    end
    b.finalize_program
    b.program
  end

  # Whether the sprite shows above the bar and not on it, on each of +frames+ frames of the cartridge.
  private def frames_with_sprite_cut_at_the_bar(program, frames)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "BARCOVER")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 30)
    Array.new(frames) do
      v.step
      v.pixel_gba(42, BAR_TOP - 2) == WHITE && v.pixel_gba(42, BAR_TOP + 2) == GREEN
    end
  end

  # A SCREEN WITH BENT ROWS has the display's interrupt on every line, so the switch is made there.
  def test_a_bar_covers_sprites_on_a_screen_with_bent_rows
    program = covering_bar { |field| field.scroll_each_row { |row| row % 4 } }

    assert_equal [true], frames_with_sprite_cut_at_the_bar(program, 12).uniq
  end

  # A PASS RUNNING LATE leaves a blank with no switches written, and the sprites must come back for
  # the top of the frame all the same.
  def test_a_bar_covers_sprites_on_a_game_whose_passes_run_late
    assert_equal [true], frames_with_sprite_cut_at_the_bar(covering_bar(work: 2500), 40).uniq
  end
end
