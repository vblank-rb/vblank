# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # THE CELL CHANGES OF A HELD BACKGROUND, kept in work memory and written in the gap between
        # frames (see Nodes::ShowHeldTiles).
        #
        # The display reads a background's map while it draws, top to bottom. A cell written while
        # it draws shows on this frame if the display has not reached that row yet, and on the next
        # if it has. One cell nobody can tell; a message box growing by seventy cells shows part of
        # each size. The console's own games keep a copy of such a map in work memory, change the
        # copy, and copy all of it into video memory between frames.
        #
        # This keeps the changes instead of the map: each `set_tile` on a held background adds one
        # word to a queue in the console's big, slow work memory, saying where the cell is in video
        # memory and what goes there, and the gap between frames writes each word's half-word where
        # it says. That is the same picture as copying a whole map, without copying the cells
        # nobody changed, and with no second copy of a map to keep in step when `show_map` or a
        # scene taking over puts the map up again: a put-up simply forgets the queue. Video memory
        # is written only in the gap, so a cell can never be read half-way through a change.
        #
        # One queue serves every held background, since a word says where it goes. A change made
        # with the queue full writes everything waiting first, so it still lands after them.
        #
        # WHAT IT COSTS: a held `set_tile` is the plain one's address arithmetic, a compare and a
        # store into the queue. The gap pays six instructions a change, in a routine kept in the
        # cartridge, and a load and a compare when nothing changed.
        module HeldTiles
          include Console::Hardware

          # How many changes are waiting.
          HELD_COUNT = :__held_tiles_count

          # Each change is one word: where the cell is, as bytes from the start of video memory,
          # in the top half, and the cell's half-word in the bottom half. Video memory for
          # backgrounds is 64 KB, so the place always fits.
          HELD_PLACE_SHIFT = 16

          # Registers the writing routine works in. It calls nothing, so the caller's loop
          # counters, in the high registers, are left alone.
          HELD_WORD = 0
          HELD_LEFT = 1
          HELD_AT = 2
          HELD_VIDEO = 3
          HELD_CELL = 12

          # Where the waiting word sits while a full queue is written, by a held set_tile.
          HELD_KEPT = 7

          # The routine that writes every waiting change, the one place they are written.
          HELD_ROUTINE = Messages::MadeNames.make(:held_tiles)

          # Does +program+ hold any cell changes? Only then is anything here emitted or reserved.
          def self.holds?(program) = program.walk.any? { |node| node.kind == :show_held_tiles || (node.kind == :set_tile && node.held) }

          # Nothing waits at power-on. Work memory holds whatever it held before the console was
          # switched on, and the gap between frames before any background is put up would write it.
          def emit_held_tiles_at_power_on(program)
            @holds_tiles = HeldTiles.holds?(program)
            return unless @holds_tiles

            emit_number(ACC, 0)
            store_var(ACC, HELD_COUNT)
          end

          # A background put up forgets every change still waiting: it was made to cells that are
          # gone now (Reference#put_up_background).
          def emit_forget_held_tiles
            return unless @holds_tiles

            emit_number(ACC, 0)
            store_var(ACC, HELD_COUNT)
          end

          # Reference#exec_show_held_tiles.
          def emit_show_held_tiles(_node)
            @held_routine_used = true
            emit_call_cold_routine(HELD_ROUTINE)
          end

          # A held change to a cell settled while the program was written: its word is a number.
          def emit_fixed_tile_held(bg, grid, entry, col, row)
            return unless grid.holds?(col, row)

            place = map_cell_address(bg, grid, col, row) - VRAM_START
            emit_number(ACC, (place << HELD_PLACE_SHIFT) | entry)
            emit_hold_word
          end

          # A held change to a cell the game works out: TILE_ADDR holds the cell's index in the map
          # (BackgroundDrawing#emit_cell_index), and its word is built around it.
          def emit_computed_tile_held(bg, entry)
            cell = BackgroundDrawing::TILE_ADDR
            emit(ASM.lsl_imm(cell, cell, 1)) # two bytes a cell
            emit_number(TMP, bg.screen_block * SCREENBLOCK_BYTES)
            emit(ASM.add_reg(cell, TMP, cell))
            emit_number(ACC, entry)
            emit(ASM.orr_reg_lsl(ACC, ACC, cell, HELD_PLACE_SHIFT))
            emit_hold_word
          end

          # Add the word in ACC to the queue, writing what waits first if it is full.
          def emit_hold_word
            @held_routine_used = true
            room = gensym
            load_var(HELD_LEFT, HELD_COUNT)
            emit(ASM.cmp_imm(HELD_LEFT, Nodes::ShowHeldTiles::MOST_CELLS))
            emit_branch(:bcond, room, cond: :lo)
            emit(ASM.mov_reg(HELD_KEPT, ACC))
            emit_call_cold_routine(HELD_ROUTINE)
            emit(ASM.mov_reg(ACC, HELD_KEPT))
            emit_number(HELD_LEFT, 0)
            place_label(room)
            emit_number(HELD_AT, held_queue_address)
            emit(ASM.lsl_imm(HELD_VIDEO, HELD_LEFT, 2)) # a word a change
            emit(ASM.add_reg(HELD_AT, HELD_AT, HELD_VIDEO))
            emit(ASM.str(ACC, HELD_AT))
            emit(ASM.add_imm(HELD_LEFT, HELD_LEFT, 1))
            store_var(HELD_LEFT, HELD_COUNT)
          end

          # THE ROUTINE THAT WRITES EVERY WAITING CHANGE, in the order they were made, and empties
          # the queue. Emitted once, after the program's own code, if anything calls it.
          def emit_held_tiles_routine
            return unless @held_routine_used

            done = gensym
            each = gensym
            emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            place_label(HELD_ROUTINE)
            load_var(HELD_LEFT, HELD_COUNT)
            emit(ASM.cmp_imm(HELD_LEFT, 0))
            emit_branch(:bcond, done, cond: :eq)
            emit_number(HELD_AT, held_queue_address)
            emit_number(HELD_VIDEO, VRAM_START)
            place_label(each)
            emit(ASM.ldr(HELD_WORD, HELD_AT))
            emit(ASM.add_imm(HELD_AT, HELD_AT, 4))
            emit(ASM.add_reg_lsr(HELD_CELL, HELD_VIDEO, HELD_WORD, HELD_PLACE_SHIFT))
            emit(ASM.store_halfword(HELD_WORD, HELD_CELL))
            emit(ASM.subs_imm(HELD_LEFT, HELD_LEFT, 1))
            emit_branch(:bcond, each, cond: :ne)
            emit_number(HELD_LEFT, 0)
            store_var(HELD_LEFT, HELD_COUNT)
            place_label(done)
            emit(ASM.return)
            # Where it ends, so a profile of the finished game can name it (see
            # GBA#lowered_routine_addresses).
            place_label(:"#{HELD_ROUTINE}_end")
          end

          # The queue, in the console's big work memory: a word for each change it can hold.
          def held_queue_address
            @held_queue_address ||= @memory.alloc_roomy(Nodes::ShowHeldTiles::MOST_CELLS * 4) or
              raise LoweringError,
                    "The work memory of the console is full, so it has no room to keep the cell changes of a " \
                    "background with `held: true`. These changes need #{Nodes::ShowHeldTiles::MOST_CELLS * 4} " \
                    "bytes. To fix this, make the lists of the game smaller, or remove `held: true`."
          end
        end
      end
    end
  end
end
