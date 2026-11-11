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
            WORDS = [PLACED, PLACED_BEFORE, ROWS_TOP, ROWS_BOTTOM].freeze
            PLACES = [PLACED, TABLE].freeze

            # One sprite placed: whose and which picture (SpriteNames' numbers), the picture's place in the art
            # segment and its height, a word each, then its x and y.
            ENTRY_BYTES = 16
            NAME = 0
            PICTURE = 2
            ART = 4
            HEIGHT = 6
            X = 8
            Y = 12

            module_function

            # +most+ is how many sprites the game has: no pass places more.
            def reserve(memory, most)
              WORDS.each { |name| memory.reserve(name, 4) }
              memory.reserve(TABLE, most * ENTRY_BYTES)
              memory.reserve(TABLE_BEFORE, most * ENTRY_BYTES)
            end

            # What the start sets: no rows stood in yet.
            def starts(memory) = [[memory[ROWS_TOP], memory.screen.height]]

            def emit(asm, memory)
              screen = Edges.new(left: 0, top: 0, right: memory.screen.width, bottom: memory.screen.height)
              emit_place(asm, memory)
              emit_over_picture(asm, memory)
              Runtime.emit_copy_changed_rows(asm, memory, "rt_sprites_picture_rows", from: :back, to: :shown, forget: false)
              Runtime.emit_blit_routine(asm, memory, screen, name: "rt_sprite_blit", marks: false)
            end

            # rt_sprite_place: one more sprite in the table. Whose in DX and which picture in DI, the
            # picture's place in SI and its height in BX, x in EAX and y in ECX. Changes BP.
            def emit_place(asm, memory)
              placed = X86.mem(nil, memory[PLACED], size: 16)
              entry = ->(part, size) { X86.mem(:bp, part, size: size) }
              asm.label("rt_sprite_place")
              asm.mov(:bp, placed)
              asm.shl(:bp, 4)
              asm.add(:bp, memory[TABLE])
              asm.mov(entry.call(NAME, 16), :dx)
              asm.mov(entry.call(PICTURE, 16), :di)
              asm.mov(entry.call(ART, 16), :si)
              asm.mov(entry.call(HEIGHT, 16), :bx)
              asm.mov(entry.call(X, 32), :eax)
              asm.mov(entry.call(Y, 32), :ecx)
              asm.inc(placed)
              asm.ret
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
              asm.shl(:cx, 4) # the bytes of the table in use
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
              asm.shl(:cx, 4)
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
              asm.add(:edx, :eax)
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
              asm.add(:bp, ENTRY_BYTES)
              asm.dec(:cx)
              asm.jne("rt_sprites_rows")
              asm.label("rt_sprites_rows_marked")
              # 2. The game's picture, where anything changed.
              asm.call("rt_sprites_picture_rows")
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
              asm.mov(:si, entry.call(ART, 16))
              asm.mov(:eax, entry.call(X, 32))
              asm.mov(:ecx, entry.call(Y, 32))
              asm.call("rt_sprite_blit")
              asm.pop(:bp)
              asm.pop(:cx)
              asm.add(:bp, ENTRY_BYTES)
              asm.dec(:cx)
              asm.jne("rt_sprites_draw")
              Rows.emit_pop_picture_segment(asm, memory.screen)
              asm.label("rt_sprites_drawn")
              asm.ret
            end
          end
        end
      end
    end
  end
end
