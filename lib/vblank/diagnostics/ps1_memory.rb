# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A RUNNING PLAYSTATION PROGRAM'S MEMORY, read by the address its own code uses. Two kinds of memory
    # hold a game's numbers: main RAM, and the scratchpad, the 1K inside the processor at 1F800000h where
    # the build keeps the numbers read most (IR::Backends::PS1::Memory). The emulator hands each over
    # by itself.
    #
    # The headless run (IR::Backends::PS1::HeadlessRun) and the finished-program reader (PS1Probe) both
    # read through this, each handing over the emulator core it holds, so neither reads a variable from
    # the wrong memory.
    module PS1Memory
      SCRATCHPAD = Console::PS1Hardware::SCRATCHPAD

      module_function

      def read8(core, address) = bytes(core, address, 1).getbyte(0)
      def read16(core, address) = bytes(core, address, 2).unpack1("v")
      def read32(core, address) = bytes(core, address, 4).unpack1("V")

      def write32(core, address, value)
        return core.ram_write32(address, value) unless scratchpad?(address)

        core.scratchpad_write32(address - SCRATCHPAD, value)
      end

      def bytes(core, address, count)
        return core.ram_bytes(address, count) unless scratchpad?(address)

        core.scratchpad_bytes(address - SCRATCHPAD, count)
      end

      def scratchpad?(address) = IR::Backends::PS1::Memory.scratchpad?(address)
    end
  end
end
