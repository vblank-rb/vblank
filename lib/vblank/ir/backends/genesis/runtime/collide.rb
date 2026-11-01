# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # DO TWO SPRITES' DRAWN PIXELS TOUCH? (`a.overlaps?(b)` without a `hitbox:`,
          # Reference#pixels_overlap?.) Each sprite is showing one of its pictures, picked by a number, at a
          # place; the two pictures' boxes may overlap, and where they do, each pixel is asked whether both
          # pictures draw it. The first one both draw answers yes.
          #
          # Each picture a sprite can show is kept for this as a MASK (Lowering::Collision): a bit for each
          # of its pixels, set where it draws, eight to a byte, leftmost pixel in the top bit, a row at a
          # time. The table "collision pictures" says where each is, its width and its height, and a sprite's
          # pictures are a list: how many, then each picture's mask number.
          #
          #   rt_pixels_overlap(a_list, a_pose, a_x, a_y, b_list, b_pose, b_x, b_y)    D0 = 1 or 0
          #
          # A pose below nought counts back from the last picture, as the interpreter reads it; one that
          # names none of them stops the game (PICTURE_NOT_THERE). The eight numbers are all the data
          # registers there are, so the routine keeps them on the stack and works from there, with A6 at them.
          module Collide
            # Where each is, from A6, once the eight are pushed: the lists, poses and places of A then B.
            LIST_A = 0
            POSE_A = 4
            X_A = 8
            Y_A = 12
            LIST_B = 16
            POSE_B = 20
            X_B = 24
            Y_B = 28

            module_function

            def emit(asm, memory)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_picture(asm, at)
              emit_overlap(asm)
            end

            # rt_collide_picture: A0 = a list of masks, D0 = a pose; gives A1 = the picture's mask, D1 = its
            # width, D2 = its height. It leaves D4, D5, A2 and A3 alone, which the caller holds the
            # first sprite's mask and size in while it asks about the second.
            def emit_picture(asm, at)
              asm.label("rt_collide_picture")
              asm.move(:l, asm.d(0), asm.d(6)) # the pose, kept for the fault
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.post(0), asm.d(3))
              asm.tst(:l, asm.d(0))
              asm.branch(:pl, "rt_collide_picture_counted")
              asm.add(:l, asm.d(3), asm.d(0))
              asm.label("rt_collide_picture_counted")
              asm.cmp(:l, asm.d(3), asm.d(0))
              asm.branch(:cc, "rt_collide_picture_none")
              asm.lsl(:l, 1, asm.d(0))
              asm.moveq(0, asm.d(1))
              asm.move(:w, asm.idx(0, 0, 0), asm.d(1))
              asm.lsl(:l, 3, asm.d(1))
              asm.lea(asm.abs_l("collision pictures"), asm.a(1))
              asm.add(:l, asm.d(1), asm.a(1))
              asm.movea(:l, asm.post(1), asm.a(4))
              asm.moveq(0, asm.d(1))
              asm.move(:w, asm.post(1), asm.d(1))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.ind(1), asm.d(2))
              asm.movea(:l, asm.a(4), asm.a(1))
              asm.rts
              asm.label("rt_collide_picture_none")
              # The pose and the count: the fault's two numbers, as the interpreter words it.
              asm.move(:l, asm.d(6), at.call(Frame::FAULT, Frame::FAULT_FIRST))
              asm.move(:l, asm.d(3), at.call(Frame::FAULT, Frame::FAULT_SECOND))
              asm.moveq(Frame::PICTURE_NOT_THERE, asm.d(0))
              asm.jmp(asm.abs_l("rt_fault"))
            end

            def emit_overlap(asm)
              asm.label("rt_pixels_overlap")
              asm.movem_push(:l, :d0, :d1, :d2, :d3, :d4, :d5, :d6, :d7)
              asm.movea(:l, asm.a(7), asm.a(6))
              # Each sprite's picture: A2 and A3 its mask, then D4 and D5, D6 and D7 its width and height.
              asm.movea(:l, asm.disp(6, LIST_A), asm.a(0))
              asm.move(:l, asm.disp(6, POSE_A), asm.d(0))
              asm.jsr(asm.abs_l("rt_collide_picture"))
              asm.movea(:l, asm.a(1), asm.a(2))
              asm.move(:l, asm.d(1), asm.d(4))
              asm.move(:l, asm.d(2), asm.d(5))
              asm.movea(:l, asm.disp(6, LIST_B), asm.a(0))
              asm.move(:l, asm.disp(6, POSE_B), asm.d(0))
              asm.jsr(asm.abs_l("rt_collide_picture"))
              asm.movea(:l, asm.a(1), asm.a(3))
              asm.move(:l, asm.d(1), asm.d(6))
              asm.move(:l, asm.d(2), asm.d(7))
              # Where the second sits from the first, kept where the places were: across in X_A, down in Y_A.
              asm.move(:l, asm.disp(6, X_B), asm.d(0))
              asm.sub(:l, asm.disp(6, X_A), asm.d(0))
              asm.move(:l, asm.d(0), asm.disp(6, X_A))
              asm.move(:l, asm.disp(6, Y_B), asm.d(1))
              asm.sub(:l, asm.disp(6, Y_A), asm.d(1))
              asm.move(:l, asm.d(1), asm.disp(6, Y_A))
              # The bytes a row of each mask takes, kept in LIST_A and LIST_B.
              asm.move(:l, asm.d(4), asm.d(2))
              asm.addq(:l, 7, asm.d(2))
              asm.lsr(:l, 3, asm.d(2))
              asm.move(:l, asm.d(2), asm.disp(6, LIST_A))
              asm.move(:l, asm.d(6), asm.d(2))
              asm.addq(:l, 7, asm.d(2))
              asm.lsr(:l, 3, asm.d(2))
              asm.move(:l, asm.d(2), asm.disp(6, LIST_B))
              emit_edges(asm)
              emit_scan(asm)
            end

            # The registers at this point: D0 across, D1 down, D4 and D5 the first's size, D6 and D7 the
            # second's. The box is left in D2 (left), D3 (right), D4 (top) and D5 (bottom), with the second's
            # offset kept in X_A and Y_A and the row sizes in LIST_A and LIST_B.
            def emit_edges(asm)
              asm.move(:l, asm.d(0), asm.d(2))
              asm.branch(:pl, "rt_pixels_overlap_left")
              asm.moveq(0, asm.d(2))
              asm.label("rt_pixels_overlap_left")
              asm.move(:l, asm.d(0), asm.d(3))
              asm.add(:l, asm.d(6), asm.d(3))
              asm.cmp(:l, asm.d(4), asm.d(3))
              asm.branch(:le, "rt_pixels_overlap_right")
              asm.move(:l, asm.d(4), asm.d(3))
              asm.label("rt_pixels_overlap_right")
              asm.cmp(:l, asm.d(3), asm.d(2))
              asm.branch(:ge, "rt_pixels_overlap_no")
              asm.move(:l, asm.d(1), asm.d(4))
              asm.branch(:pl, "rt_pixels_overlap_top")
              asm.moveq(0, asm.d(4))
              asm.label("rt_pixels_overlap_top")
              asm.move(:l, asm.d(1), asm.d(0))
              asm.add(:l, asm.d(7), asm.d(0))
              asm.cmp(:l, asm.d(5), asm.d(0))
              asm.branch(:le, "rt_pixels_overlap_bottom")
              asm.move(:l, asm.d(5), asm.d(0))
              asm.label("rt_pixels_overlap_bottom")
              asm.move(:l, asm.d(0), asm.d(5))
              asm.cmp(:l, asm.d(5), asm.d(4))
              asm.branch(:ge, "rt_pixels_overlap_no")
            end

            # Each pixel of the box, row by row: the first's bit at (x, y) and the second's at (x - across,
            # y - down). The first pixel both have set answers yes.
            def emit_scan(asm)
              asm.label("rt_pixels_overlap_row")
              # The first's row: A0 = mask + y * row bytes. The second's: A1 = mask + (y - down) * row bytes.
              asm.move(:l, asm.d(4), asm.d(0))
              asm.mulu(asm.disp(6, LIST_A + 2), asm.d(0))
              asm.movea(:l, asm.a(2), asm.a(0))
              asm.add(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.d(4), asm.d(0))
              asm.sub(:l, asm.disp(6, Y_A), asm.d(0))
              asm.mulu(asm.disp(6, LIST_B + 2), asm.d(0))
              asm.movea(:l, asm.a(3), asm.a(1))
              asm.add(:l, asm.d(0), asm.a(1))
              asm.move(:l, asm.d(2), asm.d(6))
              asm.label("rt_pixels_overlap_pixel")
              asm.move(:l, asm.d(6), asm.d(0))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.lsr(:l, 3, asm.d(0))
              asm.not(:l, asm.d(1))
              asm.btst(asm.d(1), asm.idx(0, 0, 0))
              asm.branch(:eq, "rt_pixels_overlap_next")
              asm.move(:l, asm.d(6), asm.d(0))
              asm.sub(:l, asm.disp(6, X_A), asm.d(0))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.lsr(:l, 3, asm.d(0))
              asm.not(:l, asm.d(1))
              asm.btst(asm.d(1), asm.idx(1, 0, 0))
              asm.branch(:ne, "rt_pixels_overlap_yes")
              asm.label("rt_pixels_overlap_next")
              asm.addq(:l, 1, asm.d(6))
              asm.cmp(:l, asm.d(3), asm.d(6))
              asm.branch(:lt, "rt_pixels_overlap_pixel")
              asm.addq(:l, 1, asm.d(4))
              asm.cmp(:l, asm.d(5), asm.d(4))
              asm.branch(:lt, "rt_pixels_overlap_row")
              asm.label("rt_pixels_overlap_no")
              asm.moveq(0, asm.d(0))
              asm.bra("rt_pixels_overlap_done")
              asm.label("rt_pixels_overlap_yes")
              asm.moveq(1, asm.d(0))
              asm.label("rt_pixels_overlap_done")
              asm.lea(asm.disp(6, 32), asm.a(7))
              asm.rts
            end
          end
        end
      end
    end
  end
end
