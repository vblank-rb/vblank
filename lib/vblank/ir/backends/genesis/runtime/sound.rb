# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # The sound chips, and how the 68000 talks to them. A Genesis has two: the PSG, whose port the
          # 68000 writes a byte at a time, and the YM2612, which sits on the sound processor's side of the
          # console. The 68000 reaches it only while the sound processor (a Z80) has been asked to stay off
          # its bus (Runtime::Boot), and each of its registers is two writes, which register and then what
          # goes in it, with a wait between for the chip to signal it is ready. A game with a recording lets the
          # Z80 run and plays through it (Runtime::Recordings), and the FM chip is then the Z80's: the
          # 68000's writes to it go into the Z80's queue, and the Z80 makes them.
          #
          # Nothing sounds until `enable_sound`, as nothing does on the Advance: until then ON is nought and
          # the writes here go nowhere, and a voice's loudness does not move. A sound before it is still
          # in the sound log, as it is in the interpreter's.
          #
          # A voice's loudness. A PSG voice holds a loudness and has no way of changing it, so a note that
          # fades or swells is the runtime's work: each voice's volume is kept here, with the number of
          # 64ths of a second between its steps, and once a frame each is counted on (rt_sound_fades) the
          # way the Advance's voice counts itself.
          #
          # Everything else is called at the frame boundary, where a pass's wait ends (rt_sound_frame), so
          # no write of the player's can come between two of the game's.
          module Sound
            # The commands of a group of the song table (Genesis::Music), by what each does: the first
            # number and the second, each a word.
            WRITE_PSG = 1 # One byte, or two for a voice's length of wave
            WRITE_FM = 2 # A register, its value
            SET_LOUD = 3 # A voice and a volume (high byte and low), the step it moves by
            SET_LEVEL = 5 # A voice and a volume
            SILENCE = 6 # The voices stopped, a bit each

            ROUTINES = { WRITE_PSG => "rt_psg_write", WRITE_FM => "rt_fm_write", SET_LOUD => "rt_sound_loud",
                         SET_LEVEL => "rt_sound_level", SILENCE => "rt_sound_silence" }.freeze

            # The second number of a WRITE_PSG that is one byte.
            ONE_BYTE = 0xFFFF

            ON = "rt sound on" # 1 once the game has called `enable_sound`
            VOLUMES = "rt sound volumes" # A word for each PSG voice: its volume, 0 to 15
            STEPS = "rt sound steps" # A word for each voice: the 64ths of a second between its steps, above nought when it climbs
            COUNTS = "rt sound counts" # A word for each voice: how far to its next step
            VOICES = 4

            # The sound log, for whoever reads a run back: every sound statement the game ran, as the number
            # the lowering gave its entry of the interpreter's log (Lowering::Sound), the last LOG_LENGTH of
            # them in a ring, and how many there have been (16 bits).
            LOG = "rt sound log"
            LOGGED = "rt sound logged"
            LOG_LENGTH = 256
            # ...and how many there were where each of the last Frame::STEPS_KEPT passes' waits ended, the
            # music of the frames it took played, by the pass's number less its multiples of STEPS_KEPT:
            # the pass's number's low word, so a reader can tell the slot is this pass's, then the count.
            LOGGED_BY_PASS = "rt sound logged by pass"
            LOGGED_SLOT_BYTES = 4
            TICKS_LEFT = "rt sound ticks left" # Frames still to move the music on by, where a wait ends

            # How many times the FM chip is asked if it is ready before it is written anyway.
            PATIENCE = 256

            module_function

            # The command a chip write (ChipWrites) is sent as: [the command, its first number, its second].
            def command_for(write)
              case write.first
              when :tone
                _, voice, length = write
                [WRITE_PSG, 0x80 | (voice << 5) | (length & 0x0F), (length >> 4) & 0x3F]
              when :noise_setting then [WRITE_PSG, 0xE0 | write[1], ONE_BYTE]
              when :fm then [WRITE_FM, write[1], write[2]]
              when :loud then [SET_LOUD, (write[1] << 8) | write[2], write[3] & 0xFFFF]
              when :level then [SET_LEVEL, (write[1] << 8) | write[2], 0]
              when :silence then [SILENCE, write[1], 0]
              else raise ArgumentError, "no command for #{write.inspect}"
              end
            end

            def reserve(memory)
              [ON, LOGGED, TICKS_LEFT].each { |name| memory.reserve(name, 2) }
              [VOLUMES, STEPS, COUNTS].each { |name| memory.reserve(name, VOICES * 2) }
              memory.reserve(LOG, LOG_LENGTH * 2)
              memory.reserve(LOGGED_BY_PASS, Frame::STEPS_KEPT * LOGGED_SLOT_BYTES)
            end

            # +songs+ for a game with songs, whose player (Music) runs where each wait ends; +samples+ for one
            # that plays recordings (Recordings), whose count moves on there and whose Z80 shares the FM chip.
            def emit(asm, memory, songs: false, samples: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              strikes = Strikes.strikes?(memory)
              emit_log(asm, at, samples, strikes: strikes)
              emit_chip_writes(asm, at, samples, strikes: strikes)
              emit_loudness(asm, at, strikes: strikes)
              emit_fades(asm, at)
              emit_frame(asm, memory, at, songs, samples)
            end

            # rt_sound_on: `enable_sound`.
            # rt_sound_log(entry): the entry's number into the ring, and one more counted.
            # With +strikes+ in a game that plays no recording, no FM register's value is kept yet
            # (Strikes's rt_strikes_unkept; Recordings does it in one that does).
            def emit_log(asm, at, samples, strikes: false)
              asm.label("rt_sound_on")
              asm.move(:w, asm.imm(1), at.call(ON))
              asm.jsr(asm.abs_l("rt_strikes_unkept")) if strikes && !samples
              asm.jsr(asm.abs_l("rt_recordings_on")) if samples
              asm.rts

              asm.label("rt_sound_log")
              asm.move(:w, at.call(LOGGED), asm.d(1))
              asm.and(:w, asm.imm(LOG_LENGTH - 1), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(LOG), asm.a(1))
              asm.move(:w, asm.d(0), asm.idx(1, 0, 1, :w))
              asm.addq(:w, 1, at.call(LOGGED))
              asm.rts
            end

            # rt_psg_write(first, second): a byte to the PSG, and a second one unless it is ONE_BYTE.
            #
            # rt_fm_write(register, value): the FM chip's +register+ (its second part's from $100) set to
            # +value+. The chip's two parts each have a port for the register and one for the value, and
            # it takes a little while over each, during which its first port's top bit reads 1.
            #
            # With +strikes+, for a game whose sound effects are struck inside the frame (Strikes), each goes
            # through rt_strikes_chip once the sound is on, which makes it at rt_psg_now or rt_fm_now, now or
            # at its line. rt_fm_unlisted is rt_fm_write made now, for a recording's own writes, and is
            # rt_fm_write itself in any other game.
            def emit_chip_writes(asm, at, samples, strikes: false)
              h = Console::GenesisHardware
              asm.label("rt_psg_write")
              asm.tst(:w, at.call(ON))
              asm.branch(:eq, "rt_psg_write_done")
              if strikes
                emit_psg_listed(asm)
                asm.label("rt_psg_now")
              end
              asm.move(:b, asm.d(0), asm.abs_l(h::PSG))
              asm.cmp(:w, asm.imm(ONE_BYTE), asm.d(1))
              asm.branch(:eq, "rt_psg_write_done")
              asm.move(:b, asm.d(1), asm.abs_l(h::PSG))
              asm.label("rt_psg_write_done")
              asm.rts

              asm.label("rt_fm_unlisted")
              if strikes
                asm.tst(:w, at.call(ON))
                asm.branch(:eq, "rt_fm_write_done")
                emit_fm_unchanged_dropped(asm, at, "rt_fm_unlisted")
                asm.bra("rt_fm_now")
              end
              asm.label("rt_fm_write")
              asm.tst(:w, at.call(ON))
              asm.branch(:eq, "rt_fm_write_done")
              if strikes
                emit_fm_unchanged_dropped(asm, at, "rt_fm_write")
                emit_fm_listed(asm)
                asm.label("rt_fm_now")
              end
              return emit_fm_write_queued(asm, at, dropping: !strikes) if samples

              asm.lea(asm.abs_l(h::FM), asm.a(1))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.lsr(:w, 7, asm.d(2))
              asm.and(:w, asm.imm(2), asm.d(2)) # the second part's ports are two along
              asm.jsr(asm.abs_l("rt_fm_wait"))
              asm.move(:b, asm.d(0), asm.idx(1, 0, 2, :w))
              asm.jsr(asm.abs_l("rt_fm_wait"))
              asm.move(:b, asm.d(1), asm.idx(1, 1, 2, :w))
              asm.label("rt_fm_write_done")
              asm.rts

              asm.label("rt_fm_wait")
              asm.move(:w, asm.imm(PATIENCE - 1), asm.d(3))
              asm.label("rt_fm_wait_next")
              asm.btst(7, asm.ind(1))
              asm.branch(:eq, "rt_fm_wait_done")
              asm.dbra(asm.d(3), "rt_fm_wait_next")
              asm.label("rt_fm_wait_done")
              asm.rts
            end

            # A PSG write (D0, D1) handed to rt_strikes_chip, inline: D2 the voice and kind its command
            # names (Strikes::PSG).
            def emit_psg_listed(asm)
              asm.move(:w, asm.d(0), asm.d(2))
              asm.and(:w, asm.imm(Strikes::FIRST_PSG_BITS), asm.d(2))
              asm.or(:w, asm.imm(Strikes::PSG), asm.d(2))
              asm.jmp(asm.abs_l("rt_strikes_chip"))
            end

            # An FM write (D0, D1) handed to rt_strikes_chip, inline: D2 the register, or for the key
            # register the voice its value keys (Strikes::KEY_VOICE).
            def emit_fm_listed(asm)
              asm.move(:w, asm.d(0), asm.d(2))
              asm.cmp(:w, asm.imm(ChipWrites::KEY), asm.d(2))
              asm.branch(:ne, "rt_fm_listed_register")
              asm.move(:w, asm.d(1), asm.d(2))
              asm.and(:w, asm.imm(Strikes::KEY_VOICE_BITS), asm.d(2))
              asm.or(:w, asm.imm(Strikes::KEY_VOICE), asm.d(2))
              asm.label("rt_fm_listed_register")
              asm.jmp(asm.abs_l("rt_strikes_chip"))
            end

            # A write (D0, D1) of the FM chip that changes nothing dropped, inline: to rt_fm_write_done when
            # Recordings::FM_KEPT holds that value for that register already, and otherwise kept there; the
            # key register, the timers' and the pitch registers are always made. +name+ makes the labels.
            # See #emit_fm_write_queued for why.
            def emit_fm_unchanged_dropped(asm, at, name)
              r = Recordings
              made = "#{name}_changes"
              asm.cmp(:w, asm.imm(ChipWrites::KEY), asm.d(0))
              asm.branch(:eq, made)
              asm.cmp(:w, asm.imm(r::TIMERS), asm.d(0))
              asm.branch(:eq, made)
              asm.move(:w, asm.d(0), asm.d(2))
              asm.and(:w, asm.imm(r::PITCH_REGISTERS_MASK), asm.d(2))
              asm.cmp(:w, asm.imm(r::PITCH_REGISTERS), asm.d(2))
              asm.branch(:eq, made)
              asm.and(:w, asm.imm(0xFF), asm.d(1))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.add(:w, asm.d(2), asm.d(2))
              asm.lea(at.call(r::FM_KEPT), asm.a(1))
              asm.cmp(:w, asm.idx(1, 0, 2, :w), asm.d(1))
              asm.branch(:eq, "rt_fm_write_done")
              asm.move(:w, asm.d(1), asm.idx(1, 0, 2, :w))
              asm.label(made)
            end

            # rt_fm_write in a game that plays recordings, where the FM chip is the Z80's: the write put
            # in the Z80's queue (Recordings#emit_queued), which the Z80 makes between two samples.
            #
            # The timers' register ($27) also holds the third voice's mode, and the Z80 writes it every
            # sample. So a write to it from the game's side is not queued as it is: its mode is written
            # into each of the Z80's own writes of it (Recordings::TIMER_WRITES), and what is queued is
            # the mode with the timers left counting, which changes nothing of theirs while a recording
            # plays and nothing that matters while none does.
            #
            # A write that would change nothing is not queued. Each register's last value is kept
            # (Recordings::FM_KEPT, a word each, $FFFF for one not written yet), and a write of the same
            # value again is dropped. A note sets its voice's every register, some thirty, and a voice
            # playing one instrument changes only a few of them from note to note; each write the Z80
            # makes costs it most of a sample. The key register is never dropped, since each write to it
            # is a key going down or up, and nor are the pitch registers, since the chip takes a pitch's
            # high byte only as its low byte is written.
            #
            # In a game whose sound effects are struck inside the frame (+dropping+ false) the write is
            # dropped before it is listed (#emit_chip_writes), so it is not looked at again here.
            def emit_fm_write_queued(asm, at, dropping: true)
              r = Recordings
              program = r.driver
              emit_fm_unchanged_dropped(asm, at, "rt_fm_write_queued") if dropping
              Recordings.emit_bus_taken(asm)
              asm.cmp(:w, asm.imm(r::TIMERS), asm.d(0))
              asm.branch(:ne, "rt_fm_write_queue")
              asm.and(:w, asm.imm(r::MODE_BITS), asm.d(1))
              r::TIMER_WRITES.each do |label, value|
                asm.move(:b, asm.d(1), asm.d(2))
                asm.or(:b, asm.imm(value), asm.d(2))
                asm.move(:b, asm.d(2), asm.abs_l(r::Z80_MEMORY + program.address_of(label)))
              end
              asm.or(:w, asm.imm(r::TIMERS_COUNTING), asm.d(1))
              asm.label("rt_fm_write_queue")
              asm.move(:w, asm.d(0), asm.d(3))
              asm.lsr(:w, 7, asm.d(3))
              asm.and(:w, asm.imm(r::SECOND_PART), asm.d(3)) # the second part's ports are two along
              asm.jsr(asm.abs_l("rt_z80_queued"))
              Recordings.emit_bus_given_back(asm)
              asm.label("rt_fm_write_done")
              asm.rts
            end

            # rt_sound_loud(voice and volume, step): a PSG voice at that volume, moved on from there by the
            # step (ChipWrites's [:loud ...]).
            # rt_sound_level(voice and volume): at that volume, going on as it was ([:level ...]).
            # rt_sound_silence(voices): each voice whose bit is set stopped.
            # With +strikes+ the PSG's write goes through rt_strikes_chip (#emit_chip_writes).
            def emit_loudness(asm, at, strikes: false)
              h = Console::GenesisHardware
              asm.label("rt_sound_loud")
              asm.tst(:w, at.call(ON))
              asm.branch(:eq, "rt_sound_volume_done")
              asm.move(:w, asm.d(0), asm.d(2))
              asm.lsr(:w, 7, asm.d(2))
              asm.and(:w, asm.imm(6), asm.d(2)) # two bytes a voice
              asm.lea(at.call(STEPS), asm.a(1))
              asm.move(:w, asm.d(1), asm.idx(1, 0, 2, :w))
              asm.lea(at.call(COUNTS), asm.a(1))
              asm.clr(:w, asm.idx(1, 0, 2, :w))
              asm.bra("rt_sound_level_voice")

              asm.label("rt_sound_level")
              asm.tst(:w, at.call(ON))
              asm.branch(:eq, "rt_sound_volume_done")
              asm.move(:w, asm.d(0), asm.d(2))
              asm.lsr(:w, 7, asm.d(2))
              asm.and(:w, asm.imm(6), asm.d(2))
              asm.label("rt_sound_level_voice")
              asm.and(:w, asm.imm(0xFF), asm.d(0))
              asm.lea(at.call(VOLUMES), asm.a(1))
              asm.move(:w, asm.d(0), asm.idx(1, 0, 2, :w))

              # The volume in D0 to the PSG's voice D2 names, two bytes a voice.
              asm.label("rt_sound_volume")
              asm.lea(asm.abs_l("rt_sound_attenuation"), asm.a(1))
              asm.move(:b, asm.idx(1, 0, 0, :w), asm.d(0))
              asm.move(:w, asm.d(2), asm.d(1))
              asm.lsl(:w, 4, asm.d(1)) # the voice's number in its bits of the command
              asm.or(:b, asm.d(1), asm.d(0))
              asm.or(:b, asm.imm(0x90), asm.d(0))
              if strikes
                asm.and(:w, asm.imm(0xFF), asm.d(0))
                asm.move(:w, asm.imm(ONE_BYTE), asm.d(1))
                emit_psg_listed(asm)
              else
                asm.move(:b, asm.d(0), asm.abs_l(h::PSG))
              end
              asm.label("rt_sound_volume_done")
              asm.rts

              asm.label("rt_sound_attenuation")
              asm.data_bytes(ChipWrites::ATTENUATION)

              asm.label("rt_sound_silence")
              asm.move(:w, asm.d(0), asm.d(5))
              [0, 1, ChipWrites::NOISE_VOICE].each do |voice|
                kept = "rt_sound_silence_kept_#{voice}"
                asm.btst(voice, asm.d(5))
                asm.branch(:eq, kept)
                asm.move(:w, asm.imm(voice << 8), asm.d(0))
                asm.moveq(0, asm.d(1))
                asm.jsr(asm.abs_l("rt_sound_loud"))
                asm.label(kept)
              end
              asm.btst(ChipWrites::WAVE_VOICE, asm.d(5))
              asm.branch(:eq, "rt_sound_silence_done")
              asm.move(:w, asm.imm(ChipWrites::KEY), asm.d(0))
              asm.moveq(ChipWrites::KEY_OFF, asm.d(1))
              asm.jsr(asm.abs_l("rt_fm_write"))
              asm.label("rt_sound_silence_done")
              asm.rts
            end

            # rt_sound_fades: every PSG voice moving its own loudness, a frame on. A step's count in 256ths
            # of a 64th of a second, which is how IR::Tunes keeps time for a swell: COUNTED_A_FRAME of those
            # go by in a frame.
            def emit_fades(asm, at)
              asm.label("rt_sound_fades")
              asm.moveq(6, asm.d(4)) # the voices from the last, two bytes a voice
              asm.label("rt_sound_fades_voice")
              asm.lea(at.call(STEPS), asm.a(2))
              asm.move(:w, asm.idx(2, 0, 4, :w), asm.d(1))
              asm.branch(:eq, "rt_sound_fades_next")
              asm.move(:w, asm.d(1), asm.d(3))
              asm.branch(:pl, "rt_sound_fades_size")
              asm.neg(:w, asm.d(3))
              asm.label("rt_sound_fades_size")
              asm.lsl(:w, 8, asm.d(3)) # what a step takes
              asm.lea(at.call(COUNTS), asm.a(3))
              asm.move(:w, asm.idx(3, 0, 4, :w), asm.d(5))
              asm.add(:w, asm.imm(IR::Tunes::COUNTED_A_FRAME), asm.d(5))
              asm.lea(at.call(VOLUMES), asm.a(4))
              asm.move(:w, asm.idx(4, 0, 4, :w), asm.d(0))
              asm.moveq(0, asm.d(6)) # 1 once it has moved
              asm.label("rt_sound_fades_step")
              asm.cmp(:w, asm.d(3), asm.d(5))
              asm.branch(:cs, "rt_sound_fades_counted")
              asm.sub(:w, asm.d(3), asm.d(5))
              asm.moveq(1, asm.d(6))
              asm.tst(:w, asm.d(1))
              asm.branch(:mi, "rt_sound_fades_down")
              asm.addq(:w, 1, asm.d(0))
              asm.cmp(:w, asm.imm(IR::Tunes::LOUDEST), asm.d(0))
              asm.branch(:cs, "rt_sound_fades_step")
              asm.bra("rt_sound_fades_end")
              asm.label("rt_sound_fades_down")
              asm.subq(:w, 1, asm.d(0))
              asm.branch(:hi, "rt_sound_fades_step")
              asm.label("rt_sound_fades_end") # at the top or the bottom: it stays there
              asm.clr(:w, asm.idx(2, 0, 4, :w))
              asm.label("rt_sound_fades_counted")
              asm.move(:w, asm.d(5), asm.idx(3, 0, 4, :w))
              asm.tst(:w, asm.d(6))
              asm.branch(:eq, "rt_sound_fades_next")
              asm.move(:w, asm.d(0), asm.idx(4, 0, 4, :w))
              asm.move(:w, asm.d(4), asm.d(2))
              asm.jsr(asm.abs_l("rt_sound_volume"))
              asm.label("rt_sound_fades_next")
              asm.subq(:w, 2, asm.d(4))
              asm.branch(:pl, "rt_sound_fades_voice")
              asm.rts
            end

            # rt_sound_frame, where a pass's wait ends: for every frame the pass took, the recordings' count
            # moved on, then the music played (Reference#advance_frame's order: the mix, then the player),
            # then the voices' fades; and, kept for the pass, which recording sounds then (Recordings) and how
            # many entries the log holds, with the pass's number written last (LOGGED_BY_PASS).
            def emit_frame(asm, memory, at, songs, samples)
              asm.label("rt_sound_frame")
              Strikes.emit_wait_ended(asm, at) if Strikes.strikes?(memory)
              asm.move(:w, at.call(Frame::FRAMES_TAKEN), at.call(TICKS_LEFT))
              asm.label("rt_sound_frame_tick")
              asm.jsr(asm.abs_l("rt_recordings_frame")) if samples
              asm.jsr(asm.abs_l("rt_music_frame")) if songs
              asm.jsr(asm.abs_l("rt_sound_fades"))
              asm.subq(:w, 1, at.call(TICKS_LEFT))
              asm.branch(:ne, "rt_sound_frame_tick")
              asm.jsr(asm.abs_l("rt_recordings_kept_for_pass")) if samples
              asm.move(:l, at.call(Frame::PASSES), asm.d(0))
              asm.and(:w, asm.imm(Frame::STEPS_KEPT - 1), asm.d(0))
              asm.lsl(:w, 2, asm.d(0))
              asm.lea(asm.abs_l(memory[LOGGED_BY_PASS]), asm.a(0))
              asm.move(:w, at.call(LOGGED), asm.idx(0, 2, 0, :w))
              asm.move(:w, at.call(Frame::PASSES, 2), asm.idx(0, 0, 0, :w))
              asm.rts
            end
          end
        end
      end
    end
  end
end
