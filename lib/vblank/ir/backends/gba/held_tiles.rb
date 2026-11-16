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
        # word to a queue in the console's big, slow work memory, holding where the cell is in video
        # memory and what goes there, and the gap between frames writes each word's half-word where
        # it points. That is the same picture as copying a whole map, without copying the cells
        # nobody changed, and with no second copy of a map to keep in step when `show_map` or a
        # scene taking over puts the map up again: a put-up forgets the changes waiting for the
        # cells it puts back (#emit_forget_held_tiles). Video memory is written only in the gap, so
        # a cell can never be read half-way through a change.
        #
        # One queue serves every held background, since a word holds where it goes. It holds
        # Nodes::ShowHeldTiles::MOST_CELLS changes. A change made with the queue full writes
        # everything waiting there and then, in the middle of the pass, so it still lands after
        # them: a pass that makes more changes than the queue holds shows the first queueful on
        # the frame being drawn, written while the display may be drawing those rows, and only
        # what is left of the pass waits for the gap. Every backend does the same.
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

          # The routine that forgets the waiting changes to one stretch of video memory, keeping
          # the rest in the order made. It takes the stretch as two words in the form a change is
          # kept in: where it starts, shifted up, in HELD_DROP_FROM, and how long it is, shifted
          # up, in HELD_DROP_SPAN. A change is in it when its word less the start is under the
          # length, compared without a sign: one subtract and one compare a change.
          HELD_DROP_ROUTINE = Messages::MadeNames.make(:held_tiles_drop)
          HELD_DROP_FROM = 2
          HELD_DROP_SPAN = 3
          # ...and the registers it keeps on the stack while it works: where the next kept change
          # goes, how many are kept, and the change less the start.
          HELD_DROP_TO = 4
          HELD_DROP_KEPT = 5
          HELD_DROP_OFFSET = 6

          # The whole of the places a word can name: video memory for backgrounds is 64 KB.
          HELD_PLACES = 0x10000

          # Does +program+ hold any cell changes? Only then is anything here emitted or reserved.
          def self.holds?(program) = program.walk.any? { |node| node.kind == :show_held_tiles || (node.kind == :set_tile && node.held) }

          # The names of the backgrounds +program+ changes held.
          def self.held_names(program) = program.walk.filter_map { |node| node.name if node.kind == :set_tile && node.held }.uniq

          # Nothing waits at power-on. Work memory holds whatever it held before the console was
          # switched on, and the gap between frames before any background is put up would write it.
          def emit_held_tiles_at_power_on(program)
            @holds_tiles = HeldTiles.holds?(program)
            return unless @holds_tiles

            @held_names = HeldTiles.held_names(program)
            emit_number(ACC, 0)
            store_var(ACC, HELD_COUNT)
          end

          # A BACKGROUND PUT UP FORGETS THE CHANGES WAITING FOR ITS OWN CELLS: they were made to
          # cells it puts back as declared (Reference#put_up_background). The changes waiting for
          # every other background are kept, so a box every screen shows, changed earlier in the
          # pass a scene takes over in, still shows the change on the next frame.
          #
          # A word holds only where in video memory it goes, so what is forgotten is a stretch of
          # video memory. For a background every screen shows, that is its own map. For a scene's
          # background it is every place but the maps of the held backgrounds every screen shows:
          # the scenes take turns in the same video memory (ScreenLayout#place_each_scene), so a
          # change still waiting for the scene being left would land in the arriving scene's tiles
          # or maps. The interpreter shows nothing of such a change either, since that scene's
          # backgrounds go up as declared when it comes back.
          def emit_forget_held_tiles(node, bg)
            return unless @holds_tiles

            if node.scene
              emit_forget_scene_held_tiles
            elsif @held_names.include?(node.name) && bg.map_bytes
              start = bg.screen_block * SCREENBLOCK_BYTES
              emit_drop_held_tiles(start, start + bg.map_bytes)
            end
          end

          # A PAINTED SCREEN TAKING OVER FORGETS EVERY WAITING CHANGE. Its picture is kept in the
          # same video memory the maps were in, so a change written there in the gap would be a
          # stray pixel in the picture. None of them is owed later either: coming back, the tiled
          # screen puts every background up again as declared (Reference#put_up_always_up), and
          # a scene's own when it takes over.
          def emit_forget_all_held_tiles
            emit_drop_held_tiles(0, HELD_PLACES) if @holds_tiles
          end

          # Every waiting change but those to the held backgrounds every screen shows. Nothing,
          # in a game whose scenes change no background held.
          def emit_forget_scene_held_tiles
            return unless scene_held_tiles?

            kept = held_everywhere_stretches
            return emit_drop_held_tiles(0, HELD_PLACES) if kept.empty?

            gaps = ([0] + kept.flatten + [HELD_PLACES]).each_slice(2)
            gaps.each { |start, finish| emit_drop_held_tiles(start, finish) if finish > start }
          end

          # Does any scene's own background take held changes?
          def scene_held_tiles?
            @layout.screen.picture.scenery.any? { |each| each.scene && @held_names.include?(each.name) }
          end

          # Where the maps of the held backgrounds every screen shows sit in video memory, in order,
          # each as its start and the place after its end.
          def held_everywhere_stretches
            @layout.screen.picture.scenery.filter_map do |each|
              next if each.scene || !@held_names.include?(each.name)

              bg = @layout.screen.declared_background(each)
              next unless bg&.map_bytes

              start = bg.screen_block * SCREENBLOCK_BYTES
              [start, start + bg.map_bytes]
            end.uniq.sort
          end

          # Forget the waiting changes to video memory from +start+ up to +finish+. The whole of
          # it empties the queue, one store; any less is a call to HELD_DROP_ROUTINE.
          def emit_drop_held_tiles(start, finish)
            if start.zero? && finish >= HELD_PLACES
              emit_number(ACC, 0)
              return store_var(ACC, HELD_COUNT)
            end

            @held_drop_used = true
            emit_number(HELD_DROP_FROM, start << HELD_PLACE_SHIFT)
            emit_number(HELD_DROP_SPAN, (finish - start) << HELD_PLACE_SHIFT)
            emit_call_cold_routine(HELD_DROP_ROUTINE)
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
            emit_drop_held_tiles_routine if @held_drop_used
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
            place_label(DerivedNames.routine_end(HELD_ROUTINE))
          end

          # THE ROUTINE THAT FORGETS THE WAITING CHANGES TO ONE STRETCH OF VIDEO MEMORY (see
          # HELD_DROP_ROUTINE), walking the queue once and moving each change it keeps down over
          # the ones it forgets, so the kept ones stay in the order made.
          def emit_drop_held_tiles_routine
            done = gensym
            each = gensym
            forget = gensym
            emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            place_label(HELD_DROP_ROUTINE)
            load_var(HELD_LEFT, HELD_COUNT)
            emit(ASM.cmp_imm(HELD_LEFT, 0))
            emit_branch(:bcond, done, cond: :eq)
            emit(ASM.push(HELD_DROP_TO, HELD_DROP_KEPT, HELD_DROP_OFFSET))
            emit_number(HELD_CELL, held_queue_address)
            emit(ASM.mov_reg(HELD_DROP_TO, HELD_CELL))
            emit_number(HELD_DROP_KEPT, 0)
            place_label(each)
            emit(ASM.ldr(HELD_WORD, HELD_CELL))
            emit(ASM.add_imm(HELD_CELL, HELD_CELL, 4))
            emit(ASM.sub_reg(HELD_DROP_OFFSET, HELD_WORD, HELD_DROP_FROM))
            emit(ASM.cmp_reg(HELD_DROP_OFFSET, HELD_DROP_SPAN))
            emit_branch(:bcond, forget, cond: :lo)
            emit(ASM.str_post(HELD_WORD, HELD_DROP_TO, 4))
            emit(ASM.add_imm(HELD_DROP_KEPT, HELD_DROP_KEPT, 1))
            place_label(forget)
            emit(ASM.subs_imm(HELD_LEFT, HELD_LEFT, 1))
            emit_branch(:bcond, each, cond: :ne)
            store_var(HELD_DROP_KEPT, HELD_COUNT)
            emit(ASM.pop(HELD_DROP_TO, HELD_DROP_KEPT, HELD_DROP_OFFSET))
            place_label(done)
            emit(ASM.return)
            place_label(DerivedNames.routine_end(HELD_DROP_ROUTINE))
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
