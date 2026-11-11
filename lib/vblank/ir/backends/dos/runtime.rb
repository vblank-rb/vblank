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
        # begin, which is the frame boundary.
        #
        # HOW MANY FRAMES A PASS TOOK. A program sees a retrace only while it looks at the card, so a pass
        # that works through one never knows. The timer chip does: the runtime sets it to interrupt
        # TICKS_A_FRAME times a frame (rt_timer counts them), and where a wait ends the ticks since the last
        # wait ended, rounded to whole frames, are the frames the pass took. Both ends are retraces, so the
        # ticks are a whole number of frames give or take one tick, and nothing adds up from pass to pass.
        # The BIOS counted the time of day by this interrupt at its own slower rate, so rt_timer calls the
        # BIOS's routine each time that much time has gone by, and the PC's clock keeps right.
        #
        # THE KEYBOARD. Each key going down or up interrupts the program (IRQ 1), and the routine the runtime
        # hands the processor for it (rt_keyboard) reads the key's scan code from port 60h and keeps two sets
        # of the game's buttons, a bit each in IR::Buttons's order: the ones down now, and the ones that went
        # down since the last pass ended. A key held down sends its code again and again, so only a key that
        # was up counts as going down. The wait at a pass's end hands both to the game (HELD and PRESSED) and
        # empties the second, so a tap that goes down and up inside one slow pass is still one press. The
        # BIOS's own routine is not called: it would fill its buffer of typed keys and beep when it is full.
        #
        # Not every byte the keyboard sends is a key. The arrows and the right-hand Ctrl and Alt send E0h
        # first; around an arrow a keyboard may send E0h and a Shift's code that nobody pressed; and Pause
        # sends E1h and two bytes that read as other keys. rt_keyboard keeps what it needs to tell (KEY_EXTENDED,
        # KEY_SKIP) and counts none of those as a button.
        #
        # A button down as the game starts is held through its first pass and is one press where that pass
        # ends, as on every console (Reference#read_buttons), whether or not it went down in the pass.
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
            # The timer's ticks since the game began, and what they were where the last wait ended.
            TIMER_TICKS = "rt timer ticks"
            TICKS_MARK = "rt ticks mark"
            # The timer chip's counts since the BIOS's routine was last called, and that routine (offset, segment).
            BIOS_TIME = "rt bios time"
            BIOS_TIMER = "rt bios timer"
            # The buttons as the keyboard's interrupt keeps them: down now, and gone down since the last wait ended.
            KEY_HELD = "rt key held"
            KEY_PRESSED = "rt key pressed"
            # 1 when the byte before this one was E0h, and how many bytes of a Pause are still to come.
            KEY_EXTENDED = "rt key extended"
            KEY_SKIP = "rt key skip"
            # How many frames each of the last STEPS_KEPT passes took, a byte each.
            STEPS = "rt steps"
            STEPS_KEPT = 16

            # What SHOWN holds once a stopped game's last picture is on the screen.
            END_SHOWN = 0xFFFF_FFFF

            WORDS = [STATE, WAITING, PASSES, SHOWN, HELD, SEEN, PRESSED, HOLD, LAST_PASS_TAKEN, FRAMES, STEP_TAKEN,
                     FRAMES_TAKEN, TIMER_TICKS, TICKS_MARK, BIOS_TIME, BIOS_TIMER, KEY_HELD, KEY_PRESSED,
                     KEY_EXTENDED, KEY_SKIP].freeze
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

          # The timer's interrupts in one frame, a power of two so the ticks are made frames by a shift, and
          # the number the timer chip counts down from to make them: a frame's worth of its clock, in parts.
          # The frame is the plain screen's. A variant's screen has a longer one, so the build that makes a
          # variant must work this out from that screen's frame, or the ticks stop being eight to a frame.
          TICKS_A_FRAME = 8
          TIMER_COUNT = (Console::DOSHardware::PIT_CLOCK * Console::DOS.cycles_a_frame /
                         (Console::DOS.cycles_a_second * TICKS_A_FRAME.to_f)).round

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
            emit_keyboard(asm, memory)
            emit_timer(asm, memory)
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
            asm.mov(:es, :ax)
            asm.xor(:di, :di)
            asm.mov(:cx, memory.cleared_bytes / 4)
            asm.xor(:eax, :eax)
            asm.stos(32, rep: true)
            asm.push(:bx) # the letter, kept from whatever the BIOS does with BX
            asm.mov(:ax, Console::DOSHardware::MODE_13H)
            asm.int(0x10)
            asm.pop(:bx)
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
            # The keyboard's interrupt is handed to rt_keyboard: its offset and this code's segment, written
            # with interrupts off so none comes while the two words are half changed.
            asm.xor(:cx, :cx)
            asm.mov(:es, :cx)
            asm.cli
            asm.mov_offset(:ax, "rt_keyboard")
            asm.mov(X86.mem(nil, Console::DOSHardware::KEYBOARD_VECTOR, seg: :es), :ax)
            asm.mov(X86.mem(nil, Console::DOSHardware::KEYBOARD_VECTOR + 2, seg: :es), :cs)
            emit_timer_start(asm, memory)
            asm.sti
            # THE GATE, for a program a reader asked to hold: shut and waited at after everything that takes
            # DOSBox time (the mode, the palette), so a reader that finds it shut finds the program waiting
            # there, and the game starts at the moment the reader lets go.
            asm.cmp(:bl, "H".ord)
            asm.jne("rt_gate_open")
            asm.mov(X86.mem(nil, ica::START_GATE_AT, seg: :es, size: 8), 1)
            asm.label("rt_start_gate")
            asm.mov(:al, X86.mem(nil, ica::START_GATE_AT, seg: :es))
            asm.test(:al, :al)
            asm.jne("rt_start_gate")
            asm.label("rt_gate_open")
            # The buttons down as the game starts are held through its first pass. What went down before now
            # is forgotten: the first wait makes its presses from what is down then.
            asm.cli
            asm.mov(:eax, X86.mem(nil, memory[Frame::KEY_HELD], size: 32))
            asm.mov(X86.mem(nil, memory[Frame::HELD], size: 32), :eax)
            asm.mov(X86.mem(nil, memory[Frame::KEY_PRESSED], size: 32), 0)
            asm.sti
            # THE FIRST PASS BEGINS AS A RETRACE DOES. The program is started at any moment of a frame, and a
            # pass that began part way through one would end at a retrace nobody could name ahead of time:
            # the next, or the one after if the pass ran past it. Begun at a retrace, every pass that fits a
            # frame ends at the next one.
            asm.call("rt_sleep_until_retrace")
            asm.mov(:eax, X86.mem(nil, memory[Frame::TIMER_TICKS], size: 32))
            asm.mov(X86.mem(nil, memory[Frame::TICKS_MARK], size: 32), :eax)
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
            asm.call("rt_sleep_until_retrace")
            # The buttons, taken from the keyboard's interrupt with interrupts off, so a key cannot go down
            # between the two halves and be lost.
            asm.cli
            asm.mov(:eax, at.call(Frame::KEY_PRESSED))
            # Where the first pass ends nothing was down before, so every button down now is a press.
            asm.cmp(at.call(Frame::PASSES), 1)
            asm.jne("rt_wait_not_first")
            asm.or(:eax, at.call(Frame::KEY_HELD))
            asm.label("rt_wait_not_first")
            asm.mov(at.call(Frame::PRESSED), :eax)
            asm.mov(at.call(Frame::KEY_PRESSED), 0)
            asm.mov(:eax, at.call(Frame::KEY_HELD))
            asm.mov(at.call(Frame::HELD), :eax)
            # The frames the pass took, into ECX: the timer's ticks since the last wait ended, rounded to
            # frames, and one at the least.
            asm.mov(:eax, at.call(Frame::TIMER_TICKS))
            asm.mov(:ecx, :eax)
            asm.sub(:ecx, at.call(Frame::TICKS_MARK))
            asm.mov(at.call(Frame::TICKS_MARK), :eax)
            asm.sti
            asm.add(:ecx, TICKS_A_FRAME / 2)
            asm.shr(:ecx, TICKS_A_FRAME.bit_length - 1)
            asm.jne("rt_wait_took_some")
            asm.mov(:ecx, 1)
            asm.label("rt_wait_took_some")
            asm.mov(:eax, at.call(Frame::PASSES))
            asm.mov(at.call(Frame::SHOWN), :eax)
            asm.mov(:eax, at.call(Frame::HOLD))
            asm.test(:eax, :eax)
            asm.jne("rt_stopped")
            asm.mov(:eax, at.call(Frame::FRAMES))
            asm.add(:eax, :ecx)
            asm.mov(at.call(Frame::FRAMES), :eax)
            asm.mov(at.call(Frame::FRAMES_TAKEN), :ecx)
            # The same number for a reader, a byte for each of the last passes, and for the game, which
            # catches up by no more than IR::Frames::MOST.
            asm.mov(:eax, :ecx)
            asm.cmp(:eax, 255)
            asm.jbe("rt_wait_fits_byte")
            asm.mov(:eax, 255)
            asm.label("rt_wait_fits_byte")
            asm.mov(:bx, X86.mem(nil, memory[Frame::PASSES])) # the count's low half: only its low bits are wanted
            asm.and(:bx, Frame::STEPS_KEPT - 1)
            asm.mov(X86.mem(:bx, memory[Frame::STEPS], size: 8), :al)
            asm.cmp(:ecx, IR::Frames::MOST)
            asm.jbe("rt_wait_step")
            asm.mov(:ecx, IR::Frames::MOST)
            asm.label("rt_wait_step")
            asm.mov(at.call(Frame::STEP_TAKEN), :ecx)
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

          # The bytes that are not keys, with the byte just read in AL: a Pause's first byte and the two after
          # it are passed over, and so is E0h, which is remembered for the byte after it. Leaves BL 1 where the
          # byte before this one was E0h.
          def emit_keyboard_prefixes(asm, memory)
            h = Console::DOSHardware
            extended = X86.mem(nil, memory[Frame::KEY_EXTENDED], size: 8)
            skip = X86.mem(nil, memory[Frame::KEY_SKIP], size: 8)
            asm.cmp(:al, h::PAUSE_KEY)
            asm.jne("rt_keyboard_not_pause")
            asm.mov(skip, h::PAUSE_BYTES_AFTER)
            asm.jmp("rt_keyboard_done")
            asm.label("rt_keyboard_not_pause")
            asm.cmp(skip, 0)
            asm.je("rt_keyboard_not_skipped")
            asm.dec(skip)
            asm.jmp("rt_keyboard_done")
            asm.label("rt_keyboard_not_skipped")
            asm.cmp(:al, h::EXTENDED_KEY)
            asm.jne("rt_keyboard_not_extended")
            asm.mov(extended, 1)
            asm.jmp("rt_keyboard_done")
            asm.label("rt_keyboard_not_extended")
            asm.mov(:bl, extended)
            asm.mov(extended, 0)
          end

          # The timer chip set to TIMER_COUNT and its interrupt handed to rt_timer, the BIOS's routine kept to
          # be called. ES is nought (the interrupt table's segment) and interrupts are off.
          def emit_timer_start(asm, memory)
            h = Console::DOSHardware
            bios = memory[Frame::BIOS_TIMER]
            asm.mov(:ax, X86.mem(nil, h::TIMER_VECTOR, seg: :es))
            asm.mov(X86.mem(nil, bios), :ax)
            asm.mov(:ax, X86.mem(nil, h::TIMER_VECTOR + 2, seg: :es))
            asm.mov(X86.mem(nil, bios + 2), :ax)
            asm.mov_offset(:ax, "rt_timer")
            asm.mov(X86.mem(nil, h::TIMER_VECTOR, seg: :es), :ax)
            asm.mov(X86.mem(nil, h::TIMER_VECTOR + 2, seg: :es), :cs)
            asm.mov(:al, h::PIT_SET_COUNTER_0)
            asm.out_byte(h::PIT_COMMAND)
            asm.mov(:al, TIMER_COUNT & 0xFF)
            asm.out_byte(h::PIT_COUNTER_0)
            asm.mov(:al, TIMER_COUNT >> 8)
            asm.out_byte(h::PIT_COUNTER_0)
          end

          # rt_timer, the timer's interrupt: one more tick, and the BIOS's routine called as an interrupt calls
          # it (the flags pushed, then a far call) each time the chip has counted what the BIOS set it to.
          # That routine tells the interrupt controller the interrupt was served; when it is not called, this does.
          # The BIOS set the chip to count 65536, which is what a 16-bit sum of the counts carries at.
          def emit_timer(asm, memory)
            h = Console::DOSHardware
            asm.label("rt_timer")
            asm.push(:ax)
            asm.push(:ds)
            asm.mov_segment(:ax, :data)
            asm.mov(:ds, :ax)
            asm.inc(X86.mem(nil, memory[Frame::TIMER_TICKS], size: 32))
            asm.add(X86.mem(nil, memory[Frame::BIOS_TIME], size: 16), TIMER_COUNT)
            asm.jb("rt_timer_bios")
            asm.mov(:al, h::END_OF_INTERRUPT)
            asm.out_byte(h::INTERRUPT_CONTROLLER)
            asm.jmp("rt_timer_done")
            asm.label("rt_timer_bios")
            asm.pushf
            asm.call_far(X86.mem(nil, memory[Frame::BIOS_TIMER]))
            asm.label("rt_timer_done")
            asm.pop(:ds)
            asm.pop(:ax)
            asm.iret
          end

          # rt_keyboard, the keyboard's interrupt (see THE KEYBOARD above). It keeps every register it uses,
          # since it runs in the middle of whatever the game was doing. A scan code's low seven bits are the
          # key and its top bit says the key was let go; the arrows send a byte of E0h first, which is no
          # key of the game's and falls through. The buttons' bits fit the low word of each set.
          def emit_keyboard(asm, memory)
            h = Console::DOSHardware
            held = X86.mem(nil, memory[Frame::KEY_HELD], size: 16)
            pressed = X86.mem(nil, memory[Frame::KEY_PRESSED], size: 16)
            asm.label("rt_keyboard")
            asm.push(:ax)
            asm.push(:bx)
            asm.push(:ds)
            asm.mov_segment(:ax, :data)
            asm.mov(:ds, :ax)
            asm.in_byte(h::KEYBOARD_PORT)
            emit_keyboard_prefixes(asm, memory)
            asm.mov(:ah, :al)
            asm.and(:al, h::RELEASE_BIT - 1)
            # A Shift's code after E0h is one the keyboard made up.
            asm.test(:bl, :bl)
            asm.je("rt_keyboard_real")
            h::SHIFT_KEYS.each do |shift|
              asm.cmp(:al, shift)
              asm.je("rt_keyboard_done")
            end
            asm.label("rt_keyboard_real")
            Console::DOS.buttons.each do |button|
              asm.cmp(:al, h::SCAN_CODES.fetch(button))
              asm.jne("rt_keyboard_not_#{button}")
              asm.mov(:bx, Buttons.mask(button))
              asm.jmp("rt_keyboard_button")
              asm.label("rt_keyboard_not_#{button}")
            end
            asm.jmp("rt_keyboard_done")
            asm.label("rt_keyboard_button")
            asm.test(:ah, h::RELEASE_BIT)
            asm.jne("rt_keyboard_up")
            asm.mov(:ax, held)
            asm.test(:ax, :bx)
            asm.jne("rt_keyboard_done")
            asm.or(held, :bx)
            asm.or(pressed, :bx)
            asm.jmp("rt_keyboard_done")
            asm.label("rt_keyboard_up")
            asm.not(:bx)
            asm.and(held, :bx)
            asm.label("rt_keyboard_done")
            asm.mov(:al, h::END_OF_INTERRUPT)
            asm.out_byte(h::INTERRUPT_CONTROLLER)
            asm.pop(:ds)
            asm.pop(:bx)
            asm.pop(:ax)
            asm.iret
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
