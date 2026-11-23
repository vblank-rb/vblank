# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# Every kind the IR has is one the PlayStation lowering makes (a row of its tables), one it says it
# does not make yet, by what it is part of, or one it refuses because a PlayStation cannot do it —
# and what it does not make is refused by name before anything is built.
class TestPS1KindCoverage < Minitest::Test
  Nodes = VBlank::IR::Nodes
  Portability = VBlank::IR::Portability
  PS1 = VBlank::IR::Backends::PS1
  Lowering = PS1::Lowering

  private def portable_kinds
    (Nodes.of_role(:statement) + Nodes.of_role(:value) + Nodes.of_role(:declaration))
      .reject { |kind| Portability.hardware_only?(kind) }
  end

  private def not_yet = Lowering::NOT_LOWERED_YET.values.flatten

  private def made = Lowering::STATEMENT_KINDS + Lowering::VALUE_KINDS

  # The kinds a PlayStation cannot do at all, as its answers say of the conformance fixture,
  # which touches every kind: the build refuses them by those words, so the lowering never meets one.
  private def refused
    VBlank::Console::PS1Answers.refusals(ConformanceFixture.program.walk.to_a, VBlank::Console.described(:ps1))
                                .map { |refusal| refusal.node.kind }.uniq
  end

  private def ps1_program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end

  # A game of a field of stripes on a screen drawn from tiles, then +play+ each pass.
  private def on_tiles(&play)
    proc do
      screen :tiled
      image(:stripe, "#" => :red, "." => :blue) { (["####...."] * 8).join("\n") }
      image(:hero, "#" => :green) { (["########"] * 8).join("\n") }
      tiles :ground, "#" => :stripe
      background :field, tiles: :ground, map: ["#" * 32] * 20
      instance_exec(&play)
    end
  end

  # A painted screen, then +play+ each pass.
  private def on_paint(&play)
    proc do
      screen :bitmap
      image(:pic, "#" => :green) { (["########"] * 8).join("\n") }
      instance_exec(&play)
    end
  end

  # A one-line game of each verb VERBS_NOT_MADE_YET lists.
  private def not_made_yet_games
    {
      draw_column_at: on_paint { game_loop { draw_column_at :pic, slice: 0, x: 10, top: 10, height: 8 } },
      camera: on_paint { game_loop { camera 2, 2 } },
      shake_screen: on_paint { game_loop { shake_screen intensity: 3, frames: 8 } },
      pixelate: on_tiles { game_loop { pixelate 4 } },
      pixelate_in: on_tiles { game_loop { pixelate_in } },
      pixelate_out: on_tiles { game_loop { pixelate_out } },
      spotlight: on_tiles { game_loop { spotlight at: [120, 80], radius: 40, dark: 75 } },
      iris_in: on_tiles { game_loop { iris_in } },
      iris_out: on_tiles { game_loop { iris_out } },
      pulse: on_tiles { hero = sprite(:hero, at: [100, 60]); game_loop { pulse hero, to: 2 } },
      canvas: proc do
        screen :tiled
        board = canvas :board, width: 16, height: 8, colors: %i[transparent white black]
        background :front, tiles: :board, map: board.cells
        game_loop { board.clear :white }
      end,
      tile_pictures: proc do
        screen :tiled
        colors :pond, %i[transparent red blue]
        image :red_tile, width: 8, height: 8, colors: :pond, places: Array.new(64, 1)
        image :blue_tile, width: 8, height: 8, colors: :pond, places: Array.new(64, 2)
        water = tile_pictures :water, colors: :pond, tiles: { left: %i[red_tile blue_tile] }
        tiles :field, "l" => water[:left]
        background :ground, tiles: :field, map: ["ll"]
        game_loop { wait_vblank }
      end,
      sprite_tiles: proc do
        screen :tiled
        colors :ball, %i[white red]
        image :reds, width: 8, height: 8, colors: :ball, places: Array.new(64, 1)
        set = sprite_tiles :ball_tiles, count: 1, colors: :ball
        image :spin, tiles_from: :ball_tiles, pieces: [[0, 0, 0]]
        sprite :ball, at: [40, 20], facing: { spin: :spin }
        set.copy_from :reds, at: 0, count: 1, to: 0
        game_loop { wait_vblank }
      end,
      picture_groups: on_tiles do
        rooms = picture_groups :rooms, { 0 => %i[hero], 1 => %i[stripe] }
        look = var :look, 0
        rooms.show look
        boat = sprite :boat, facing: { hero: :hero, stripe: :stripe }, at: [40, 40]
        game_loop { boat.face %i[hero stripe], showing: look }
      end,
      save_var: on_tiles { best = save_var(:best, 0); game_loop { best += 1 } },
      save_data: on_tiles do
        hearts = var :hearts, 3
        file = save_data(:file) { keep hearts }
        game_loop { file[0].save }
      end,
      saves_keep_everything: on_tiles do
        hearts = var :hearts, 3
        file = save_data(:file) { keep hearts }
        saves_keep_everything
        game_loop { file[0].save }
      end
    }
  end

  def test_the_not_yet_list_names_only_kinds_that_exist
    assert_empty not_yet - portable_kinds
  end

  # The page names the verbs that wait on each part the lowering does not make yet, and each is a verb
  # the answers table answers.
  def test_the_page_names_verbs_for_every_part_not_made_yet
    verbs = VBlank::Console::PS1Answers::VERBS_NOT_MADE_YET

    assert_equal Lowering::NOT_LOWERED_YET.keys.sort, verbs.keys.sort
    assert_empty verbs.values.flatten - VBlank::Console::PS1Answers::ANSWERS.keys
  end

  # A verb that waits on a part not made yet works on the console, so its answer is "works", and
  # the answer itself tells the reader the build does not make it yet.
  def test_every_verb_not_made_yet_says_so_in_its_answer
    VBlank::Console::PS1Answers::VERBS_NOT_MADE_YET.values.flatten.each do |verb|
      assert_match(/does not make/, VBlank::Console::PS1Answers.words_of(verb), "the answer for `#{verb}`")
    end
  end

  # Verbs whose one-line game is another's: camera_follows moves the camera that `camera` does.
  SAME_GAME_AS_ANOTHER = %i[camera_follows].freeze

  # A one-line game of each verb the page says waits on a part is refused, naming that part, so the
  # page cannot keep a verb on the list after the build makes it, nor list a verb the build makes.
  def test_a_game_of_each_verb_not_made_yet_is_refused_naming_its_part
    verbs = VBlank::Console::PS1Answers::VERBS_NOT_MADE_YET

    assert_empty verbs.values.flatten - not_made_yet_games.keys - SAME_GAME_AS_ANOTHER
    not_made_yet_games.each do |verb, game|
      error = assert_raises(Lowering::NotMadeYet, "a game of `#{verb}`") { PS1.new.build(ps1_program(&game)) }

      assert_equal verbs.find { |_, listed| listed.include?(verb) }.first, error.part, "the part `#{verb}` waits on"
    end
  end

  def test_no_kind_is_listed_twice
    assert_equal not_yet.uniq, not_yet
  end

  def test_every_kind_is_made_listed_or_refused
    assert_empty portable_kinds - made - not_yet - refused - %i[else]
  end

  def test_no_kind_is_both_made_and_not_made_yet
    assert_empty made & not_yet
  end

  # A kind the answers refuse only in part (a fade of part of the screen) is not made yet at all
  # while its whole is still to come; the day it is made it leaves this list, and the exemption.
  REFUSED_IN_PART_AND_NOT_MADE = %i[fade see_through].freeze

  def test_no_kind_is_both_refused_and_not_made_yet
    assert_empty((refused & not_yet) - REFUSED_IN_PART_AND_NOT_MADE)
  end

  # The conformance fixture touches every kind, some of which a PlayStation cannot do, so building
  # it is refused, saying what the PlayStation cannot do.
  def test_the_whole_fixture_is_refused_saying_why
    error = assert_raises(PS1::LoweringError) { PS1.new.build(ConformanceFixture.program) }

    assert_match(/PlayStation/, error.message)
  end
end
