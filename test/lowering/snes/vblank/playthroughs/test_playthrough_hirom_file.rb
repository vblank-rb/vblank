# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/cartridge/test_snes_rom"

# A SUPER NINTENDO CARTRIDGE FILE LAID OUT THE HIROM WAY plays from a script, as a LoROM one
# does. A game rebuilding a retail cartridge plays the file it was given beside itself, and about
# half the console's library is HiROM.
#
# The cartridge is a small game built here as LoROM and laid out again as HiROM (HiROMLayout):
# a white box on a blue field that walks two pixels a frame from column 20 while RIGHT is down.
# Nothing anybody else made is ever played.
class TestPlaythroughHiROMFile < Minitest::Test
  include HiROMLayout

  WALKED = 10

  private def walker
    VBlank.build("WALKER", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      box = sprite :box, at: [20, 60]
      game_loop { box.x += 2 if held(:right) }
    end
  end

  # The walker as a LoROM file and as a HiROM one, in a folder of their own.
  private def with_walker_files
    Dir.mktmpdir("cartridges") do |folder|
      built = walker
      lorom = File.join(folder, "walker.sfc").tap { |path| built.write(path) }
      hirom = File.join(folder, "walker_hirom.sfc").tap { |path| File.binwrite(path, hirom_layout_of(built)) }
      yield lorom, hirom, folder
    end
  end

  # The game a script leaves standing, after WALKED frames of RIGHT.
  private def walked(path)
    game = VBlank.playthrough("x") {}.play(path).game
    WALKED.times { game.step(1, keys: VBlank::IR::Buttons.mask(:right)) }
    game
  end

  private def white_columns(game) = (0...game.screen_width).select { |x| game.white?(x, 64) }

  def test_a_hirom_file_plays_and_steps_as_the_lorom_file_does
    with_walker_files do |lorom, hirom, _folder|
      laid_out_lorom = walked(lorom)
      laid_out_hirom = walked(hirom)

      assert_equal :snes, VBlank::Diagnostics::CartridgeFile.new(hirom).console
      assert_equal "WALKER", VBlank::Diagnostics::CartridgeFile.new(hirom).header_title.rstrip
      assert laid_out_hirom.blue?(0, 0), "the field is up"
      refute_empty white_columns(laid_out_hirom), "the box is up"
      assert_operator white_columns(laid_out_hirom).first, :>, 20, "the box walked"
      assert_equal laid_out_lorom.frame_gba, laid_out_hirom.frame_gba
    end
  end

  def test_a_hirom_file_is_screenshot_and_filmed
    with_walker_files do |_lorom, hirom, folder|
      picture = File.join(folder, "walked.png")
      walked(hirom).screenshot(picture)
      film = VBlank::Diagnostics::Film.make(File.join(folder, "walk.mp4"),
                                            sides: { "hirom" => -> { VBlank.playthrough("x") {}.play(hirom).game } },
                                            parts: [1..4], keys: ->(_frame) { :right })

      assert_operator File.size(picture), :>, 0
      assert_operator File.size(film), :>, 0
    end
  end
end
