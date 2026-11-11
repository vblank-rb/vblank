# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # DO TWO PICTURES' DRAWN PIXELS TOUCH? (`a.overlaps?(b)` without a `hitbox:`, Reference#pixels_overlap?.)
          # Each side is showing one of its pictures, picked by a number, at a place. Where the two pictures'
          # boxes cover the same pixels, each of those pixels is asked whether both pictures draw it, and the
          # first that both draw answers yes. A picture here is the one a `blit` draws: its width and height,
          # then a palette entry a pixel, TRANSPARENT where it draws nothing.
          #
          #   rt_overlap_picture   EAX the pose, ECX how many pictures, DX the table of their places
          #                        → EAX the picture's place. A pose below nought counts back from the last,
          #                        as the interpreter reads it; one that names none stops the game.
          #   rt_pixels_overlap    the first side's picture, x and y, then the second's, pushed as six
          #                        32-bit numbers in that order → EAX 1 or 0, the six taken off the stack.
          #
          # The caller pushes the six as it works them out, rather than writing them to fixed places, because
          # working out the second side's numbers can ask another overlap first. The routine copies them into
          # its own places once it is called, when nothing else can ask one.
          #
          # Two pictures whose places are further apart than one's width or height do not touch, so once those
          # are ruled out every number left fits in 32 bits with room, however far off the screen they are.
          module Overlap
            # The six numbers, in the order they come off the stack, then what the routine works out.
            PLACES = ["rt overlap second y", "rt overlap second x", "rt overlap second picture",
                      "rt overlap first y", "rt overlap first x", "rt overlap first picture",
                      "rt overlap first width", "rt overlap first height", "rt overlap second width",
                      "rt overlap second height", "rt overlap across", "rt overlap down", "rt overlap left",
                      "rt overlap right", "rt overlap top", "rt overlap bottom", "rt overlap first row",
                      "rt overlap second row"].freeze

            module_function

            def reserve(memory) = PLACES.each { |name| memory.reserve(name, 4) }

            def emit(asm, memory)
              emit_picture(asm, memory)
              emit_overlap(asm, memory)
            end

            # rt_overlap_picture. Changes BX.
            def emit_picture(asm, memory)
              fault = ->(part) { X86.mem(nil, memory[Frame::FAULT] + part, size: 32) }
              asm.label("rt_overlap_picture")
              asm.cmp(:eax, :ecx)
              asm.jb("rt_overlap_picture_found") # as numbers with no sign, so one below nought is too big here
              asm.mov(fault.call(Frame::FAULT_FIRST), :eax)
              asm.add(:eax, :ecx) # one below nought counted back from the end
              asm.cmp(:eax, :ecx)
              asm.jae("rt_overlap_picture_missing")
              asm.label("rt_overlap_picture_found")
              asm.mov(:bx, :ax)
              asm.add(:bx, :bx)
              asm.add(:bx, :dx)
              asm.push(:ds)
              asm.mov_segment(:ax, :art)
              asm.mov(:ds, :ax)
              asm.movzx(:eax, X86.mem(:bx, 0, size: 16))
              asm.pop(:ds)
              asm.ret
              asm.label("rt_overlap_picture_missing")
              asm.mov(fault.call(0), CartridgeFaults::PICTURE_NOT_THERE)
              asm.mov(fault.call(Frame::FAULT_SECOND), :ecx)
              asm.jmp("rt_fault")
            end

            # rt_pixels_overlap. Changes every number register; keeps the segment registers.
            def emit_overlap(asm, memory)
              at = ->(name, size = 32) { X86.mem(nil, memory[name], size: size) }
              asm.label("rt_pixels_overlap")
              asm.pop(:di) # where to come back to
              PLACES.first(6).each do |name|
                asm.pop(:eax)
                asm.mov(at.call(name), :eax)
              end
              asm.push(:di)
              asm.push(:es)
              asm.mov_segment(:ax, :art)
              asm.mov(:es, :ax)
              %w[first second].each do |side|
                asm.mov(:bx, at.call("rt overlap #{side} picture", 16))
                asm.movzx(:eax, X86.mem(:bx, 0, seg: :es, size: 16))
                asm.mov(at.call("rt overlap #{side} width"), :eax)
                asm.movzx(:eax, X86.mem(:bx, 2, seg: :es, size: 16))
                asm.mov(at.call("rt overlap #{side} height"), :eax)
              end
              emit_span(asm, at, %w[x across width left right])
              emit_span(asm, at, %w[y down height top bottom])
              emit_rows_start(asm, at)
              emit_walk(asm, at)
              asm.label("rt_overlap_apart")
              asm.xor(:eax, :eax)
              asm.label("rt_overlap_done")
              asm.pop(:es)
              asm.ret
            end

            # Where the second side sits from the first one way (+offset+, from the second's place less the
            # first's), and the span of the first's pixels both cover that way, from +low+ up to and not +high+.
            # Pictures that cover none of the same pixels that way are apart.
            def emit_span(asm, at, words)
              place, offset, length, low, high = words
              asm.mov(:eax, at.call("rt overlap second #{place}"))
              asm.sub(:eax, at.call("rt overlap first #{place}"))
              asm.jo("rt_overlap_apart")
              asm.cmp(:eax, at.call("rt overlap first #{length}"))
              asm.jge("rt_overlap_apart")
              asm.mov(at.call("rt overlap #{offset}"), :eax)
              asm.mov(:edx, :eax)
              asm.add(:edx, at.call("rt overlap second #{length}")) # the second's far edge, in the first's pixels
              asm.cmp(:edx, at.call("rt overlap first #{length}"))
              asm.jle("rt_overlap_#{high}_kept")
              asm.mov(:edx, at.call("rt overlap first #{length}"))
              asm.label("rt_overlap_#{high}_kept")
              asm.test(:eax, :eax)
              asm.jge("rt_overlap_#{low}_kept")
              asm.xor(:eax, :eax)
              asm.label("rt_overlap_#{low}_kept")
              asm.cmp(:edx, :eax)
              asm.jle("rt_overlap_apart")
              asm.mov(at.call("rt overlap #{low}"), :eax)
              asm.mov(at.call("rt overlap #{high}"), :edx)
            end

            # Where the first row of the covered pixels starts in each picture: past its width and height,
            # down the rows above it and along to the left edge.
            def emit_rows_start(asm, at)
              %w[first second].each do |side|
                asm.mov(:eax, at.call("rt overlap top"))
                asm.mov(:edx, at.call("rt overlap left"))
                if side == "second"
                  asm.sub(:eax, at.call("rt overlap down"))
                  asm.sub(:edx, at.call("rt overlap across"))
                end
                asm.imul(:eax, at.call("rt overlap #{side} width"))
                asm.add(:eax, :edx)
                asm.add(:eax, at.call("rt overlap #{side} picture"))
                asm.add(:eax, 4)
                asm.mov(at.call("rt overlap #{side} row"), :eax)
              end
            end

            # Each covered row, each covered pixel along it, until one both pictures draw.
            def emit_walk(asm, at)
              asm.label("rt_overlap_row")
              asm.mov(:si, at.call("rt overlap first row", 16))
              asm.mov(:di, at.call("rt overlap second row", 16))
              asm.mov(:cx, at.call("rt overlap right", 16))
              asm.sub(:cx, at.call("rt overlap left", 16))
              asm.label("rt_overlap_pixel")
              asm.cmp(X86.mem(:si, 0, seg: :es, size: 8), TRANSPARENT)
              asm.je("rt_overlap_next")
              asm.cmp(X86.mem(:di, 0, seg: :es, size: 8), TRANSPARENT)
              asm.je("rt_overlap_next")
              asm.mov(:eax, 1)
              asm.jmp("rt_overlap_done")
              asm.label("rt_overlap_next")
              asm.inc(:si)
              asm.inc(:di)
              asm.dec(:cx)
              asm.jne("rt_overlap_pixel")
              %w[first second].each do |side|
                asm.mov(:eax, at.call("rt overlap #{side} width"))
                asm.add(at.call("rt overlap #{side} row"), :eax)
              end
              asm.mov(:eax, at.call("rt overlap top"))
              asm.inc(:eax)
              asm.mov(at.call("rt overlap top"), :eax)
              asm.cmp(:eax, at.call("rt overlap bottom"))
              asm.jl("rt_overlap_row")
              asm.jmp("rt_overlap_apart")
            end
          end
        end
      end
    end
  end
end
