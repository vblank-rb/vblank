# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_recolor_several_lists"

# A background drawn with several lists the game changes (`recolor`) on a Genesis: its tiles of each
# list are drawn from that list's own palette, the one the list's sprites are drawn from, so the
# write that changes a list changes its tiles and the background keeps no colours of its own.
class TestGenesisRecolorSeveralLists < Minitest::Test
  include RecolorSeveralListsGames

  Genesis = VBlank::IR::Backends::Genesis

  # The game's lists settle from this pass on: :sign its own colours, :words set 2, :trim set 1.
  SETTLED_FRAMES = 60

  def test_the_cartridge_plays_every_pass_as_the_interpreter
    Genesis::CheckedRun.new.run(genesis_program, frames: LAST_PASS + 4)
  end

  # FOUR LISTS IN FOUR PALETTES: three the background and a sprite each follow, and the plain one.
  # A palette kept for the background's own colours beside any of them would be a fifth, and the
  # game would not fit. Read in the emulator, before any list is told to hold a set and after.
  def test_the_colour_memory_holds_each_list_once_and_what_it_holds_now
    early, late = colour_memory_first_and_after(later: SETTLED_FRAMES)
    games = RecolorSeveralListsGames

    assert_lists_once(early, sign: games.list(CHANGING[:sign]), words: games.list(CHANGING[:words]),
                             trim: games.list(CHANGING[:trim]), plain: PLAIN)
    assert_lists_once(late, sign: games.colors_at(:sign, STEPS[:sign].last), words: games.colors_at(:words, STEPS[:words].last),
                            trim: games.colors_at(:trim, STEPS[:trim].last), plain: PLAIN)
  end

  private def genesis_program = several_lists_game.copy.tap { |copy| copy.console = :genesis }

  # +color+ as a word of the console's colour memory.
  private def word(color) = VBlank::Console::GenesisHardware.color_word(VBlank::Graphics::Color.resolve(color))

  # The 64 words of the colour memory on the first frame the cartridge has written any of it, which is
  # before the game's first pass is shown, and again +later+ frames on.
  private def colour_memory_first_and_after(later:)
    rom = Genesis.new.build(genesis_program)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "lists.gen")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_genesis(path)
      first = nil
      120.times do
        core.run_frame
        first = core.cram.unpack("v*")
        break unless first.all?(&:zero?)
      end
      later.times { core.run_frame }
      [first, core.cram.unpack("v*")]
    ensure
      core&.destroy
    end
  end

  # Each of +lists+ (a name, for the message, and its colours, place 0 first) is in exactly one of the
  # four palettes of +memory+, at the palette's places 1 onward.
  private def assert_lists_once(memory, lists)
    found = lists.transform_values do |colors|
      words = colors.drop(1).map { |color| word(color) }
      (0...4).count { |line| memory[(line * 16) + 1, words.length] == words }
    end

    assert_equal(lists.transform_values { 1 }, found, "how many palettes hold each list")
  end
end
