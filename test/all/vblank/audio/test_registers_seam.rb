# frozen_string_literal: true

require "test_helper"
require "prism"

# THE LINE THROUGH THE SOUND MODULE, which its own comment draws: the musical half is what a
# "beep" or a note means, and every backend reads it; Backends::GameBoySound is the bit patterns of
# the sound chip two consoles have, and only the lowerings for those two have any business there.
#
# The comment said that before this test did, and the comment was WRONG — twice. The headless
# interpreter was asking Registers how loud a wave note is, and a guardrail that runs before
# any cartridge exists was asking it for the lowest note a square voice reaches. Neither wanted
# an encoding. Both wanted a LIMIT: the wave voice has five loudnesses, the square voices stop
# at 64 Hz. Those are facts about the console every backend has to agree on, so they moved out
# to the shared half where anything may read them.
#
# Nothing about that drift was visible. Both files kept working, the comment kept claiming the
# opposite, and the next person to reach across would have had the same reason and the same
# silence. So the claim is a test now: reach into the chip from outside those two lowerings and
# this fails, naming the file and what it asked for. The Game Boy Color's voices are the ones the
# Advance kept from it, so each says where it keeps the chip's registers (GBA::SoundRegisters,
# GBC::SoundRegisters) and the shared audio module names no register at all.
class TestRegistersSeam < Minitest::Test
  LIB = VBlank.root.join("lib").to_s

  # Where writing the chip's registers is somebody's job.
  ALLOWED = [
    "lib/vblank/ir/backends/game_boy_sound.rb",
    "lib/vblank/ir/backends/gba/",
    "lib/vblank/ir/backends/gbc/"
  ].freeze

  def test_only_the_cartridge_lowerings_read_the_sound_registers
    reaching = Hash.new { |h, k| h[k] = [] }

    Dir.glob(File.join(LIB, "**/*.rb")).sort.each do |path|
      short = path.delete_prefix("#{File.dirname(LIB)}/")
      next if ALLOWED.any? { |ok| short.start_with?(ok) }

      names_registers(path).each { |name| reaching[short] << name }
    end

    assert_empty reaching, <<~WHY
      These read the Game Boy sound chip from outside the two lowerings that have one:

      #{reaching.map { |file, names| "  #{file}: #{names.uniq.join(', ')}" }.join("\n")}

      GameBoySound turns a musical value into the exact half-words that chip wants, so a
      backend that never writes it cannot want one. If what you need is a LIMIT of a
      voice — how many loudnesses it has, how low it goes — that belongs in the musical half
      of Sound, where both backends can read it. Move it there and read it from there.
    WHY
  end

  def test_the_shared_audio_module_names_no_console_hardware
    source = Prism.parse_file(File.join(LIB, "vblank/audio/sound.rb")).value.slice

    refute_match(/Console::Hardware|REG_SOUND|\bNR\d\d\b/, source)
  end

  # A guard on the guard: the fact this test is looking for is a constant, so it has to
  # find one when there really is one. Scanning the GBA backend's own audio file, which is
  # exempt above, must turn something up — otherwise a rename could make the check pass by
  # finding nothing anywhere.
  def test_the_check_can_see_a_reader
    audio = File.join(LIB, "vblank/ir/backends/gba/audio.rb")

    refute_empty names_registers(audio), "the scan has stopped recognising a reader"
  end

  private

  # Every mention of GameBoySound in the file's CODE — a comment that talks about it is
  # talking, not reaching.
  def names_registers(path)
    out = []
    stack = [Prism.parse_file(path).value]
    until stack.empty?
      node = stack.shift
      if (node.is_a?(Prism::ConstantPathNode) || node.is_a?(Prism::ConstantReadNode)) && node.slice.include?("GameBoySound")
        # The whole path, not its own leading pieces too — `A::GameBoySound::THING` is one reach.
        out << node.slice
        next
      end
      stack.unshift(*node.compact_child_nodes)
    end
    out
  end
end
