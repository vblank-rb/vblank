# frozen_string_literal: true

require "test_helper"
require "stringio"

# A PLAYING STARTED FROM A GAME AND NOT A CARTRIDGE, AND A SEED PER PLAYING. A way that runs the game
# itself (the interpreter, the game as C, its rules alone) needs only the checked program, so a game
# handed to a playthrough is checked and never lowered, measured or assembled. And a playing can
# start the game's random numbers somewhere else, with no build for each seed: its seed is added to
# them once the game has set itself up, as a match adds its seed (Reference#play_as_match).
class TestPlaythroughSeed < Minitest::Test
  runs_on_the_main_ractor! # a run in another process hangs inside a Ractor

  # The game picks `seed 7` for itself, and from its second pass draws a number each pass.
  private def dice
    VBlank.game("DICE", consoles: %i[gba]) do
      seed 7
      passes = var :passes, 0
      drawn = var :drawn, 0
      game_loop do
        drawn = rand(0..9999) if passes.positive?
        passes += 1
      end
    end
  end

  private def roll = VBlank::Playthroughs::Playthrough.new("roll") { wait frames: 6 }

  # Every phase a build begins, by name.
  class Phases < VBlank::Messages::Progress
    attr_reader :names

    def initialize
      super
      @names = []
    end

    def step(name) = @names << name
  end

  private def drawn(on, seed: nil, game: dice) = roll.play(game, on: on, seed: seed).game.var(:drawn)

  def test_a_game_plays_on_the_rules_alone_without_its_cartridge
    building = Phases.new
    dice.build_rom(out: StringIO.new, err: StringIO.new, progress: building)
    checking = Phases.new
    unbuilt = VBlank::Playthroughs::UnbuiltGame.of(dice, err: StringIO.new, progress: checking)

    assert_equal drawn("interpreter"), drawn("logic", game: unbuilt)
    assert_empty checking.names - building.names
    assert_empty checking.names & ["Building once to measure", "Measuring each scene", "Compiling", "Assembling cartridge"]
    assert_equal 1, checking.names.count("Reading game"), "the game is read once, and a measured build reads it twice"
  end

  def test_a_game_handed_to_a_playthrough_is_checked_for_the_way_it_plays_on
    assert_equal drawn("interpreter"), drawn("logic")
  end

  def test_a_seed_changes_what_the_game_draws
    refute_equal drawn("interpreter", seed: 1), drawn("interpreter", seed: 2)
    assert_equal drawn("interpreter"), drawn("interpreter", seed: 0)
  end

  # One game checked once, eight seeds, on the rules alone and the game as C: each draws what the
  # interpreter draws on the same seed.
  def test_a_sweep_of_seeds_on_one_check_draws_as_the_interpreter_does
    unbuilt = VBlank::Playthroughs::UnbuiltGame.of(dice, err: StringIO.new)
    seeds = (1..8).to_a
    wanted = seeds.map { |seed| drawn("interpreter", seed: seed, game: unbuilt) }

    assert_equal wanted, seeds.map { |seed| drawn("logic", seed: seed, game: unbuilt) }
    assert_equal wanted, seeds.map { |seed| drawn("native", seed: seed, game: unbuilt) }
    assert_equal seeds.size, wanted.uniq.size
  end

  def test_a_seed_on_the_cartridge_is_refused
    cartridge = dice.build_rom(out: StringIO.new, err: StringIO.new)
    error = assert_raises(ArgumentError) { roll.play(cartridge, seed: 3) }

    assert_match(/seed/, error.message)
    assert_match(/logic/, error.message)
  end

  def test_a_seed_on_a_way_that_cannot_take_one_is_refused
    error = assert_raises(ArgumentError) { roll.play(dice, on: "web", seed: 3) }

    assert_match(/web/, error.message)
    assert_match(/interpreter/, error.message)
  end

  def test_a_seed_that_is_not_a_whole_number_is_refused
    error = assert_raises(ArgumentError) { roll.play(dice, on: "logic", seed: "4") }

    assert_match(/whole number/, error.message)
  end

  def test_a_game_on_the_emulator_is_refused_saying_to_build_it
    error = assert_raises(ArgumentError) { roll.play(dice) }

    assert_match(/build_rom/, error.message)
  end

  def test_the_tape_of_a_seeded_playing_says_its_seed_and_plays_it_again
    played = roll.play(dice, on: "interpreter", seed: 5)
    tape = VBlank::Playthroughs::Tape.parse(played.tape.to_s)

    assert_includes played.tape.to_s, "\nseed: 5\n"
    assert_equal 5, tape.seed
    assert_equal played.game.var(:drawn), tape.play(dice, on: "logic").game.var(:drawn)
  end

  def test_a_seeded_tape_on_the_cartridge_is_refused
    tape = roll.play(dice, on: "interpreter", seed: 5).tape
    cartridge = dice.build_rom(out: StringIO.new, err: StringIO.new)
    error = assert_raises(ArgumentError) { tape.play(cartridge) }

    assert_match(/seed 5/, error.message)
  end
end
