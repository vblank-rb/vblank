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
            # A program a reader opened (started as `GAME.EXE HOLD`) takes its frame boundary from TICKS, which
            # the reader moves on once before each frame it plays, in place of the card's retrace. DOSBox's
            # frame and the retrace are not locked one to one (one frame can hold none, or two), and a reader
            # needs each pass to end in its own frame. DRIVEN says the program is one of those; TICKS_SEEN is
            # how many ticks the program has used.
            DRIVEN = "rt driven"
            TICKS = "rt ticks"
            TICKS_SEEN = "rt ticks seen"
            # How many frames each of the last STEPS_KEPT passes took, a byte each.
            STEPS = "rt steps"
            STEPS_KEPT = 16

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            WORDS = [STATE, WAITING, PASSES, SHOWN, HELD, SEEN, PRESSED, HOLD, LAST_PASS_TAKEN, FRAMES, STEP_TAKEN,
                     FRAMES_TAKEN, DRIVEN, TICKS, TICKS_SEEN].freeze
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
          def emit(asm, memory, palette:, starts:)
            emit_start(asm, memory, palette, starts)
            emit_frame(asm, memory)
            emit_number_routines(asm)
            emit_drawing_routines(asm)
          end

          def emit_start(asm, memory, palette, starts)
            ica = Diagnostics::DOSMemory
            asm.label("start")
            # ES is the program's PSP: its command tail (PSP:0081h) holds " HOLD" if a reader asked for the gate.
            asm.mov(:bl, X86.mem(nil, 0x82, seg: :es))
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
            asm.mov_memory_number(X86.mem(nil, ica::START_GATE_AT, seg: :es), 1, size: 8)
            asm.label("rt_no_gate")
            asm.mov(:es, :ax)
            asm.xor(:di, :di)
            asm.mov(:cx, memory.cleared_bytes / 4)
            asm.xor(:eax, :eax)
            asm.stos(32, rep: true)
            asm.cmp(:bl, "H".ord)
            asm.jne("rt_not_driven")
            asm.mov_memory_number(X86.mem(nil, memory[Frame::DRIVEN]), 1, size: 32)
            asm.label("rt_not_driven")
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
            starts.each { |offset, number| asm.mov_memory_number(X86.mem(nil, offset), number & 0xFFFF_FFFF, size: 32) }
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
            at = ->(name) { X86.mem(nil, memory[name]) }
            retrace = Console::DOSHardware::RETRACE_BIT

            # A frame boundary: the card's retrace, or the next tick where a reader drives the frames.
            asm.label("rt_sleep_until_retrace")
            asm.mov(:eax, at.call(Frame::DRIVEN))
            asm.test(:eax, :eax)
            asm.je("rt_sleep_until_vertical_retrace")
            asm.label("rt_sleep_until_tick")
            asm.mov(:eax, at.call(Frame::TICKS))
            asm.cmp(:eax, at.call(Frame::TICKS_SEEN))
            asm.je("rt_sleep_until_tick")
            asm.mov(at.call(Frame::TICKS_SEEN), :eax)
            asm.ret
            asm.label("rt_sleep_until_vertical_retrace")
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
            asm.mov_memory_number(at.call(Frame::WAITING), 1, size: 32)
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
            asm.mov_memory_number(at.call(Frame::FRAMES_TAKEN), 1, size: 32)
            asm.mov_memory_number(at.call(Frame::STEP_TAKEN), 1, size: 32)
            asm.mov(:bx, at.call(Frame::PASSES))
            asm.and(:bx, Frame::STEPS_KEPT - 1)
            asm.mov_memory_number(X86.mem(:bx, memory[Frame::STEPS]), 1, size: 8)
            asm.mov_memory_number(at.call(Frame::WAITING), 0, size: 32)
            asm.ret

            # Stopping: the game is marked as halted, and the last picture is shown by the retrace after it.
            asm.label("rt_halt")
            asm.mov_memory_number(at.call(Frame::STATE), Frame::HALTED, size: 32)
            asm.call("rt_sleep_until_retrace")
            asm.mov_memory_number(at.call(Frame::SHOWN), Frame::END_SHOWN, size: 32)
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
