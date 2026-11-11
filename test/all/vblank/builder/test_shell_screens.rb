# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "shell_screen_tests"

# `shell_screen`: WHAT A GAME MAY AND MAY NOT GIVE ITS SHELL'S FIRST SCREEN, told as the shell is
# built (Original::Shell.build), and that a cartridge holds nothing of it. What the screen shows on
# each runtime is tested in that runtime's folder (test_shell_screen.rb under
# test/lowering/ruby/vblank/live/, and the web page's and the desktop program's).
class TestShellScreens < Minitest::Test
  include ShellScreenTests

  # The made-up port with +first_screen+ as its `shell_screen` block, handed +pack+ besides the
  # screen so a test can give it a slot, and built as a shell.
  private def build_shell_with(folder, &first_screen)
    from = original_nowhere(folder)
    game = VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      pack = data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
      shell_screen { |first| instance_exec(first, pack, &first_screen) }
      image :wall, width: 8, height: 8, colors: pack[:palette], places: Array.new(64, 1)
      game_loop { blit :wall, 0, 0 }
    end
    VBlank::Original::Shell.build(game, err: nil)
  end

  private def refusal_of(&first_screen)
    Dir.mktmpdir { |folder| assert_raises(ArgumentError) { build_shell_with(folder, &first_screen) }.message }
  end

  def test_a_slot_of_the_data_pack_given_to_the_screen_is_refused
    assert_match "before the player's copy is read", refusal_of { |first, pack| first.colors ground: pack[:palette] }
    assert_match "slot :palette", refusal_of { |first, pack| first.picture pack[:palette] }
  end

  def test_a_slot_of_the_data_pack_given_to_a_verb_in_the_block_is_refused
    said = refusal_of { |_first, pack| image :logo, width: 8, height: 8, colors: pack[:palette], places: Array.new(64, 1) }

    assert_match "before the player's copy is read", said
    assert_match "of the game's own", said
  end

  def test_a_line_that_shows_a_scene_the_block_does_not_have_is_refused_naming_the_line
    said = refusal_of { |first, _pack| first.line "CREDITS", shows: :credits }

    assert_match "no such scene", said
    assert_match "test_shell_screens.rb:", said
  end

  def test_a_line_that_names_nothing_to_show_is_refused
    assert_match "needs shows:", refusal_of { |first, _pack| first.line "CREDITS" }
    assert_match ":load_rom or under :settings", refusal_of { |first, _pack| first.line "CREDITS", shows: :credits, under: :title }
  end

  def test_more_lines_than_fit_the_screen_are_refused_saying_how_many_fit
    said = refusal_of do |first, _pack|
      scene(:credits) { clear_screen :black }
      9.times { |at| first.line "LINE #{at}", shows: :credits }
    end

    assert_match "11 lines", said
    assert_match "lines fit the screen", said
  end

  def test_words_the_font_cannot_write_are_refused_naming_the_letters
    said = refusal_of do |first, _pack|
      font :one_letter, glyphs: { "A" => [[1]] }
      first.font :one_letter
      first.title "A"
    end

    assert_match "font :one_letter", said
    assert_match "has no", said
  end

  def test_a_picture_the_block_does_not_declare_is_refused
    assert_match "declares no such picture", refusal_of { |first, _pack| first.picture :sky }
  end

  def test_a_part_of_the_screen_that_has_no_color_is_refused_naming_the_parts
    assert_match "cursor:", refusal_of { |first, _pack| first.colors border: :red }
  end

  # Only a shell build runs the block: a cartridge is the same bytes with it and without it.
  def test_a_cartridge_holds_nothing_of_the_first_screen
    plain = VBlank.build("PLAIN", console: :gba, out: nil, err: nil) do
      screen :bitmap
      game_loop { draw_rect_at 4, 4, 4, 4, :white }
    end
    with_screen = VBlank.build("PLAIN", console: :gba, out: nil, err: nil) do
      screen :bitmap
      shell_screen { |first| first.title "NEVER BUILT" }
      game_loop { draw_rect_at 4, 4, 4, 4, :white }
    end

    assert_equal plain.buffer, with_screen.buffer
  end

  def test_a_second_shell_screen_is_refused
    said = assert_raises(ArgumentError) do
      VBlank.build("TWICE", console: :gba, out: nil, err: nil) do
        screen :bitmap
        shell_screen { |first| first.title "ONE" }
        shell_screen { |first| first.title "TWO" }
        game_loop { wait_vblank }
      end
    end.message

    assert_match "one first screen", said
  end

  # The lines keep the numbers three runtimes read: LOAD ROM 1 and SETTINGS 2 wherever they stand.
  def test_load_rom_and_settings_keep_their_numbers_among_the_games_own_lines
    given = VBlank::DSL::ShellScreen.new
    given.line "CREDITS", shows: :credits
    given.line "THANKS", shows: :thanks, under: :settings
    lines = VBlank::Original::Shell.menu_lines(given)

    assert_equal ["LOAD ROM", "CREDITS", "SETTINGS", "THANKS"], lines.map(&:words)
    assert_equal [1, 3, 2, 4], lines.map(&:number)
  end
end
