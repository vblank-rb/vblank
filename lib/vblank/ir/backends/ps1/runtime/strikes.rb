# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # Sound effects on a timer, struck inside the frame. A PlayStation game's sound driver keys its
          # effects' notes on as each tick of its own timer comes, part way through a frame, where this
          # runtime otherwise keys every note on as the frame begins (Sound's KEYS_ON). For a game whose
          # effects say `on_timer: true` (IR::Tunes.effect_clock_step) it does the same as such a driver.
          #
          # ### Who decides, and when the chip is told
          #
          # The processor still plays the effects a frame at a time, ticks counted as every player counts
          # them, so the sound log, who holds which voice and which note plays are the interpreter's. While
          # a tick's pass over the effects plays (STRIKING), what it asks of the chip (a key on or off, a
          # register written, a voice's volume) is not done or gathered for the frame boundary but put on a
          # list (rt_strikes_put) with the line of the screen it is due on (DUE): the line the frame began
          # on (BASE, the second timer's count as the blank began, which the blank's interrupt keeps in
          # Frame::BLANK_LINE), plus the part of the frame the tick comes after. So a note and the rest after
          # it in one frame each reach the voice at their own tick, and a voice still sounding the note
          # before keeps its pitch and volume until then. What the runtime keeps of each voice (its volume,
          # its fade) moves on at once, as before; only the chip is told later.
          #
          # ### The second timer as the clock
          #
          # The second timer already counts the lines the screen has drawn, from power-on and never
          # started again (Boot), PS1Hardware::LINES_A_FRAME a frame (every build is NTSC), a line some
          # 64 microseconds (psx-spx, "Timers"). Told to
          # raise its interrupt each time the count reaches its target, it is the clock: the list's first
          # entry's line is the target, and the interrupt (Frame#emit_interrupt) does every entry that is
          # due and sets the target to the next (rt_strikes_due). The count runs on past the target, so
          # the line counting is as before. A target set after its line has gone by would not come round
          # for 65536 lines, so the routine reads the count again once it has set it, and does that entry
          # at once when it is due. The frame boundary calls it too, with the interrupt held off, for the
          # entries due already.
          #
          # ### What it costs
          #
          # Nothing for a game without the word. With it, a frame works out where each tick falls (a
          # multiply and a divide), and each key on or off or write a tick asks for is an entry, and later an
          # interrupt.
          module Strikes
            STRIKING = "rt strikes striking" # 1 while a tick's pass over the effects plays
            DUE = "rt strikes due" # The line the pass's keys are due on
            REMAINING = "rt strikes remaining" # The 65536ths of a tick the effects' count had to go to the tick playing
            BASE = "rt strikes base" # The line the frame playing began on
            LIST = "rt strikes list" # A ring of entries: [the key, the line it is due on], a word each
            HEAD = "rt strikes head" # The oldest entry, as a distance into LIST
            TAIL = "rt strikes tail" # Where the next goes
            ENTRY_BYTES = 8
            ENTRIES = 64
            LIST_MASK = (ENTRIES * ENTRY_BYTES) - 1
            # In an entry's key: the voice, and this bit for a key off rather than a key on.
            KEY_OFF = 0x100

            module_function

            def h = Console::PS1Hardware

            def reserve(memory)
              [STRIKING, DUE, REMAINING, BASE, HEAD, TAIL].each { |name| memory.reserve(name, 4) }
              memory.reserve(LIST, ENTRIES * ENTRY_BYTES)
            end

            def strikes?(memory) = memory.reserved?(LIST)

            def emit(asm, memory)
              at = ->(name) { Runtime.at(memory, name) }
              emit_put(asm, at)
              emit_due(asm, at)
            end

            # rt_strikes_put(a0 = an entry's word: a key, or a write, #write_word): onto the list, due on
            # DUE; done at once when the list is full. Every register is as it was after it, since it is
            # called from the middle of the sound's routines.
            def emit_put(asm, at)
              kept = %i[ra t0 t1 t2 t3 t5 t6 t7]
              asm.label("rt_strikes_put")
              asm.addiu(:sp, :sp, -4 * kept.size)
              kept.each_with_index { |name, i| asm.sw(name, i * 4, :sp) }
              asm.lw(:t2, at.call(TAIL), :gp)
              asm.addiu(:t3, :t2, ENTRY_BYTES)
              asm.andi(:t3, :t3, LIST_MASK)
              asm.lw(:t0, at.call(HEAD), :gp)
              asm.beq(:t3, :t0, "rt_strikes_put_full")
              asm.addu(:t0, :gp, :t2)
              asm.sw(:a0, at.call(LIST), :t0)
              asm.lw(:t1, at.call(DUE), :gp)
              asm.sw(:t1, at.call(LIST) + 4, :t0)
              asm.b("rt_strikes_put_done") { asm.sw(:t3, at.call(TAIL), :gp) }
              asm.label("rt_strikes_put_full")
              asm.move(:t5, :a0)
              asm.lui(:t1, h::IO >> 16)
              asm.jal("rt_strikes_key")
              asm.label("rt_strikes_put_done")
              kept.each_with_index { |name, i| asm.lw(name, i * 4, :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * kept.size) }
            end

            # An entry's word for a write of the sound chip's register at +register+ (a distance from
            # 1F801C00h): its top bit set, the distance above, and the value in the low 16 bits; a key's
            # top bit is clear.
            WRITE = 0x8000_0000
            def write_word(register, value) = WRITE | (register << 16) | (value & 0xFFFF)

            # rt_strikes_due (with the interrupt held off): every entry whose line has come done, oldest
            # first, and the timer's target set to the next. rt_strikes_key (t5 = an entry's key, t1 = the
            # ports): the key written, a half for voices 0 to 15 and one for 16 to 23.
            def emit_due(asm, at)
              asm.label("rt_strikes_due")
              asm.lui(:t1, h::IO >> 16)
              asm.label("rt_strikes_due_next")
              asm.lw(:t2, at.call(HEAD), :gp)
              asm.lw(:t3, at.call(TAIL), :gp)
              asm.beq(:t2, :t3, "rt_strikes_due_done")
              asm.addu(:t4, :gp, :t2)
              asm.lw(:t5, at.call(LIST) + 4, :t4)
              emit_branch_if_due(asm, "rt_strikes_due_strike")
              asm.sh(:t5, h::TIMER1_TARGET & 0xFFFF, :t1)
              emit_branch_if_due(asm, "rt_strikes_due_strike") # the line went by as the target was set
              asm.b("rt_strikes_due_done")
              asm.label("rt_strikes_due_strike")
              asm.addiu(:t2, :t2, ENTRY_BYTES)
              asm.andi(:t2, :t2, LIST_MASK)
              asm.sw(:t2, at.call(HEAD), :gp)
              asm.lw(:t5, at.call(LIST), :t4)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.jal("rt_strikes_key")
              asm.lw(:ra, 0, :sp)
              asm.b("rt_strikes_due_next") { asm.addiu(:sp, :sp, 4) }
              asm.label("rt_strikes_due_done")
              asm.jr(:ra)

              asm.label("rt_strikes_key")
              asm.bltz(:t5, "rt_strikes_write")
              asm.andi(:t6, :t5, 0xFF)
              asm.li(:t7, 1)
              asm.sllv(:t7, :t7, :t6)
              asm.andi(:t6, :t5, KEY_OFF)
              asm.bne(:t6, :zero, "rt_strikes_key_off")
              asm.sh(:t7, Sound.spu_at(h::SPU_KEY_ON), :t1)
              asm.srl(:t7, :t7, 16)
              asm.jr(:ra) { asm.sh(:t7, Sound.spu_at(h::SPU_KEY_ON + 2), :t1) }
              asm.label("rt_strikes_key_off")
              asm.sh(:t7, Sound.spu_at(h::SPU_KEY_OFF), :t1)
              asm.srl(:t7, :t7, 16)
              asm.jr(:ra) { asm.sh(:t7, Sound.spu_at(h::SPU_KEY_OFF + 2), :t1) }
              asm.label("rt_strikes_write")
              asm.srl(:t6, :t5, 16)
              asm.andi(:t6, :t6, 0x7FFF)
              asm.addu(:t6, :t6, :t1)
              asm.jr(:ra) { asm.sh(:t5, Sound.spu_at(0), :t6) }
            end

            # To +label+ when the line in t5 has come: the count, less it, with bit 15 clear. Uses t6 and t7;
            # t1 holds the ports.
            def emit_branch_if_due(asm, label)
              asm.lhu(:t6, h::TIMER1_COUNT & 0xFFFF, :t1)
              asm.subu(:t7, :t6, :t5)
              asm.andi(:t7, :t7, 0x8000)
              asm.beq(:t7, :zero, label)
            end

            # --- where the music works out when ---

            # As a frame of the music begins, inline: BASE, the line the blank before it began on, less a
            # frame for each frame the pass took still to play after this one; and REMAINING, what the
            # effects' count (+clock+) has to go to its first tick, before it moves on.
            def emit_set_frame_base(asm, at, clock)
              asm.lw(:t0, at.call(Frame::BLANK_LINE), :gp)
              asm.lw(:t1, at.call(Sound::TICKS_LEFT), :gp)
              asm.addiu(:t1, :t1, -1)
              asm.li(:t2, h::LINES_A_FRAME)
              asm.multu(:t1, :t2)
              asm.mflo(:t1)
              asm.subu(:t0, :t0, :t1)
              asm.andi(:t0, :t0, 0xFFFF)
              asm.sw(:t0, at.call(BASE), :gp)
              asm.lw(:t0, at.call(clock), :gp)
              asm.lui(:t1, 1)
              asm.subu(:t0, :t1, :t0)
              asm.sw(:t0, at.call(REMAINING), :gp)
            end

            # A tick's pass is about to play, inline: DUE, BASE plus REMAINING's share of the frame's lines
            # (+step+ is a frame's 65536ths, IR::Tunes.effect_clock_step), and STRIKING on.
            def emit_striking_on(asm, at, step)
              asm.lw(:t0, at.call(REMAINING), :gp)
              asm.li(:t1, h::LINES_A_FRAME)
              asm.multu(:t0, :t1)
              asm.mflo(:t0)
              asm.li(:t1, step)
              asm.divu(:t0, :t1)
              asm.mflo(:t0)
              asm.lw(:t1, at.call(BASE), :gp)
              asm.addu(:t0, :t0, :t1)
              asm.andi(:t0, :t0, 0xFFFF)
              asm.sw(:t0, at.call(DUE), :gp)
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(STRIKING), :gp)
            end

            # ...and played, inline: STRIKING off.
            def emit_striking_off(asm, at) = asm.sw(:zero, at.call(STRIKING), :gp)

            # The next tick of the frame, inline: a whole count further to go.
            def emit_next_tick(asm, at)
              asm.lw(:t0, at.call(REMAINING), :gp)
              asm.lui(:t1, 1)
              asm.addu(:t0, :t0, :t1)
              asm.sw(:t0, at.call(REMAINING), :gp)
            end
          end
        end
      end
    end
  end
end
