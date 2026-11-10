# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ruby_dos_emulator"

# A .COM program made by hand, for a test that needs the machine to run something: the bytes are
# machine code as Intel's manual encodes it, and DOS loads a .COM at offset 100h of a segment of its own.
module HandMadeProgram
  module_function

  # Sets mode 13h (AX = 0013h, INT 10h), points ES at A000h and fills 32000 words with +colour+ twice
  # over (REP STOSW), so every one of the 64000 pixels is +colour+, then loops forever.
  def fill_screen(colour)
    [0xB8, 0x13, 0x00, 0xCD, 0x10, # MOV AX,13h ; INT 10h
     0xB8, 0x00, 0xA0, 0x8E, 0xC0, # MOV AX,A000h ; MOV ES,AX
     0x31, 0xFF, # XOR DI,DI
     0xB9, 0x00, 0x7D, # MOV CX,32000
     0xB8, colour, colour, # MOV AX,colour*257
     0xF3, 0xAB, # REP STOSW
     0xEB, 0xFE].pack("C*") # JMP $
  end

  # Copies what port 60h (the keyboard's) says into the byte at 0000:0600h, again and again.
  def copy_keyboard_port
    [0x31, 0xC0, 0x8E, 0xD8, # XOR AX,AX ; MOV DS,AX
     0xE4, 0x60, # IN AL,60h
     0xA2, 0x00, 0x06, # MOV [0600h],AL
     0xEB, 0xF9].pack("C*") # JMP back to the IN
  end

  # The program written into a folder of its own as TEST.COM; the path is handed to the block.
  def written(program)
    Dir.mktmpdir("hand-made") do |dir|
      path = File.join(dir, "TEST.COM")
      File.binwrite(path, program)
      yield path
    end
  end
end
