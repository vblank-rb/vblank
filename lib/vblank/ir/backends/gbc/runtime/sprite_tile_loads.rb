# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # LOADS OF SPRITE TILES THE GAME SAID IN A PASS (Lowering::SpriteTiles), put into sprite
          # memory in the blank after it.
          #
          # The Color's picture memory cannot be written while the display reads it, so a load is
          # only noted where the game says it: the bank its tiles are in, where they are there,
          # where they go in sprite memory and how many. That is a few stores, whatever the tiles.
          # In the blank, rt_sprite_tile_loads puts each noted load's bank in view and has the
          # console's own copy (rt_gdma) move its tiles, sixteen bytes a tile, straight from the
          # cartridge: nothing is copied through work memory, and nothing is repacked, since the
          # cartridge keeps the tiles in the Color's own form (Lowering::SpriteTiles).
          #
          # A pass can note MOST_LOADS loads. A blank is short, and a pass noting more than that
          # stops the game and says so (CartridgeFaults::TILE_LOADS_FULL), as a pass changing too
          # many cells of a background does on the consoles that queue those.
          module SpriteTileLoads
            QUEUE = "rt sprite tile loads"

            # Loads one pass can note.
            MOST_LOADS = 8

            # A noted load: the cartridge's bank, the side of picture memory, where the tiles are (two
            # bytes), where they go (two bytes), and how many blocks of 16 bytes less one.
            ENTRY_BYTES = 7

            module_function

            def reserve(memory) = memory.reserve(QUEUE, 1 + (MOST_LOADS * ENTRY_BYTES))

            def any?(memory) = memory.reserved?(QUEUE)

            def emit(asm, memory)
              h = Console::GBCHardware
              queue = memory[QUEUE]
              asm.label("rt_sprite_tile_loads")
              asm.load(:a, [queue])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:b, :a)
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.push(:af)
              asm.load(:hl, queue + 1)
              asm.label("rt_sprite_tile_loads_next")
              asm.load(:a, [:hli])
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.load(:a, [:hli])
              asm.load_high(h::VBK, :a)
              asm.push(:bc)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli])
              asm.push(:hl)
              asm.load(:h, :b)
              asm.load(:l, :c)
              asm.load(:c, :a)
              asm.call("rt_gdma")
              asm.pop(:hl)
              asm.pop(:bc)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_sprite_tile_loads_next")
              asm.xor_a(:a)
              asm.load([queue], :a)
              asm.load_high(h::VBK, :a)
              asm.pop(:af)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.ret

              # rt_sprite_tile_loads_full: a pass noted more loads than the queue holds.
              asm.label("rt_sprite_tile_loads_full")
              asm.load(:a, Frame::TILE_LOADS_FULL)
              asm.jump("rt_fault")
            end
          end
        end
      end
    end
  end
end
