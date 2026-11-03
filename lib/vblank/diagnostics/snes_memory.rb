# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING SUPER NINTENDO CARTRIDGE'S MEMORY, read by the address its own code uses. Two kinds
    # of memory hold a game's numbers. Work RAM is the console's own: banks $7E and $7F, and its
    # first 8K is seen again at the low addresses every bank shares, so an address there is its own
    # offset. A Super FX cartridge has RAM of its own too, which the console sees as bank $70
    # (Console::SNESHardware::GSU_RAM_BANK), and a list a chip routine reaches lives there for the
    # whole game. The emulator hands that RAM over as the cartridge's save memory.
    #
    # The headless run (IR::Backends::SNES::HeadlessRun) and the finished-cartridge reader
    # (SNESProbe) both read through this, each handing over the emulator core it holds, so neither
    # can read a list from the wrong memory.
    module SNESMemory
      WORK_RAM_START = 0x7E0000

      module_function

      def read8(core, address) = chip_ram?(address) ? chip_ram(core, address, 1).getbyte(0) : core.wram_read8(work_ram_offset(address))
      def read16(core, address) = chip_ram?(address) ? chip_ram(core, address, 2).unpack1("v") : core.wram_read16(work_ram_offset(address))
      def read32(core, address) = chip_ram?(address) ? chip_ram(core, address, 4).unpack1("V") : core.wram_read32(work_ram_offset(address))

      # Where +address+ is in work RAM: an address in the first 8K is its own offset, and one in
      # banks $7E and $7F is counted from $7E:0000.
      def work_ram_offset(address) = address >= WORK_RAM_START ? address - WORK_RAM_START : address

      def chip_ram?(address) = (address >> 16) == Console::SNESHardware::GSU_RAM_BANK
      def chip_ram(core, address, count) = core.save_ram_bytes(address & 0xFFFF, count)
    end
  end
end
