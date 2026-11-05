# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A PORT OF A SUPER NINTENDO GAME READS ITS ORIGINAL'S NUMBERS WHERE ITS CODE KEEPS THEM. The 65816
# reads two bytes at any address, odd ones included, and keeps a routine's address in three, so a
# game's own code keeps a word at an odd address and a three-byte pointer, and the probe reads them
# as that code does: low byte first.
#
# The cartridge is a small game built here, written to a file: a list of five bytes, 0x11, 0x22,
# 0xF3, 0xF4 and 0x55, where the build put it. Whether its first byte is at an odd address is the
# build's, so each test reads from whichever of the first two is odd, and expects what is there.
class TestProbeOnTheSuperNintendo < Minitest::Test
  # As the game pushes them: a byte slot keeps -13 as 0xF3.
  BYTES = [0x11, 0x22, -13, -12, 0x55].freeze

  private def bytes_game
    VBlank.build("BYTES", console: :snes, out: StringIO.new, err: StringIO.new) do
      kept = list :kept, capacity: BYTES.size, width: :byte
      BYTES.each { |byte| kept.push byte }
      game_loop {}
    end
  end

  # The probe on the game as a bare file, the first odd address of the list's bytes, and how far
  # into the bytes that is.
  private def with_odd_address
    Dir.mktmpdir("cartridges") do |folder|
      built = bytes_game
      path = File.join(folder, "bytes.sfc").tap { |file| built.write(file) }
      first = built.built.lists.fetch(:kept).first + VBlank::IR::Backends::SNES::Runtime::Lists::HEADER
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step_until("the last byte kept", within: 120) { probe.read(first + BYTES.size - 1) == BYTES.last }
        yield probe, (first.odd? ? first : first + 1), (first.odd? ? 0 : 1)
      end
    end
  end

  def test_a_word_at_an_odd_address_is_read_low_byte_first
    with_odd_address do |probe, at, into|
      assert_equal({ 0 => 0x2211, 1 => 0xF322 }.fetch(into), probe.read(at, as: :u16))
    end
  end

  def test_three_bytes_are_read_as_one_number_low_byte_first
    with_odd_address do |probe, at, into|
      assert_equal({ 0 => 0xF3_2211, 1 => 0xF4_F322 }.fetch(into), probe.read(at, as: :u24))
    end
  end

  def test_three_bytes_read_signed_are_negative_when_the_top_bit_is_set
    with_odd_address do |probe, at, into|
      assert_equal({ 0 => -0x0C_DDEF, 1 => -0x0B_0CDE }.fetch(into), probe.read(at, as: :s24))
    end
  end
end
