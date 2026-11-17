# frozen_string_literal: true

require "test_helper"
require "stringio"

# A TITLE WHOSE SPRITES ARE DRAWN IN AN ORDER THE GAME WORKS OUT, and a later scene with sprites
# of its own. A Genesis places the sprites that show on every pass, back to front, into a table of
# 80 rows, so the title's sprites take no row while the other scene is up, whatever their order.
# Together the two scenes declare more sprites than the table holds; each alone fits.
class TestGenesisOrderedSpriteScenes < Minitest::Test
  TITLE_SPRITES = 50
  ROOM_SPRITES = 34
  SWITCH_AT = 4

  VBlank::Testing::InRactors.share_constants(self)

  def self.game
    VBlank.game("ORDERED SCENES", consoles: %i[genesis]) do
      screen :tiled
      image(:dot, "#" => :red, "." => :blue) { (["#.#.#..#"] * 8).join("\n") }
      image(:blob, "#" => :green, "." => :yellow) { (["##..##.."] * 8).join("\n") }
      t = var :t, 0
      state = var :state, 0
      scene(:title) do
        actors = Array.new(TITLE_SPRITES) do |i|
          sprite :"actor_#{i}", at: [(i % 10) * 30, (i / 10) * 40 + ((t + i) & 15)], facing: { down: :dot }
        end
        draw_in_order(*actors)
      end
      scene(:room) do
        Array.new(ROOM_SPRITES) { |i| sprite :"thing_#{i}", at: [(i % 17) * 18, (i / 17) * 60 + 20], facing: { down: :blob } }
      end
      game_loop do
        t += 1
        state.store! 1 if t == SWITCH_AT
        case_var(:state) do
          when_val 0, :title
          when_val 1, :room
        end
      end
    end
  end

  def test_the_title_and_the_room_build_though_together_they_declare_more_sprites_than_the_table_holds
    rom = TestGenesisOrderedSpriteScenes.game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)

    refute_nil rom
  end

  def test_both_scenes_show_what_the_interpreter_shows
    game_player.run(TestGenesisOrderedSpriteScenes.game.program(console: :genesis), frames: SWITCH_AT + 4)
  end
end
