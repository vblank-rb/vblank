# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE SOUND CHIP, AND HOW THE PROCESSOR TALKS TO IT. The PlayStation's sound chip (the SPU) sits
          # among the ports from 1F801C00h, a register of 16 bits each: for each of its 24 voices a volume
          # for each speaker, a pitch, where in the chip's own 512K of sound memory its sound starts, and its
          # envelope; and for the whole chip which voices to start (key on) and let go (key off), its main
          # volume, and whether it is on at all (psx-spx, "Sound Processing Unit"). What each sound-log entry
          # writes is SPUWrites'.
          #
          # AT POWER-ON the game's loops (SoundMemory) are copied into sound memory, 32 halfwords at a time
          # through the chip's queue for them, and the game's voices are given their envelope (#emit_upload).
          # The chip is on from then but its sound is held in (SPU_UNMUTED clear) and its main volume is
          # nought.
          #
          # NOTHING SOUNDS UNTIL `enable_sound`, as nothing does on the Advance: until then ON is nought and
          # the writes here go nowhere, and a voice's loudness does not move. A sound before it is still in
          # the sound log, as it is in the interpreter's.
          #
          # A VOICE'S LOUDNESS. A voice's volume register holds a loudness, so a note that fades or swells is
          # the runtime's work, as on the Genesis: each voice's volume is kept here, with the number of 64ths
          # of a second between its steps, and once a frame each is counted on (rt_sound_fades) the way the
          # Advance's voice counts itself. The chip's envelope could fade a voice by itself, but by rates
          # of its own, not the Advance's sixty-fourths.
          #
          # THE FRAME BOUNDARY, where a pass's wait ends (rt_sound_frame): every voice's fade moved on for
          # each frame the pass took, the voices the pass started and let go told to the chip at once
          # (SPUWrites says why), and the count of the log kept for the pass.
          module Sound
            ON = "rt sound on" # 1 once the game has called `enable_sound`
            VOLUMES = "rt sound volumes" # A word for each voice: its volume, 0 to 15
            STEPS = "rt sound steps" # A word for each voice: the 64ths of a second between its steps, above nought when it climbs
            COUNTS = "rt sound counts" # A word for each voice: how far to its next step
            KEYS_ON = "rt sound keys on" # The voices to start at the frame boundary, a bit each
            KEYS_OFF = "rt sound keys off" # The voices to let go there
            TICKS_LEFT = "rt sound ticks left" # Frames still to move the fades on by, where a wait ends

            # THE SOUND LOG, for whoever reads a run back: every sound statement the game ran, as the number
            # the lowering gave its entry of the interpreter's log (Lowering::Sound), the last LOG_LENGTH of
            # them in a ring (a half each), and how many there have been (a word).
            LOG = "rt sound log"
            LOGGED = "rt sound logged"
            LOG_LENGTH = 256
            # ...and how many there were where each of the last Frame::STEPS_KEPT passes' waits ended, by the
            # pass's number less its multiples of STEPS_KEPT: the pass's number's low half, so a reader can
            # tell the slot is this pass's, then the count's.
            LOGGED_BY_PASS = "rt sound logged by pass"
            LOGGED_SLOT_BYTES = 4

            # THE ENVELOPE every game voice is given (Beetle PSX, spu.c SPU_CacheEnvelope and
            # SPU_RunEnvelope): attack at rate 0, linear, which climbs 7 << 11 a sample and is at full in
            # three; decay at its slowest rate, Fh, which takes off 8 every 16 samples, so the level is under
            # the sustain level (Fh, which is 8000h) after its first step and stays; sustain at rate 7Fh,
            # which never steps; release at rate 0, linear, which takes 4000h off a sample, so a voice let go
            # is silent in two.
            ADSR_LOW = 0x00FF
            ADSR_HIGH = 0x1FC0

            # How many halfwords the chip's queue for sound memory holds (psx-spx: "FIFO ... 32 halfwords").
            QUEUE_HALVES = 32

            # THE COMMANDS OF A GROUP of the song table (PS1::Music), one for each kind of write, each sent to
            # its routine with its first number in a0 and its second in a1. Nought ends a group and 4 logs an
            # entry (SongTable::GROUP_END, GROUP_LOG), so neither is one of these.
            WRITE_SPU = 1
            SET_LOUD = 2
            KEY_ON = 3
            KEY_OFF = 5
            SILENCE = 6
            SET_LEVEL = 7

            ROUTINES = Ractor.make_shareable({ WRITE_SPU => "rt_spu_write", SET_LOUD => "rt_sound_loud", KEY_ON => "rt_sound_key_on",
                                               KEY_OFF => "rt_sound_key_off", SILENCE => "rt_sound_silence",
                                               SET_LEVEL => "rt_sound_level" })

            module_function

            # The command a write (SPUWrites) is sent as: [the command, its first number, its second], each 16
            # bits; the second is read back signed (a fade's step can be below nought).
            def command_for(write)
              case write.first
              when :spu then [WRITE_SPU, write[1], write[2]]
              when :loud then [SET_LOUD, (write[1] << 8) | write[2], write[3] & 0xFFFF]
              when :level then [SET_LEVEL, (write[1] << 8) | write[2], 0]
              when :key_on then [KEY_ON, write[1], 0]
              when :key_off then [KEY_OFF, write[1], 0]
              when :silence then [SILENCE, write[1], 0]
              else raise ArgumentError, "no command for #{write.inspect}"
              end
            end

            # The runtime routine a write is made with in the game's own code, and its numbers.
            def call_for(write)
              command, first, second = command_for(write)
              second -= 0x10000 if second >= 0x8000
              [ROUTINES.fetch(command), [first, second]]
            end

            def reserve(memory)
              [ON, LOGGED, TICKS_LEFT, KEYS_ON, KEYS_OFF].each { |name| memory.reserve(name, 4) }
              [VOLUMES, STEPS, COUNTS].each { |name| memory.reserve(name, SPUWrites::VOICES * 4) }
              memory.reserve(LOG, LOG_LENGTH * 2)
              memory.reserve(LOGGED_BY_PASS, Frame::STEPS_KEPT * LOGGED_SLOT_BYTES)
            end

            # +songs+ for a game with songs, whose player (Music) runs where each wait ends.
            def emit(asm, memory, songs: false)
              at = ->(name) { Runtime.at(memory, name) }
              emit_on(asm, at)
              emit_log(asm, at)
              emit_spu_write(asm, at)
              emit_loudness(asm, at)
              emit_key(asm, at, "rt_sound_key_on", KEYS_ON, KEYS_OFF)
              emit_key(asm, at, "rt_sound_key_off", KEYS_OFF, KEYS_ON)
              emit_silence(asm)
              emit_keys(asm, at)
              emit_fades(asm, at)
              emit_frame(asm, at, songs)
              emit_upload(asm)
              emit_volume_table(asm)
            end

            def h = Console::PS1Hardware

            # The sound chip's registers are reached from t1 holding 1F800000h, each at its distance from
            # there, which fits an instruction's 16 bits.
            def spu_at(register) = (h::SPU & 0xFFFF) + register

            # rt_sound_on: `enable_sound`. The chip's sound let out, at its main volume's loudest.
            def emit_on(asm, at)
              asm.label("rt_sound_on")
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(ON), :gp)
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t0, h::SPU_ON | h::SPU_UNMUTED)
              asm.sh(:t0, spu_at(h::SPU_CONTROL_AT), :t1)
              asm.li(:t0, h::SPU_MAIN_LOUDEST)
              asm.sh(:t0, h::SPU_MAIN_VOLUME & 0xFFFF, :t1)
              asm.sh(:t0, (h::SPU_MAIN_VOLUME + 2) & 0xFFFF, :t1)
              asm.jr(:ra)
            end

            # rt_sound_log(a0 = the entry's number): into the ring, and one more counted.
            def emit_log(asm, at)
              asm.label("rt_sound_log")
              asm.lw(:t0, at.call(LOGGED), :gp)
              asm.andi(:t1, :t0, LOG_LENGTH - 1)
              asm.sll(:t1, :t1, 1)
              asm.addu(:t1, :t1, :gp)
              asm.sh(:a0, at.call(LOG), :t1)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(LOGGED), :gp)
              asm.jr(:ra)
            end

            # rt_spu_write(a0 = the register's distance from 1F801C00h, a1 = what goes in it).
            def emit_spu_write(asm, at)
              asm.label("rt_spu_write")
              asm.lw(:t0, at.call(ON), :gp)
              asm.beq(:t0, :zero, "rt_spu_write_done")
              asm.lui(:t1, h::IO >> 16)
              asm.addu(:t1, :t1, :a0)
              asm.sh(:a1, spu_at(0), :t1)
              asm.label("rt_spu_write_done")
              asm.jr(:ra)
            end

            # rt_sound_loud(a0 = the voice << 8 | its volume, a1 = the step it moves by): the voice at that
            # volume, moved on from there by the step (SPUWrites's [:loud ...]).
            #
            # rt_sound_level(a0 = the voice << 8 | its volume): at that volume, going on as it was ([:level ...]).
            #
            # rt_sound_volume (t0 = a volume, t2 = a voice): the voice's volume registers, both speakers, set
            # to the volume's loudness (SPUWrites::VOLUME_REGISTER). It changes t4 to t7.
            def emit_loudness(asm, at)
              asm.label("rt_sound_loud")
              asm.lw(:t0, at.call(ON), :gp)
              asm.beq(:t0, :zero, "rt_sound_volume_done")
              asm.srl(:t2, :a0, 8)
              asm.sll(:t3, :t2, 2)
              asm.addu(:t3, :t3, :gp)
              asm.sw(:a1, at.call(STEPS), :t3)
              asm.b("rt_sound_level_voice") { asm.sw(:zero, at.call(COUNTS), :t3) }

              asm.label("rt_sound_level")
              asm.lw(:t0, at.call(ON), :gp)
              asm.beq(:t0, :zero, "rt_sound_volume_done")
              asm.srl(:t2, :a0, 8)
              asm.sll(:t3, :t2, 2)
              asm.addu(:t3, :t3, :gp)
              asm.label("rt_sound_level_voice")
              asm.andi(:t0, :a0, 0xFF)
              asm.sw(:t0, at.call(VOLUMES), :t3)

              asm.label("rt_sound_volume")
              asm.la(:t4, "rt_sound_volume_table")
              asm.sll(:t5, :t0, 1)
              asm.addu(:t4, :t4, :t5)
              asm.lhu(:t5, 0, :t4)
              asm.sll(:t6, :t2, 4)
              asm.lui(:t7, h::IO >> 16)
              asm.addu(:t7, :t7, :t6)
              asm.sh(:t5, spu_at(h::SPU_VOLUME_LEFT), :t7)
              asm.sh(:t5, spu_at(h::SPU_VOLUME_RIGHT), :t7)
              asm.label("rt_sound_volume_done")
              asm.jr(:ra)
            end

            # rt_sound_key_on(a0 = a voice) and rt_sound_key_off: the voice's bit set in what the frame
            # boundary writes (+mine+), and taken from the other (+other+), so the last asked for wins.
            def emit_key(asm, at, label, mine, other)
              asm.label(label)
              asm.lw(:t0, at.call(ON), :gp)
              asm.beq(:t0, :zero, "#{label}_done")
              asm.li(:t1, 1)
              asm.sllv(:t1, :t1, :a0)
              asm.lw(:t2, at.call(mine), :gp)
              asm.or(:t2, :t2, :t1)
              asm.sw(:t2, at.call(mine), :gp)
              asm.nor(:t1, :t1, :zero)
              asm.lw(:t2, at.call(other), :gp)
              asm.and(:t2, :t2, :t1)
              asm.sw(:t2, at.call(other), :gp)
              asm.label("#{label}_done")
              asm.jr(:ra)
            end

            # rt_sound_silence(a0 = voices, a bit each): each voice whose bit is set at nought, not moving, and
            # let go ([:silence ...]).
            def emit_silence(asm)
              asm.label("rt_sound_silence")
              asm.addiu(:sp, :sp, -12)
              asm.sw(:ra, 0, :sp)
              asm.sw(:s0, 4, :sp)
              asm.sw(:s1, 8, :sp)
              asm.move(:s0, :a0)
              asm.move(:s1, :zero)
              asm.label("rt_sound_silence_voice")
              asm.srlv(:t0, :s0, :s1)
              asm.andi(:t0, :t0, 1)
              asm.beq(:t0, :zero, "rt_sound_silence_next")
              asm.sll(:a0, :s1, 8)
              asm.move(:a1, :zero)
              asm.jal("rt_sound_loud")
              asm.move(:a0, :s1)
              asm.jal("rt_sound_key_off")
              asm.label("rt_sound_silence_next")
              asm.addiu(:s1, :s1, 1)
              asm.sltiu(:t0, :s1, SPUWrites::VOICES)
              asm.bne(:t0, :zero, "rt_sound_silence_voice")
              asm.lw(:ra, 0, :sp)
              asm.lw(:s0, 4, :sp)
              asm.lw(:s1, 8, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 12) }
            end

            # rt_sound_keys: the voices let go and the voices started this pass, each told to the chip in
            # one write, and both forgotten.
            def emit_keys(asm, at)
              asm.label("rt_sound_keys")
              asm.lui(:t1, h::IO >> 16)
              asm.lw(:t0, at.call(KEYS_OFF), :gp)
              asm.beq(:t0, :zero, "rt_sound_keys_on")
              asm.sh(:t0, spu_at(h::SPU_KEY_OFF), :t1)
              asm.label("rt_sound_keys_on")
              asm.lw(:t0, at.call(KEYS_ON), :gp)
              asm.beq(:t0, :zero, "rt_sound_keys_done")
              asm.sh(:t0, spu_at(h::SPU_KEY_ON), :t1)
              asm.label("rt_sound_keys_done")
              asm.sw(:zero, at.call(KEYS_OFF), :gp)
              asm.sw(:zero, at.call(KEYS_ON), :gp)
              asm.jr(:ra)
            end

            # rt_sound_fades: every voice moving its own loudness, a frame on. A step's count is in 256ths of a
            # 64th of a second, which is how IR::Tunes keeps time for a swell: COUNTED_A_FRAME of those go by
            # in a frame. A voice that reaches the top or nought stays there and stops moving.
            def emit_fades(asm, at)
              asm.label("rt_sound_fades")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.li(:t8, (SPUWrites::VOICES - 1) * 4) # the voices from the last, a word each
              asm.label("rt_sound_fades_voice")
              asm.addu(:t9, :gp, :t8)
              asm.lw(:t1, at.call(STEPS), :t9)
              asm.beq(:t1, :zero, "rt_sound_fades_next")
              asm.move(:t3, :t1)
              asm.bgez(:t3, "rt_sound_fades_size")
              asm.subu(:t3, :zero, :t1)
              asm.label("rt_sound_fades_size")
              asm.sll(:t3, :t3, 8) # what a step takes
              asm.lw(:t5, at.call(COUNTS), :t9)
              asm.addiu(:t5, :t5, IR::Tunes::COUNTED_A_FRAME)
              asm.lw(:t0, at.call(VOLUMES), :t9)
              asm.move(:t6, :zero) # 1 once it has moved
              asm.label("rt_sound_fades_step")
              asm.sltu(:t7, :t5, :t3)
              asm.bne(:t7, :zero, "rt_sound_fades_counted")
              asm.subu(:t5, :t5, :t3)
              asm.li(:t6, 1)
              asm.bltz(:t1, "rt_sound_fades_down")
              asm.addiu(:t0, :t0, 1)
              asm.sltiu(:t7, :t0, IR::Tunes::LOUDEST)
              asm.bne(:t7, :zero, "rt_sound_fades_step")
              asm.b("rt_sound_fades_end")
              asm.label("rt_sound_fades_down")
              asm.addiu(:t0, :t0, -1)
              asm.bgtz(:t0, "rt_sound_fades_step")
              asm.move(:t0, :zero) # a fade from nought stays at nought
              asm.label("rt_sound_fades_end") # at the top or the bottom: it stays there
              asm.sw(:zero, at.call(STEPS), :t9)
              asm.label("rt_sound_fades_counted")
              asm.sw(:t5, at.call(COUNTS), :t9)
              asm.beq(:t6, :zero, "rt_sound_fades_next")
              asm.sw(:t0, at.call(VOLUMES), :t9)
              asm.srl(:t2, :t8, 2)
              asm.jal("rt_sound_volume")
              asm.label("rt_sound_fades_next")
              asm.addiu(:t8, :t8, -4)
              asm.bgez(:t8, "rt_sound_fades_voice")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # rt_sound_frame, where a pass's wait ends, once the buttons are read: for every frame the pass
            # took, the voices' fades (Reference#advance_frame's order: the mix, then the player); then the
            # voices started and let go; and, kept for the pass, how many entries the log holds, with the
            # pass's number (LOGGED_BY_PASS).
            def emit_frame(asm, at, songs)
              asm.label("rt_sound_frame")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.lw(:t0, at.call(Frame::FRAMES_TAKEN), :gp)
              asm.sw(:t0, at.call(TICKS_LEFT), :gp)
              asm.label("rt_sound_frame_tick")
              asm.jal("rt_music_frame") if songs
              asm.jal("rt_sound_fades")
              asm.lw(:t0, at.call(TICKS_LEFT), :gp)
              asm.addiu(:t0, :t0, -1)
              asm.sw(:t0, at.call(TICKS_LEFT), :gp)
              asm.bgtz(:t0, "rt_sound_frame_tick")
              asm.jal("rt_sound_keys")
              asm.lw(:t0, at.call(Frame::PASSES), :gp)
              asm.andi(:t1, :t0, Frame::STEPS_KEPT - 1)
              asm.sll(:t1, :t1, 2)
              asm.addu(:t1, :t1, :gp)
              asm.lw(:t2, at.call(LOGGED), :gp)
              asm.sh(:t2, at.call(LOGGED_BY_PASS) + 2, :t1)
              asm.sh(:t0, at.call(LOGGED_BY_PASS), :t1)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # rt_sound_upload, at power-on: the chip on with its sound held in, the game's loops (the bytes
            # from "sound_memory" to "sound_memory_end") written into sound memory from its first free byte,
            # and each game voice given its envelope.
            #
            # Sound memory is written through a queue of QUEUE_HALVES halfwords: where to start is set once
            # (it moves on by itself), the queue is filled, and the chip told to write it (transfer mode 1,
            # manual), and then waited on until it is no longer busy, before the next (psx-spx, "SPU RAM
            # Manual Write"). RAM_CONTROL is set to 0004h first, as psx-spx says it must be.
            def emit_upload(asm)
              asm.label("rt_sound_upload")
              asm.lui(:t1, h::IO >> 16)
              asm.li(:t0, h::SPU_ON)
              asm.sh(:t0, spu_at(h::SPU_CONTROL_AT), :t1)
              asm.li(:t0, h::SPU_RAM_CONTROL_NORMAL)
              asm.sh(:t0, spu_at(h::SPU_RAM_CONTROL), :t1)
              asm.li(:t0, h::SPU_FIRST_FREE / 8)
              asm.sh(:t0, spu_at(h::SPU_TRANSFER_ADDRESS), :t1)
              asm.la(:t2, "sound_memory")
              asm.la(:t3, "sound_memory_end")
              asm.label("rt_sound_upload_queue")
              asm.beq(:t2, :t3, "rt_sound_upload_voices")
              asm.li(:t4, QUEUE_HALVES)
              asm.label("rt_sound_upload_half")
              asm.lhu(:t0, 0, :t2)
              asm.addiu(:t2, :t2, 2)
              asm.sh(:t0, spu_at(h::SPU_TRANSFER_FIFO), :t1)
              asm.addiu(:t4, :t4, -1)
              asm.beq(:t2, :t3, "rt_sound_upload_write")
              asm.bgtz(:t4, "rt_sound_upload_half")
              asm.label("rt_sound_upload_write")
              asm.li(:t0, h::SPU_ON | h::SPU_MANUAL_WRITE)
              asm.sh(:t0, spu_at(h::SPU_CONTROL_AT), :t1)
              asm.label("rt_sound_upload_busy")
              asm.lhu(:t0, spu_at(h::SPU_STATUS), :t1)
              asm.andi(:t0, :t0, h::SPU_TRANSFER_BUSY)
              asm.bne(:t0, :zero, "rt_sound_upload_busy")
              asm.li(:t0, h::SPU_ON)
              asm.sh(:t0, spu_at(h::SPU_CONTROL_AT), :t1)
              asm.b("rt_sound_upload_queue")
              asm.label("rt_sound_upload_voices")
              asm.li(:t0, ADSR_LOW)
              asm.li(:t2, ADSR_HIGH)
              SPUWrites::VOICES.times do |voice|
                asm.sh(:t0, spu_at(SPUWrites.register(voice, h::SPU_ADSR_LOW)), :t1)
                asm.sh(:t2, spu_at(SPUWrites.register(voice, h::SPU_ADSR_HIGH)), :t1)
              end
              asm.jr(:ra)
            end

            def emit_volume_table(asm)
              asm.label("rt_sound_volume_table")
              asm.data_halves(SPUWrites::VOLUME_REGISTER)
              asm.align
            end
          end
        end
      end
    end
  end
end
