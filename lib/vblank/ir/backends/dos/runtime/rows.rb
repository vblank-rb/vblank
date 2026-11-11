# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # A PICTURE BIGGER THAN A SEGMENT. In real mode an address is a segment and an offset of 16 bits, so
          # one segment reaches 64K and no further. The plain screen's picture, 320 x 200, is 64,000 bytes:
          # one segment holds it, and a pixel is at offset (row x 320 + column). A 320 x 240 picture is 76,800.
          #
          # A segment's number counts in sixteens of bytes (a "paragraph"), and a row of 320 pixels is exactly
          # twenty of them. So EVERY ROW STARTS A SEGMENT OF ITS OWN: row r of a picture that begins at segment
          # P is at segment P + 20 x r, offset nought, and its pixel in column c is at offset c. No offset is
          # ever more than a row's width, the picture can be as tall as memory holds, and nothing needs an
          # address of more than 16 bits. It works for any width that is a whole number of paragraphs.
          #
          # The drawing routines all work a row at a time, so each asks here for a row's start (#emit_row_start)
          # and for the next row (#emit_next_row). For a picture one segment holds these are the sums they
          # always were, with ES left at the picture; for a bigger one they move ES, and the picture drawing
          # goes to is kept in FS, a segment register the 386 added, since ES no longer says where it starts.
          #
          # SO FOR SUCH A PICTURE ES IS NOBODY'S TO KEEP: every drawing routine leaves it at the last row it
          # drew in, and each works its row out from FS afresh. A routine that points ES somewhere else has
          # nothing to put back there; one that draws into another picture keeps and puts back FS
          # (#emit_push_picture_segment).
          module Rows
            SEGMENT_BYTES = Console::DOSHardware::SEGMENT_SIZE

            module_function

            # Whether +screen+'s picture is more than a segment holds, and so is addressed a row a segment.
            def apart?(screen) = screen.pixels > SEGMENT_BYTES

            # How many paragraphs a row of +screen+'s picture is, and how many the whole picture takes: a
            # whole segment for one a segment holds, as it always was.
            def row_paragraphs(screen) = screen.width / 16
            def picture_paragraphs(screen) = apart?(screen) ? (screen.pixels + 15) / 16 : SEGMENT_BYTES / 16

            # The picture drawing goes to from here on: the segment +segment+ names. Changes AX.
            def emit_picture_segment(asm, screen, segment)
              asm.mov_segment(:ax, segment)
              asm.mov(:es, :ax)
              asm.mov(:fs, :ax) if apart?(screen)
            end

            # The picture drawing goes to kept on the stack, and put back from it.
            def emit_push_picture_segment(asm, screen)
              asm.push(:es)
              asm.push(:fs) if apart?(screen)
            end

            def emit_pop_picture_segment(asm, screen)
              asm.pop(:fs) if apart?(screen)
              asm.pop(:es)
            end

            # ES:DI at the start of the row whose number is in +row+ (a 32-bit register, not EAX). Changes EAX.
            def emit_row_start(asm, screen, row)
              if apart?(screen)
                asm.mov(:eax, row_paragraphs(screen))
                asm.imul(:eax, row)
                asm.mov(:di, :fs)
                asm.add(:ax, :di)
                asm.mov(:es, :ax)
                asm.xor(:di, :di)
              else
                asm.mov(:eax, screen.width)
                asm.imul(:eax, row)
                asm.mov(:di, :ax)
              end
            end

            # ES:DI moved down a row, from wherever in a row it points. Changes AX for a picture in rows.
            def emit_next_row(asm, screen)
              return asm.add(:di, screen.width) unless apart?(screen)

              asm.mov(:ax, :es)
              asm.add(:ax, row_paragraphs(screen))
              asm.mov(:es, :ax)
            end

            # The whole picture drawing goes to filled with EAX, four pixels' worth of one palette entry.
            # +tag+ names the routine doing it, for its labels. Changes CX and DI.
            def emit_fill_picture(asm, screen, tag)
              unless apart?(screen)
                asm.xor(:di, :di)
                asm.mov(:cx, screen.pixels / 4)
                return asm.stos(32, rep: true)
              end

              asm.push(:ebp)
              asm.push(:eax)
              asm.xor(:ebp, :ebp)
              asm.label("#{tag}_fill_row")
              emit_row_start(asm, screen, :ebp)
              asm.pop(:eax)
              asm.push(:eax)
              asm.mov(:cx, screen.width / 4)
              asm.stos(32, rep: true)
              asm.inc(:ebp)
              asm.cmp(:ebp, screen.height)
              asm.jb("#{tag}_fill_row")
              asm.pop(:eax)
              asm.pop(:ebp)
            end
          end
        end
      end
    end
  end
end
