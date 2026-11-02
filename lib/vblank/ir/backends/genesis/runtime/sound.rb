# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE SOUND CHIPS, AND HOW THE 68000 TALKS TO THEM. A Genesis has two: the PSG, whose port the
          # 68000 writes a byte at a time, and the YM2612, which sits on the sound processor's side of the
          # console. The 68000 reaches it only while the sound processor (a Z80) has been asked to stay off
          # its bus (Runtime::Boot), and each of its registers is two writes, which register and then what
          # goes in it, with a wait between for the chip to say it is ready. A game with a recording lets the
          # Z80 run and plays through it (Runtime::Recordings); its FM writes each ask for the bus, write and
          # give it back.
          #
          # NOTHING SOUNDS UNTIL `enable_sound`, as nothing does on the Advance: until then ON is nought and
          # the writes here go nowhere, and a voice's loudness does not move. A sound before it is still
          # in the sound log, as it is in the interpreter's.
          #
          # A VOICE'S LOUDNESS. A PSG voice holds a loudness and has no way of changing it, so a note that
          # fades or swells is the runtime's work: each voice's volume is kept here, with the number of
          # 64ths of a second between its steps, and once a frame each is counted on (rt_sound_fades) the
          # way the Advance's voice counts itself.
          #
          # Everything else is called at the frame boundary, where a pass's wait ends (rt_sound_frame), so
          # no write of the player's can come between two of the game's.
          module Sound
            # The commands of a group of the song table (Genesis::Music), by what each does: the first
            # number and the second, each a word.
            WRITE_PSG = 1 # one byte, or two for a voice's length of wave
            WRITE_FM = 2 # a register, its value
            SET_LOUD = 3 # a voice and a volume (high byte and low), the step it moves by
            SET_LEVEL = 5 # a voice and a volume
            SILENCE = 6 # the voices stopped, a bit each

            ROUTINES = { WRITE_PSG => "rt_psg_write", WRITE_FM => "rt_fm_write", SET_LOUD => "rt_sound_loud",
                         SET_LEVEL => "rt_sound_level", SILENCE => "rt_sound_silence" }.freeze

            # The second number of a WRITE_PSG that is one byte.
            ONE_BYTE = 0xFFFF

            ON = "rt sound on" # 1 once the game has said `enable_sound`
            VOLUMES = "rt sound volumes" # a word for each PSG voice: its volume, 0 to 15...
            STEPS = "rt sound steps" # ...the 64ths of a second between its steps, above nought when it climbs...
            COUNTS = "rt sound counts" # ...and how far to the next one
            VOICES = 4

            # THE SOUND LOG, for whoever reads a run back: every sound statement the game ran, as the number
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
            TICKS_LEFT = "rt sound ticks left" # frames still to move the music on by, where a wait ends

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
              emit_log(asm, at)
              emit_chip_writes(asm, at, samples)
              emit_loudness(asm, at)
              emit_fades(asm, at)
              emit_frame(asm, memory, at, songs, samples)
            end

            # rt_sound_on: `enable_sound`.
            # rt_sound_log(entry): the entry's number into the ring, and one more counted.
            def emit_log(asm, at)
              asm.label("rt_sound_on")
              asm.move(:w, asm.imm(1), at.call(ON))
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

            # rt_psg_write(first, second): a byte to the PSG, and a second one unless it says ONE_BYTE.
            #
            # rt_fm_write(register, value): the FM chip's +register+ (its second part's from $100) set to
            # +value+. The chip's two parts each have a port for the register and one for the value, and
            # it takes a little while over each, during which its first port's top bit reads 1.
            def emit_chip_writes(asm, at, samples)
              h = Console::GenesisHardware
              asm.label("rt_psg_write")
              asm.tst(:w, at.call(ON))
              asm.branch(:eq, "rt_psg_write_done")
              asm.move(:b, asm.d(0), asm.abs_l(h::PSG))
              asm.cmp(:w, asm.imm(ONE_BYTE), asm.d(1))
              asm.branch(:eq, "rt_psg_write_done")
              asm.move(:b, asm.d(1), asm.abs_l(h::PSG))
              asm.label("rt_psg_write_done")
              asm.rts

              asm.label("rt_fm_write")
              asm.tst(:w, at.call(ON))
              asm.branch(:eq, "rt_fm_write_done")
              Recordings.emit_bus_taken(asm) if samples
              asm.lea(asm.abs_l(h::FM), asm.a(1))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.lsr(:w, 7, asm.d(2))
              asm.and(:w, asm.imm(2), asm.d(2)) # the second part's ports are two along
              asm.jsr(asm.abs_l("rt_fm_wait"))
              asm.move(:b, asm.d(0), asm.idx(1, 0, 2, :w))
              asm.jsr(asm.abs_l("rt_fm_wait"))
              asm.move(:b, asm.d(1), asm.idx(1, 1, 2, :w))
              Recordings.emit_bus_given_back(asm) if samples
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

            # rt_sound_loud(voice and volume, step): a PSG voice at that volume, moved on from there by the
            # step (ChipWrites's [:loud ...]).
            # rt_sound_level(voice and volume): at that volume, going on as it was ([:level ...]).
            # rt_sound_silence(voices): each voice whose bit is set stopped.
            def emit_loudness(asm, at)
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

              # The volume in D0 to the PSG's voice D2 says, two bytes a voice.
              asm.label("rt_sound_volume")
              asm.lea(asm.abs_l("rt_sound_attenuation"), asm.a(1))
              asm.move(:b, asm.idx(1, 0, 0, :w), asm.d(0))
              asm.move(:w, asm.d(2), asm.d(1))
              asm.lsl(:w, 4, asm.d(1)) # the voice's number in its bits of the command
              asm.or(:b, asm.d(1), asm.d(0))
              asm.or(:b, asm.imm(0x90), asm.d(0))
              asm.move(:b, asm.d(0), asm.abs_l(h::PSG))
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
