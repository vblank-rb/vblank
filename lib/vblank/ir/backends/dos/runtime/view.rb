# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # THE CAMERA (`camera x, y`): the view moved over the picture, so that the screen's top left shows
          # what the game drew at (x, y). Nothing the game drew moves. The card could slide its view by a
          # register, but only round a picture bigger than the screen, and past this picture's edge there
          # must be the backdrop, not the picture again. So the processor does it, where the picture the
          # player is shown is made (THE PICTURE SHOWN, a second picture, which a game with a camera has as a
          # game with sprites does): each row of it is the game's row that far down, moved that far across,
          # with the backdrop (palette entry 0) wherever the view is past the picture.
          #
          # A pass says where the view is (rt_camera). As the pass ends every row is marked as changed if the
          # view moved (rt_view_rows, before the rows are copied), and every row is made again if the view is
          # anywhere but (0, 0) and any row changed (rt_picture_rows): a row the game marked is a row of its
          # picture, which is another row of the screen while the view is moved. A game whose view rests at
          # (0, 0) with its picture as drawn copies the rows it changed and no more, as a game with neither a
          # camera nor blocks does.
          #
          # THE PICTURE IN BLOCKS (`pixelate size`) is made in the same place: flat squares that many pixels
          # each way, fixed to the screen, each the colour the picture has at the square's top left corner
          # as the view has it (Reference::Framebuffer#block_corner). A row that begins a line of squares is
          # made as any row is and then each square's first pixel is spread over the square; the rows under
          # it are copies of it. Where the view is past the picture's left edge the squares count from the
          # picture's first column. While the picture is in blocks a pass that changes any row makes every
          # row again, since a row is made from the one above.
          #
          # Sprites shown over the picture are drawn after, where the game put them and as they are: the view
          # moves the picture under them, and the blocks are the picture's (Reference::Framebuffer#pixel).
          module View
            # Where the game last put the view, and where it was when the picture shown was last made.
            X = "rt camera x"
            Y = "rt camera y"
            SHOWN_X = "rt camera shown x"
            SHOWN_Y = "rt camera shown y"
            # A row of the picture shown, in its parts: the backdrop's pixels at its left, the game's, the
            # backdrop's at its right, and the column the game's begin at.
            LEFT = "rt view left"
            COUNT = "rt view count"
            RIGHT = "rt view right"
            FROM = "rt view from"
            # How many pixels a block is each way as the game last said, 1 for the picture as drawn, the
            # size the picture shown was last made with, and how far down its block the row being made is.
            BLOCK = "rt view block"
            SHOWN_BLOCK = "rt view shown block"
            ROW_IN_BLOCK = "rt view row in block"
            WORDS = [X, Y, SHOWN_X, SHOWN_Y, LEFT, COUNT, RIGHT, FROM, BLOCK, SHOWN_BLOCK, ROW_IN_BLOCK].freeze
            PLACES = [SHOWN_X, SHOWN_Y].freeze

            module_function

            def reserve(memory) = WORDS.each { |name| memory.reserve(name, 4) }

            # What the start sets: the picture as drawn.
            def starts(memory) = [[memory[BLOCK], 1], [memory[SHOWN_BLOCK], 1]]

            def emit(asm, memory)
              emit_camera(asm, memory)
              emit_pixelate(asm, memory)
              emit_mark_rows_of_changed_view(asm, memory)
              emit_picture_rows(asm, memory)
            end

            # rt_camera: the view put at x in EAX and y in ECX.
            def emit_camera(asm, memory)
              asm.label("rt_camera")
              asm.mov(X86.mem(nil, memory[X], size: 32), :eax)
              asm.mov(X86.mem(nil, memory[Y], size: 32), :ecx)
              asm.ret
            end

            # rt_pixelate: the picture shown in blocks of EAX pixels each way from now on, held to the sizes
            # there are (Blocks.size).
            def emit_pixelate(asm, memory)
              asm.label("rt_pixelate")
              asm.cmp(:eax, 1)
              asm.jge("rt_pixelate_not_small")
              asm.mov(:eax, 1)
              asm.label("rt_pixelate_not_small")
              asm.cmp(:eax, Blocks::LARGEST)
              asm.jle("rt_pixelate_not_big")
              asm.mov(:eax, Blocks::LARGEST)
              asm.label("rt_pixelate_not_big")
              asm.mov(X86.mem(nil, memory[BLOCK], size: 32), :eax)
              asm.ret
            end

            # rt_view_rows: every row marked as changed if the view moved or the blocks changed size, and
            # the view the picture shown is made with kept. Changes EAX, ECX and EDX.
            def emit_mark_rows_of_changed_view(asm, memory)
              at = ->(name) { X86.mem(nil, memory[name], size: 32) }
              asm.label("rt_view_rows")
              asm.mov(:eax, at.call(X))
              asm.mov(:edx, at.call(Y))
              asm.mov(:ecx, at.call(BLOCK))
              asm.cmp(:eax, at.call(SHOWN_X))
              asm.jne("rt_view_changed")
              asm.cmp(:edx, at.call(SHOWN_Y))
              asm.jne("rt_view_changed")
              asm.cmp(:ecx, at.call(SHOWN_BLOCK))
              asm.je("rt_view_rows_marked")
              asm.label("rt_view_changed")
              asm.mov(at.call(SHOWN_X), :eax)
              asm.mov(at.call(SHOWN_Y), :edx)
              asm.mov(at.call(SHOWN_BLOCK), :ecx)
              Runtime.emit_mark_every_row(asm, memory)
              asm.label("rt_view_rows_marked")
              asm.ret
            end

            # rt_picture_rows, for a game with a camera: the rows marked as changed made in the picture shown
            # from the game's picture as the view has it. Keeps the segment registers; changes the others.
            def emit_picture_rows(asm, memory)
              screen = memory.screen
              word = ->(name) { X86.mem(nil, memory[name], size: 16) }
              asm.label("rt_picture_rows")
              asm.mov(:bx, word.call(Frame::CHANGED_TOP))
              asm.cmp(:bx, word.call(Frame::CHANGED_BOTTOM))
              asm.jae("rt_picture_rows_done")
              # A view at rest anywhere but (0, 0), or a picture in blocks: every row, from the first.
              asm.mov(:eax, X86.mem(nil, memory[SHOWN_X], size: 32))
              asm.or(:eax, X86.mem(nil, memory[SHOWN_Y], size: 32))
              asm.jne("rt_picture_rows_all")
              asm.cmp(word.call(SHOWN_BLOCK), 1)
              asm.je("rt_picture_rows_some")
              asm.label("rt_picture_rows_all")
              Runtime.emit_mark_every_row(asm, memory)
              asm.xor(:bx, :bx)
              asm.label("rt_picture_rows_some")
              asm.mov(word.call(ROW_IN_BLOCK), 0)
              asm.push(:es)
              emit_row_parts(asm, memory)
              unless Rows.apart?(screen)
                asm.mov_segment(:ax, :shown)
                asm.mov(:es, :ax)
              end
              asm.label("rt_picture_row")
              emit_counted_row_start(asm, screen, :shown) # ES:DI the row of the picture shown, BX its number
              asm.cmp(word.call(ROW_IN_BLOCK), 0)
              asm.je("rt_picture_row_made")
              emit_copy_row_above(asm, screen)
              asm.jmp("rt_picture_row_done")
              asm.label("rt_picture_row_made")
              asm.xor(:al, :al)
              asm.mov(:cx, word.call(LEFT))
              asm.stos(8, rep: true)
              # The game's row the view puts here, if its picture has one: as numbers with no sign, so a
              # row above the picture is past its end as well.
              asm.xor(:eax, :eax)
              asm.mov(:ax, :bx)
              asm.add(:eax, X86.mem(nil, memory[SHOWN_Y], size: 32))
              asm.cmp(:eax, screen.height)
              asm.jae("rt_picture_row_past")
              asm.mov(:cx, word.call(COUNT))
              asm.mov(:si, word.call(FROM))
              asm.push(:ds)
              emit_row_from(asm, screen) # DS:SI the game's pixels
              asm.mov(:ax, :cx)
              asm.shr(:cx, 2)
              asm.movs(32, rep: true)
              asm.mov(:cx, :ax)
              asm.and(:cx, 3)
              asm.movs(8, rep: true)
              asm.pop(:ds)
              asm.jmp("rt_picture_row_right")
              asm.label("rt_picture_row_past")
              asm.mov(:cx, word.call(COUNT))
              asm.xor(:al, :al)
              asm.stos(8, rep: true)
              asm.label("rt_picture_row_right")
              asm.mov(:cx, word.call(RIGHT))
              asm.xor(:al, :al)
              asm.stos(8, rep: true)
              emit_spread_blocks(asm, memory)
              asm.label("rt_picture_row_done")
              asm.mov(:ax, word.call(ROW_IN_BLOCK))
              asm.inc(:ax)
              asm.cmp(:ax, word.call(SHOWN_BLOCK))
              asm.jb("rt_picture_row_in_block")
              asm.xor(:ax, :ax)
              asm.label("rt_picture_row_in_block")
              asm.mov(word.call(ROW_IN_BLOCK), :ax)
              asm.inc(:bx)
              asm.cmp(:bx, word.call(Frame::CHANGED_BOTTOM))
              asm.jb("rt_picture_row")
              asm.pop(:es)
              asm.label("rt_picture_rows_done")
              asm.ret
            end

            # The row at ES:DI made a copy of the row of the picture shown above it. Changes AX, CX, SI and DI.
            def emit_copy_row_above(asm, screen)
              asm.push(:ds)
              if Rows.apart?(screen)
                asm.mov(:ax, :es)
                asm.sub(:ax, Rows.row_paragraphs(screen))
                asm.mov(:ds, :ax)
                asm.xor(:si, :si)
              else
                asm.mov(:si, :di)
                asm.sub(:si, screen.width)
                asm.push(:es)
                asm.pop(:ds)
              end
              asm.mov(:cx, screen.width / 4)
              asm.movs(32, rep: true)
              asm.pop(:ds)
            end

            # The row just made, which ends at ES:DI, put in blocks across: from the picture's first column
            # (LEFT), each block's first pixel spread over the block, the last one cut off by the screen's
            # edge. Nothing for a picture as drawn. Changes AX, CX, DX and DI.
            def emit_spread_blocks(asm, memory)
              width = memory.screen.width
              word = ->(name) { X86.mem(nil, memory[name], size: 16) }
              asm.cmp(word.call(SHOWN_BLOCK), 1)
              asm.je("rt_picture_row_done")
              asm.sub(:di, width)
              asm.add(:di, word.call(LEFT))
              asm.mov(:dx, width)
              asm.sub(:dx, word.call(LEFT)) # the pixels left in the row
              asm.je("rt_picture_row_done")
              asm.label("rt_picture_row_block")
              asm.mov(:al, X86.mem(:di, 0, seg: :es, size: 8))
              asm.mov(:cx, word.call(SHOWN_BLOCK))
              asm.cmp(:cx, :dx)
              asm.jbe("rt_picture_row_block_fits")
              asm.mov(:cx, :dx)
              asm.label("rt_picture_row_block_fits")
              asm.sub(:dx, :cx)
              asm.stos(8, rep: true)
              asm.test(:dx, :dx)
              asm.jne("rt_picture_row_block")
            end

            # The parts of a row (LEFT, COUNT, RIGHT, FROM) for the view's x, held to a screen's width
            # either way: past that the row is all backdrop.
            def emit_row_parts(asm, memory)
              width = memory.screen.width
              word = ->(name) { X86.mem(nil, memory[name], size: 16) }
              asm.mov(:eax, X86.mem(nil, memory[SHOWN_X], size: 32))
              asm.cmp(:eax, width)
              asm.jle("rt_camera_not_right_of_picture")
              asm.mov(:eax, width)
              asm.label("rt_camera_not_right_of_picture")
              asm.cmp(:eax, -width)
              asm.jge("rt_camera_not_left_of_picture")
              asm.mov(:eax, -width)
              asm.label("rt_camera_not_left_of_picture")
              asm.xor(:edx, :edx) # the backdrop at the left
              asm.mov(:ecx, :eax) # the column the game's pixels begin at
              asm.test(:eax, :eax)
              asm.jge("rt_camera_parts")
              asm.neg(:eax)
              asm.mov(:edx, :eax)
              asm.xor(:ecx, :ecx)
              asm.label("rt_camera_parts") # AX how far the view is across, either way
              asm.mov(word.call(LEFT), :dx)
              asm.mov(word.call(FROM), :cx)
              asm.mov(:cx, width)
              asm.sub(:cx, :ax)
              asm.mov(word.call(COUNT), :cx)
              asm.sub(:ax, :dx)
              asm.mov(word.call(RIGHT), :ax)
            end

            # ES:DI at the start of row BX of the picture in the segment named +picture+. For a picture all
            # in one segment ES is already its segment. Changes AX and DX.
            def emit_counted_row_start(asm, screen, picture)
              asm.mov(:ax, :bx)
              if Rows.apart?(screen)
                asm.mov(:dx, Rows.row_paragraphs(screen))
                asm.mul(:dx)
                asm.mov_segment(:dx, picture)
                asm.add(:ax, :dx)
                asm.mov(:es, :ax)
                asm.xor(:di, :di)
              else
                asm.mov(:dx, screen.width)
                asm.mul(:dx)
                asm.mov(:di, :ax)
              end
            end

            # DS:SI moved from column SI of the data segment's nothing to that column of row AX of the game's
            # picture. Changes AX and DX; nothing in the data segment can be read after it.
            def emit_row_from(asm, screen)
              if Rows.apart?(screen)
                asm.mov(:dx, Rows.row_paragraphs(screen))
                asm.mul(:dx)
                asm.mov_segment(:dx, :back)
                asm.add(:ax, :dx)
              else
                asm.mov(:dx, screen.width)
                asm.mul(:dx)
                asm.add(:si, :ax)
                asm.mov_segment(:ax, :back)
              end
              asm.mov(:ds, :ax)
            end
          end
        end
      end
    end
  end
end
