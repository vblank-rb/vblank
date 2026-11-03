# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# A Super Nintendo cartridge measured as it runs (Diagnostics::SNESProfiler): how many frames each
# pass of the game loop took, read from the running cartridge.
class TestSNESProfile < Minitest::Test
  LIGHT = VBlank.game("LIGHT", consoles: %i[snes]) do
    total = 0
    game_loop { total += 1 }
  end

  # Every fourth pass does far more work than a frame holds.
  HEAVY_NOW_AND_THEN = VBlank.game("HEAVY", consoles: %i[snes]) do
    total = 0
    pass = 0
    game_loop do
      pass += 1
      repeat(9000) { total += 3 } if (pass & 3) == 0
    end
  end

  # A screen of eight lists of fifteen colours, so a change that moved every colour would have 120
  # to go through. One list steps on every pass while a sprite moves on every pass, which is how a
  # console's own game brings a line of text up from black. The pass has work of its own too, enough
  # to leave room for those fifteen colours and not for all of them.
  STEPPED_COLORS = VBlank.game("STEPPED", consoles: %i[snes]) do
    screen :tiled
    letters = "abcdefghijklmno".chars
    8.times do |list|
      shades = letters.each_with_index.to_h { |letter, shade| [letter, rgb(list * 2, shade * 2, 31 - list)] }
      image(:"art#{list}", shades) { Array.new(8) { |row| letters.rotate(row).first(8).join }.join("\n") }
    end
    tiles :set, Array.new(8) { |list| [list.to_s(16), :"art#{list}"] }.to_h
    field = background :field, tiles: :set, map: Array.new(32) { |row| Array.new(32) { |column| ((row + column) % 8).to_s(16) }.join }
    own = [:transparent, *Array.new(15) { |shade| rgb(31, shade * 2, shade) }]
    image :ball, width: 8, height: 8, data: Array.new(64) { |pixel| own[(pixel % 15) + 1] }, colors: own
    colors :letters, own
    walk = color_walk :letters, from: :black
    ball = sprite :ball, at: [0, 40]
    ball.draw_with :letters
    field.scroll_to 3, 0
    step = 0
    total = 0
    game_loop do
      recolor :letters, walk, showing: step
      step = (step + 1) & 31
      ball.x = (ball.x + 1) & 127
      repeat(200) { total += 3 }
    end
  end

  # The same screen faded to black over and over while the pass does the same work: a fade that is
  # the display's brightness touches no colour, so it takes no time.
  FADED = VBlank.game("FADED", consoles: %i[snes]) do
    screen :tiled
    letters = "abcdefghijklmno".chars
    8.times do |list|
      shades = letters.each_with_index.to_h { |letter, shade| [letter, rgb(list * 2, shade * 2, 31 - list)] }
      image(:"art#{list}", shades) { Array.new(8) { |row| letters.rotate(row).first(8).join }.join("\n") }
    end
    tiles :set, Array.new(8) { |list| [list.to_s(16), :"art#{list}"] }.to_h
    field = background :field, tiles: :set, map: Array.new(32) { |row| Array.new(32) { |column| ((row + column) % 8).to_s(16) }.join }
    field.scroll_to 3, 0
    level = 0
    total = 0
    game_loop do
      level = (level + 6) % 100
      fade :black, level
      repeat(200) { total += 3 }
    end
  end

  # Thirty-two sound effects, the most of them asked for nothing, and a pass with little room left.
  # What an effect costs is for the frames it plays; one nothing has asked for costs none.
  private def many_effects_game(playing:)
    score = VBlank::Audio::Score
    VBlank.game("MANY EFFECTS", consoles: %i[snes]) do
      enable_sound
      instrument :tone, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      note = score::Note.new(at: 0, key: :C4, length: 240)
      sfx = sound_effects :sfx, (0...32).to_h { |n| [:"effect#{n}", score.new(parts: [score::Part.new(plays: :tone, notes: [note])], tempo: 150, ticks_per_beat: 4)] }
      passes = var :passes, 0
      work = var :work, 0
      game_loop do
        passes += 1
        sfx.play 0 if playing && passes == 2
        repeat(320) { work += 1 }
      end
    end
  end

  # A routine of the game's that does most of the work there is.
  BUSY = VBlank.game("BUSY", consoles: %i[snes]) do
    total = 0
    func(:hard_work) { repeat(100) { total += 3 } }
    game_loop { call :hard_work }
  end

  def test_the_report_says_which_routine_took_the_time_and_what_was_left
    result = rom_of(BUSY).profile(out: StringIO.new, frames: 20)

    assert_equal "hard_work", result.game.first.routine.to_s[/hard_work/]
    assert_operator result.game.first.share, :>, 0.05
    assert_operator result.idle_share, :>, 0.1
    assert_operator result.idle_share, :<, 1
    assert_operator result.fewest_lines_spare, :>, 10
    assert_operator result.fewest_lines_spare, :<, 262
  end

  def test_effects_nothing_plays_cost_a_pass_nothing
    [false, true].each do |playing|
      out = StringIO.new
      rom_of(many_effects_game(playing: playing)).profile(format: :json, out: out, frames: 30, settle: 10)

      assert_equal ["1"], JSON.parse(out.string).fetch("passes_by_frames").keys, "playing: #{playing}"
    end
  end

  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  def test_a_fade_to_black_keeps_a_pass_a_frame
    result = rom_of(FADED).profile(out: StringIO.new, settle: 30, frames: 40)

    assert_equal({ 1 => 40 }, result.passes_by_frames)
  end

  def test_a_list_of_colours_stepped_every_pass_keeps_a_pass_a_frame
    result = rom_of(STEPPED_COLORS).profile(out: StringIO.new, settle: 30, frames: 40)

    assert_equal({ 1 => 40 }, result.passes_by_frames)
  end

  # A stage of blocks, every one showing one big tile, whose picture turns every seven frames: one
  # copy from the cartridge, however many cells show it, so the pass that turns it costs what any
  # other costs. Five rows of seven blocks, more than a stage holds.
  BLOCKS = VBlank.game("BLOCKS", consoles: %i[snes]) do
    screen :tiled
    colors :block, %i[transparent red green]
    image(:first, width: 16, height: 16, colors: :block, places: Array.new(256) { |at| 1 + (at % 2) })
    image(:second, width: 16, height: 16, colors: :block, places: Array.new(256) { |at| 2 - (at % 2) })
    blocks = tile_pictures :blocks, colors: :block, tiles: { soft: %i[first second] }
    tiles :stage, "s" => blocks[:soft]
    background :ground, tiles: :stage, map: Array.new(5) { "s" * 7 }
    tick = var :tick, 0
    game_loop do
      tick += 1
      blocks.show((tick / 7) % 2)
    end
  end

  def test_turning_one_big_tile_shown_in_many_cells_keeps_a_pass_a_frame
    result = rom_of(BLOCKS).profile(out: StringIO.new, settle: 30, frames: 70)

    assert_equal({ 1 => 70 }, result.passes_by_frames)
  end

  def test_a_light_game_takes_a_frame_a_pass
    result = rom_of(LIGHT).profile(out: StringIO.new, frames: 20)

    assert_equal 20, result.passes
    assert_equal 20, result.frames
    assert_equal 1, result.slowest_frames
    assert_equal({ 1 => 20 }, result.passes_by_frames)
    assert_in_delta 60.1, result.fps, 0.5
  end

  def test_a_pass_that_runs_over_is_counted_and_found
    result = rom_of(HEAVY_NOW_AND_THEN).profile(out: StringIO.new, frames: 20)

    assert_operator result.slowest_frames, :>, 1
    assert_equal 0, result.slowest_pass % 4, "a heavy pass"
    assert_operator result.frames, :>, result.passes
    assert_operator result.fps, :<, 59
  end

  def test_the_report_says_the_frame_rate_and_the_slowest_pass
    out = StringIO.new
    rom_of(HEAVY_NOW_AND_THEN).profile(out: out, frames: 20)

    assert_match(/20 passes of the game loop in \d+ frames/, out.string)
    assert_match(/slowest pass took \d+ frames/, out.string)
  end

  def test_the_report_comes_as_data_too
    out = StringIO.new
    rom_of(LIGHT).profile(format: :json, out: out, frames: 5)

    assert_equal 5, JSON.parse(out.string).fetch("passes")
  end

  # A game that costs more while a button is down, as a walking player does.
  WALKER = VBlank.game("WALKER", consoles: %i[snes]) do
    total = 0
    game_loop { repeat(9000) { total += 3 } if held(:up) }
  end

  # What the command line hands over, `press:` among it: holding a button is how a walking player
  # is measured.
  def test_a_button_held_is_measured
    still = rom_of(WALKER).profile(out: StringIO.new, frames: 10, keys: [], press: [])
    walking = rom_of(WALKER).profile(out: StringIO.new, frames: 10, keys: [:up], press: [])

    assert_equal 1, still.slowest_frames
    assert_operator walking.slowest_frames, :>, 1
  end

  def test_a_button_pressed_as_the_measuring_starts_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom_of(LIGHT).profile(out: StringIO.new, press: [:a]) }

    assert_match(/--press/, error.message)
    assert_match(/--keys/, error.message)
  end

  def test_a_scene_to_measure_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom_of(LIGHT).profile(out: StringIO.new, scene: :title) }

    assert_match(/cannot be told a scene/, error.message)
  end
end
