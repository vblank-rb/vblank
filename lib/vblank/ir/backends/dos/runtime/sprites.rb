# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # SPRITES SHOWN OVER THE PICTURE (`sprite ..., over_picture: true`). The card has no sprites: every
          # pixel it shows is in its one picture. So the processor draws them, and where it draws them is what
          # keeps the game's picture as the game painted it: not into that picture, but into a second one, THE
          # PICTURE SHOWN, in a segment of its own, which is the game's picture with the sprites over it and
          # is what the card is sent (rt_show_picture).
          #
          # A pass says which sprites are on the screen and where (rt_sprite_place, once for each, from the
          # game's own step that places its sprites), which fills a table. As the pass ends, before the wait
          # (rt_sprites_over_picture):
          #
          #   0. if the table is what it was last pass, the sprites are where they were: steps 1 is passed
          #      over, and if the game changed no row either there is nothing to do at all;
          #   1. the rows the sprites stood in last time are marked as changed, and the rows they stand in now;
          #   2. every row marked as changed is copied from the game's picture to the picture shown, which
          #      rubs out the sprites as they were and brings in what the game painted this pass;
          #   3. each sprite in the table is drawn into the picture shown, in the table's order, so the last
          #      is in front.
          #
          # The retrace then sends those rows to the card. A sprite that moves leaves nothing behind, a game
          # that paints its whole picture again paints over no sprite, and nothing is copied for a row no
          # sprite and no drawing touched. (The rows marked are one run from the first to the last, so two
          # sprites far apart that both move send every row between them.) A sprite is held to the screen's
          # edges and not to the area the
          # game's drawing is held to: it is over the picture, not in it.
          #
          # The table is what a reader of the running program reads too (DOS::HeadlessRun#read_sprites): for
          # each sprite placed, whose it is and which picture it shows, as the numbers SpriteNames gives
          # them, and where it stands.
          module Sprites
            PLACED = "rt sprites placed"
            # The rows the sprites placed last time stand in: from the first, up to and not the row after the last.
            ROWS_TOP = "rt sprites top"
            ROWS_BOTTOM = "rt sprites bottom"
            TABLE = "rt sprites"
            # The table as it was when the picture shown was last made, and how many it held.
            PLACED_BEFORE = "rt sprites placed before"
            TABLE_BEFORE = "rt sprites before"
            # A SPRITE AT ITS LEVEL IN THE STACK. Where a game's layers put a background in front of a sprite, or its
            # sprites at different levels, the sprites are not drawn over the picture but into the view as it is
            # built (Runtime::Scenery#emit_view), each after the backgrounds of its own level and before those in
            # front, as the interpreter paints them (Reference#repaint_view). Such a game keeps a byte for each sprite
            # placed, its level, in the order of the table (LEVELS), and the picture shown is then the game's
            # picture with nothing over it.
            LEVELS = "rt sprites levels"
            # A place nothing is kept in: a game has it when one of its sprites turns or changes size, which is
            # what says its table's rows are the longer ones.
            TURNED = "rt sprites turned"
            WORDS = [PLACED, PLACED_BEFORE, ROWS_TOP, ROWS_BOTTOM].freeze

            # One sprite placed: whose and which picture (SpriteNames' numbers), the picture's place in the art
            # segment and its height, a word each, then its x and y.
            ENTRY_BYTES = 16
            NAME = 0
            PICTURE = 2
            ART = 4
            HEIGHT = 6
            X = 8
            Y = 12
            # And in a game with a sprite that turns (Turning): the picture's width and whether this one turns, a
            # word each, its angle and its size, and the rows of its patch it can reach, a word each.
            TURNED_ENTRY_BYTES = 32
            WIDTH = 16
            TURNS = 18
            ANGLE = 20
            SCALE = 24
            REACH_BEGIN = 28
            REACH_END = 30

            module_function

            def turned?(memory) = memory.places.key?(TURNED)

            # Whether the sprites are drawn into the view at their levels (LEVELS).
            def stacked?(memory) = memory.places.key?(LEVELS)

            # How long a row of the table is, and the shift that multiplies by it.
            def entry_bytes(memory) = turned?(memory) ? TURNED_ENTRY_BYTES : ENTRY_BYTES
            def entry_shift(memory) = entry_bytes(memory).bit_length - 1

            # The places a reader of the running program is told of.
            def places(memory) = [PLACED, TABLE] + (turned?(memory) ? [TURNED] : [])

            # +most+ is how many sprites the game has: no pass places more. +turned+ is whether any of them
            # turns or changes size, and +stacked+ whether they are drawn at their levels in the stack.
            def reserve(memory, most, turned: false, stacked: false)
              memory.reserve(TURNED, 4) if turned
              memory.reserve(LEVELS, most) if stacked
              WORDS.each { |name| memory.reserve(name, 4) }
              memory.reserve(TABLE, most * entry_bytes(memory))
              memory.reserve(TABLE_BEFORE, most * entry_bytes(memory))
            end

            # What the start sets: no rows stood in yet.
            def starts(memory) = [[memory[ROWS_TOP], memory.screen.height]]

            def emit(asm, memory)
              screen = Edges.new(left: 0, top: 0, right: memory.screen.width, bottom: memory.screen.height)
              emit_place(asm, memory)
              emit_over_picture(asm, memory)
              emit_at_level(asm, memory) if stacked?(memory)
              Turning.emit(asm, memory) if turned?(memory)
              SpriteBlocks.emit(asm, memory) if SpriteBlocks.used?(memory)
              Runtime.emit_blit_routine(asm, memory, screen, name: "rt_sprite_blit", marks: false)
            end

            # rt_sprite_place: one more sprite in the table. Whose in DX and which picture in DI, the
            # picture's place in SI, x in EAX and y in ECX. Its height is read from the picture, since a
            # sprite's pictures can be of different sizes. Changes BX and BP.
            def emit_place(asm, memory)
              placed = X86.mem(nil, memory[PLACED], size: 16)
              entry = ->(part, size) { X86.mem(:bp, part, size: size) }
              asm.label("rt_sprite_place")
              asm.mov(:bp, placed)
              asm.shl(:bp, entry_shift(memory))
              asm.add(:bp, memory[TABLE])
              asm.mov(entry.call(TURNS, 16), 0) if turned?(memory) # until rt_sprite_turned says it does
              asm.mov(entry.call(NAME, 16), :dx)
              asm.mov(entry.call(PICTURE, 16), :di)
              asm.mov(entry.call(ART, 16), :si)
              asm.push(:ds)
              asm.mov_segment(:bx, :art)
              asm.mov(:ds, :bx)
              asm.mov(:bx, X86.mem(:si, 2, size: 16))
              asm.pop(:ds)
              asm.mov(entry.call(HEIGHT, 16), :bx)
              asm.mov(entry.call(X, 32), :eax)
              asm.mov(entry.call(Y, 32), :ecx)
              asm.inc(placed)
              asm.ret
            end

            # The rows a sprite that turns stands in, for the row of the table BP is at, with its y in EAX and its
            # picture's height in EDX: its patch, a picture's height taller than the picture and half of that
            # above it. A patch that can be counted round the screen's 256 rows (Turning) is every row. One that
            # does not turn goes on as it was. Changes EBX.
            def emit_turned_rows(asm, memory)
              asm.cmp(X86.mem(:bp, TURNS, size: 16), 0)
              asm.je("rt_sprites_rows_upright")
              asm.mov(:ebx, :edx)
              asm.shr(:ebx, 1)
              asm.sub(:eax, :ebx)
              asm.shl(:edx, 1)
              asm.add(:edx, :eax)
              asm.cmp(:eax, memory.screen.height - Reference::TurnedBox::LINES)
              asm.jl("rt_sprites_rows_every")
              asm.cmp(:edx, Reference::TurnedBox::LINES)
              asm.jle("rt_sprites_rows_known")
              asm.label("rt_sprites_rows_every")
              asm.xor(:eax, :eax)
              asm.mov(:edx, memory.screen.height)
              asm.jmp("rt_sprites_rows_known")
              asm.label("rt_sprites_rows_upright")
            end

            # rt_sprites_over_picture: the picture shown made from the game's picture and the sprites placed
            # (the three steps above). Changes every register but the segment ones (Rows says what ES is then).
            def emit_over_picture(asm, memory)
              height = memory.screen.height
              placed = X86.mem(nil, memory[PLACED], size: 16)
              top = X86.mem(nil, memory[ROWS_TOP], size: 16)
              bottom = X86.mem(nil, memory[ROWS_BOTTOM], size: 16)
              entry = ->(part, size) { X86.mem(:bp, part, size: size) }
              asm.label("rt_sprites_over_picture")
              # 0. The same sprites in the same places showing the same pictures?
              asm.mov(:cx, placed)
              asm.cmp(:cx, X86.mem(nil, memory[PLACED_BEFORE], size: 16))
              asm.jne("rt_sprites_changed")
              asm.shl(:cx, entry_shift(memory)) # the bytes of the table in use
              asm.push(:es)
              asm.push(:ds)
              asm.pop(:es)
              asm.mov(:si, memory[TABLE])
              asm.mov(:di, memory[TABLE_BEFORE])
              asm.cmp(:cx, :cx) # so that no sprites at all is "the same"
              asm.cmps(8, rep: true)
              asm.pop(:es)
              asm.jne("rt_sprites_changed")
              asm.mov(:ax, X86.mem(nil, memory[Frame::CHANGED_BOTTOM], size: 16))
              asm.cmp(:ax, X86.mem(nil, memory[Frame::CHANGED_TOP], size: 16))
              asm.jbe("rt_sprites_drawn") # and the game changed no row: the picture shown is right as it is
              asm.jmp("rt_sprites_rows_marked")
              asm.label("rt_sprites_changed")
              asm.mov(:cx, placed)
              asm.mov(X86.mem(nil, memory[PLACED_BEFORE], size: 16), :cx)
              asm.shl(:cx, entry_shift(memory))
              asm.push(:es)
              asm.push(:ds)
              asm.pop(:es)
              asm.mov(:si, memory[TABLE])
              asm.mov(:di, memory[TABLE_BEFORE])
              asm.movs(8, rep: true)
              asm.pop(:es)
              # 1. Where they stood last time, and where they stand now.
              asm.mov(:ax, top)
              asm.mov(:dx, bottom)
              asm.cmp(:ax, :dx)
              asm.jae("rt_sprites_stood_nowhere")
              Runtime.emit_mark_rows(asm, memory, :ax, :dx, "rt_sprites_stood")
              asm.label("rt_sprites_stood_nowhere")
              asm.mov(top, height)
              asm.mov(bottom, 0)
              asm.mov(:cx, placed)
              asm.test(:cx, :cx)
              asm.je("rt_sprites_rows_marked")
              asm.mov(:bp, memory[TABLE])
              asm.label("rt_sprites_rows")
              asm.mov(:eax, entry.call(Y, 32))
              asm.movzx(:edx, entry.call(HEIGHT, 16))
              emit_turned_rows(asm, memory) if turned?(memory)
              asm.add(:edx, :eax)
              asm.label("rt_sprites_rows_known")
              asm.cmp(:eax, 0)
              asm.jge("rt_sprites_top_held")
              asm.xor(:eax, :eax)
              asm.label("rt_sprites_top_held")
              asm.cmp(:edx, height)
              asm.jle("rt_sprites_bottom_held")
              asm.mov(:edx, height)
              asm.label("rt_sprites_bottom_held")
              asm.cmp(:eax, :edx)
              asm.jge("rt_sprites_rows_next")
              asm.cmp(:ax, top)
              asm.jae("rt_sprites_top_kept")
              asm.mov(top, :ax)
              asm.label("rt_sprites_top_kept")
              asm.cmp(:dx, bottom)
              asm.jbe("rt_sprites_bottom_kept")
              asm.mov(bottom, :dx)
              asm.label("rt_sprites_bottom_kept")
              Runtime.emit_mark_rows(asm, memory, :ax, :dx, "rt_sprites_stand")
              asm.label("rt_sprites_rows_next")
              asm.add(:bp, entry_bytes(memory))
              asm.dec(:cx)
              asm.jne("rt_sprites_rows")
              asm.label("rt_sprites_rows_marked")
              # 2. The game's picture, where anything changed.
              asm.call("rt_picture_rows")
              return emit_drawn_already(asm) if stacked?(memory)

              # 3. The sprites over it.
              asm.mov(:cx, placed)
              asm.test(:cx, :cx)
              asm.je("rt_sprites_drawn")
              Rows.emit_push_picture_segment(asm, memory.screen)
              Rows.emit_picture_segment(asm, memory.screen, :shown)
              asm.mov(:bp, memory[TABLE])
              asm.label("rt_sprites_draw")
              asm.push(:cx)
              asm.push(:bp)
              emit_entry_drawn(asm, memory, "rt_sprites_draw")
              asm.pop(:bp)
              asm.pop(:cx)
              asm.add(:bp, entry_bytes(memory))
              asm.dec(:cx)
              asm.jne("rt_sprites_draw")
              Rows.emit_pop_picture_segment(asm, memory.screen)
              asm.label("rt_sprites_drawn")
              asm.ret
            end

            # The end of rt_sprites_over_picture where the sprites are in the game's picture already (LEVELS).
            def emit_drawn_already(asm)
              asm.label("rt_sprites_drawn")
              asm.ret
            end

            # One sprite of the table drawn into the picture ES (and FS) name, with BP at its row.
            def emit_entry_drawn(asm, memory, tag)
              entry = ->(part, size) { X86.mem(:bp, part, size: size) }
              if turned?(memory)
                asm.cmp(entry.call(TURNS, 16), 0)
                asm.je("#{tag}_upright")
                asm.call("rt_sprite_turned_blit")
                asm.jmp("#{tag}_next")
                asm.label("#{tag}_upright")
              end
              SpriteBlocks.emit_unless_in_blocks(asm, memory, "#{tag}_in_blocks") if SpriteBlocks.used?(memory)
              asm.mov(:si, entry.call(ART, 16))
              asm.mov(:eax, entry.call(X, 32))
              asm.mov(:ecx, entry.call(Y, 32))
              asm.call("rt_sprite_blit")
              if SpriteBlocks.used?(memory)
                asm.jmp("#{tag}_next")
                asm.label("#{tag}_in_blocks")
                asm.call("rt_sprite_blocks_blit")
              end
              asm.label("#{tag}_next")
            end

            # rt_paint_sprite_tile: one tile the game loads (Lowering::Sprites#emit_load_sprite_tiles) painted into a
            # picture, all in the art segment: SI at the tile's first byte, its 32 a row of four after another (the
            # left pixel in each byte's low four bits), CX bytes apart; DI at the pixel of the picture its top left
            # lands on, the picture DX pixels wide; BX at its set's colours, a palette entry for each of the sixteen
            # places, the see-through entry for place nought. Changes every register but the segment ones.
            def emit_paint_tile(asm)
              asm.label("rt_paint_sprite_tile")
              asm.push(:ds)
              asm.push(:es)
              asm.mov_segment(:ax, :art)
              asm.mov(:ds, :ax)
              asm.mov(:es, :ax)
              asm.sub(:dx, 8) # from a row's end to the next row's start
              asm.mov(:bp, 8)
              asm.label("rt_paint_sprite_tile_row")
              4.times do
                asm.mov(:al, X86.mem(:si, 0, size: 8))
                asm.add(:si, :cx)
                asm.push(:ax)
                [0x0F, nil].each do |low|
                  if low
                    asm.and(:ax, low)
                  else
                    asm.pop(:ax)
                    asm.shr(:al, 4)
                    asm.xor(:ah, :ah)
                  end
                  asm.push(:bx)
                  asm.add(:bx, :ax)
                  asm.mov(:al, X86.mem(:bx, 0, size: 8))
                  asm.pop(:bx)
                  asm.stos(8)
                end
              end
              asm.add(:di, :dx)
              asm.dec(:bp)
              asm.jne("rt_paint_sprite_tile_row")
              asm.pop(:es)
              asm.pop(:ds)
              asm.ret
            end

            # rt_sprites_at_level: each sprite placed whose level is AL drawn into the game's picture, in the table's
            # order, as the view is built. Changes every register but the segment ones and AL.
            def emit_at_level(asm, memory)
              asm.label("rt_sprites_at_level")
              asm.mov(:cx, X86.mem(nil, memory[PLACED], size: 16))
              asm.test(:cx, :cx)
              asm.je("rt_sprites_at_level_done")
              asm.mov(:bp, memory[TABLE])
              asm.mov(:bx, memory[LEVELS])
              asm.label("rt_sprites_at_level_each")
              asm.cmp(X86.mem(:bx, 0, size: 8), :al)
              asm.jne("rt_sprites_at_level_passed")
              %i[ax bx cx bp].each { |register| asm.push(register) }
              emit_entry_drawn(asm, memory, "rt_sprites_at_level_draw")
              %i[bp cx bx ax].each { |register| asm.pop(register) }
              asm.label("rt_sprites_at_level_passed")
              asm.add(:bp, entry_bytes(memory))
              asm.inc(:bx)
              asm.dec(:cx)
              asm.jne("rt_sprites_at_level_each")
              asm.label("rt_sprites_at_level_done")
              asm.ret
            end
          end
        end
      end
    end
  end
end
