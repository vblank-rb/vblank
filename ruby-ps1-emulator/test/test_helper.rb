# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ruby_ps1_emulator"

# A PS-X EXE made by hand, for a test that needs the console to run something: +words+ of MIPS code
# loaded at 80010000h, where the header says to start (psx-spx, "CDROM File Formats", PS-X EXE: the
# entry point at 10h, the load address at 18h, the size at 1Ch, the stack at 30h, the code from 800h,
# its size a multiple of 2048).
module HandMadeProgram
  LOAD_AT = 0x8001_0000
  IO = 0x1F80
  GP0 = 0x1810
  GP1 = 0x1814

  module_function

  def bytes(words)
    code = words.pack("V*")
    code += "\0".b * ((-code.bytesize) % 0x800)
    header = "\0".b * 0x800
    header[0, 8] = "PS-X EXE"
    header[0x10, 4] = [LOAD_AT].pack("V")
    header[0x18, 8] = [LOAD_AT, code.bytesize].pack("V2")
    header[0x30, 4] = [0x801F_FFF0].pack("V")
    header + code
  end

  def write(dir, words)
    path = File.join(dir, "test.exe")
    File.binwrite(path, bytes(words))
    path
  end

  # The words of the instructions a test program is made of, each as psx-spx's CPU chapter encodes it.
  # t0 (register 8) holds 1F800000h, the ports' page, for the whole program; t1 (9) is a number on its way.

  # LUI t0, 1F80h
  def ports = [0x3C08_0000 | IO]

  # LUI t1, high; ORI t1, t1, low
  def number(value) = [0x3C09_0000 | (value >> 16), 0x3529_0000 | (value & 0xFFFF)]

  # SW t1, distance(t0)
  def store(distance) = [0xAD09_0000 | distance]

  def gp0(value) = number(value) + store(GP0)
  def gp1(value) = number(value) + store(GP1)

  # SW t1, 0(t2), with t2 (10) set to +address+ first.
  def store_at(address, value) = number(value) + [0x3C0A_0000 | (address >> 16), 0x354A_0000 | (address & 0xFFFF), 0xAD49_0000]

  # J to itself, then a NOP in its delay slot: the end of a program.
  def forever(at) = [0x0800_0000 | ((at >> 2) & 0x3FF_FFFF), 0]
end
