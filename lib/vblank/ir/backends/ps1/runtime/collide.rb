# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # WHETHER TWO SPRITES' DRAWN PIXELS TOUCH (Reference#pixels_overlap?): only the rectangle where
          # the two pictures overlap is walked, a row at a time, stopping at the first pixel both draw.
          # Each picture is a mask made while the program is built (Lowering::Collision): its width and its
          # height, a word each, then a byte a pixel, row by row, 1 where it draws.
          module Collide
            MASK_WIDTH = 0
            MASK_HEIGHT = 4
            MASK_PIXELS = 8
            SAVED_REGISTERS = %i[s0 s1 s2 s3 s4 s5].freeze

            module_function

            # rt_pixels_overlap: a0 = the first sprite's list of masks (how many, then each one's place, a
            # word each), a1 = which it shows, a2, a3 = where; t4 to t7 the same of the second. v0 = 1 when a
            # pixel both draw lands on one place, 0 when none does. A number naming none of a sprite's
            # pictures touches nothing.
            def emit(asm)
              asm.label("rt_pixels_overlap")
              asm.addiu(:sp, :sp, -4 * SAVED_REGISTERS.length)
              SAVED_REGISTERS.each_with_index { |register, i| asm.sw(register, i * 4, :sp) }
              emit_mask(asm, list: :a0, which: :a1, pixels: :s0, width: :s1, height: :s4)
              emit_mask(asm, list: :t4, which: :t5, pixels: :s2, width: :s3, height: :s5)
              # x0, x1 in t0, t1; y0, y1 in t2, t3: the later starts and the earlier ends.
              emit_later(asm, :t0, :a2, :t6)
              asm.addu(:t8, :a2, :s1)
              asm.addu(:t9, :t6, :s3)
              emit_earlier(asm, :t1, :t8, :t9)
              asm.slt(:t8, :t0, :t1)
              asm.beq(:t8, :zero, "rt_pixels_overlap_none")
              emit_later(asm, :t2, :a3, :t7)
              asm.addu(:t8, :a3, :s4)
              asm.addu(:t9, :t7, :s5)
              emit_earlier(asm, :t3, :t8, :t9)
              asm.slt(:t8, :t2, :t3)
              asm.beq(:t8, :zero, "rt_pixels_overlap_none")
              asm.label("rt_pixels_overlap_row")
              # The first pixel of this row of the overlap in each mask: its row times its width, and across.
              asm.subu(:t8, :t2, :a3)
              asm.mult(:t8, :s1)
              asm.mflo(:t8)
              asm.addu(:t8, :t8, :s0)
              asm.subu(:t9, :t0, :a2)
              asm.addu(:t8, :t8, :t9)
              asm.subu(:t9, :t2, :t7)
              asm.mult(:t9, :s3)
              asm.mflo(:t9)
              asm.addu(:t9, :t9, :s2)
              asm.subu(:v0, :t0, :t6)
              asm.addu(:t9, :t9, :v0)
              asm.subu(:v1, :t1, :t0)
              asm.label("rt_pixels_overlap_pixel")
              asm.lbu(:v0, 0, :t8)
              asm.lbu(:a0, 0, :t9)
              asm.and(:v0, :v0, :a0)
              asm.bne(:v0, :zero, "rt_pixels_overlap_hit")
              asm.addiu(:t8, :t8, 1)
              asm.addiu(:v1, :v1, -1)
              asm.bgtz(:v1, "rt_pixels_overlap_pixel") { asm.addiu(:t9, :t9, 1) }
              asm.addiu(:t2, :t2, 1)
              asm.slt(:v0, :t2, :t3)
              asm.bne(:v0, :zero, "rt_pixels_overlap_row")
              asm.label("rt_pixels_overlap_none")
              asm.b("rt_pixels_overlap_end") { asm.move(:v0, :zero) }
              asm.label("rt_pixels_overlap_hit")
              asm.li(:v0, 1)
              asm.label("rt_pixels_overlap_end")
              SAVED_REGISTERS.each_with_index { |register, i| asm.lw(register, i * 4, :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * SAVED_REGISTERS.length) }
            end

            # +pixels+, +width+ and +height+ of the mask numbered +which+ in +list+; on to the end with v0 = 0
            # for a number naming none.
            def emit_mask(asm, list:, which:, pixels:, width:, height:)
              asm.lw(:t8, 0, list)
              asm.sltu(:t8, which, :t8)
              asm.beq(:t8, :zero, "rt_pixels_overlap_none")
              asm.sll(:t8, which, 2)
              asm.addu(:t8, :t8, list)
              asm.lw(:t8, 4, :t8)
              asm.lw(width, MASK_WIDTH, :t8)
              asm.lw(height, MASK_HEIGHT, :t8)
              asm.addiu(pixels, :t8, MASK_PIXELS)
            end

            # +into+ = the larger of +a+ and +b+ (#emit_later), and the smaller (#emit_earlier): +a+, and +b+
            # where it is past +a+ that way. The branch's delay slot puts +a+ in, so a taken branch keeps it.
            # Changes v0.
            def emit_later(asm, into, a, b) = emit_pick(asm, into, a, b, past: :later)
            def emit_earlier(asm, into, a, b) = emit_pick(asm, into, a, b, past: :earlier)

            def emit_pick(asm, into, a, b, past:)
              kept = "rt_pixels_overlap_#{into}_kept"
              past == :later ? asm.slt(:v0, a, b) : asm.slt(:v0, b, a)
              asm.beq(:v0, :zero, kept) { asm.move(into, a) }
              asm.move(into, b)
              asm.label(kept)
            end
          end
        end
      end
    end
  end
end
