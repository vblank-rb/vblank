# frozen_string_literal: true

require "test_helper"

# A GROUP OF TILE PICTURES ON THE COLOR is held in the Color's own form, so showing a picture is a
# copy, with no tile turned from one form to the other as the game plays. Two groups of 24 tiles,
# each picture of a colour of its own, change together, and a cell changes beside them.
class TestTilePicturesOnTheColor < Minitest::Test
  TILES = 24
  PICTURES = 3

  private def billboard
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :warm, %i[transparent red yellow white]
      colors :cool, %i[transparent blue green white]
      board = { warm: {}, cool: {} }
      board.each_key do |list|
        TILES.times do |tile|
          board[list][tile] = Array.new(PICTURES) do |picture|
            name = :"#{list}_#{tile}_#{picture}"
            image name, width: 8, height: 8, colors: list, places: Array.new(64) { |place| ((place + picture) % 3) + 1 }
            name
          end
        end
      end
      warm = tile_pictures :warm_board, tiles: board[:warm], colors: :warm
      cool = tile_pictures :cool_board, tiles: board[:cool], colors: :cool
      image(:sky, "#" => :black) { (["#" * 8] * 8).join("\n") }
      keys = { "." => :sky }
      TILES.times do |tile|
        keys["abcdefghijklmnopqrstuvwx"[tile]] = warm[tile]
        keys["ABCDEFGHIJKLMNOPQRSTUVWX"[tile]] = cool[tile]
      end
      tiles :field, keys
      ground = background :ground, tiles: :field, map: ["abcdef", "ghijkl", "mnopqr", "stuvwx", "ABCDEF"]
      pass = var :pass, 0
      game_loop do
        pass += 1
        which = (pass / 4) % PICTURES
        warm.show which
        cool.show which
        if pass % 8 < 4
          ground.set_tile 0, 4, "A"
        else
          ground.set_tile 0, 4, "a"
        end
      end
    end
    b.finalize_program
    b.program
  end

  # More pictures than the part of the cartridge always in view holds: 2 × 24 × 21 tiles of 16 bytes.
  private def too_many_for_the_view
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :warm, %i[transparent red yellow white]
      colors :cool, %i[transparent blue green white]
      board = {}
      %i[warm cool].each do |list|
        3.times { |look| image :"#{list}_#{look}", width: 8, height: 8, colors: list, places: Array.new(64) { |place| ((place + look) % 3) + 1 } }
        board[list] = Array.new(24) { |tile| [tile, Array.new(21) { |picture| :"#{list}_#{picture % 3}" }] }.to_h
      end
      warm = tile_pictures :warm_board, tiles: board[:warm], colors: :warm
      cool = tile_pictures :cool_board, tiles: board[:cool], colors: :cool
      tiles :field, "a" => warm[0], "b" => cool[0]
      background :ground, tiles: :field, map: ["abab"]
      pass = var :pass, 0
      game_loop do
        pass += 1
        warm.show((pass / 2) % 21)
        cool.show((pass / 3) % 21)
      end
    end
    b.finalize_program
    b.program
  end

  def test_pictures_too_many_for_the_part_always_in_view_are_kept_in_a_bank
    game_player.run(too_many_for_the_view, frames: 20)
    pass
  end

  def test_two_groups_show_on_the_console_as_the_interpreter_shows_them
    game_player.run(billboard, frames: 40)
    pass
  end

  def test_showing_two_groups_keeps_a_frame_a_pass
    run = VBlank::IR::Backends::GBC::HeadlessRun.new.run(billboard, frames: 40)

    assert_empty (8...40).select { |pass| run.frames_took(pass) > 1 }
  end
end
