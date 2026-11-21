# frozen_string_literal: true

require "tmpdir"

# A film's two sides of one game, the cartridge and the interpreter, show the same pass on the same
# frame (Diagnostics::FilmCartridge): the interpreter's side is held back, a switched-off screen, for
# the frames the game's own cartridge takes to start up and show its first pass, on each screen a game
# can start on, and for a game with more to copy as it sets up. Played by each console whose cartridge
# shows the interpreter's pictures pass for pass (not the Genesis, whose cartridge shows a sprite a
# pass later). Each including test says +console+.
#
# Held to what the hold-back means, not to a number: from the frame the interpreter's side first shows
# the game, every frame of the two sides is the same picture. The games move something a pixel every
# pass, so no two passes look alike, and a side a frame early or late fails on its first frame.
module FilmStartTests
  FRAMES = 30

  # Characters for the cells of a map of many distinct tiles.
  CELL_LETTERS = Ractor.make_shareable(("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a +
                                       %w[! @ # $ % & * + = ? / < > ~ ^ : ; , -])

  # A sprite moving over a background of 80 distinct tiles on a map 40 cells wide: more to copy before
  # the first pass than #sprite_game, which takes a frame longer to set up on the Color and the Super
  # Nintendo.
  private def big_sprite_game
    letters = CELL_LETTERS
    VBlank.build("BIG", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      kinds = letters.each_with_index.to_h do |letter, at|
        name = :"tile#{at}"
        image(name, "." => :blue, "o" => :green) do
          Array.new(8) { |row| Array.new(8) { |col| ((row * 8) + col + at).to_s(2).count("1").even? ? "." : "o" }.join }.join("\n")
        end
        [letter, name]
      end
      tiles :set, kinds
      background :field, tiles: :set, map: Array.new(32) { |row| Array.new(40) { |col| letters[((row * 40) + col) % letters.size] }.join }
      dot = sprite :dot, at: [8, 24]
      game_loop { dot.x += 1 }
    end
  end

  def test_a_game_with_more_to_set_up_shows_its_first_pass_on_the_same_frame_on_both_sides
    assert_sides_alike_from_first_pass(big_sprite_game)
  end

  # A square the game paints itself, a pixel further right each pass.
  private def painted_game
    VBlank.build("PAINTED", console: console, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      x = var :x, 8
      game_loop do
        x += 1
        clear_screen :blue
        draw_rect_at x, 16, 8, 8, :red
      end
    end
  end

  # A sprite the framework draws for the game, a pixel further right each pass, over a background.
  private def sprite_game
    VBlank.build("SPRITED", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      dot = sprite :dot, at: [8, 24]
      game_loop { dot.x += 1 }
    end
  end

  def test_a_painted_game_shows_its_first_pass_on_the_same_frame_on_both_sides
    assert_sides_alike_from_first_pass(painted_game)
  end

  def test_a_tiled_game_shows_its_first_pass_on_the_same_frame_on_both_sides
    assert_sides_alike_from_first_pass(sprite_game)
  end

  # Every frame's picture on the cartridge's side and the interpreter's, from the frame the
  # interpreter's side first shows the game.
  private def assert_sides_alike_from_first_pass(built)
    Dir.mktmpdir("film-start") do |folder|
      cartridge = VBlank::Diagnostics::FilmCartridge.open(built)
      lowered = VBlank::Diagnostics::FilmCartridge.open(built, lowering: "interpreter")
      pictures = Array.new(FRAMES) do |frame|
        [cartridge, lowered].map do |side|
          File.binread(side.step(1).screenshot(File.join(folder, "frame#{frame}.png")))
        end
      end
      switched_off = pictures.first.last
      first_pass = pictures.index { |_, shown| shown != switched_off }

      refute_nil first_pass, "the interpreter's side never showed the game in #{FRAMES} frames"
      shown = pictures.drop(first_pass)
      assert_equal shown.size, shown.map(&:last).uniq.size, "the game moves every pass, so no two frames look alike"
      shown.each_with_index do |(on_cartridge, on_interpreter), at|
        assert_equal on_cartridge, on_interpreter,
                     "frame #{first_pass + at + 1}: the cartridge and the interpreter show different pictures " \
                     "(the interpreter's side first showed the game on frame #{first_pass + 1})"
      end
    ensure
      cartridge&.close
      lowered&.close
    end
  end
end
