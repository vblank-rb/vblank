# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "zlib"

# A PLAYTHROUGH OF A SUPER FX GAME THAT SAVES hands back the save alone, and starts the next one
# in it. The chip's RAM on such a cartridge is 128K: the chip's own working 64K, where it paints
# the screen, and then the save, the other 64K (Cartridge::SNESROM::SUPER_FX). The emulator keeps all 128K in its
# save file, so the save a playthrough hands back, the save it starts from and the save a tape
# names are the second half of that file and never the first.
#
# The game counts a saved number up by two a pass from five, while the chip paints a rectangle
# that moves with it. Started from a save, it counts on from where the save left it.
class TestPlaythroughSuperFXSaves < Minitest::Test
  SAVE_BYTES = 0x10000

  private def counting
    VBlank.build("FX SAVES", console: :snes, variant: :superfx, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      best = save_var :best, 5
      game_loop do
        clear_screen :black
        draw_rect_at (best & 63) + 10, 40, 20, 20, :green
        best += 2
      end
    end
  end

  private def ten_frames = VBlank.playthrough("count for ten frames") { wait frames: 10 }

  private def saved_best(save) = save.to_sav.byteslice(VBlank::IR::SaveLayout.save_var_at(0), 4).unpack1("V")

  # The first playing from power-on, its save, and a second playing of +cartridge+ from what
  # +save_for+ makes of that first playing.
  private def played_twice(cartridge)
    first = ten_frames.play(cartridge)
    [first, ten_frames.play(cartridge, save: yield(first))]
  end

  private def assert_counted_on_from_the_save(first, second)
    best = saved_best(first.save)

    assert_equal SAVE_BYTES, first.save.to_sav.bytesize, "the save alone, not the chip's working RAM before it"
    assert_predicate best, :odd?, "counted up from five by twos"
    assert_operator best, :>, 5
    assert_operator saved_best(second.save), :>, best, "the second playing counted on from the save"
  end

  def test_the_save_handed_back_starts_the_next_playthrough_of_the_built_cartridge
    first, second = played_twice(counting, &:save)

    assert_counted_on_from_the_save(first, second)
    assert_includes second.tape.to_s, format("starts from: a save 0x%08X", Zlib.crc32(first.save.to_sav))
  end

  def test_the_save_handed_back_starts_the_next_playthrough_of_a_cartridge_file
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "fx_saves.sfc")
      counting.write(path)
      first, second = played_twice(path, &:save)

      assert_counted_on_from_the_save(first, second)
    end
  end

  # The emulator's own save file, all 128K of it, given by its path: the save is read from the
  # second half, and the tape names the save alone.
  def test_the_emulators_save_file_starts_a_playthrough_from_its_path
    Dir.mktmpdir("saves") do |folder|
      first, second = played_twice(counting) do |played|
        File.join(folder, "fx_saves.srm").tap { |path| File.binwrite(path, played.game.save_bytes) }
      end

      assert_equal 0x20000, File.size(File.join(folder, "fx_saves.srm"))
      assert_counted_on_from_the_save(first, second)
      assert_includes second.tape.to_s, format("starts from: a save 0x%08X", Zlib.crc32(first.save.to_sav))
    end
  end
end
