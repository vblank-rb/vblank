# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SOUND UNIT, AND HOW THE CONSOLE TALKS TO IT. A Super Nintendo's sound is made by a
          # small computer of its own: an SPC700 processor with 64K of memory, and the S-DSP, which
          # mixes eight voices, each playing a recorded sound at the pitch and volume its registers
          # set. The console's processor cannot see any of that memory. All it has are four one-byte
          # mailboxes ($2140-$2143 on its side, $F4-$F7 on the sound unit's): a byte the console
          # writes into one is read by the SPC700, and a byte the SPC700 writes is read by the console.
          #
          # SENDING ITS PROGRAM. At power-on the SPC700 runs a little program built into the chip,
          # which zeroes its direct page, puts $AA and $BB in the first two mailboxes to signal it is
          # ready, and then takes a program a byte at a time: the console writes the byte into
          # mailbox 1 and its number (the low eight bits of where it is) into mailbox 0, and waits
          # until the SPC700 copies that number back to signal it has the byte. Each command is started
          # by a "kick", a number in mailbox 0 that is not the next byte's: $CC for the first, and
          # after the bytes one past the last byte's number. A last command with nought in mailbox 1
          # gives where to start the program, and the built-in program jumps there. rt_sound_start
          # does all that, once, at power-on, with interrupts held off and the screen's interrupt
          # still off: the last byte's answer lasts only a few of the SPC700's cycles, and an
          # interrupt could miss it. Its waits have no limit — at power-on the built-in program is
          # always there to answer. (fullsnes, "SNES APU Main CPU Communication Port", which has the
          # built-in program.)
          #
          # THE PROGRAM IT RUNS (Sound.driver) does one thing: it waits for mailbox 0 to change, and
          # then does the command the other three hold — today only "write this value into this
          # DSP register" — and copies mailbox 0's new number back to signal it is done. Everything a
          # sound is (which recording, its pitch, its volume, its envelope, key on and key off) is
          # DSP registers, so the console plays every sound by writing them through it.
          #
          # NEVER LOSING A FRAME TO SOUND. rt_sound_write sends one register write and does not wait
          # for it to be done: it waits instead, before sending, for the write before it to have been
          # answered, which takes the SPC700 a few dozen of its cycles. That wait is bounded
          # (PATIENCE tries); a sound unit that has not answered by then has its write dropped and
          # counted in DROPPED, and the game goes on.
          #
          # A NOTE IS NINE WRITES (two commands in a game with sound effects, #driver says why), and each still waits for the one before, so parts starting notes
          # together would stand in a game's way. So a game with music queues its writes (QUEUE) and
          # the queue is sent while the game waits for the screen, one write each time the sound
          # unit has answered (#emit_idle_step). A recorded note, or its loudness, is one entry until
          # it reaches the front. Queueing takes a few instructions, and the waiting comes out of
          # time the game was not using. A note then starts later in the frame than the wait it
          # follows, never more than a frame late while the game has time to spare, and always in
          # the order it was asked. What power-on sends goes at once, before any wait.
          #
          # Every routine is reached with JSL and leaves A, X and Y 16 bits wide. Mailboxes 0 and 1
          # are written a byte at a time, since a 16-bit write to $2140 can spoil $2143 on some
          # cartridges (fullsnes); mailboxes 2 and 3 take a 16-bit write, as fullsnes's uploader
          # writes them.
          module Sound
            # Where in the sound unit's memory its program goes: past the direct page, the stack
            # ($0100-$01FF) and nothing else. The sample table and the recordings (Samples) go after
            # it, from the next page, since the DSP finds the table by its page alone.
            DRIVER_AT = 0x0200
            TABLE_AT = 0x0300

            # What the built-in program puts in mailboxes 0 and 1 when it is ready, and the first
            # number the console answers with.
            READY = 0xBBAA
            FIRST_KICK = 0xCC

            # The commands the program knows, in mailbox 1: write a DSP register (mailbox 2 names it,
            # mailbox 3 is its value), and set some of FLG's or KOFF's bits (mailbox 2 holds which,
            # mailbox 3 what they become), leaving the rest as the DSP holds them (DSPWrites, "FLG is
            # shared" and "KOFF is shared").
            WRITE_DSP = 1
            SET_FLAG_BITS = 2
            SET_KEY_OFF_BITS = 3
            # A note told whole (#driver): the pitch of the note coming, and then, with a voice's number
            # in the command's high half, the note itself, or a new loudness for the voice.
            HOLD_PITCH = 8
            WHOLE_NOTE = 9
            VOICE_LOUDNESS = 10
            # ...and in a game with a recording shaped by the chip's own envelope bytes, those of the
            # note coming: ADSR1 and ADSR2, then GAIN.
            HOLD_ENVELOPE = 11
            HOLD_GAIN = 12
            COMMAND_BITS = 0x0F
            VOICE_BITS = 0x70

            # Which command sets bits of which register, and the routine that sends each command.
            SET_BITS_COMMANDS = { DSPWrites::FLAGS => SET_FLAG_BITS, DSPWrites::KEY_OFF => SET_KEY_OFF_BITS }.freeze
            ROUTINES = { WRITE_DSP => "rt_sound_write", SET_FLAG_BITS => "rt_sound_flag_bits",
                         SET_KEY_OFF_BITS => "rt_sound_key_off_bits" }.freeze

            # The SPC700's mailboxes and the DSP's two registers that reach the rest of it: $F2
            # picks a DSP register, and $F3 is its value.
            DSP_ADDRESS = 0xF2
            DSP_DATA = 0xF3
            PORTS = [0xF4, 0xF5, 0xF6, 0xF7].freeze

            # Where the program keeps the last number it answered, in its direct page, and FLG's bits
            # that stay while it works out the new ones.
            LAST_ANSWERED = 0x00
            KEPT_BITS = 0x01
            # ...and the pitch of the note it is about to be told, two bytes.
            NEXT_PITCH = 0x02
            # ...and its envelope's bytes: ADSR1 and ADSR2, then GAIN.
            NEXT_ENVELOPE = 0x04
            NEXT_GAIN = 0x06

            # How many times rt_sound_write reads mailbox 0 for the answer to the write before.
            PATIENCE = 256

            LIVE = "rt sound live" # 1 once the program was sent and started
            SENT = "rt sound sent" # The number of the last command sent, in mailbox 0
            DROPPED = "rt sound dropped" # Writes dropped because the sound unit had not answered

            # THE WRITES WAITING TO GO, in a game with music: a ring of entries, the oldest at
            # QUEUE_HEAD and the next free at QUEUE_TAIL, both as offsets into it, so the two are equal
            # when it is empty. One entry is left free so that full and empty differ. A power of two.
            QUEUE = "rt sound queue"
            QUEUE_HEAD = "rt sound queue head"
            QUEUE_TAIL = "rt sound queue tail"
            QUEUE_ENTRIES = 64
            ENTRY_BYTES = 8
            QUEUE_MASK = (QUEUE_ENTRIES * ENTRY_BYTES) - 1
            ENTRY_COMMAND = 0
            ENTRY_REGISTER = 2
            ENTRY_VALUE = 4
            # An entry that is a recording's whole note, or a new loudness for one: its register is
            # the place's offset and its value the recording's row, and it becomes this many writes
            # where it stood, worked out by the routine named (Recordings), with what its name asks.
            START_NOTE = 4
            NOTE_VOLUME = 5
            NOTE_PITCH = 6
            NOTE_START_WRITES = 9
            NOTE_VOLUME_WRITES = 2
            NOTE_PITCH_WRITES = 2
            VOICE_TOLD = { START_NOTE => [NOTE_START_WRITES, "rt_recordings_voice_start"],
                           NOTE_VOLUME => [NOTE_VOLUME_WRITES, "rt_recordings_voice_volume"] }.freeze
            # ...told whole, where the sound unit's program takes them (#driver).
            VOICE_TOLD_WHOLE = { START_NOTE => [2, "rt_recordings_voice_start"],
                                 NOTE_VOLUME => [1, "rt_recordings_voice_volume"] }.freeze
            # ...and in a game with a note that glides, its new pitch.
            VOICE_TOLD_OF_GLIDES = { NOTE_PITCH => [NOTE_PITCH_WRITES, "rt_recordings_voice_pitch"] }.freeze
            # What a note's start takes more in a game with a recording shaped by the chip's own
            # envelope bytes: a write for ADSR2, or told whole, the two commands that hold the bytes.
            CHIP_ENVELOPE_WRITES = 1
            CHIP_ENVELOPE_COMMANDS = 2
            # The room a write leaves in the queue, so an entry at the front can always become its
            # writes (#queue_room adds what a chip envelope takes).
            QUEUE_ROOM = (NOTE_START_WRITES + 1) * ENTRY_BYTES
            QUEUE_TAIL_KEPT = "rt sound queue tail kept"
            # THE LINE AHEAD OF IT, in a game with sound effects (#emit_write_ahead), a ring laid out
            # the same way. ASKING_AHEAD is set while an effect plays, FRONT_LEFT counts what is at the
            # front of the queue to go before the next can be moved there, and FORGOTTEN is what an
            # entry becomes that nothing wants any more.
            AHEAD = "rt sound ahead"
            AHEAD_HEAD = "rt sound ahead head"
            AHEAD_TAIL = "rt sound ahead tail"
            AHEAD_ENTRIES = 32
            AHEAD_MASK = (AHEAD_ENTRIES * ENTRY_BYTES) - 1
            ASKING_AHEAD = "rt sound asking ahead"
            FRONT_LEFT = "rt sound front left"
            FORGOTTEN = 7
            FORGET_KEEPS = "rt sound forget keeps"
            AHEAD_TRIES = 16

            # THE SOUND LOG, for whoever reads a run back: every sound statement the game ran, as the
            # number the lowering gave its entry of the interpreter's log (Lowering::Sound), the
            # last LOG_LENGTH of them in a ring, and how many there have been (16 bits).
            LOG = "rt sound log"
            LOGGED = "rt sound logged"
            LOG_LENGTH = 256
            # ...and how many there were where each of the last Frame::STEPS_KEPT passes' waits ended,
            # the music of the frames it took played (Music), by the pass's number less its multiples
            # of STEPS_KEPT: the pass's number's low word, so a reader can tell the slot is this
            # pass's, then the count. That is the interpreter's log as the pass's frame boundary
            # leaves it.
            LOGGED_BY_PASS = "rt sound logged by pass"
            LOGGED_SLOT_BYTES = 4
            # Frames still to move the recordings and the music on by, where a wait ends.
            TICKS_LEFT = "rt sound ticks left"
            # Where the sound unit's memory ends for what is sent: its last 64 bytes are where its
            # built-in program is read from (fullsnes, "SNES APU Memory").
            MEMORY_END = 0xFFC0

            R0 = Memory.register(0)
            R1 = Memory.register(1)
            R2 = Memory.register(2)

            module_function

            # The command a DSP write (DSPWrites.for_entry) is sent as: [the command, its first number,
            # its second].
            def command_for(write)
              register, *values = write
              return [WRITE_DSP, register, values.first] unless register == DSPWrites::SET_BITS

              target, mask, bits = values
              [SET_BITS_COMMANDS.fetch(target), mask, bits]
            end

            def reserve(memory, queued: false, effects: false)
              if queued
                memory.reserve_table(QUEUE, QUEUE_ENTRIES * ENTRY_BYTES)
                memory.reserve(QUEUE_HEAD, 2)
                memory.reserve(QUEUE_TAIL, 2)
                memory.reserve(QUEUE_TAIL_KEPT, 2)
              end
              if queued && effects
                memory.reserve_table(AHEAD, AHEAD_ENTRIES * ENTRY_BYTES)
                [AHEAD_HEAD, AHEAD_TAIL, ASKING_AHEAD, FRONT_LEFT, FORGET_KEEPS].each { |name| memory.reserve(name, 2) }
              end
              memory.reserve(LIVE, 2)
              memory.reserve(SENT, 2)
              memory.reserve(DROPPED, 2)
              memory.reserve(LOGGED, 2)
              memory.reserve_table(LOG, LOG_LENGTH * 2)
              memory.reserve_table(LOGGED_BY_PASS, Frame::STEPS_KEPT * LOGGED_SLOT_BYTES)
              memory.reserve(TICKS_LEFT, 2)
            end

            # Everything sent across at power-on, from DRIVER_AT: the program, then from TABLE_AT the
            # sample table and the recordings, the game's +waves+ and then its own +recordings+
            # (Samples.recording's pairs) last (Samples.image). #sections and #emit are each handed the
            # same lists, since rt_sound_start sends as many bytes as it is given. What does not fit in the
            # sound unit's memory, below the part its built-in program is kept in, is refused.
            def image(waves, recordings: [], whole_notes: false, chip_envelopes: false)
              program = driver(whole_notes: whole_notes, chip_envelopes: chip_envelopes).assembled.bytes
              room = TABLE_AT - DRIVER_AT
              raise ArgumentError, "the sound program is #{program.size} bytes, more than #{room}" if program.size > room

              table = Samples.image(TABLE_AT, waves, recordings)
              if TABLE_AT + table.size > MEMORY_END
                raise LoweringError, "This game's sounds take #{table.size} bytes of the Super Nintendo's sound memory. " \
                                     "There is room for #{MEMORY_END - TABLE_AT} bytes. A recording that holds from a " \
                                     "point keeps its held part up to 16 times over. To fix this, use shorter " \
                                     "recordings, record them at a lower rate, or make each held part a multiple of " \
                                     "16 samples long."
              end
              program + Array.new(room - program.size, 0) + table
            end

            # A NOTE TOLD WHOLE. The two chips talk a byte at a time, and a note is nine registers, so
            # a chord of seven is sixty-three turns of the mailbox the game has to wait for, and in a
            # game with no time to spare they fall behind what the music is doing. In a game with sound
            # effects, which have to answer a press, the sound unit's program does that work itself,
            # as a console game's own sound program does: told the pitch, and then a voice, a
            # recording and a loudness, it writes the nine registers, and the game has sent two
            # turns. A note's loudness, which changes every frame, is one turn and not two.
            #
            # The program the SPC700 runs once it has been sent. +whole_notes+ is one that takes them,
            # and +chip_envelopes+ one that is told each note's envelope bytes first.
            def driver(whole_notes: false, chip_envelopes: false)
              ports = PORTS
              spc = SPC700.new(origin: DRIVER_AT)
              spc.instance_eval do
                mov :a, direct(ports[0]) # the number the console started it with
                mov direct(LAST_ANSWERED), :a
                label "wait"
                mov :a, direct(ports[0])
                cmp :a, direct(LAST_ANSWERED)
                beq "wait"
                mov direct(LAST_ANSWERED), :a
                mov :a, direct(ports[1])
                cmp :a, imm(WRITE_DSP)
                bne "flag_bits"
                mov direct(DSP_ADDRESS), direct(ports[2])
                mov direct(DSP_DATA), direct(ports[3])
                bra "answer"
                label "flag_bits"
                cmp :a, imm(SET_FLAG_BITS)
                bne "key_off_bits"
                mov direct(DSP_ADDRESS), imm(DSPWrites::FLAGS)
                bra "set_bits"
                label "key_off_bits"
                cmp :a, imm(SET_KEY_OFF_BITS)
                bne(whole_notes ? "whole" : "answer")
                mov direct(DSP_ADDRESS), imm(DSPWrites::KEY_OFF)
                label "set_bits"
                mov :a, direct(ports[2]) # which bits change
                eor :a, imm(0xFF)
                and_ :a, direct(DSP_DATA) # the register's other bits, as the DSP holds them
                mov direct(KEPT_BITS), :a
                mov :a, direct(ports[3])
                and_ :a, direct(ports[2]) # the new bits
                or_ :a, direct(KEPT_BITS)
                mov direct(DSP_DATA), :a
                label "answer"
                mov :a, direct(LAST_ANSWERED)
                mov direct(ports[0]), :a
                bra "wait"
              end
              emit_whole_note_commands(spc, chip_envelopes: chip_envelopes) if whole_notes
              spc
            end

            # What the sound unit does with a note told whole, a voice's number being the high half of
            # its command. The registers of a voice sit in order, so each is the one after.
            #
            # With +chip_envelopes+ a note's envelope is the three bytes it was last told to hold
            # (HOLD_ENVELOPE, HOLD_GAIN), written to the voice as they are; without, every note sounds
            # flat out (ADSR off, GAIN fixed at the top) and its loudness is the game's to move.
            def emit_whole_note_commands(spc, chip_envelopes: false)
              ports = PORTS
              dsp = DSPWrites
              unless [dsp::VOLUME_LEFT, dsp::VOLUME_RIGHT, dsp::PITCH_LOW, dsp::PITCH_HIGH, dsp::SOURCE, dsp::ADSR1] == (0..5).to_a && dsp::GAIN == 7
                raise ArgumentError, "a voice's registers are not in the order the sound program writes them"
              end

              spc.instance_eval do
                label "whole"
                cmp :a, imm(HOLD_PITCH)
                bne "whole_voice"
                mov direct(NEXT_PITCH), direct(ports[2])
                mov direct(NEXT_PITCH + 1), direct(ports[3])
                bra "answer"
                label "whole_voice"
                if chip_envelopes
                  cmp :a, imm(HOLD_ENVELOPE)
                  bne "whole_gain"
                  mov direct(NEXT_ENVELOPE), direct(ports[2])
                  mov direct(NEXT_ENVELOPE + 1), direct(ports[3])
                  jmp "answer"
                  label "whole_gain"
                  cmp :a, imm(HOLD_GAIN)
                  bne "whole_voice_told"
                  mov direct(NEXT_GAIN), direct(ports[2])
                  jmp "answer"
                  label "whole_voice_told"
                end
                mov :x, :a
                and_ :a, imm(COMMAND_BITS)
                cmp :a, imm(VOICE_LOUDNESS)
                beq "whole_loudness"
                mov :a, :x
                and_ :a, imm(VOICE_BITS)
                mov direct(DSP_ADDRESS), :a
                mov direct(DSP_DATA), direct(ports[3])
                inc direct(DSP_ADDRESS)
                mov direct(DSP_DATA), direct(ports[3])
                inc direct(DSP_ADDRESS)
                mov direct(DSP_DATA), direct(NEXT_PITCH)
                inc direct(DSP_ADDRESS)
                mov direct(DSP_DATA), direct(NEXT_PITCH + 1)
                inc direct(DSP_ADDRESS)
                mov direct(DSP_DATA), direct(ports[2])
                inc direct(DSP_ADDRESS)
                if chip_envelopes
                  mov direct(DSP_DATA), direct(NEXT_ENVELOPE)
                  inc direct(DSP_ADDRESS)
                  mov direct(DSP_DATA), direct(NEXT_ENVELOPE + 1)
                  inc direct(DSP_ADDRESS)
                  mov direct(DSP_DATA), direct(NEXT_GAIN)
                else
                  mov direct(DSP_DATA), imm(dsp::ADSR_OFF)
                  inc direct(DSP_ADDRESS)
                  inc direct(DSP_ADDRESS)
                  mov direct(DSP_DATA), imm(dsp::FIXED_TOP)
                end
                mov :a, :x
                lsr :a
                lsr :a
                lsr :a
                lsr :a
                mov :x, :a
                mov :a, abs_x("voice_bits")
                mov direct(KEPT_BITS), :a
                eor :a, imm(0xFF)
                mov direct(DSP_ADDRESS), imm(dsp::KEY_OFF)
                and_ :a, direct(DSP_DATA)
                mov direct(DSP_DATA), :a
                mov direct(DSP_ADDRESS), imm(dsp::KEY_ON)
                mov direct(DSP_DATA), direct(KEPT_BITS)
                jmp "answer"
                label "whole_loudness"
                mov :a, :x
                and_ :a, imm(VOICE_BITS)
                mov direct(DSP_ADDRESS), :a
                mov direct(DSP_DATA), direct(ports[3])
                inc direct(DSP_ADDRESS)
                mov direct(DSP_DATA), direct(ports[3])
                jmp "answer"
                label "voice_bits"
                data_bytes((0...8).map { |voice| 1 << voice })
              end
            end

            # What is sent across, in the cartridge, for rt_sound_start to send.
            def sections(waves, recordings: [], whole_notes: false, chip_envelopes: false)
              asm = W65816.new("sound driver")
              asm.label("sound driver")
              asm.data_bytes(image(waves, recordings: recordings, whole_notes: whole_notes, chip_envelopes: chip_envelopes))
              [asm.section]
            end

            # +songs+ for a game with songs, whose player (Music) runs where each wait ends, and
            # +samples+ for one that plays recordings (Recordings), whose count of each moves on there.
            def emit(asm, memory, waves, recordings: [], songs: false, samples: false)
              emit_start(asm, memory, image(waves, recordings: recordings).size)
              emit_write(asm, memory, samples)
              emit_log(asm, memory)
              emit_frame(asm, memory, songs, samples)
            end

            # rt_sound_frame, where a pass's wait ends: for every frame the pass took, the recordings'
            # count moved on and then the music played (Reference#advance_frame's order: the mix, then
            # the player); and, kept for the pass, which recordings sound then (Recordings) and how many
            # entries the log holds, with the pass's number written last (LOGGED_BY_PASS).
            def emit_frame(asm, memory, songs, samples)
              asm.label("rt_sound_frame")
              if songs || samples
                asm.lda(asm.abs(memory[Frame::FRAMES_TAKEN]))
                asm.sta(asm.abs(memory[TICKS_LEFT]))
                asm.label("rt_sound_frame_tick")
                asm.jsr(asm.abs("rt_recordings_frame")) if samples
                asm.jsr(asm.abs("rt_music_frame")) if songs
                asm.jsr(asm.abs("rt_recordings_shapes")) if samples # every note's shape, after the music
                asm.dec(asm.abs(memory[TICKS_LEFT]))
                asm.bne("rt_sound_frame_tick")
              end
              asm.jsr(asm.abs("rt_recordings_kept_for_pass")) if samples
              emit_ahead_sent_at_frame(asm, memory) if memory.reserved?(AHEAD)
              asm.lda(asm.abs(memory[Frame::PASSES]))
              asm.and_a(Frame::STEPS_KEPT - 1)
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.abs(memory[LOGGED]))
              asm.sta(memory.indexed(asm, LOGGED_BY_PASS, 2))
              asm.lda(asm.abs(memory[Frame::PASSES]))
              asm.sta(memory.indexed(asm, LOGGED_BY_PASS))
              asm.rtl
            end

            # rt_sound_log: entry number R0 (a word) into the ring, and one more counted.
            def emit_log(asm, memory)
              asm.label("rt_sound_log")
              asm.lda(asm.abs(memory[LOGGED]))
              asm.and_a(LOG_LENGTH - 1)
              asm.asl
              asm.tax
              asm.lda(asm.direct(R0))
              asm.sta(memory.indexed(asm, LOG))
              asm.inc(asm.abs(memory[LOGGED]))
              asm.rtl
            end

            # rt_sound_start: the program sent, +length+ bytes a byte at a time, and started; then the
            # DSP told where the sample table is, with every voice quiet (DSPWrites.at_power_on).
            def emit_start(asm, memory, length)
              h = Console::SNESHardware
              kick = ((length + 2) & 0xFF) | 1 # past the last byte's number, and never nought
              asm.label("rt_sound_start")
              asm.php
              asm.sei
              asm.label("rt_sound_await_ready")
              asm.lda(asm.abs(h::APUIO0))
              asm.cmp(READY)
              asm.bne("rt_sound_await_ready")
              emit_command(asm, command: 1, kick: FIRST_KICK, echo: "rt_sound_kicked")
              asm.ldx(0)
              asm.sep(0x20)
              asm.label("rt_sound_next_byte")
              asm.lda(asm.long_x("sound driver"))
              asm.sta(asm.abs(h::APUIO1))
              asm.txa
              asm.sta(asm.abs(h::APUIO0))
              emit_await_echo(asm, "rt_sound_byte_taken")
              asm.inx
              asm.cpx(length)
              asm.bne("rt_sound_next_byte")
              asm.rep(0x20)
              emit_command(asm, command: 0, kick: kick, echo: "rt_sound_started")
              asm.lda(kick)
              asm.sta(asm.abs(memory[SENT]))
              asm.lda(1)
              asm.sta(asm.abs(memory[LIVE]))
              write = memory.reserved?(QUEUE) ? "rt_sound_write_at_once" : "rt_sound_write"
              DSPWrites.at_power_on(TABLE_AT >> 8).each do |register, value|
                asm.lda(register)
                asm.sta(asm.direct(R0))
                asm.lda(value)
                asm.sta(asm.direct(R1))
                asm.jsl(asm.long(write))
              end
              asm.plp
              asm.rtl
            end

            # One of the built-in program's commands, with A 16 bits wide before and after: where
            # (always DRIVER_AT, which is where the bytes go and then where the program starts) in
            # mailboxes 2 and 3, +command+ in mailbox 1 (nought starts the program), and +kick+ in
            # mailbox 0, waited for until it comes back.
            def emit_command(asm, command:, kick:, echo:)
              h = Console::SNESHardware
              asm.lda(DRIVER_AT)
              asm.sta(asm.abs(h::APUIO2))
              asm.sep(0x20)
              if command.zero?
                asm.stz(asm.abs(h::APUIO1))
              else
                asm.lda(command)
                asm.sta(asm.abs(h::APUIO1))
              end
              asm.lda(kick)
              asm.sta(asm.abs(h::APUIO0))
              emit_await_echo(asm, echo)
              asm.rep(0x20)
            end

            # A wait, at +label+, until mailbox 0 reads back what A (8 bits) holds.
            def emit_await_echo(asm, label)
              asm.label(label)
              asm.cmp(asm.abs(Console::SNESHardware::APUIO0))
              asm.bne(label)
            end

            # rt_sound_write: DSP register R0 = R1, sent once the write before it has been answered,
            # or dropped and counted when it is not answered in time, or queued in a game with music
            # (rt_sound_write_at_once there is the same with no queue). Nothing at all before the
            # program has been sent.
            #
            # rt_sound_flag_bits: FLG's bits R0 set to R1's, the rest as they are, sent the same way;
            # rt_sound_key_off_bits the same for KOFF's. rt_sound_command: command A, with its two
            # numbers in R0 and R1.
            def emit_write(asm, memory, samples)
              asm.label("rt_sound_key_off_bits")
              asm.lda(SET_KEY_OFF_BITS)
              asm.bra("rt_sound_command")
              asm.label("rt_sound_flag_bits")
              asm.lda(SET_FLAG_BITS)
              asm.bra("rt_sound_command")
              asm.label("rt_sound_write")
              asm.lda(WRITE_DSP)
              asm.label("rt_sound_command") # the command in A, its two numbers in R0 and R1
              asm.sta(asm.direct(R2))
              asm.lda(asm.abs(memory[LIVE]))
              if memory.reserved?(AHEAD)
                asm.branch_long(:beq, "rt_sound_write_done")
                emit_write_ahead(asm, memory)
              else
                asm.beq("rt_sound_write_done")
              end
              memory.reserved?(QUEUE) ? emit_queued_write(asm, memory) : emit_write_at_once(asm, memory)
              asm.label("rt_sound_write_done")
              asm.rtl
              return unless memory.reserved?(QUEUE)

              asm.label("rt_sound_write_at_once")
              asm.lda(WRITE_DSP)
              asm.sta(asm.direct(R2))
              emit_write_at_once(asm, memory)
              asm.rtl
              emit_queue_room_made(asm, memory, samples)
              emit_send_queued(asm, memory, samples)
              emit_forget_place(asm, memory) if memory.reserved?(AHEAD) && samples
            end

            # A SOUND EFFECT GOES AHEAD. An effect answers a press, and a song's chord and every
            # note's loudness can fill the queue for frames in a game with little time to spare to
            # send it. So what is asked for while an effect plays (ASKING_AHEAD) waits in a short line
            # of its own, and #emit_move_ahead puts its oldest at the very front of the queue. The
            # two lines reach different voices, once rt_sound_forget_place has cleared the queue of
            # what it held for a voice an effect has taken.
            #
            # A game with no time to spare has no wait to send it in either, so while anything of an
            # effect's is waiting, a frame spends up to AHEAD_TRIES looks at the mailbox on it, whether
            # the game has time or not, and stops as soon as it has all gone. That is what an effect's
            # note costs a frame, and a frame with nothing of an effect's waiting spends a compare.
            def emit_ahead_sent_at_frame(asm, memory)
              asm.ldy(AHEAD_TRIES)
              asm.label("rt_sound_ahead_try")
              asm.lda(asm.abs(memory[FRONT_LEFT]))
              asm.bne("rt_sound_ahead_waiting")
              asm.lda(asm.abs(memory[AHEAD_HEAD]))
              asm.cmp(asm.abs(memory[AHEAD_TAIL]))
              asm.beq("rt_sound_ahead_sent")
              asm.label("rt_sound_ahead_waiting")
              asm.jsl(asm.long("rt_sound_send_queued"))
              asm.dey
              asm.bne("rt_sound_ahead_try")
              asm.label("rt_sound_ahead_sent")
            end

            # The command in R2, into that line, unless it is full or nothing is asking.
            def emit_write_ahead(asm, memory)
              asm.lda(asm.abs(memory[ASKING_AHEAD]))
              asm.beq("rt_sound_write_in_line")
              asm.ldx(asm.abs(memory[AHEAD_TAIL]))
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.and_a(AHEAD_MASK)
              asm.cmp(asm.abs(memory[AHEAD_HEAD]))
              asm.beq("rt_sound_write_in_line")
              asm.sta(asm.abs(memory[AHEAD_TAIL]))
              asm.lda(asm.direct(R2))
              asm.sta(memory.indexed(asm, AHEAD,ENTRY_COMMAND))
              asm.lda(asm.direct(R0))
              asm.sta(memory.indexed(asm, AHEAD,ENTRY_REGISTER))
              asm.lda(asm.direct(R1))
              asm.sta(memory.indexed(asm, AHEAD,ENTRY_VALUE))
              asm.brl("rt_sound_write_done")
              asm.label("rt_sound_write_in_line")
            end

            # The oldest of the line ahead moved to the very front of the queue, once what is at the
            # front has all gone (FRONT_LEFT): a note's writes are not to be split, or the rest of one
            # would land on another's voice over it.
            def emit_move_ahead(asm, memory)
              asm.lda(asm.abs(memory[FRONT_LEFT]))
              asm.bne("rt_sound_move_ahead_done")
              asm.ldx(asm.abs(memory[AHEAD_HEAD]))
              asm.cpx(asm.abs(memory[AHEAD_TAIL]))
              asm.beq("rt_sound_move_ahead_done")
              [ENTRY_COMMAND, ENTRY_REGISTER, ENTRY_VALUE].each do |field|
                asm.lda(memory.indexed(asm, AHEAD,field))
                asm.pha
              end
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.and_a(AHEAD_MASK)
              asm.sta(asm.abs(memory[AHEAD_HEAD]))
              asm.lda(asm.abs(memory[QUEUE_HEAD]))
              asm.sec
              asm.sbc(ENTRY_BYTES)
              asm.and_a(QUEUE_MASK)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              asm.tax
              [ENTRY_VALUE, ENTRY_REGISTER, ENTRY_COMMAND].each do |field|
                asm.pla
                asm.sta(memory.indexed(asm, QUEUE,field))
              end
              asm.lda(1)
              asm.sta(asm.abs(memory[FRONT_LEFT]))
              asm.label("rt_sound_move_ahead_done")
            end

            # One thing gone from the front of the queue.
            def emit_front_gone(asm, memory)
              return unless memory.reserved?(AHEAD)

              asm.lda(asm.abs(memory[FRONT_LEFT]))
              asm.beq(label = "rt_sound_front_counted_#{asm.here}")
              asm.dec(asm.abs(memory[FRONT_LEFT]))
              asm.label(label)
            end

            # rt_sound_forget_place (JSL): anything the queue still has to tell the voice of the place
            # Y holds forgotten, since an effect has taken that place: a song's note arriving after
            # the effect's would strike over it, and a song's key-off, which A's bit of the voice is
            # taken out of, would cut it short. A is nought for a place with no voice. X is the
            # routine's, and Y stays.
            def emit_forget_place(asm, memory)
              asm.label("rt_sound_forget_place")
              asm.eor(0xFFFF)
              asm.sta(asm.abs(memory[FORGET_KEEPS]))
              asm.ldx(asm.abs(memory[QUEUE_HEAD]))
              asm.label("rt_sound_forget_next")
              asm.cpx(asm.abs(memory[QUEUE_TAIL]))
              asm.beq("rt_sound_forget_done")
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_COMMAND))
              asm.cmp(SET_KEY_OFF_BITS)
              asm.bne("rt_sound_forget_not_key_off")
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
              asm.and_a(asm.abs(memory[FORGET_KEEPS]))
              asm.sta(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
              asm.bra("rt_sound_forget_past")
              asm.label("rt_sound_forget_not_key_off")
              asm.cmp(START_NOTE)
              asm.bcc("rt_sound_forget_past")
              asm.cmp(FORGOTTEN) # past the three that name a place, and a command told whole
              asm.bcs("rt_sound_forget_past")
              asm.tya
              asm.cmp(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
              asm.bne("rt_sound_forget_past")
              asm.lda(FORGOTTEN)
              asm.sta(memory.indexed(asm, QUEUE,ENTRY_COMMAND))
              asm.label("rt_sound_forget_past")
              asm.txa
              emit_advance_queue_place(asm)
              asm.tax
              asm.bra("rt_sound_forget_next")
              asm.label("rt_sound_forget_done")
              asm.rtl
            end

            # A game with a sound queue sends from it while it waits; any other sleeps until an
            # interrupt comes.
            def emit_idle_step(asm, memory)
              if memory.reserved?(QUEUE)
                asm.jsl(asm.long("rt_sound_send_queued"))
              else
                asm.wai
              end
            end

            # The command sent as soon as the one before it has been answered, or dropped and counted.
            def emit_write_at_once(asm, memory)
              h = Console::SNESHardware
              asm.ldx(PATIENCE)
              asm.sep(0x20)
              asm.label("rt_sound_write_wait")
              asm.lda(asm.abs(h::APUIO0))
              asm.cmp(asm.abs(memory[SENT]))
              asm.beq("rt_sound_write_send")
              asm.dex
              asm.bne("rt_sound_write_wait")
              asm.rep(0x20)
              asm.inc(asm.abs(memory[DROPPED]))
              asm.rtl
              asm.label("rt_sound_write_send")
              # Reached by the branch above with A still 8 bits wide, whatever the lines just before
              # the label left the assembler counting.
              asm.widths(a16: false, xy16: true)
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs(h::APUIO2))
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs(h::APUIO3))
              asm.lda(asm.direct(R2))
              asm.sta(asm.abs(h::APUIO1))
              asm.lda(asm.abs(memory[SENT]))
              asm.inc
              asm.sta(asm.abs(memory[SENT]))
              asm.sta(asm.abs(h::APUIO0))
              asm.rep(0x20)
            end

            # The command at the end of the queue, for #emit_send_queued's routine to send.
            def emit_queued_write(asm, memory)
              asm.lda(asm.abs(memory[QUEUE_TAIL]))
              emit_advance_queue_place(asm)
              asm.pha
              emit_queue_room_left(asm, memory, 1)
              asm.bcs("rt_sound_queue_has_room")
              asm.jsr(asm.abs("rt_sound_queue_make_room"))
              asm.label("rt_sound_queue_has_room")
              asm.ldx(asm.abs(memory[QUEUE_TAIL]))
              asm.pla
              asm.sta(asm.abs(memory[QUEUE_TAIL]))
              asm.lda(asm.direct(R2))
              asm.sta(memory.indexed(asm, QUEUE,ENTRY_COMMAND))
              asm.lda(asm.direct(R0))
              asm.sta(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
              asm.lda(asm.direct(R1))
              asm.sta(memory.indexed(asm, QUEUE,ENTRY_VALUE))
            end

            # A = the place in the queue after the place A holds, round from its end to its start.
            def emit_advance_queue_place(asm)
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.and_a(QUEUE_MASK)
            end

            # Carry set when the queue has QUEUE_ROOM left past the place at stack offset +past_end+.
            def emit_queue_room_left(asm, memory, past_end)
              asm.lda(asm.abs(memory[QUEUE_HEAD]))
              asm.sec
              asm.sbc(asm.stack(past_end))
              asm.and_a(QUEUE_MASK)
              asm.cmp(memory.reserved?(AHEAD) ? queue_room(memory) + ENTRY_BYTES : queue_room(memory)) # an effect's note goes in front of it
            end

            # QUEUE_ROOM, and an entry more where a note's start writes its envelope's second byte too.
            def queue_room(memory)
              memory.reserved?(Recordings::CHIP_ENVELOPES) ? QUEUE_ROOM + (CHIP_ENVELOPE_WRITES * ENTRY_BYTES) : QUEUE_ROOM
            end

            # rt_sound_queue_make_room, with the queue nearly full and the place past its end on the
            # stack: the oldest entries sent, however long the sound unit takes, up to PATIENCE tries,
            # and then dropped and counted until there is room. A game that never waits for the
            # screen goes on this way, a command at a time, once its queue has filled.
            def emit_queue_room_made(asm, memory, samples)
              asm.label("rt_sound_queue_make_room")
              asm.phy
              asm.ldy(PATIENCE)
              asm.label("rt_sound_queue_make_room_try")
              asm.jsl(asm.long("rt_sound_send_queued"))
              emit_queue_room_left(asm, memory, 5) # the Y kept, then this routine's way back
              asm.bcs("rt_sound_queue_room_made")
              asm.dey
              asm.bne("rt_sound_queue_make_room_try")
              asm.label("rt_sound_queue_drop")
              asm.inc(asm.abs(memory[DROPPED]))
              if samples # a loudness dropped is no longer waiting (Recordings#emit_shapes), nor one a note's start stood for
                asm.ldx(asm.abs(memory[QUEUE_HEAD]))
                asm.lda(memory.indexed(asm, QUEUE,ENTRY_COMMAND))
                asm.cmp(START_NOTE)
                asm.beq("rt_sound_queue_drop_loudness")
                asm.cmp(NOTE_VOLUME)
                asm.bne("rt_sound_queue_drop_counted")
                asm.label("rt_sound_queue_drop_loudness")
                asm.lda(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
                asm.tax
                asm.lda(0)
                asm.sta(asm.abs_x(memory[Recordings::PLACES_STATE], Recordings::VOLUME_WAITING))
                asm.label("rt_sound_queue_drop_counted")
              end
              asm.lda(asm.abs(memory[QUEUE_HEAD]))
              emit_advance_queue_place(asm)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              emit_front_gone(asm, memory)
              emit_queue_room_left(asm, memory, 5)
              asm.bcc("rt_sound_queue_drop")
              asm.label("rt_sound_queue_room_made")
              asm.ply
              asm.rts
            end

            # rt_sound_send_queued (JSL): the oldest entry sent if the one before it has been answered,
            # with no waiting at all, or, for one that tells a voice about a note, made into its
            # writes. Y stays as it was.
            def emit_send_queued(asm, memory, samples)
              h = Console::SNESHardware
              asm.label("rt_sound_send_queued")
              if memory.reserved?(AHEAD)
                # The first thing asked, and the quickest: this is called again and again while the
                # game waits, and how soon it sees an answer is how many writes a frame can send.
                asm.sep(0x20)
                asm.lda(asm.abs(h::APUIO0))
                asm.cmp(asm.abs(memory[SENT]))
                asm.rep(0x20)
                asm.branch_long(:bne, "rt_sound_send_queued_done")
                emit_move_ahead(asm, memory)
              end
              asm.ldx(asm.abs(memory[QUEUE_HEAD]))
              asm.cpx(asm.abs(memory[QUEUE_TAIL]))
              asm.beq("rt_sound_send_queued_done")
              if samples
                asm.lda(memory.indexed(asm, QUEUE,ENTRY_COMMAND))
                if memory.reserved?(AHEAD)
                  asm.cmp(FORGOTTEN)
                  asm.bne("rt_sound_send_queued_not_forgotten")
                  asm.txa
                  emit_advance_queue_place(asm)
                  asm.sta(asm.abs(memory[QUEUE_HEAD]))
                  emit_front_gone(asm, memory)
                  asm.rtl
                  asm.label("rt_sound_send_queued_not_forgotten")
                end
                voice_told(memory).each_key do |command|
                  asm.cmp(command)
                  asm.bne("rt_sound_send_queued_not_#{command}")
                  asm.jmp(asm.abs("rt_sound_entry_into_writes_#{command}"))
                  asm.label("rt_sound_send_queued_not_#{command}")
                end
              end
              asm.sep(0x20)
              asm.lda(asm.abs(h::APUIO0))
              asm.cmp(asm.abs(memory[SENT]))
              asm.bne("rt_sound_send_queued_unanswered")
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
              asm.sta(asm.abs(h::APUIO2))
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_VALUE))
              asm.sta(asm.abs(h::APUIO3))
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_COMMAND))
              asm.sta(asm.abs(h::APUIO1))
              asm.lda(asm.abs(memory[SENT]))
              asm.inc
              asm.sta(asm.abs(memory[SENT]))
              asm.sta(asm.abs(h::APUIO0))
              asm.rep(0x20)
              asm.txa
              emit_advance_queue_place(asm)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              emit_front_gone(asm, memory)
              asm.rtl
              asm.label("rt_sound_send_queued_unanswered")
              asm.widths(a16: false, xy16: true) # reached by the branch above, with A still 8 bits wide
              asm.rep(0x20)
              asm.label("rt_sound_send_queued_done")
              asm.rtl
              voice_told(memory).each { |command, (writes, routine)| emit_entry_into_writes(asm, memory, command, writes, routine) } if samples
            end

            def voice_told(memory)
              told = memory.reserved?(AHEAD) ? VOICE_TOLD_WHOLE : VOICE_TOLD
              if memory.reserved?(Recordings::CHIP_ENVELOPES)
                writes, routine = told.fetch(START_NOTE)
                more = memory.reserved?(AHEAD) ? CHIP_ENVELOPE_COMMANDS : CHIP_ENVELOPE_WRITES
                told = told.merge(START_NOTE => [writes + more, routine])
              end
              memory.reserved?(Recordings::GLIDES) ? told.merge(VOICE_TOLD_OF_GLIDES) : told
            end

            # THE ENTRY AT THE FRONT OF THE QUEUE BECOMES ITS WRITES, in the place it stood and before
            # anything queued after it: the front of the queue moves back by as many entries as there
            # are writes, its end is put there for as long as they take to queue, and then goes back
            # to where it was. QUEUE_ROOM is what keeps those entries free. What the routine uses is
            # the game's, if the game is in the middle of queueing a write, so it is kept.
            def emit_entry_into_writes(asm, memory, command, writes, routine)
              kept = [Recordings::PLACE, Recordings::ROW, Recordings::REGISTERS, Recordings::BEST]
              kept << ASKING_AHEAD if memory.reserved?(AHEAD) # these writes take the entry's place in line
              scratch = [R0, R1, R2]
              asm.label("rt_sound_entry_into_writes_#{command}")
              asm.phy
              scratch.each do |register|
                asm.lda(asm.direct(register))
                asm.pha
              end
              kept.each do |name|
                asm.lda(asm.abs(memory[name]))
                asm.pha
              end
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_REGISTER))
              asm.sta(asm.abs(memory[Recordings::PLACE]))
              asm.lda(memory.indexed(asm, QUEUE,ENTRY_VALUE))
              asm.sta(asm.abs(memory[Recordings::ROW]))
              asm.lda(asm.abs(memory[QUEUE_TAIL]))
              asm.sta(asm.abs(memory[QUEUE_TAIL_KEPT]))
              asm.txa
              asm.sec
              asm.sbc((writes - 1) * ENTRY_BYTES)
              asm.and_a(QUEUE_MASK)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              asm.sta(asm.abs(memory[QUEUE_TAIL]))
              if memory.reserved?(AHEAD) # the writes are the front now, however it came to be there
                asm.stz(asm.abs(memory[ASKING_AHEAD]))
                asm.lda(writes)
                asm.sta(asm.abs(memory[FRONT_LEFT]))
              end
              asm.jsl(asm.long(routine))
              asm.lda(asm.abs(memory[QUEUE_TAIL_KEPT]))
              asm.sta(asm.abs(memory[QUEUE_TAIL]))
              kept.reverse_each do |name|
                asm.pla
                asm.sta(asm.abs(memory[name]))
              end
              scratch.reverse_each do |register|
                asm.pla
                asm.sta(asm.direct(register))
              end
              asm.ply
              asm.rtl
            end
          end
        end
      end
    end
  end
end
