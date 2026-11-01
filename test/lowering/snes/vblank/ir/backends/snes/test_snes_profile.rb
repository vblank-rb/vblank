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

  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  def test_a_list_of_colours_stepped_every_pass_keeps_a_pass_a_frame
    result = rom_of(STEPPED_COLORS).profile(out: StringIO.new, settle: 30, frames: 40)

    assert_equal({ 1 => 40 }, result.passes_by_frames)
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

  def test_a_scene_to_measure_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom_of(LIGHT).profile(out: StringIO.new, scene: :title) }

    assert_match(/cannot be told a scene/, error.message)
  end
end
