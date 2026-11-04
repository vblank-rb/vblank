# frozen_string_literal: true

require "test_helper"

# A game hears, while it builds, what its console does with what it asks for (Console::Answers,
# read for the console the build is for): an error for what the hardware cannot do, and a warning
# for a row with more sprites than it draws. The Advance does all of it, so a game built for the
# Advance hears none of it.
class TestConsoleAnswers < Minitest::Test
  CHECK = VBlank::IR::Guardrails::Checks::ConsoleAnswers.new

  TURNING = VBlank.game("TURNING", consoles: %i[gba gbc]) do
    screen :rotozoom
    image(:dark, "#" => :black) { "########\n" * 8 }
    tiles :floor, "#" => :dark
    board = background :board, tiles: :floor, map: ["#" * 4] * 4
    game_loop { board.rotate 30 }
  end

  # A sprite turned by a little more each pass: its angle is worked out as the game runs.
  SPINNING = VBlank.game("SPINNING", consoles: %i[gba gbc]) do
    screen :tiled
    image(:ship, "#" => :white) { "########\n" * 8 }
    ship = sprite :ship, at: [40, 40]
    game_loop { ship.turn 4 }
  end

  SHOULDERS = VBlank.game("SHOULDERS", consoles: %i[gba gbc]) do
    count = var :count, 0
    game_loop { count += 1 if held(:l) }
  end

  X_BUTTON = VBlank.game("XBUTTON", consoles: %i[gba gbc snes]) do
    count = var :count, 0
    game_loop { count += 1 if held(:x) }
  end

  # Any button at all is not a button a console can lack.
  ANY_BUTTON = VBlank.game("ANYBUTTON", consoles: %i[gba gbc]) do
    count = var :count, 0
    game_loop { count += 1 if pressed(:any) }
  end

  CROWDED = VBlank.game("CROWDED", consoles: %i[gba gbc]) do
    screen :tiled
    draw_text "ABCDEFGHIJKL", 4, 20, :white
    game_loop { wait_vblank }
  end

  # A layer seen through by an amount written in the program is told to the console once, at boot,
  # so there is no step of the game's for it: only the layers' declaration says it.
  GHOST = VBlank.game("GHOST", consoles: %i[gba gbc]) do
    screen :tiled
    image(:ghost, "#" => :white) { "########\n" * 8 }
    layers :world, :ghosts
    layer(:ghosts, transparency: 40) { sprite :ghost, at: [40, 40] }
    game_loop { wait_vblank }
  end

  # A voice clip played once, as it was recorded: the Color plays that.
  CLIP = VBlank.game("CLIP", consoles: %i[gba gbc]) do
    hello = sample :hello, pcm: [60, -60] * 200
    hello.play
    game_loop { wait_vblank }
  end

  # ...and each way of playing a recording that the Color plays too: looped, at another note, at
  # three quarters of its volume (played at full).
  CLIP_PARTS = {
    loop: VBlank.game("CLIPLOOP", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200).play(loop: true)
      game_loop { wait_vblank }
    end,
    pitch: VBlank.game("CLIPNOTE", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200).play(pitch: :E4)
      game_loop { wait_vblank }
    end,
    volume: VBlank.game("CLIPVOL", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200).play(volume: :three_quarter)
      game_loop { wait_vblank }
    end
  }.freeze

  # A shaped recording, which a clip player has no way to play: its loudness is all or nothing.
  SHAPED_CLIP = VBlank.game("CLIPSHAPE", consoles: %i[gba gbc]) do
    sample(:hum, pcm: [60, -60] * 200, envelope: { release: 0.2 }).play
    game_loop { wait_vblank }
  end

  # The game's own wave beside a recording: it takes effect as the recording ends.
  CLIP_AND_WAVE = VBlank.game("CLIPWAVE", consoles: %i[gba gbc]) do
    enable_sound
    sample(:hum, pcm: [60, -60] * 200).play
    wave :triangle, 440
    game_loop { stop_wave }
  end

  # A song with a part on the wave voice beside a recording: the part stands aside while the
  # recording plays, so the Color plays both.
  CLIP_AND_SONG = VBlank.game("CLIPSONG", consoles: %i[gba gbc]) do
    enable_sound
    song(:pad) { voice(:low, plays: :wave) { |v| v.note :A4, :whole } }
    play_song :pad
    sample(:hum, pcm: [60, -60] * 200).play
    game_loop { wait_vblank }
  end

  # A game that reads the clock, and one that sets it.
  CLOCKED = VBlank.game("CLOCKED", consoles: %i[gba gbc snes]) do
    hour = 0
    game_loop { hour = clock.hour }
  end

  SETTING_CLOCK = VBlank.game("SETCLOCK", consoles: %i[gba gbc snes]) do
    clock.set_to(year: 2026, month: 10, day: 30, hour: 9, minute: 0)
    game_loop { wait_vblank }
  end

  # A layer seen through by an amount the game works out, which is told to the console again
  # before every frame.
  FADING_GHOST = VBlank.game("FADEGHOST", consoles: %i[gba snes]) do
    screen :tiled
    image(:ghost, "#" => :white) { "########\n" * 8 }
    image(:dark, "#" => :black) { "########\n" * 8 }
    tiles :floor, "#" => :dark
    see = 50
    layers :world, :ghosts
    layer(:world) { background :ground, tiles: :floor, map: ["#" * 32] * 32 }
    layer(:ghosts, transparency: see) { background :mist, tiles: :floor, map: ["#" * 32] * 32 }
    game_loop { see = 52 }
  end

  CELL_SHOWN_NOW = VBlank.game("CELL NOW", consoles: %i[gba gbc snes]) do
    screen :tiled
    image(:red_tile, "#" => :red) { "########\n" * 8 }
    tiles :floor, "r" => :red_tile
    bar = status_bar :menu, tiles: :floor, map: ["r" * 20], top: screen_height - 8
    game_loop { bar.set_tile 1, 0, "r", now: true if pressed(:down) }
  end

  # A place made of one face, drawn as a viewer sees it.
  PLACE = VBlank.game("PLACE", consoles: %i[gba gbc snes genesis]) do
    screen :bitmap, tear_free: true
    image(:wall, "#" => :white) { "##\n##\n" }
    place :room do
      a = point(-1.0, 1.0, 2.0)
      b = point(1.0, 1.0, 2.0)
      c = point(1.0, -1.0, 2.0)
      face a, b, c, picture: :wall, on_picture: [[0, 0], [2, 0], [2, 2]]
    end
    eye = viewer :eye, at: [0.0, 0.0, 0.0]
    game_loop { draw_place :room, seen_by: eye }
  end

  private def findings(game, console) = CHECK.detect(game.program(console: console))

  def test_a_place_is_refused_naming_what_each_console_lacks
    { gbc: /no multiply instruction/, snes: /Super FX chip/, genesis: /does not draw a place on a Genesis yet/ }.each do |console, words|
      found = findings(PLACE, console)

      assert_equal [:error], found.map(&:severity).uniq, console
      assert_match(/draw_place/, found.first.message)
      assert_match(words, found.first.message)
    end
    assert_empty findings(PLACE, :gba)
  end

  def test_a_bar_cell_shown_now_is_refused_on_the_super_nintendo
    found = findings(CELL_SHOWN_NOW, :snes)

    assert_equal [:error], found.map(&:severity).uniq
    assert_match(/between frames/, found.first.message)
    assert_empty findings(CELL_SHOWN_NOW, :gba)
    assert_empty findings(CELL_SHOWN_NOW, :gbc)
  end

  def test_a_bar_cell_told_now_with_anything_but_true_or_false_is_refused
    error = assert_raises(ArgumentError) do
      VBlank.game("CELL WHEN", consoles: %i[gba]) do
        screen :tiled
        image(:red_tile, "#" => :red) { "########\n" * 8 }
        tiles :floor, "r" => :red_tile
        bar = status_bar :menu, tiles: :floor, map: ["r" * 20], top: 120
        game_loop { bar.set_tile 1, 0, "r", now: :soon }
      end.program(console: :gba)
    end

    assert_match(/must be true or false/, error.message)
  end

  def test_reading_or_setting_the_clock_is_refused_on_the_super_nintendo_in_its_words
    [CLOCKED, SETTING_CLOCK].each do |game|
      found = findings(game, :snes)

      assert_equal [:error], found.map(&:severity).uniq, game.title
      assert_match(/no clock chip/, found.first.message)
      assert_empty findings(game, :gba), game.title
      assert_empty findings(game, :gbc), game.title
    end
  end

  def test_a_see_through_amount_the_game_works_out_is_refused_on_the_super_nintendo
    found = findings(FADING_GHOST, :snes)

    assert_equal [:error], found.map(&:severity).uniq
    assert_match(/only by half/, found.first.message)
    assert_empty findings(FADING_GHOST, :gba)
  end

  def test_a_songs_wave_part_beside_a_recording_works_on_the_color
    assert_empty findings(CLIP_AND_SONG, :gbc)
  end

  def test_the_games_own_wave_beside_a_recording_works_on_the_color
    assert_empty findings(CLIP_AND_WAVE, :gbc)
  end

  def test_a_recording_played_once_as_recorded_works_on_the_color
    assert_empty findings(CLIP, :gbc)
  end

  # Neither console's build hears anything of these.
  def test_a_looped_pitched_or_three_quarter_recording_plays_on_the_color
    CLIP_PARTS.each do |part, game|
      assert_empty findings(game, :gbc), part.to_s
      assert_empty findings(game, :gba), part.to_s
    end
  end

  def test_a_shaped_recording_is_refused_on_the_color
    found = findings(SHAPED_CLIP, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/`envelope:`/, found.first.message)
    assert_match(/one recording at a time/, found.first.message)
    assert_empty findings(SHAPED_CLIP, :gba)
  end

  def test_a_layer_seen_through_by_a_fixed_amount_is_refused_in_plain_words
    found = findings(GHOST, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/`transparency:`/, found.first.message)
  end

  # Nothing is shown differently on the Color: a turning screen, and the line that turns its
  # background, are each refused.
  def test_a_turning_screen_and_a_turned_background_are_refused
    found = findings(TURNING, :gbc)

    assert_equal %i[error error], found.map(&:severity)
    assert(found.any? { |finding| finding.message.include?("cannot turn or resize a background") })
  end

  def test_a_turning_sprite_is_refused_naming_what_the_color_lacks
    found = findings(SPINNING, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/cannot turn or resize a sprite/, found.first.message)
    assert_empty findings(SPINNING, :gba)
  end

  def test_a_shoulder_button_is_refused_in_plain_words
    found = findings(SHOULDERS, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/:l button/, found.first.message)
    assert_match(/no shoulder buttons/, found.first.message)
  end

  # X and Y are the Super Nintendo's alone.
  def test_x_and_y_are_refused_where_the_console_has_neither
    [:gba, :gbc].each do |console|
      found = findings(X_BUTTON, console)

      assert_equal [:error], found.map(&:severity)
      assert_match(/:x button/, found.first.message)
      assert_match(/no X or Y button/, found.first.message)
    end
    assert_empty findings(X_BUTTON, :snes)
  end

  def test_any_button_is_not_refused
    assert_empty findings(ANY_BUTTON, :gbc)
  end

  def test_a_row_of_more_than_ten_sprites_is_named
    found = findings(CROWDED, :gbc)

    assert_equal [:warning], found.map(&:severity)
    assert_match(/row 20/, found.first.message)
    assert_match(/10 on any one row/, found.first.message)
  end

  def test_the_advances_build_hears_nothing
    [TURNING, SPINNING, SHOULDERS, CROWDED, GHOST].each { |game| assert_empty findings(game, :gba) }
  end

  def test_a_color_build_stops_on_a_refusal
    error = assert_raises(VBlank::ROMError) do
      SHOULDERS.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    end

    assert_match(/stopped/, error.message)
  end
end
