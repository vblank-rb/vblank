# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # THE START OF THE GAME'S CARTRIDGE, written where the desktop build's window reads it:
        # rg_cartridge_start.h, beside game.c. The console's start-up (runtime/rg_bios_boot.h) is
        # the player's BIOS running, and the BIOS reads the cartridge as it starts: the logo and the
        # check byte in its header, and the few words after. So a desktop build of a console that
        # plays its start-up (Console::Description#plays_bios_start_up) carries the first BYTES bytes
        # of the cartridge the same game builds, and how big the whole cartridge is, which says where
        # a read finds nothing. These are the game's own bytes, made by VBlank; nothing of the BIOS
        # is in them.
        module CartridgeStart
          FILE = "rg_cartridge_start.h"

          # As many bytes as runtime/rg_bios_boot.h's RG_BIOS_BOOT_CARTRIDGE_BYTES.
          BYTES = 256

          module_function

          # The header for a cartridge whose bytes are +rom+.
          def header(rom)
            start = rom.byteslice(0, BYTES).ljust(BYTES, "\0".b).bytes
            rows = start.each_slice(16).map { |row| "  #{row.map { |byte| format('0x%02X,', byte) }.join(' ')}\n" }
            "/* Written by Native::CartridgeStart: the first #{BYTES} bytes of the game's cartridge, and its size. */\n" \
              "static const uint8_t rg_cartridge_start[#{BYTES}] = {\n#{rows.join}};\n" \
              "static const uint32_t rg_cartridge_size = #{rom.bytesize}u;\n"
          end
        end
      end
    end
  end
end
