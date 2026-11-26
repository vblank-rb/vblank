# frozen_string_literal: true

require "test_helper"
require "stringio"

# The six-button pad's X and Y on a Sega Genesis (Genesis::Runtime::Frame#emit_pad_now): read after the
# pad's two usual halves, by two more turns of the select line (plutiedev, "Controllers"). A cartridge
# says it reads one in its header ("6" in the devices), and the emulator then plugs a six-button pad in.
class TestGenesisSixButtonPad < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  # A game counting the frames X is held and the frames right is held.
  private def counting_game(button = :x)
    VBlank.game("SIX PAD", consoles: %i[genesis]) do
      pressed_count = var :pressed_count, 0
      right_count = var :right_count, 0
      game_loop do
        pressed_count.store!(pressed_count + 1) if held(button)
        right_count.store!(right_count + 1) if held(:right)
      end
    end
  end

  private def built(button = :x) = counting_game(button).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)

  # On a three-button pad nothing answers for X: it reads as not held, and the buttons the pad does have
  # read right.
  def test_a_three_button_pad_reads_no_x_and_every_other_button
    rom = built
    counts = Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gen")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_genesis(path)
      core.plug_in_pad(six_buttons: false)
      core.set_buttons(%i[x right])
      30.times { core.run_frame }
      [core.wram_read32(rom.var_addresses.fetch(:pressed_count)), core.wram_read32(rom.var_addresses.fetch(:right_count))]
    ensure
      core&.destroy
    end

    assert_equal 0, counts.first, "X on a three-button pad"
    assert_operator counts.last, :>, 0, "right on a three-button pad"
  end

  def test_the_header_says_the_cartridge_reads_a_six_button_pad_only_when_it_does
    assert_equal "J6".ljust(16, " "), built(:x).bytes.byteslice(0x190, 16)
    assert_equal "J".ljust(16, " "), built(:a).bytes.byteslice(0x190, 16)
  end

  private def read_lines(button)
    rows = built(button).profile(out: StringIO.new, settle: 10, frames: 20).runtime
    rows.select { |row| row.routine.to_s == "rt_buttons_now" }.sum { |row| row.share * 262 }
  end

  # The two added turns of the select line cost about 250 cycles of the 68000 by the M68000 User's Manual's
  # tables (four move.b #imm,abs.l writes at 20, six nops at 4, two move.b abs.l,d3 reads at 16, the
  # shift, the mask, the compare and two btst and or.w pairs), 7 core cycles each over 3420 a line: about
  # half a line. Derived, not measured; the budget of a line leaves room for the branches taken.
  def test_reading_x_and_y_costs_under_a_line_a_frame
    extra = read_lines(:x) - read_lines(:a)

    assert_operator extra, :<, 1.0, "reading X costs #{extra.round(3)} lines a frame more than reading A"
  end
end
