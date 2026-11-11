# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # A PATCH OF THE PICTURE KEPT AND PUT BACK (`save_region`, `restore_region`), which is how a sprite
          # painted into the picture moves without rubbing out what it stood on: before it is drawn, the patch
          # under it is kept, and before it is drawn somewhere else, the patch is put back.
          #
          # A patch is kept in the data segment in the shape a picture has in the art segment (its width and
          # height, a word each, then a byte a pixel, a row at a time), so putting one back is the routine that
          # draws a picture, reading the data segment (rt_restore_region: held to the area the game's drawing
          # is held to, as Framebuffer#set_pixel holds it). A pixel of the patch that was off the screen when
          # it was kept holds what a picture holds where nothing is drawn (TRANSPARENT), and is passed over
          # when the patch is put back, as the interpreter passes over a cell it never read.
          module Regions
            module_function

            def emit(asm, memory, edges)
              emit_save(asm, memory.screen)
              Runtime.emit_blit_routine(asm, memory, edges, name: "rt_restore_region", from_art: false)
            end

            # rt_save_region: the patch at offset SI of the data segment filled from the game's picture, its
            # top left at x in EAX and y in ECX. On the stack, from BP: the x of its left edge, the y of the
            # row to keep next, its width, and the rows left. Changes every register but the segment ones.
            def emit_save(asm, screen)
              frame = ->(offset, size) { X86.mem(:bp, offset, size: size) }
              asm.label("rt_save_region")
              asm.sub(:sp, 12)
              asm.mov(:bp, :sp)
              asm.mov(frame.call(0, 32), :eax)
              asm.mov(frame.call(4, 32), :ecx)
              asm.mov(:dx, X86.mem(:si, 0))
              asm.mov(frame.call(8, 16), :dx)
              asm.mov(:dx, X86.mem(:si, 2))
              asm.mov(frame.call(10, 16), :dx)
              asm.add(:si, 4)
              asm.label("rt_save_region_row")
              asm.mov(:dx, frame.call(10, 16))
              asm.test(:dx, :dx)
              asm.je("rt_save_region_done")
              asm.dec(:dx)
              asm.mov(frame.call(10, 16), :dx)
              asm.mov(:ecx, frame.call(4, 32))
              asm.inc(frame.call(4, 32))
              asm.mov(:ebx, frame.call(0, 32))
              # Where the row's first pixel is in the picture, which is used only for a pixel on the screen.
              asm.mov(:eax, screen.width)
              asm.imul(:eax, :ecx)
              asm.add(:eax, :ebx)
              asm.mov(:di, :ax)
              asm.mov(:dx, frame.call(8, 16))
              asm.label("rt_save_region_pixel")
              asm.mov(:al, TRANSPARENT)
              # As numbers with no sign, so one below nought is off the screen as one past its edge is.
              asm.cmp(:ecx, screen.height)
              asm.jae("rt_save_region_kept")
              asm.cmp(:ebx, screen.width)
              asm.jae("rt_save_region_kept")
              asm.mov(:al, X86.mem(:di, 0, seg: :es))
              asm.label("rt_save_region_kept")
              asm.mov(X86.mem(:si, 0), :al)
              asm.inc(:si)
              asm.inc(:di)
              asm.inc(:ebx)
              asm.dec(:dx)
              asm.jne("rt_save_region_pixel")
              asm.jmp("rt_save_region_row")
              asm.label("rt_save_region_done")
              asm.add(:sp, 12)
              asm.ret
            end
          end
        end
      end
    end
  end
end
