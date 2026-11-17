# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # A SPRITE IN BLOCKS, on a screen of tiles shown in them (`pixelate`, Reference#paint_object_in_blocks). The
          # rule is the one a console's display has for a sprite, which draws it as one or more boxes of the sizes it
          # has (SpriteCut) and puts each box into blocks by itself (Reference::SpriteBlocks):
          #
          #   * the blocks are fixed to the screen, as a background's are;
          #   * a block that starts left of the box, or above it, shows the box's own first column or row;
          #   * the box's last block across is drawn whole, so it runs on past the box's right edge, and down nothing
          #     is drawn past the box's bottom;
          #   * the boxes are drawn back to front, so the front one wins where a last block runs over another.
          #
          # A PC has no boxes, but the rule is the console's and the picture is held to it, so the build hands each
          # sprite's boxes over: in the art segment, a table of a word for each sprite and picture (SpriteNames'
          # numbers, the sprite's times how many pictures there are, plus the picture's), each the place of that
          # picture's boxes, or nought for a sprite left as drawn; and at each place how many boxes, then each box's
          # left, top, width and height inside the sprite's canvas, the front one first. TABLE and PICTURES say where
          # the table is and how many pictures there are.
          module SpriteBlocks
            TABLE = "rt sprite blocks table"
            PICTURES = "rt sprite blocks pictures"
            # What drawing one sprite keeps while it works: where it stands, its picture's width and height and where
            # its pixels are, the box being drawn (its left and top on the screen, its width and height), how many
            # boxes are left and where the next is, the rows it is drawn in, and the row being drawn.
            SPRITE_X = "rt sprite blocks x"
            SPRITE_Y = "rt sprite blocks y"
            PICTURE_W = "rt sprite blocks picture w"
            PICTURE_H = "rt sprite blocks picture h"
            PIXELS = "rt sprite blocks pixels"
            BOX_X = "rt sprite blocks box x"
            BOX_Y = "rt sprite blocks box y"
            BOX_W = "rt sprite blocks box w"
            BOX_H = "rt sprite blocks box h"
            BOXES_LEFT = "rt sprite blocks left"
            BOX_AT = "rt sprite blocks box at"
            ROW = "rt sprite blocks row"
            ROW_END = "rt sprite blocks row end"
            RIGHT = "rt sprite blocks right"
            ROW_PIXELS = "rt sprite blocks row pixels"
            WORDS = [TABLE, PICTURES, SPRITE_X, SPRITE_Y, PICTURE_W, PICTURE_H, PIXELS, BOX_X, BOX_Y, BOX_W, BOX_H, BOXES_LEFT,
                     BOX_AT, ROW, ROW_END, RIGHT, ROW_PIXELS].freeze

            module_function

            def reserve(memory) = WORDS.each { |name| memory.reserve(name, 4) }

            # Whether the game's sprites can be in blocks.
            def used?(memory) = memory.reserved?(TABLE)

            # To +drawn+ where the sprite of the table's row BP is at is to be drawn in blocks now, with BX at its
            # boxes in the art segment; on, where it is drawn as it is: the blocks are a pixel, a painted screen is up
            # (which goes into them whole, Runtime::View), or the sprite is left as drawn. Changes EAX and BX.
            def emit_unless_in_blocks(asm, memory, drawn)
              word = ->(name) { X86.mem(nil, memory[name], size: 32) }
              upright = "#{drawn}_as_drawn"
              asm.cmp(word.call(Scenery::BLOCK), 1)
              asm.je(upright)
              asm.cmp(word.call(Scenery::SCREEN_KIND), Scenery::PAINTED)
              asm.je(upright)
              asm.movsx(:eax, X86.mem(:bp, Sprites::NAME, size: 16))
              asm.test(:eax, :eax)
              asm.js(upright) # a sprite the game named nothing for
              asm.imul(:eax, word.call(PICTURES))
              asm.movzx(:ebx, X86.mem(:bp, Sprites::PICTURE, size: 16))
              asm.add(:eax, :ebx)
              asm.shl(:eax, 1)
              asm.add(:eax, word.call(TABLE))
              asm.push(:ds)
              asm.mov_segment(:bx, :art)
              asm.mov(:ds, :bx)
              asm.mov(:bx, :ax)
              asm.mov(:bx, X86.mem(:bx, 0, size: 16))
              asm.pop(:ds)
              asm.test(:bx, :bx)
              asm.jne(drawn)
              asm.label(upright)
            end

            # rt_sprite_blocks_blit: the sprite of the table's row BP is at drawn in blocks of Scenery::BLOCK into the
            # picture ES (and FS) name, with BX at its boxes in the art segment: each box from the back, each held to
            # the screen. Changes every register but the segment ones.
            def emit(asm, memory)
              word = ->(name) { X86.mem(nil, memory[name], size: 32) }
              asm.label("rt_sprite_blocks_blit")
              asm.push(:gs)
              asm.mov_segment(:ax, :art)
              asm.mov(:gs, :ax)
              asm.mov(:eax, X86.mem(:bp, Sprites::X, size: 32))
              asm.mov(word.call(SPRITE_X), :eax)
              asm.mov(:eax, X86.mem(:bp, Sprites::Y, size: 32))
              asm.mov(word.call(SPRITE_Y), :eax)
              asm.mov(:si, X86.mem(:bp, Sprites::ART, size: 16))
              asm.movzx(:eax, X86.mem(:si, 0, seg: :gs, size: 16))
              asm.mov(word.call(PICTURE_W), :eax)
              asm.movzx(:eax, X86.mem(:si, 2, seg: :gs, size: 16))
              asm.mov(word.call(PICTURE_H), :eax)
              asm.add(:si, 4)
              asm.movzx(:esi, :si)
              asm.mov(word.call(PIXELS), :esi)
              asm.movzx(:ecx, X86.mem(:bx, 0, seg: :gs, size: 16))
              asm.mov(word.call(BOXES_LEFT), :ecx)
              asm.shl(:cx, 3)
              asm.add(:bx, :cx)
              asm.add(:bx, 2) # just past the last box, the one at the back
              asm.movzx(:ebx, :bx)
              asm.mov(word.call(BOX_AT), :ebx)
              asm.label("rt_sprite_blocks_box")
              asm.cmp(word.call(BOXES_LEFT), 0)
              asm.je("rt_sprite_blocks_done")
              asm.dec(word.call(BOXES_LEFT))
              asm.sub(word.call(BOX_AT), 8)
              asm.mov(:bx, X86.mem(nil, memory[BOX_AT], size: 16))
              { 0 => [BOX_X, SPRITE_X], 2 => [BOX_Y, SPRITE_Y], 4 => [BOX_W, nil], 6 => [BOX_H, nil] }.each do |offset, (name, from)|
                asm.movzx(:eax, X86.mem(:bx, offset, seg: :gs, size: 16))
                asm.add(:eax, word.call(from)) if from
                asm.mov(word.call(name), :eax)
              end
              asm.call("rt_sprite_blocks_one_box")
              asm.jmp("rt_sprite_blocks_box")
              asm.label("rt_sprite_blocks_done")
              asm.pop(:gs)
              asm.ret
              emit_box(asm, memory)
            end

            # rt_sprite_blocks_one_box: the box BOX_X..BOX_H in blocks (Reference::SpriteBlocks#paint_box): each row of
            # the screen it is on reads the picture's row at its block's first row, held inside the box, and each block
            # across from the first one at or left of the box's left to the one the box's right edge falls in reads
            # the picture's column at the block's first column, held inside the box. A place outside the picture, or a
            # see-through pixel, leaves the picture as it is. GS is the art.
            def emit_box(asm, memory)
              word = ->(name) { X86.mem(nil, memory[name], size: 32) }
              size = word.call(Scenery::BLOCK)
              screen = memory.screen
              asm.label("rt_sprite_blocks_one_box")
              # Across: from the box's left, or the screen's, to the end of the block its right edge falls in.
              asm.mov(:eax, word.call(BOX_X))
              asm.add(:eax, word.call(BOX_W))
              asm.cmp(:eax, 0)
              asm.jle("rt_sprite_blocks_box_none")
              asm.xor(:edx, :edx)
              asm.div(size)
              asm.test(:edx, :edx)
              asm.je("rt_sprite_blocks_rounded")
              asm.inc(:eax)
              asm.label("rt_sprite_blocks_rounded")
              asm.imul(:eax, size)
              asm.cmp(:eax, screen.width)
              asm.jle("rt_sprite_blocks_right_kept")
              asm.mov(:eax, screen.width)
              asm.label("rt_sprite_blocks_right_kept")
              asm.mov(word.call(RIGHT), :eax)
              # Down: the box's rows on the screen.
              asm.mov(:eax, word.call(BOX_Y))
              asm.add(:eax, word.call(BOX_H))
              asm.cmp(:eax, screen.height)
              asm.jle("rt_sprite_blocks_bottom_kept")
              asm.mov(:eax, screen.height)
              asm.label("rt_sprite_blocks_bottom_kept")
              asm.mov(word.call(ROW_END), :eax)
              asm.mov(:eax, word.call(BOX_Y))
              asm.test(:eax, :eax)
              asm.jns("rt_sprite_blocks_top_kept")
              asm.xor(:eax, :eax)
              asm.label("rt_sprite_blocks_top_kept")
              asm.mov(word.call(ROW), :eax)

              asm.label("rt_sprite_blocks_row")
              asm.mov(:eax, word.call(ROW))
              asm.cmp(:eax, word.call(ROW_END))
              asm.jge("rt_sprite_blocks_box_none")
              # The picture's row: the block's first row, held inside the box, less the sprite's top.
              asm.xor(:edx, :edx)
              asm.div(size)
              asm.mov(:eax, word.call(ROW))
              asm.sub(:eax, :edx)
              emit_held_inside(asm, word.call(BOX_Y), word.call(BOX_H), "rt_sprite_blocks_from_y")
              asm.sub(:eax, word.call(SPRITE_Y))
              asm.js("rt_sprite_blocks_row_next")
              asm.cmp(:eax, word.call(PICTURE_H))
              asm.jge("rt_sprite_blocks_row_next")
              asm.imul(:eax, word.call(PICTURE_W))
              asm.add(:eax, word.call(PIXELS))
              asm.mov(word.call(ROW_PIXELS), :eax)
              asm.push(:ebp)
              asm.mov(:ebp, word.call(ROW))
              Rows.emit_row_start(asm, screen, :ebp) # ES:DI the row of the picture
              asm.pop(:ebp)
              # ECX the first column drawn, EBX its block's first column.
              asm.mov(:ecx, word.call(BOX_X))
              asm.test(:ecx, :ecx)
              asm.jns("rt_sprite_blocks_left_kept")
              asm.xor(:ecx, :ecx)
              asm.label("rt_sprite_blocks_left_kept")
              asm.mov(:eax, :ecx)
              asm.xor(:edx, :edx)
              asm.div(size)
              asm.mov(:ebx, :ecx)
              asm.sub(:ebx, :edx)

              asm.label("rt_sprite_blocks_block")
              asm.cmp(:ecx, word.call(RIGHT))
              asm.jge("rt_sprite_blocks_row_next")
              asm.mov(:edx, :ebx)
              asm.add(:edx, size)
              asm.cmp(:edx, word.call(RIGHT))
              asm.jle("rt_sprite_blocks_end_kept")
              asm.mov(:edx, word.call(RIGHT))
              asm.label("rt_sprite_blocks_end_kept") # EDX just past the part of the block drawn
              asm.mov(:eax, :ebx)
              emit_held_inside(asm, word.call(BOX_X), word.call(BOX_W), "rt_sprite_blocks_from_x")
              asm.sub(:eax, word.call(SPRITE_X))
              asm.js("rt_sprite_blocks_block_next")
              asm.cmp(:eax, word.call(PICTURE_W))
              asm.jge("rt_sprite_blocks_block_next")
              asm.add(:eax, word.call(ROW_PIXELS))
              asm.mov(:si, :ax)
              asm.mov(:al, X86.mem(:si, 0, seg: :gs, size: 8))
              asm.cmp(:al, TRANSPARENT)
              asm.je("rt_sprite_blocks_block_next")
              asm.push(:di)
              asm.push(:ecx)
              asm.add(:di, :cx)
              asm.neg(:ecx)
              asm.add(:ecx, :edx)
              asm.stos(8, rep: true)
              asm.pop(:ecx)
              asm.pop(:di)
              asm.label("rt_sprite_blocks_block_next")
              asm.mov(:ecx, :edx)
              asm.add(:ebx, size)
              asm.jmp("rt_sprite_blocks_block")

              asm.label("rt_sprite_blocks_row_next")
              asm.inc(word.call(ROW))
              asm.jmp("rt_sprite_blocks_row")
              asm.label("rt_sprite_blocks_box_none")
              asm.ret
            end

            # EAX held to the box that starts at +start+ and is +length+ long: no less than its first place and no more
            # than its last. Changes ESI.
            def emit_held_inside(asm, start, length, tag)
              asm.cmp(:eax, start)
              asm.jge("#{tag}_after_start")
              asm.mov(:eax, start)
              asm.label("#{tag}_after_start")
              asm.mov(:esi, start)
              asm.add(:esi, length)
              asm.dec(:esi)
              asm.cmp(:eax, :esi)
              asm.jle("#{tag}_before_end")
              asm.mov(:eax, :esi)
              asm.label("#{tag}_before_end")
            end
          end
        end
      end
    end
  end
end
