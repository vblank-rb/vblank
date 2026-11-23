# frozen_string_literal: true

# A cartridge read in the emulator by a reader nobody closes, in a process that then ends, with
# files as Windows keeps them: a file the emulator holds open cannot be removed. macOS and Linux
# remove an open file and say nothing, so without the stand-in below a removal in the wrong order
# never shows here. Played by test_reader_left_open.rb in a process of its own, with TMPDIR set
# to a folder of its own, which it reads afterwards for anything left behind.

require "stringio"
require "vblank"

VBlank::Diagnostics::Emulator.load!

# The files the emulator holds open, by full path, from the moment a core opens them until it
# is destroyed.
OPEN_IN_EMULATOR = []

# A core opening its cartridge and save files and letting them go, as libmgba does: it keeps
# both open for as long as the core lives, the save file in the save directory under the
# cartridge's name.
module CartridgeHeldOpen
  def initialize(rom_path, save_dir, *rest)
    super
    save = File.join(save_dir || File.dirname(rom_path), "#{File.basename(rom_path, '.*')}.sav")
    @held_paths = [File.expand_path(rom_path), File.expand_path(save)]
    OPEN_IN_EMULATOR.concat(@held_paths)
  end

  def destroy
    super
    @held_paths.each { |path| OPEN_IN_EMULATOR.delete(path) }
  end
end
RubyGBAEmulator::Core.prepend(CartridgeHeldOpen)

# Removing a file the emulator holds open is refused, as Windows refuses it.
module RemovalRefusedWhileOpen
  def unlink(*paths)
    refuse_open_removal!(paths)
    super
  end

  def delete(*paths)
    refuse_open_removal!(paths)
    super
  end

  private def refuse_open_removal!(paths)
    held = paths.map { |path| File.expand_path(path) } & OPEN_IN_EMULATOR
    raise Errno::EACCES, held.first unless held.empty?
  end
end
File.singleton_class.prepend(RemovalRefusedWhileOpen)

rom = VBlank.build("LEFTOPEN", console: :gba, out: StringIO.new, err: StringIO.new) do
  screen :bitmap
  pixel 10, 10, :red
  halt
end

reader = VBlank::Diagnostics::Verifier.new(rom, frames: 2)
reader.pixel(10, 10)
puts "played"
