# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # FADES AND TINTS, THROUGH THE CARD'S PALETTE. A pixel of the picture is not a colour but the number
          # of one, and the card looks each number up in its palette as it draws. So the whole picture is
          # faded or tinted by changing the palette and not one pixel: every colour the game uses is moved
          # part of the way toward black, white or a colour of the game's, and the moved colours are sent to
          # the card. It is the walk every console with no blend does (Backends::PaletteWalk, which has the
          # rules), and on a PC it is the cheapest thing there is to do to a whole screen.
          #
          # A `fade` or `tint` only says what is asked for (rt_walk: toward what, the colour, how far in 256ths).
          # THE COLOURS ARE WORKED OUT AS THE PASS ENDS AND SENT AS THE RETRACE BEGINS: rt_walk_work, before the
          # wait, fills a list of the bytes the card wants, and rt_walk_send, beside the picture's own sending,
          # only hands them over, so the retrace is spent on nothing but the card. A palette changed while the
          # beam draws shows two palettes on one frame, and on an old card sparkles. Asked for again the same,
          # nothing is worked out: a game says `tint :red, hurt` on every pass, and on nearly every pass
          # nothing moved. No steps is the colours as they are, toward whatever.
          #
          # THE SUMS are the interpreter's, a channel of five bits at a time (Framebuffer#walked_toward and
          # #mixed): toward black a channel loses its share of itself, toward white it gains its share of what
          # it lacks, and toward a colour it is the two mixed, each share in 256ths. The card's channel is six
          # bits, so each answer is widened as the palette's colours were at the start (Runtime.dac_of).
          #
          # The game's colours are kept beside the code as it is assembled (rt_palette, a word each of fifteen
          # bits), since the card's own palette cannot be read back as what the game named once it has moved.
          module Fades
            ASKED = "rt walk asked" # toward, colour, steps: a word each
            SENT = "rt walk sent" # the same three, as the card's palette was last worked out from
            LEFT = "rt walk left" # colours still to work out, while they are
            # The card's bytes for every colour, three a colour, and how many are waiting to be sent (none, or all).
            BYTES = "rt walk bytes"
            WAITING = "rt walk waiting"
            MOST_COLORS = 256
            TOWARD = 0
            COLOR = 4
            STEPS = 8
            WALK_BYTES = 12

            module_function

            def reserve(memory)
              memory.reserve(ASKED, WALK_BYTES)
              memory.reserve(SENT, WALK_BYTES)
              memory.reserve(LEFT, 4)
              memory.reserve(WAITING, 4)
              memory.reserve(BYTES, MOST_COLORS * 3)
            end

            def emit(asm, memory, palette)
              emit_ask(asm, memory)
              emit_work(asm, memory, palette.size)
              emit_send(asm, memory)
              emit_channel(asm, memory)
              asm.label("rt_palette")
              palette.each { |color| asm.word(color) }
            end

            # rt_walk: a walk asked for. The steps in EAX, held to their range already; toward what in ECX and
            # the colour in EDX. Nothing is worked out here.
            def emit_ask(asm, memory)
              asked = ->(part) { X86.mem(nil, memory[ASKED] + part, size: 32) }
              asm.label("rt_walk")
              asm.mov(asked.call(STEPS), :eax)
              asm.mov(asked.call(TOWARD), :ecx)
              asm.mov(asked.call(COLOR), :edx)
              asm.ret
            end

            # rt_walk_work: the card's bytes worked out from what is asked, if what is asked is not what they
            # were last worked out from, and left waiting to be sent. Changes EAX, EBX, ECX and DX.
            def emit_work(asm, memory, colors)
              asked = ->(part) { X86.mem(nil, memory[ASKED] + part, size: 32) }
              sent = ->(part) { X86.mem(nil, memory[SENT] + part, size: 32) }
              left = X86.mem(nil, memory[LEFT], size: 16)
              asm.label("rt_walk_work")
              asm.mov(:eax, asked.call(STEPS))
              asm.mov(:ebx, asked.call(TOWARD))
              asm.mov(:ecx, asked.call(COLOR))
              asm.test(:eax, :eax)
              asm.jne("rt_walk_some")
              asm.xor(:ebx, :ebx) # no steps is one state, whatever it was toward
              asm.xor(:ecx, :ecx)
              asm.label("rt_walk_some")
              asm.cmp(:eax, sent.call(STEPS))
              asm.jne("rt_walk_changed")
              asm.cmp(:ebx, sent.call(TOWARD))
              asm.jne("rt_walk_changed")
              asm.cmp(:ecx, sent.call(COLOR))
              asm.je("rt_walk_worked")
              asm.label("rt_walk_changed")
              asm.mov(sent.call(STEPS), :eax)
              asm.mov(sent.call(TOWARD), :ebx)
              asm.mov(sent.call(COLOR), :ecx)
              asm.push(:si)
              asm.push(:di)
              asm.push(:bp)
              asm.mov(left, colors)
              asm.mov_offset(:bx, "rt_palette")
              asm.mov(:dx, memory[BYTES]) # where the next byte goes, kept on the stack while a channel is worked out
              asm.label("rt_walk_color")
              asm.mov(:si, X86.mem(:bx, 0, seg: :cs))
              asm.mov(:di, X86.mem(nil, memory[SENT] + COLOR, size: 16))
              3.times do
                asm.push(:dx)
                asm.call("rt_walk_channel")
                asm.pop(:dx)
                asm.xchg(:bx, :dx)
                asm.mov(X86.mem(:bx, 0), :al)
                asm.inc(:bx)
                asm.xchg(:bx, :dx)
                asm.shr(:si, 5)
                asm.shr(:di, 5)
              end
              asm.add(:bx, 2)
              asm.dec(left)
              asm.jne("rt_walk_color")
              asm.mov(X86.mem(nil, memory[WAITING], size: 16), colors * 3)
              asm.pop(:bp)
              asm.pop(:di)
              asm.pop(:si)
              asm.label("rt_walk_worked")
              asm.ret
            end

            # rt_walk_send: the bytes waiting, if any, sent to the card from its first colour on (the card
            # moves to the next colour after each three). Changes AX, CX and DX.
            def emit_send(asm, memory)
              h = Console::DOSHardware
              waiting = X86.mem(nil, memory[WAITING], size: 16)
              asm.label("rt_walk_send")
              asm.mov(:cx, waiting)
              asm.test(:cx, :cx)
              asm.je("rt_walk_sent")
              asm.mov(waiting, 0)
              asm.mov(:dx, h::DAC_WRITE_INDEX)
              asm.xor(:al, :al)
              asm.out_to_dx(:al)
              asm.inc(:dx)
              asm.push(:si)
              asm.mov(:si, memory[BYTES])
              asm.outs_bytes
              asm.pop(:si)
              asm.label("rt_walk_sent")
              asm.ret
            end

            # rt_walk_channel: AL = the card's six bits for the channel in the low five bits of SI, walked as
            # the walk sent says, toward the channel in the low five bits of DI where it is toward a colour.
            # Changes AX, CX, DX and BP.
            def emit_channel(asm, memory)
              sent = ->(part) { X86.mem(nil, memory[SENT] + part, size: 16) }
              asm.label("rt_walk_channel")
              asm.mov(:ax, :si)
              asm.and(:ax, 31)
              asm.mov(:cx, sent.call(STEPS))
              asm.mov(:bp, :ax)
              asm.cmp(sent.call(TOWARD), PaletteWalk::TOWARD_WHITE)
              asm.je("rt_walk_channel_white")
              asm.ja("rt_walk_channel_color")
              # Toward black: less its share of itself.
              asm.mul(:cx)
              asm.shr(:ax, 8)
              asm.sub(:bp, :ax)
              asm.mov(:ax, :bp)
              asm.jmp("rt_walk_channel_widen")
              asm.label("rt_walk_channel_white")
              # Toward white: more by its share of what it lacks.
              asm.mov(:ax, 31)
              asm.sub(:ax, :bp)
              asm.mul(:cx)
              asm.shr(:ax, 8)
              asm.add(:ax, :bp)
              asm.jmp("rt_walk_channel_widen")
              asm.label("rt_walk_channel_color")
              # Toward a colour: what is kept of it, and the colour's share, the two adding to 256.
              asm.mov(:bp, FadeSteps::WALK)
              asm.sub(:bp, :cx)
              asm.mul(:bp)
              asm.mov(:bp, :ax)
              asm.mov(:ax, :di)
              asm.and(:ax, 31)
              asm.mul(:cx)
              asm.add(:ax, :bp)
              asm.shr(:ax, 8)
              asm.label("rt_walk_channel_widen")
              # Five bits to the card's six, the top bit again at the bottom.
              asm.mov(:ah, :al)
              asm.shl(:al, 1)
              asm.shr(:ah, 4)
              asm.or(:al, :ah)
              asm.ret
            end
          end
        end
      end
    end
  end
end
