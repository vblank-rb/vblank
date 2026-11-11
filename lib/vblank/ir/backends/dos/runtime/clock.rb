# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # THE PC'S CLOCK. Every PC since the AT has a clock chip a battery keeps going while the machine is
          # off (the "CMOS clock", an MC146818): it holds the date and the time, and a bit that says whether
          # its battery kept them. A program asks it by writing a register's number to port 70h and reading
          # the answer from port 71h.
          #
          # THE CHIP IS READ ONCE, AS THE PROGRAM STARTS (rt_clock_start), and the time is counted on from
          # there by the frames the game has shown (rt_clock_tick, after each wait), which is how the PC's
          # own BIOS keeps the time of day: it reads the chip at power-on and counts timer interrupts after.
          # So every reading in one pass is of one moment, the clock moves on only between passes, and it
          # moves by the frames the interpreter counts by (Reference#clock_now): a second each time the
          # frames' dots add up to a second's worth, kept in whole numbers.
          #
          # WHAT THE CHIP HOLDS IS NOT ALWAYS PLAIN NUMBERS. Its second register says how: by default each
          # number is two decimal digits packed into a byte (59 is 59h), and the hour may be counted to twelve
          # with the top bit for the afternoon. Both are turned into plain numbers here. The chip must not be
          # read while it moves its own numbers on, which a bit of its first status register says, so the
          # read waits for that bit to clear. The year is two digits, and the century is in a register of its
          # own on every PC that has one; a chip without it reads something that is no century, and the
          # year is then taken to be in the 2000s.
          #
          # What is kept, each a 32-bit number a game's own code can read as it reads a variable
          # (Lowering::Clock): the date read, the seconds since that date's midnight (counting on past
          # midnight, a day's worth and more), and whether the battery kept the time.
          module Clock
            YEAR = "rt clock year"
            MONTH = "rt clock month"
            DAY = "rt clock day"
            SECONDS = "rt clock seconds"
            KEPT = "rt clock kept"
            # The dots of the card's clock the frames have counted that are not yet a whole second.
            DOTS = "rt clock dots"
            WORDS = [YEAR, MONTH, DAY, SECONDS, KEPT, DOTS].freeze

            REGISTER = 0x70
            ANSWER = 0x71
            SECOND_REGISTER = 0x00
            MINUTE_REGISTER = 0x02
            HOUR_REGISTER = 0x04
            DAY_REGISTER = 0x07
            MONTH_REGISTER = 0x08
            YEAR_REGISTER = 0x09
            CENTURY_REGISTER = 0x32
            STATUS_A = 0x0A
            MOVING_ON = 0x80 # status A: the chip is changing its numbers
            STATUS_B = 0x0B
            PLAIN_NUMBERS = 0x04 # status B: not two packed digits
            HOURS_TO_24 = 0x02 # status B: the hour counts to 24
            STATUS_D = 0x0D # its top bit: the battery kept the time
            AFTERNOON = 0x80

            # The most frames one wait is counted for, so their dots fit a 32-bit number: over a minute.
            MOST_FRAMES = 5000

            module_function

            def reserve(memory) = WORDS.each { |name| memory.reserve(name, 4) }

            def emit(asm, memory)
              emit_start(asm, memory)
              emit_numbers(asm)
              emit_tick(asm, memory)
            end

            # rt_clock_start: the chip read into what is kept. Changes EAX, EBX and ECX.
            def emit_start(asm, memory)
              at = ->(name) { X86.mem(nil, memory[name], size: 32) }
              asm.label("rt_clock_start")
              asm.label("rt_clock_moving_on")
              emit_ask(asm, STATUS_A)
              asm.test(:al, MOVING_ON)
              asm.jne("rt_clock_moving_on")
              emit_ask(asm, STATUS_B)
              asm.mov(:bl, :al)
              emit_ask(asm, STATUS_D)
              asm.shr(:al, 7)
              asm.movzx(:eax, :al)
              asm.mov(at.call(KEPT), :eax)
              emit_number_of(asm, SECOND_REGISTER)
              asm.mov(at.call(SECONDS), :eax)
              emit_number_of(asm, MINUTE_REGISTER)
              asm.mov(:ecx, 60)
              asm.imul(:eax, :ecx)
              asm.add(at.call(SECONDS), :eax)
              asm.call("rt_clock_hour")
              asm.mov(:ecx, 3600)
              asm.imul(:eax, :ecx)
              asm.add(at.call(SECONDS), :eax)
              emit_number_of(asm, DAY_REGISTER)
              asm.mov(at.call(DAY), :eax)
              emit_number_of(asm, MONTH_REGISTER)
              asm.mov(at.call(MONTH), :eax)
              emit_number_of(asm, YEAR_REGISTER)
              asm.mov(at.call(YEAR), :eax)
              emit_number_of(asm, CENTURY_REGISTER)
              asm.cmp(:eax, 19) # anything less is no century: a chip without the register
              asm.jae("rt_clock_century")
              asm.mov(:eax, 20)
              asm.label("rt_clock_century")
              asm.mov(:ecx, 100)
              asm.imul(:eax, :ecx)
              asm.add(at.call(YEAR), :eax)
              asm.ret
            end

            # AL = what the chip's register +register+ holds.
            def emit_ask(asm, register)
              asm.mov(:al, register)
              asm.out_byte(REGISTER)
              asm.in_byte(ANSWER)
            end

            # EAX = the plain number in the chip's register +register+.
            def emit_number_of(asm, register)
              emit_ask(asm, register)
              asm.call("rt_clock_number")
            end

            # rt_clock_number: EAX = the plain number of the byte in AL, two packed digits unless the chip said
            # otherwise (BL is its status B): the tens digit times ten, as twice and eight times itself, and the
            # units. rt_clock_hour: EAX = the hour, 0 to 23, whichever way the chip counts it.
            def emit_numbers(asm)
              asm.label("rt_clock_number")
              asm.test(:bl, PLAIN_NUMBERS)
              asm.jne("rt_clock_number_plain")
              asm.mov(:ah, :al)
              asm.shr(:ah, 4)
              asm.and(:al, 0x0F)
              asm.shl(:ah, 1)
              asm.add(:al, :ah)
              asm.shl(:ah, 2)
              asm.add(:al, :ah)
              asm.label("rt_clock_number_plain")
              asm.movzx(:eax, :al)
              asm.ret

              asm.label("rt_clock_hour")
              emit_ask(asm, HOUR_REGISTER)
              asm.test(:bl, HOURS_TO_24)
              asm.jne("rt_clock_number")
              # Counted to twelve: twelve is the hour after midnight or noon, and the afternoon is twelve more.
              asm.mov(:bh, :al)
              asm.and(:al, AFTERNOON - 1)
              asm.call("rt_clock_number")
              asm.cmp(:eax, 12)
              asm.jne("rt_clock_hour_not_twelve")
              asm.xor(:eax, :eax)
              asm.label("rt_clock_hour_not_twelve")
              asm.test(:bh, AFTERNOON)
              asm.je("rt_clock_hour_done")
              asm.add(:eax, 12)
              asm.label("rt_clock_hour_done")
              asm.ret
            end

            # rt_clock_tick: the clock moved on by the frames the wait just ended took. Changes EAX and ECX.
            # The frame is the screen's the program is built for, as the interpreter's is.
            def emit_tick(asm, memory)
              at = ->(name) { X86.mem(nil, memory[name], size: 32) }
              a_second = memory.screen.cycles_a_second
              asm.label("rt_clock_tick")
              asm.mov(:eax, at.call(Frame::FRAMES_TAKEN))
              asm.cmp(:eax, MOST_FRAMES)
              asm.jbe("rt_clock_tick_frames")
              asm.mov(:eax, MOST_FRAMES)
              asm.label("rt_clock_tick_frames")
              asm.mov(:ecx, memory.screen.cycles_a_frame)
              asm.imul(:eax, :ecx)
              asm.add(:eax, at.call(DOTS))
              asm.label("rt_clock_tick_second")
              asm.cmp(:eax, a_second)
              asm.jb("rt_clock_tick_done")
              asm.sub(:eax, a_second)
              asm.inc(at.call(SECONDS))
              asm.jmp("rt_clock_tick_second")
              asm.label("rt_clock_tick_done")
              asm.mov(at.call(DOTS), :eax)
              asm.ret
            end
          end
        end
      end
    end
  end
end
