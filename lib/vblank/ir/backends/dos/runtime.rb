# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # THE RUNTIME every DOS program carries, written in the assembler (X86) and linked with the game's code:
        # the start, the wait for the screen, stopping, and the routines that do a number's work the way
        # IR::Int32 says (divide, remainder, shifts) or draw (a pixel, a cleared screen).
        #
        # THE START. DOS jumps to the program with DS and ES pointing at its PSP and the stack where the header
        # says. The runtime points DS and SS at the data segment (loaded as a relocated word, since DOS chose
        # where the program is), tells a reader of the running program where that is (Diagnostics::DOSMemory),
        # clears the segment, sets VGA mode 13h through the BIOS, programs the palette, leaves ES at the video
        # memory (A000h) for the drawing routines, and runs the game.
        #
        # THE FRAME. A frame is one vertical retrace, which bit 3 of port 3DAh says. A pass of the game loop ends
        # by waiting (rt_wait_vblank): it lets any retrace already going end, then waits for the next to
        # begin, which is the frame boundary. A pass that takes longer than one frame misses boundaries, and
        # the wait still takes one: FRAMES moves on by one a pass. (Counting the retraces a long pass missed
        # takes a timer interrupt, which is part of the input and time work.)
        #
        # What the run is doing is kept where a reader finds it (DOS::HeadlessRun), by the names every cartridge
        # console's runtime keeps: how many passes have ended, which pass the screen shows, whether the game is
        # waiting, and whether it stopped or went wrong.
        module Runtime
          module Frame
            RUNNING = 0
            HALTED = 1
            WENT_WRONG = 2

            include CartridgeFaults

            FAULT_LIST = 4
            FAULT_FIRST = 8
            FAULT_SECOND = 12
            FAULT_BYTES = 16

            STATE = "rt state"
            WAITING = "rt waiting" # 1 while the game waits for its next frame
            PASSES = "rt passes" # passes of the game loop ended
            SHOWN = "rt shown" # the pass whose picture the card shows
            HELD = "rt held"
            SEEN = "rt seen"
            PRESSED = "rt pressed"
            FAULT = "rt fault"
            # Set by whoever reads the run when it has the pass it wanted last: the game shows it and goes no further.
            HOLD = "rt hold"
            # Set when the reader has taken the last pass it compares one by one (timers are not made yet).
            LAST_PASS_TAKEN = "rt last pass taken"
            FRAMES = "rt frames" # frames counted since the game began
            STEP_TAKEN = "rt step"
            FRAMES_TAKEN = "rt frames taken"
            # How many frames each of the last STEPS_KEPT passes took, a byte each.
            STEPS = "rt steps"
            STEPS_KEPT = 16

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            WORDS = [STATE, WAITING, PASSES, SHOWN, HELD, SEEN, PRESSED, HOLD, LAST_PASS_TAKEN, FRAMES, STEP_TAKEN,
                     FRAMES_TAKEN].freeze
          end

          # WHERE A LIST KEEPS ITS COUNTS, which every cartridge's reader asks (CartridgeHeadlessRun#read_lists):
          # a header of three 16-bit words (how many it can hold, where the front is, how many it holds) and
          # then its slots, a ring from the front. No list is made yet, so no program has one; the reader
          # asks for the layout whatever the program.
          module Lists
            CAPACITY = 0
            FRONT = 2
            LENGTH = 4
            HEADER = 8
          end

          # The video memory's segment, and the card's ports.
          VIDEO = Console::DOSHardware::VIDEO_SEGMENT
          PIXELS = Console::DOS.screen_width * Console::DOS.screen_height

          module_function

          def reserve(memory)
            Frame::WORDS.each { |name| memory.reserve(name, 4) }
            memory.reserve(Frame::FAULT, Frame::FAULT_BYTES)
            memory.reserve(Frame::STEPS, Frame::STEPS_KEPT)
          end

          # Where each of the runtime's names is, for a reader.
          def places(memory) = (Frame::WORDS + [Frame::FAULT, Frame::STEPS]).to_h { |name| [name, memory[name]] }

          # The 6-bit red, green and blue of a 15-bit colour (red in the low five bits): each five-bit channel
          # widened by repeating its top bit, which the card's `(value >> 1)` takes back to the five.
          def dac_of(color)
            [color & 31, (color >> 5) & 31, (color >> 10) & 31].map { |channel| (channel << 1) | (channel >> 4) }
          end

          # The start, then the routines. +palette+ is the 15-bit colours of palette entries 0, 1, 2...
          # +starts+ is [offset, number] for places that begin on something other than nought.
          def emit(asm, memory, palette:, starts:, pictures:)
            emit_start(asm, memory, palette, starts)
            emit_frame(asm, memory)
            emit_number_routines(asm)
            emit_drawing_routines(asm)
            emit_blit_routine(asm) if pictures
          end

          # What a picture's pixel holds where nothing is drawn: a palette entry the build never gives a colour.
          TRANSPARENT = 255

          # Where in the PSP (the 256 bytes DOS puts before a program) the command tail's length is: the tail
          # itself follows it, a space and then what was typed after the program's name.
          PSP_TAIL_LENGTH = 0x80

          def emit_start(asm, memory, palette, starts)
            ica = Diagnostics::DOSMemory
            asm.label("start")
            # ES is the program's PSP, whose command tail says whether a reader asked for the gate: " HOLD", its
            # length in the byte before it. A tail of no letters is not cleared, so its first letter is read only
            # when the length says there is one; BL is then that letter, or nought.
            asm.xor(:bl, :bl)
            asm.cmp(X86.mem(nil, PSP_TAIL_LENGTH, seg: :es, size: 8), 2)
            asm.jb("rt_no_tail")
            asm.mov(:bl, X86.mem(nil, PSP_TAIL_LENGTH + 2, seg: :es))
            asm.label("rt_no_tail")
            asm.mov_segment(:ax, :data)
            asm.mov(:ds, :ax)
            asm.mov(:ss, :ax)
            asm.mov(:sp, 0xFFFE)
            asm.cld
            asm.xor(:cx, :cx)
            asm.mov(:es, :cx)
            asm.mov(X86.mem(nil, ica::DATA_SEGMENT_AT, seg: :es), :ax)
            asm.cmp(:bl, "H".ord)
            asm.jne("rt_no_gate")
            asm.mov(X86.mem(nil, ica::START_GATE_AT, seg: :es, size: 8), 1)
            asm.label("rt_no_gate")
            asm.mov(:es, :ax)
            asm.xor(:di, :di)
            asm.mov(:cx, memory.cleared_bytes / 4)
            asm.xor(:eax, :eax)
            asm.stos(32, rep: true)
            asm.mov(:ax, Console::DOSHardware::MODE_13H)
            asm.int(0x10)
            asm.mov(:dx, Console::DOSHardware::DAC_WRITE_INDEX)
            asm.xor(:al, :al)
            asm.out_to_dx(:al)
            asm.inc(:dx)
            palette.each do |color|
              dac_of(color).each do |channel|
                asm.mov(:al, channel)
                asm.out_to_dx(:al)
              end
            end
            starts.each { |offset, number| asm.mov(X86.mem(nil, offset, size: 32), number & 0xFFFF_FFFF) }
            # THE GATE, after everything that takes DOSBox time (the mode, the palette), so the game's first pass
            # starts at the moment a reader lets go.
            asm.xor(:bx, :bx)
            asm.mov(:es, :bx)
            asm.label("rt_start_gate")
            asm.mov(:al, X86.mem(nil, ica::START_GATE_AT, seg: :es))
            asm.test(:al, :al)
            asm.jne("rt_start_gate")
            asm.mov(:ax, VIDEO)
            asm.mov(:es, :ax)
            asm.call("main")
            asm.jmp("rt_halt")
          end

          # The end of a pass, stopping, and the wait for a retrace they share.
          def emit_frame(asm, memory)
            at = ->(name) { X86.mem(nil, memory[name], size: 32) }
            retrace = Console::DOSHardware::RETRACE_BIT

            # A frame boundary: the start of the card's next retrace. A program a reader plays waits here
            # too: the emulator's frame is one retrace (RubyDOSEmulator::Core#run_frame), so each frame it
            # plays holds exactly one boundary.
            asm.label("rt_sleep_until_retrace")
            asm.mov(:dx, Console::DOSHardware::INPUT_STATUS)
            asm.label("rt_retrace_ends")
            asm.in_from_dx(:al)
            asm.test(:al, retrace)
            asm.jne("rt_retrace_ends")
            asm.label("rt_retrace_begins")
            asm.in_from_dx(:al)
            asm.test(:al, retrace)
            asm.je("rt_retrace_begins")
            asm.ret

            asm.label("rt_wait_vblank")
            asm.mov(:eax, at.call(Frame::PASSES))
            asm.inc(:eax)
            asm.mov(at.call(Frame::PASSES), :eax)
            asm.mov(at.call(Frame::WAITING), 1)
            # THE FIRST WAIT TAKES TWO RETRACES. The first pass starts at an unknown moment of a frame, so the
            # retrace that follows may be a frame's whole length away or a hair: skipping it makes the first
            # pass end a whole frame later in either case, and a reader that looks once a frame finds the first
            # pass waiting, as it finds each pass after it.
            asm.mov(:eax, at.call(Frame::PASSES))
            asm.cmp(:eax, 1)
            asm.jne("rt_wait_once")
            asm.call("rt_sleep_until_retrace")
            asm.label("rt_wait_once")
            asm.call("rt_sleep_until_retrace")
            asm.mov(:eax, at.call(Frame::PASSES))
            asm.mov(at.call(Frame::SHOWN), :eax)
            asm.mov(:eax, at.call(Frame::HOLD))
            asm.test(:eax, :eax)
            asm.jne("rt_stopped")
            asm.mov(:eax, at.call(Frame::FRAMES))
            asm.inc(:eax)
            asm.mov(at.call(Frame::FRAMES), :eax)
            asm.mov(at.call(Frame::FRAMES_TAKEN), 1)
            asm.mov(at.call(Frame::STEP_TAKEN), 1)
            asm.mov(:bx, X86.mem(nil, memory[Frame::PASSES])) # the count's low half: only its low bits are wanted
            asm.and(:bx, Frame::STEPS_KEPT - 1)
            asm.mov(X86.mem(:bx, memory[Frame::STEPS], size: 8), 1)
            asm.mov(at.call(Frame::WAITING), 0)
            asm.ret

            # Stopping: the game is marked as halted, and the last picture is shown by the retrace after it.
            asm.label("rt_halt")
            asm.mov(at.call(Frame::STATE), Frame::HALTED)
            asm.call("rt_sleep_until_retrace")
            asm.mov(at.call(Frame::SHOWN), Frame::END_SHOWN)
            asm.label("rt_stopped")
            asm.jmp("rt_stopped")
          end

          # IR::Int32 for the operations the processor does differently. Each takes the left number in EAX and
          # the right in ECX, and leaves the answer in EAX.
          def emit_number_routines(asm)
            # Divide: by nought gives 1, or -1 for a negative number (Int32.quotient_by_zero). By -1 is a
            # negation, which wraps for the smallest number where IDIV would stop the program. Otherwise
            # IDIV, which truncates toward zero as Int32.div does.
            asm.label("rt_div32")
            asm.test(:ecx, :ecx)
            asm.jne("rt_div32_by_something")
            asm.mov(:ecx, 1)
            asm.test(:eax, :eax)
            asm.jns("rt_div32_positive")
            asm.mov(:ecx, -1)
            asm.label("rt_div32_positive")
            asm.mov(:eax, :ecx)
            asm.ret
            asm.label("rt_div32_by_something")
            asm.cmp(:ecx, -1)
            asm.jne("rt_div32_divides")
            asm.neg(:eax)
            asm.ret
            asm.label("rt_div32_divides")
            asm.cdq
            asm.idiv(:ecx)
            asm.ret

            # Remainder with Ruby's meaning: the sign of the divisor. IDIV leaves the sign of the dividend, so
            # a remainder that is not nought and has the other sign than the divisor has the divisor added.
            # By nought gives the number back (Int32.mod), and by -1 gives nought, where IDIV would stop.
            asm.label("rt_mod32")
            asm.test(:ecx, :ecx)
            asm.jne("rt_mod32_by_something")
            asm.ret
            asm.label("rt_mod32_by_something")
            asm.cmp(:ecx, -1)
            asm.jne("rt_mod32_divides")
            asm.xor(:eax, :eax)
            asm.ret
            asm.label("rt_mod32_divides")
            asm.cdq
            asm.idiv(:ecx)
            asm.mov(:eax, :edx)
            asm.test(:edx, :edx)
            asm.je("rt_mod32_done")
            asm.xor(:edx, :ecx)
            asm.jns("rt_mod32_done")
            asm.add(:eax, :ecx)
            asm.label("rt_mod32_done")
            asm.ret

            # Shifts: a count outside 0 to 31 empties the number (Int32.shift_left), or leaves its sign for a
            # shift right (Int32.shift_right). The processor would use the count's low five bits instead.
            # One unsigned compare is enough: a negative count is a huge unsigned one.
            asm.label("rt_shl32")
            asm.cmp(:ecx, 32)
            asm.jb("rt_shl32_in_range")
            asm.xor(:eax, :eax)
            asm.ret
            asm.label("rt_shl32_in_range")
            asm.shl(:eax, :cl)
            asm.ret

            asm.label("rt_shr32")
            asm.cmp(:ecx, 32)
            asm.jb("rt_shr32_in_range")
            asm.sar(:eax, 31)
            asm.ret
            asm.label("rt_shr32_in_range")
            asm.sar(:eax, :cl)
            asm.ret
          end

          # A rectangle: x in EAX, y in ECX, width in EDX, height in EBX, the palette entry in SI. It is the
          # pixels of the interpreter's `x.upto(x + width - 1)` loop that are on the screen, so each far edge is
          # x + width (saturating, so a sum past 32 bits is the far end it would be on a number line, not a
          # wrapped one), each edge is held to the screen, and a rectangle with no width or height left draws
          # nothing. The rows are then one REP STOSB each.
          def emit_rectangle_routine(asm, width, height)
            asm.label("rt_fill_rect")
            [[:edx, :eax, "x"], [:ebx, :ecx, "y"]].each do |far, near, axis|
              asm.add(far, near)
              asm.jno("rt_fill_rect_#{axis}_sum")
              asm.mov(far, 0x7FFF_FFFF)
              asm.test(near, near)
              asm.jns("rt_fill_rect_#{axis}_sum")
              asm.mov(far, -0x8000_0000)
              asm.label("rt_fill_rect_#{axis}_sum")
              asm.test(near, near)
              asm.jns("rt_fill_rect_#{axis}_near")
              asm.xor(near, near)
              asm.label("rt_fill_rect_#{axis}_near")
              asm.cmp(far, axis == "x" ? width : height)
              asm.jle("rt_fill_rect_#{axis}_far")
              asm.mov(far, axis == "x" ? width : height)
              asm.label("rt_fill_rect_#{axis}_far")
              asm.cmp(near, far)
              asm.jge("rt_fill_rect_done")
            end
            asm.sub(:edx, :eax)
            asm.sub(:ebx, :ecx)
            asm.mov(:ebp, width)
            asm.imul(:ecx, :ebp)
            asm.add(:ecx, :eax)
            asm.mov(:di, :cx)
            asm.mov(:ax, :si)
            asm.label("rt_fill_rect_row")
            asm.mov(:cx, :dx)
            asm.push(:di)
            asm.stos(8, rep: true)
            asm.pop(:di)
            asm.add(:di, width)
            asm.dec(:ebx)
            asm.jne("rt_fill_rect_row")
            asm.label("rt_fill_rect_done")
            asm.ret
          end

          # A PICTURE, drawn at x in EAX and y in ECX from the picture at offset SI of the art segment: its width
          # and its height (a word each), then a byte for each pixel, a row at a time, each a palette entry or
          # TRANSPARENT. Each pixel is held to the screen by itself (Reference#blit_image sets pixels one at a
          # time, and `set_pixel` leaves out one that is off it), so a picture half off the screen shows its
          # half, and a row off the screen is passed over by the width of its pixels.
          #
          # The numbers it keeps are on the stack, which is in the data segment (SS), since DS is the art
          # segment while it reads pixels: BP+0 the x of the picture's left edge, +4 the y of the row to
          # draw, +8 the picture's width, +10 the rows left.
          def emit_blit_routine(asm)
            frame = ->(offset) { X86.mem(:bp, offset) }
            width = Console::DOS.screen_width
            height = Console::DOS.screen_height
            asm.label("rt_blit")
            asm.push(:ds)
            asm.sub(:sp, 12)
            asm.mov(:bp, :sp)
            asm.mov(frame.call(0), :eax)
            asm.mov(frame.call(4), :ecx)
            asm.mov_segment(:bx, :art)
            asm.mov(:ds, :bx)
            asm.mov(:dx, X86.mem(:si, 0))
            asm.mov(frame.call(8), :dx)
            asm.mov(:dx, X86.mem(:si, 2))
            asm.mov(frame.call(10), :dx)
            asm.add(:si, 4)
            asm.label("rt_blit_row")
            asm.mov(:dx, frame.call(10))
            asm.test(:dx, :dx)
            asm.je("rt_blit_done")
            asm.dec(:dx)
            asm.mov(frame.call(10), :dx)
            asm.mov(:eax, frame.call(4))
            asm.mov(:edi, :eax)
            asm.inc(:eax)
            asm.mov(frame.call(4), :eax)
            asm.xor(:ecx, :ecx)
            asm.mov(:cx, frame.call(8))
            asm.cmp(:edi, height)
            asm.jb("rt_blit_draw_row")
            asm.add(:si, :cx)
            asm.jmp("rt_blit_row")
            asm.label("rt_blit_draw_row")
            asm.mov(:eax, width)
            asm.imul(:edi, :eax)
            asm.mov(:ebx, frame.call(0))
            asm.label("rt_blit_pixel")
            asm.mov(:dl, X86.mem(:si, 0))
            asm.inc(:si)
            asm.cmp(:dl, TRANSPARENT)
            asm.je("rt_blit_next")
            asm.cmp(:ebx, width)
            asm.jae("rt_blit_next")
            asm.mov(X86.mem(:bx, 0, index: :di, seg: :es), :dl)
            asm.label("rt_blit_next")
            asm.inc(:ebx)
            asm.dec(:cx)
            asm.jne("rt_blit_pixel")
            asm.jmp("rt_blit_row")
            asm.label("rt_blit_done")
            asm.add(:sp, 12)
            asm.pop(:ds)
            asm.ret
          end

          # Drawing on the card's memory, with ES at A000h.
          def emit_drawing_routines(asm)
            width = Console::DOS.screen_width
            height = Console::DOS.screen_height

            # A pixel: x in EAX, y in ECX, the palette entry in DL. One that is off the screen is left out
            # (Framebuffer#set_pixel), and one unsigned compare each says so for a negative number too.
            asm.label("rt_pixel")
            asm.cmp(:eax, width)
            asm.jae("rt_pixel_done")
            asm.cmp(:ecx, height)
            asm.jae("rt_pixel_done")
            asm.mov(:ebx, width)
            asm.imul(:ecx, :ebx)
            asm.add(:ecx, :eax)
            asm.mov(:di, :cx)
            asm.mov(:al, :dl)
            asm.stos(8)
            asm.label("rt_pixel_done")
            asm.ret

            emit_rectangle_routine(asm, width, height)

            # The whole screen one colour: EAX is four pixels' worth of the palette entry.
            asm.label("rt_clear_screen")
            asm.xor(:di, :di)
            asm.mov(:cx, PIXELS / 4)
            asm.stos(32, rep: true)
            asm.ret
          end
        end
      end
    end
  end
end
