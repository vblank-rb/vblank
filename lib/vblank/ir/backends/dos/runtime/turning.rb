# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # A SPRITE THAT TURNS OR CHANGES SIZE, drawn by the processor into the picture shown. No card turns a
          # picture, so this is the sum the interpreter does (Reference#blit_image_transformed), a pixel at a
          # time: the sprite has a patch of the screen twice its picture's size each way, about the picture's
          # middle, so a corner has room to swing, and for each pixel of the patch the sum works back to which
          # pixel of the picture shows there, if any.
          #
          # The four numbers of that sum (IR::Affine.matrix) are in 256ths: the sine and cosine of the angle,
          # from a table of 360 beside the code, each times one over the size. Along a row of the patch the
          # picture's column and row each change by one of those numbers, so a pixel costs two additions, two
          # shifts and the tests that it is inside the picture and on the screen.
          #
          # WHICH ROW OF THE SCREEN A ROW OF THE PATCH LANDS ON is counted round at 256 (Reference::TurnedBox,
          # which every build keeps so that they agree): a patch that reaches past row 255 shows its last
          # rows at the top of the screen. Sprites marks every row as changed for a patch that can do that.
          #
          # A sprite that turns has more in its row of the sprites' table (Sprites::TURNED_ENTRY_BYTES): its
          # picture's width, whether it turns, its angle and size as the game last gave them, and the rows
          # of its patch it can reach (IR::Affine.rows_reached), outside which it is not drawn at all.
          module Turning
            SINES = Ractor.make_shareable((0...360).map { |degrees| Affine.sine(degrees) })

            # The numbers the routine keeps on the stack while it draws, a place each of four bytes.
            FRAME = %i[across_by_column across_by_row down_by_column down_by_row width height half_width half_height left top
                      row_across row_down row rows pixels count].each_with_index.to_h { |name, i| [name, i * 4] }.freeze
            FRAME_BYTES = FRAME.size * 4

            module_function

            def emit(asm, memory)
              emit_turned(asm, memory)
              emit_blit(asm, memory)
              asm.label("rt_sines")
              asm.bytes(SINES.pack("s<*"))
            end

            # rt_sprite_turned: the sprite just placed turns. Its angle in EAX and its size in ECX, its picture's
            # width in DX, and the first row of its patch it can reach and the row after the last in BX and SI.
            # Called straight after rt_sprite_place, whose row of the table it adds to. Changes BP.
            def emit_turned(asm, memory)
              entry = ->(part, size) { X86.mem(:bp, part, size: size) }
              asm.label("rt_sprite_turned")
              asm.mov(:bp, X86.mem(nil, memory[Sprites::PLACED], size: 16))
              asm.dec(:bp)
              asm.shl(:bp, Sprites.entry_shift(memory))
              asm.add(:bp, memory[Sprites::TABLE])
              asm.mov(entry.call(Sprites::WIDTH, 16), :dx)
              asm.mov(entry.call(Sprites::TURNS, 16), 1)
              asm.mov(entry.call(Sprites::ANGLE, 32), :eax)
              asm.mov(entry.call(Sprites::SCALE, 32), :ecx)
              asm.mov(entry.call(Sprites::REACH_BEGIN, 16), :bx)
              asm.mov(entry.call(Sprites::REACH_END, 16), :si)
              asm.ret
            end

            # rt_sprite_turned_blit: the sprite whose row of the table BP is at, drawn turned into the picture
            # ES (and FS, Rows) is set to. Changes every register but the segment ones.
            def emit_blit(asm, memory)
              screen = memory.screen
              entry = ->(part, size) { X86.mem(:bx, part, size: size) }
              frame = ->(name, size = 32) { X86.mem(:bp, FRAME.fetch(name), size: size) }
              asm.label("rt_sprite_turned_blit")
              asm.mov(:bx, :bp)
              asm.push(:ds)
              asm.sub(:sp, FRAME_BYTES)
              asm.mov(:bp, :sp)
              # The picture's size, half of it, and where the patch stands: half a picture out on every side.
              asm.xor(:eax, :eax)
              asm.mov(:ax, entry.call(Sprites::WIDTH, 16))
              asm.mov(frame.call(:width), :eax)
              asm.shr(:eax, 1)
              asm.mov(frame.call(:half_width), :eax)
              asm.xor(:eax, :eax)
              asm.mov(:ax, entry.call(Sprites::HEIGHT, 16))
              asm.mov(frame.call(:height), :eax)
              asm.mov(:ecx, :eax)
              asm.shl(:ecx, 1)
              asm.mov(frame.call(:rows), :ecx)
              asm.shr(:eax, 1)
              asm.mov(frame.call(:half_height), :eax)
              asm.mov(:eax, entry.call(Sprites::X, 32))
              asm.sub(:eax, frame.call(:half_width))
              asm.mov(frame.call(:left), :eax)
              asm.mov(:eax, entry.call(Sprites::Y, 32))
              asm.sub(:eax, frame.call(:half_height))
              asm.mov(frame.call(:top), :eax)
              # Not drawn at all unless the rows it can reach meet the screen (TurnedBox.rows_shown).
              asm.movsx(:ecx, entry.call(Sprites::REACH_END, 16))
              asm.add(:ecx, :eax)
              asm.cmp(:ecx, 0)
              asm.jle("rt_sprite_turned_done")
              asm.movsx(:ecx, entry.call(Sprites::REACH_BEGIN, 16))
              asm.add(:ecx, :eax)
              asm.cmp(:ecx, screen.height)
              asm.jge("rt_sprite_turned_done")
              asm.mov(:ax, entry.call(Sprites::ART, 16))
              asm.add(:ax, 4)
              asm.mov(frame.call(:pixels, 16), :ax)
              # The angle as degrees from 0 to 359, whichever way round the game counted it.
              asm.mov(:eax, entry.call(Sprites::ANGLE, 32))
              asm.cdq
              asm.mov(:ecx, 360)
              asm.idiv(:ecx)
              asm.test(:edx, :edx)
              asm.jns("rt_sprite_turned_degrees")
              asm.add(:edx, 360)
              asm.label("rt_sprite_turned_degrees")
              asm.push(:dx)
              # One over the size, in 256ths (Affine.reciprocal), into ECX.
              asm.mov(:ecx, entry.call(Sprites::SCALE, 32))
              asm.cmp(:ecx, Affine::MIN_SCALE)
              asm.jge("rt_sprite_turned_size")
              asm.mov(:ecx, Affine::MIN_SCALE)
              asm.label("rt_sprite_turned_size")
              asm.mov(:eax, Build::SCALE_ONE * Affine::ONE_TH)
              asm.xor(:edx, :edx)
              asm.div(:ecx)
              asm.cmp(:eax, Affine::MAX)
              asm.jbe("rt_sprite_turned_size_held")
              asm.mov(:eax, Affine::MAX)
              asm.label("rt_sprite_turned_size_held")
              asm.mov(:ecx, :eax)
              asm.pop(:bx) # the degrees: the sprite's row of the table is read no more
              # The sine and the cosine, each times that, a 256th of it kept, rounded down as the interpreter's
              # division rounds (Affine.matrix).
              asm.mov_offset(:si, "rt_sines")
              asm.push(:bx)
              asm.shl(:bx, 1)
              asm.add(:bx, :si)
              asm.movsx(:eax, X86.mem(:bx, 0, seg: :cs, size: 16))
              asm.imul(:eax, :ecx)
              asm.sar(:eax, 8)
              asm.mov(frame.call(:across_by_row), :eax)
              asm.neg(:eax)
              asm.mov(frame.call(:down_by_column), :eax)
              asm.pop(:bx)
              asm.add(:bx, 90) # the cosine is the sine a quarter turn on
              asm.cmp(:bx, 360)
              asm.jb("rt_sprite_turned_cosine")
              asm.sub(:bx, 360)
              asm.label("rt_sprite_turned_cosine")
              asm.shl(:bx, 1)
              asm.add(:bx, :si)
              asm.movsx(:eax, X86.mem(:bx, 0, seg: :cs, size: 16))
              asm.imul(:eax, :ecx)
              asm.sar(:eax, 8)
              asm.mov(frame.call(:across_by_column), :eax)
              asm.mov(frame.call(:down_by_row), :eax)
              # Where in the picture the patch's first pixel is, in 256ths from the picture's middle: a picture's
              # width to the left of it and a height above.
              starts = [[:row_across, :across_by_column, :across_by_row], [:row_down, :down_by_column, :down_by_row]]
              starts.each do |start, by_column, by_row|
                asm.mov(:eax, frame.call(by_column))
                asm.imul(:eax, frame.call(:width))
                asm.mov(:ecx, frame.call(by_row))
                asm.imul(:ecx, frame.call(:height))
                asm.add(:eax, :ecx)
                asm.neg(:eax)
                asm.mov(frame.call(start), :eax)
              end
              asm.mov(frame.call(:row), 0)
              asm.mov_segment(:ax, :art)
              asm.mov(:ds, :ax)

              asm.label("rt_sprite_turned_row")
              asm.mov(:eax, frame.call(:top))
              asm.add(:eax, frame.call(:row))
              asm.and(:eax, Reference::TurnedBox::LINES - 1)
              asm.cmp(:eax, screen.height)
              asm.jae("rt_sprite_turned_row_done")
              if Rows.apart?(screen)
                asm.mov(:ecx, :eax)
                Rows.emit_row_start(asm, screen, :ecx)
              else
                asm.mov(:ecx, screen.width)
                asm.imul(:eax, :ecx)
                asm.mov(:di, :ax)
              end
              asm.mov(:ebx, frame.call(:row_across))
              asm.mov(:edx, frame.call(:row_down))
              asm.mov(:esi, frame.call(:left))
              asm.mov(:ax, frame.call(:width, 16))
              asm.shl(:ax, 1)
              asm.mov(frame.call(:count, 16), :ax)
              # A pixel of the patch: on the screen, inside the picture, and something drawn there. EBX and EDX
              # are where it is in the picture across and down, ESI its x on the screen, DI the row's start.
              asm.label("rt_sprite_turned_pixel")
              asm.cmp(:esi, screen.width) # as numbers with no sign, so left of the screen is past its end too
              asm.jae("rt_sprite_turned_pixel_done")
              asm.mov(:eax, :ebx)
              asm.sar(:eax, 8)
              asm.add(:eax, frame.call(:half_width))
              asm.cmp(:eax, frame.call(:width))
              asm.jae("rt_sprite_turned_pixel_done")
              asm.mov(:ecx, :edx)
              asm.sar(:ecx, 8)
              asm.add(:ecx, frame.call(:half_height))
              asm.cmp(:ecx, frame.call(:height))
              asm.jae("rt_sprite_turned_pixel_done")
              asm.imul(:ecx, frame.call(:width))
              asm.add(:cx, :ax)
              asm.add(:cx, frame.call(:pixels, 16))
              asm.push(:bx)
              asm.mov(:bx, :cx)
              asm.mov(:al, X86.mem(:bx, 0, size: 8))
              asm.pop(:bx)
              asm.cmp(:al, TRANSPARENT)
              asm.je("rt_sprite_turned_pixel_done")
              asm.mov(:cx, :di)
              asm.add(:di, :si)
              asm.mov(X86.mem(:di, 0, seg: :es, size: 8), :al)
              asm.mov(:di, :cx)
              asm.label("rt_sprite_turned_pixel_done")
              asm.add(:ebx, frame.call(:across_by_column))
              asm.add(:edx, frame.call(:down_by_column))
              asm.inc(:esi)
              asm.dec(frame.call(:count, 16))
              asm.jne("rt_sprite_turned_pixel")
              asm.label("rt_sprite_turned_row_done")
              asm.mov(:eax, frame.call(:across_by_row))
              asm.add(frame.call(:row_across), :eax)
              asm.mov(:eax, frame.call(:down_by_row))
              asm.add(frame.call(:row_down), :eax)
              asm.mov(:eax, frame.call(:row))
              asm.inc(:eax)
              asm.mov(frame.call(:row), :eax)
              asm.cmp(:eax, frame.call(:rows))
              asm.jb("rt_sprite_turned_row")
              asm.label("rt_sprite_turned_done")
              asm.add(:sp, FRAME_BYTES)
              asm.pop(:ds)
              asm.ret
            end
          end
        end
      end
    end
  end
end
