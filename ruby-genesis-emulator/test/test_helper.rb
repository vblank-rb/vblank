# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ruby_genesis_emulator"

# A Mega Drive cartridge of 64K made by hand, for a test that needs the console to run something:
# +code+ placed at $0200, where the reset vector points, and a header at $0100 that names the
# console, which is how an emulator tells a Mega Drive cartridge from any other.
#
# What the 68000 reads at power-on (Sega's Mega Drive hardware manual, "Exception vectors"): the
# first long word of the cartridge is the stack's starting place and the second is where to start
# running. The 64 vectors are 256 bytes, then the header's 256 bytes, then code. Every vector but
# those two points at a spot that just loops, so a stray interrupt in a test does no harm.
module HandMadeCartridge
  LOOP = [0x60, 0xFE].freeze # BRA.S to itself

  # The video chip's two ports: data at $C00000 and control at $C00004.
  VDP_DATA = 0xC00000
  VDP_CONTROL = 0xC00004

  module_function

  def bytes(code)
    rom = "\0".b * 0x10000
    rom[0, 8] = [0x00FF0000, 0x200].pack("N2")
    rom[8, 62 * 4] = [0x1FE].pack("N") * 62
    rom[0x1FE, 2] = LOOP.pack("C*")
    rom[0x100, 16] = "SEGA MEGA DRIVE "
    rom[0x110, 16] = "(C)TEST 2026.NOV"
    rom[0x120, 48] = "HAND MADE TEST".ljust(48, " ")
    rom[0x150, 48] = "HAND MADE TEST".ljust(48, " ")
    rom[0x180, 14] = "GM 00000000-00"
    rom[0x190, 16] = "J               "
    rom[0x1A0, 8] = [0, 0xFFFF].pack("N2") # ROM from $000000 to $00FFFF
    rom[0x1A8, 8] = [0x00FF0000, 0x00FFFFFF].pack("N2") # RAM
    rom[0x1F0, 3] = "JUE"
    rom[0x200, code.size] = code.pack("C*")
    rom
  end

  # Writes the cartridge into +dir+ and gives back its path.
  def write(dir, code)
    path = File.join(dir, "test.gen")
    File.binwrite(path, bytes(code))
    path
  end

  # MOVE.W #value,(address).L
  def move_word(value, address) = [0x33, 0xFC, value >> 8, value & 0xFF, *long(address)]

  # MOVE.L #value,(address).L
  def move_long(value, address) = [0x23, 0xFC, *long(value), *long(address)]

  # MOVE.B #value,(address).L
  def move_byte(value, address) = [0x13, 0xFC, 0x00, value, *long(address)]

  # MOVE.B (from).L,(to).L
  def copy_byte(from, to) = [0x13, 0xF9, *long(from), *long(to)]

  def long(value) = [value].pack("N").bytes
end
