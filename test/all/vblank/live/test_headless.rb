# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# THE HEADLESS DEVICE ASKS A GAME WHAT THE WINDOW ASKS (Live::SDL). A play that passes on Headless
# and stops in a window is a check that missed something, so each question the session puts to the
# window, and each picture the window refuses, is put to and refused by Headless too: the players
# the game seats, its save memory kept between plays, and a picture the size the window was opened for.
class TestHeadless < Minitest::Test
  # The game is built as Ruby and its source evaluated here, which sets constants the whole process shares.
  runs_on_the_main_ractor!

  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  private def program(players: nil, &block)
    options = VBlank::Cartridge::Options.new(console: :gba, players: players)
    builder = Builder.new(options: options)
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def plain_program(players: nil) = program(players: players) { game_loop { clear_screen :black } }

  def test_headless_is_told_how_many_players_each_play_seats
    device = Headless.new(frames: 2)
    Session.new(plain_program(players: 1..2)).play(device)
    Session.new(plain_program, stop_after_passes: 1).play(device)

    assert_equal [2, 0], device.seat_counts
  end

  # The window asks the game how many players it seats, so a game with no answer stops on Headless as it does there.
  def test_a_game_with_no_seat_count_stops_on_headless
    game = VBlank::IR::Backends::Ruby.new.live_game(plain_program)
    game.singleton_class.undef_method(:seats)

    assert_raises(NoMethodError) { Session.new(game: game).play(Headless.new(frames: 2)) }
  end

  # A game that adds one to a number in its save memory every pass, shown as a red pixel's column.
  private def counting_program
    program do
      best = save_var :best, 0
      game_loop do
        clear_screen :black
        best += 1
        draw_rect_at best, 0, 1, 1, :red
      end
    end
  end

  private def counted(device) = device.pictures.map { |picture| picture.pixels.first(picture.width).index(Color.resolve(:red)) }

  # The window keeps a game's save memory in a file between plays; Headless keeps it as bytes, which
  # the next play can be handed as the file the last one left.
  def test_headless_keeps_the_save_memory_the_game_writes
    first = Headless.new(frames: 6)
    Session.new(counting_program).play(first)
    second = Headless.new(frames: 4, save: first.saved)
    Session.new(counting_program).play(second)

    assert_equal [nil, 1, 2, 3, 4, 5], counted(first)
    assert_equal [nil, 6, 7, 8], counted(second)
  end

  # A window in a match with other players keeps no save memory, nor does Headless told to keep none.
  def test_headless_told_to_keep_no_save_keeps_none
    device = Headless.new(frames: 4, keeps_save: false)
    Session.new(counting_program).play(device)

    assert_nil device.saved
    assert_equal [nil, 1, 2, 3], counted(device)
  end

  def test_a_save_not_the_size_of_the_games_stops_the_game_before_it_starts
    error = assert_raises(VBlank::Live::SaveFile::NotThisGamesSave) do
      Session.new(counting_program).play(Headless.new(frames: 3, save: "x" * 5))
    end

    assert_match(/not a save of this game/, error.message)
  end

  def test_a_game_with_no_save_memory_keeps_no_save
    device = Headless.new(frames: 3)
    Session.new(plain_program).play(device)

    assert_nil device.saved
  end

  # The window is opened for one size of picture and refuses any other, so Headless given that size does too.
  def test_a_picture_of_another_size_than_the_screen_is_refused
    device = Headless.new(frames: 1, screen: [240, 160])
    error = assert_raises(ArgumentError) { device.show(Array.new(120 * 80, 0), 120, 80) }

    assert_match(/240x160/, error.message)
    device.show(Array.new(240 * 160, 0), 240, 160)
    assert_equal 1, device.pictures.size
  end

  def test_a_picture_whose_pixels_are_not_its_size_is_refused
    assert_raises(ArgumentError) { Headless.new(frames: 1).show(Array.new(10, 0), 4, 4) }
  end
end
