# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a program's own settings ask of a console (Console::Questions#program_question), asked of
# every console's build at once, as test_refused_verbs.rb asks each refused verb.
class TestQuestions < Minitest::Test
  # Every console's build but the Genesis's writes the main volume to its sound chip
  # (test/main_volume_tests.rb). The Genesis's chips have none, so its build refuses a game that
  # names one, rather than play it at another loudness.
  def test_a_main_volume_is_refused_by_a_console_without_one
    consoles = VBlank::Console.kits.map(&:name).reject { |console| VBlank::Console.described(console).sets_main_volume }
    assert_equal [:genesis], consoles

    printed = StringIO.new
    error = assert_raises(VBlank::BuildError) do
      VBlank.build("MAINVOL", console: :genesis, out: StringIO.new, err: printed) do
        enable_sound main_volume: 96
        game_loop { nil }
      end
    end
    assert_match(/main volume/, "#{printed.string} #{error.message}")
  end

  # A cell written now is refused by a console whose video memory is written only between frames. A
  # plain background's refusal is in words about that background and the reason; only a status
  # bar's is about a bar.
  def test_a_background_cell_written_now_is_refused_in_words_about_the_background
    { snes: VBlank::Console::SNESAnswers, genesis: VBlank::Console::GenesisAnswers }.each do |console, answers|
      refusals = answers.refusals(program_for(console).walk, VBlank::Console.described(console)).map(&:words)
      background = refusals.find { |words| words.include?("background :room") }

      assert background, "#{console} refuses the background's cell: #{refusals.inspect}"
      assert_match(/between frames/, background)
      assert_match(/frame being drawn/, background)
      refute_match(/bar/, background)
    end
  end

  def test_a_status_bar_cell_written_now_is_still_refused_in_words_about_the_bar
    { snes: VBlank::Console::SNESAnswers, genesis: VBlank::Console::GenesisAnswers }.each do |console, answers|
      refusals = answers.refusals(program_for(console).walk, VBlank::Console.described(console)).map(&:words)

      assert(refusals.any? { |words| words.include?("a bar's cell") }, "#{console} refuses the bar's cell: #{refusals.inspect}")
    end
  end

  # A cell in front covers every sprite on the Color, so a sprite told `in_front: true` has nothing to go
  # over, and is told why.
  def test_a_sprite_in_front_on_the_color_is_refused_saying_why
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :red) { Minitest::Test::SOLID_TILE }
      sprite :dot, at: [0, 0], in_front: true
      game_loop { nil }
    end
    b.finalize_program
    program = b.program

    words = VBlank::Console::ColorAnswers.refusals(program.walk, VBlank::Console.described(:gbc)).map(&:words).join(" ")

    assert_match(/in_front: true/, words)
    assert_match(/over every sprite/, words)
  end

  # A background :room and a status bar, each with a cell written now.
  private def program_for(console)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    b.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      tiles :set, "#" => :wall, "g" => :wall
      room = background :room, tiles: :set, map: ["####", "####"]
      bar = status_bar :score, tiles: :set, map: ["####"], top: screen_height - 8
      game_loop do
        room.set_tile 1, 1, "g", now: true
        bar.set_tile 1, 0, "g", now: true
      end
    end
    b.finalize_program
    b.program
  end
end
