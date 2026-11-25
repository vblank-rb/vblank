# frozen_string_literal: true

require "test_helper"

# More than 128 sprites on one screen, on every run that plays games as the PlayStation. Its graphics
# chip draws whatever it is sent, and a game can keep places for 512 sprites there
# (Console::PLAYSTATION's sprite_places), so every sprite the frame shows is drawn, as the interpreter
# draws it. Not in test/all/: the Color, the Super Nintendo and the Genesis keep places for fewer.
#
# The build's table never runs out (PS1::Runtime::Tiles::MOST_SPRITES says why). It is filled from the
# sprite furthest back, so a sprite that found it full would be the one in front: these tests fill it,
# and pass a game with more places than it has rows to the build, which refuses it.
class TestManySpritesOnThePlayStation < Minitest::Test
  GREEN = Color.resolve(:green)
  DOT_ROWS = (["########"] * 8).join("\n")
  DOTS_ACROSS = 32
  DOT_STEP = 10
  COUNT = 140
  FULL = VBlank::Console::PLAYSTATION.sprite_places
  SCENE_SPRITES = 300

  def test_every_sprite_past_the_128th_is_drawn
    run = game_player.run(crowd_program(COUNT), frames: 3)

    assert_equal COUNT, run.sprites.length, "every sprite the frame shows"
    assert_equal GREEN, run.screen.pixel(*dot_middle(COUNT - 1)), "the last sprite declared"
  end

  # The table's every row taken: the sprite in front, the last placed, still finds one.
  def test_a_full_table_draws_the_sprite_in_front
    run = game_player.run(crowd_program(FULL), frames: 3)

    assert_equal FULL, run.sprites.length, "every sprite the frame shows"
    assert_equal GREEN, run.screen.pixel(*dot_middle(FULL - 1)), "the sprite in front"
  end

  def test_a_place_past_the_table_is_refused
    error = assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(crowd_program(FULL + 1), frames: 1) }

    assert_match(/places for #{FULL} sprites/, error.message)
  end

  # Two scenes of 300 sprites each, more than the table together: they are never up together, so each
  # frame places one scene's and the table holds them all. The second scene is up from frame 6 and the
  # first again from frame 12; 7, 8, 13 and 14 are the frames just after each change.
  def test_two_scenes_take_turns_past_the_table
    { 3 => :dot, 7 => :other_dot, 8 => :other_dot, 13 => :dot, 14 => :dot }.each do |frames, shown|
      run = game_player.run(two_scenes_program, frames: frames)

      assert_equal SCENE_SPRITES, run.sprites(shown).length, "frame #{frames}: every sprite of the scene up"
      assert_equal SCENE_SPRITES, run.sprites.length, "frame #{frames}: nothing of the other scene"
      assert_equal GREEN, run.screen.pixel(*dot_middle(SCENE_SPRITES - 1)), "frame #{frames}: the sprite in front"
    end
  end

  # Where dot +at+ stands, in rows of DOTS_ACROSS. Public: the game blocks call back for it.
  def dot_at(at) = [(at % DOTS_ACROSS) * DOT_STEP, (at / DOTS_ACROSS) * DOT_STEP]

  private def dot_middle(at) = dot_at(at).map { |side| side + 4 }

  private def built(&game)
    b = Builder.new
    b.instance_eval(&game)
    b.finalize_program
    b.program
  end

  private def crowd_program(count)
    test = self
    built do
      screen :tiled
      image(:dot, "#" => :green) { DOT_ROWS }
      count.times { |i| sprite :dot, at: test.dot_at(i) }
      game_loop {}
    end
  end

  # The first scene until frame 6, the second until frame 12, the first again.
  private def two_scenes_program
    test = self
    count = SCENE_SPRITES
    built do
      screen :tiled
      image(:dot, "#" => :green) { DOT_ROWS }
      image(:other_dot, "#" => :green) { DOT_ROWS }
      frame = 0
      scene_up = 0
      scene(:first) { count.times { |i| sprite :dot, at: test.dot_at(i) } }
      scene(:second) { count.times { |i| sprite :other_dot, at: test.dot_at(i) } }
      game_loop do
        frame += 1
        scene_up = 1 if frame == 6
        scene_up = 0 if frame == 12
        call({ 0 => :first, 1 => :second }, number: :scene_up)
      end
    end
  end
end
