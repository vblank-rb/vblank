# frozen_string_literal: true

require "test_helper"

# A GROUP OF TILE PICTURES IN ALL FOUR COLOURS OF A COLOR PALETTE. Its list is see-through first,
# never drawn, and four solid after, none of them the backdrop. The first of the four shows, not
# the backdrop, and the group fades through a list of its own beside tiles of another.
class TestTilePicturesOfFourSolidColors < Minitest::Test
  private def field
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      colors :field, %i[transparent white red green blue]
      colors :board, %i[transparent yellow orange cyan white]
      colors :board_dim, %i[transparent red green blue black]
      image :plain, width: 8, height: 8, colors: :field, places: Array.new(64) { |at| (at % 4) + 1 }
      image :first, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| (at % 4) + 1 }
      image :second, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| ((at + 1) % 4) + 1 }
      group = tile_pictures :billboard, tiles: { a: %i[first second] }, colors: :board
      tiles :set, "." => :plain, "a" => group[:a]
      ground = background :ground, tiles: :set, map: ["..a."]
      pass = var :pass, 0
      game_loop do
        pass += 1
        group.show(pass / 8 % 2)
        ground.draw_with({ board: :board_dim }) if pass == 12
      end
    end
    b.finalize_program
    b.program
  end

  # Two groups that start in the same colours and are told different ones later.
  private def twins
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      colors :left, %i[transparent white red green blue]
      colors :right, %i[transparent white red green blue]
      colors :left_late, %i[transparent yellow orange cyan white]
      colors :right_late, %i[transparent red green blue black]
      image :left_one, width: 8, height: 8, colors: :left, places: Array.new(64) { |at| (at % 4) + 1 }
      image :right_one, width: 8, height: 8, colors: :right, places: Array.new(64) { |at| (at % 4) + 1 }
      left = tile_pictures :left_board, tiles: { a: %i[left_one] }, colors: :left
      right = tile_pictures :right_board, tiles: { b: %i[right_one] }, colors: :right
      tiles :set, "a" => left[:a], "b" => right[:b]
      ground = background :ground, tiles: :set, map: ["ab"]
      pass = var :pass, 0
      game_loop do
        pass += 1
        ground.draw_with({ left: :left_late, right: :right_late }) if pass == 6
      end
    end
    b.finalize_program
    b.program
  end

  # A title that fills the console's lists, seven solid ones and black for an empty cell, and a
  # group in another scene.
  private def full_title_beside_group
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      7.times do |list|
        colors :"title#{list}", [:transparent, rgb((list * 3) + 1, 0, 0), rgb(0, (list * 3) + 1, 0), rgb(0, 0, (list * 3) + 1)]
        image :"title_tile#{list}", width: 8, height: 8, colors: :"title#{list}", places: Array.new(64) { |at| (at % 3) + 1 }
      end
      tiles :title_set, Array.new(7) { |list| ["abcdefg"[list], :"title_tile#{list}"] }.to_h
      colors :board, %i[transparent yellow orange cyan white]
      image :first, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| (at % 4) + 1 }
      image :second, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| ((at + 1) % 4) + 1 }
      passes = var :passes, 0
      state = var :state, 0
      scene(:title) { background :words, tiles: :title_set, map: ["abcdefg"] }
      scene(:field) do
        group = tile_pictures :billboard, tiles: { a: %i[first second] }, colors: :board
        tiles :field_set, "a" => group[:a]
        background :ground, tiles: :field_set, map: ["aa"]
        group.show(passes / 4 % 2)
      end
      game_loop do
        passes += 1
        state = 1 if passes == 6
        case_var(:state) do
          when_val 0, :title
          when_val 1, :field
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_group_in_one_scene_takes_no_list_from_another_scene
    game_player.run(full_title_beside_group, frames: 20)
    pass
  end

  def test_the_group_shows_its_four_colours_and_fades_as_the_interpreter_shows_them
    game_player.run(field, frames: 24)
    pass
  end

  def test_two_groups_that_start_alike_can_be_told_different_colours
    game_player.run(twins, frames: 12)
    pass
  end
end
