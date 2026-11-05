# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE COLOR'S PROCESSOR READS A WORD AT ANY ADDRESS, a byte at a time and low byte first, so a game
# for it keeps words at odd addresses and a port's probe reads and writes them there.
#
# The cartridge is a small game built here, written to a file: a list of five bytes, 0x11 to 0x55,
# where the build put it.
class TestProbeOnTheColor < Minitest::Test
  BYTES = [0x11, 0x22, 0x33, 0x44, 0x55].freeze

  private def bytes_game
    VBlank.build("BYTES", console: :gbc, out: StringIO.new, err: StringIO.new) do
      kept = list :kept, capacity: BYTES.size, width: :byte
      BYTES.each { |byte| kept.push byte }
      game_loop {}
    end
  end

  # The probe on the game as a bare file, and the address of the list's first byte.
  private def with_bytes
    Dir.mktmpdir("cartridges") do |folder|
      built = bytes_game
      path = File.join(folder, "bytes.gbc").tap { |file| built.write(file) }
      first = built.built.lists.fetch(:kept).first + VBlank::IR::Backends::GBC::Runtime::Lists::HEADER
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step_until("the last byte kept", within: 120) { probe.read(first + BYTES.size - 1) == BYTES.last }
        yield probe, first
      end
    end
  end

  def test_a_word_at_an_odd_address_is_read_low_byte_first
    with_bytes do |probe, first|
      at, into = first.odd? ? [first, 0] : [first + 1, 1]

      assert_equal({ 0 => 0x2211, 1 => 0x3322 }.fetch(into), probe.read(at, as: :u16))
    end
  end

  def test_a_word_written_across_two_words_of_memory_is_written_whole
    with_bytes do |probe, first|
      at = (first..(first + 3)).find { |address| address % 4 == 3 }
      probe.write(at, 0x6677, as: :u16)

      expected = BYTES.dup
      expected[at - first] = 0x77
      expected[at - first + 1] = 0x66

      assert_equal 0x6677, probe.read(at, as: :u16)
      assert_equal expected.pack("C*"), probe.read_bytes(first, BYTES.size)
    end
  end
end
