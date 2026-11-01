# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SOUND UNIT, AND HOW THE CONSOLE TALKS TO IT. A Super Nintendo's sound is made by a
          # small computer of its own: an SPC700 processor with 64K of memory, and the S-DSP, which
          # mixes eight voices, each playing a recorded sound at the pitch and volume its registers
          # say. The console's processor cannot see any of that memory. All it has are four one-byte
          # mailboxes ($2140-$2143 on its side, $F4-$F7 on the sound unit's): a byte the console
          # writes into one is read by the SPC700, and a byte the SPC700 writes is read by the console.
          #
          # SENDING ITS PROGRAM. At power-on the SPC700 runs a little program built into the chip,
          # which zeroes its direct page, puts $AA and $BB in the first two mailboxes to say it is
          # ready, and then takes a program a byte at a time: the console writes the byte into
          # mailbox 1 and its number (the low eight bits of where it is) into mailbox 0, and waits
          # until the SPC700 copies that number back to say it has the byte. Each command is started
          # by a "kick", a number in mailbox 0 that is not the next byte's: $CC for the first, and
          # after the bytes one past the last byte's number. A last command with nought in mailbox 1
          # says where to start the program, and the built-in program jumps there. rt_sound_start
          # does all that, once, at power-on, with interrupts held off and the screen's interrupt
          # still off: the last byte's answer lasts only a few of the SPC700's cycles, and an
          # interrupt could miss it. Its waits have no limit — at power-on the built-in program is
          # always there to answer. (fullsnes, "SNES APU Main CPU Communication Port", which has the
          # built-in program.)
          #
          # THE PROGRAM IT RUNS (Sound.driver) does one thing: it waits for mailbox 0 to change, and
          # then does the command the other three hold — today only "write this value into this
          # DSP register" — and copies mailbox 0's new number back to say it is done. Everything a
          # sound is (which recording, its pitch, its volume, its envelope, key on and key off) is
          # DSP registers, so the console plays every sound by writing them through it.
          #
          # NEVER LOSING A FRAME TO SOUND. rt_sound_write sends one register write and does not wait
          # for it to be done: it waits instead, before sending, for the write before it to have been
          # answered, which takes the SPC700 a few dozen of its cycles. That wait is bounded
          # (PATIENCE tries); a sound unit that has not answered by then has its write dropped and
          # counted in DROPPED, and the game goes on.
          #
          # A NOTE IS ABOUT TEN WRITES, and each still waits for the one before, so eight parts
          # starting a note on one frame take nearly half of the game's time. So a game with music
          # queues its writes (QUEUE) and the queue is sent while the game waits for the screen, one
          # write each time the sound unit has answered (Frame's rt_sleep_until_vblank). A recorded
          # note is one entry until it reaches the front. Queueing takes a few instructions, and the
          # waiting comes out of time the game was not using. A note then starts later in the frame
          # than the wait it follows, never more than a frame late while the game has time to
          # spare, and always in the order it was asked.
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
            # mailbox 3 is its value), and set some of FLG's or KOFF's bits (mailbox 2 says which,
            # mailbox 3 what they become), leaving the rest as the DSP holds them (DSPWrites, "FLG is
            # shared" and "KOFF is shared").
            WRITE_DSP = 1
            SET_FLAG_BITS = 2
            SET_KEY_OFF_BITS = 3

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

            # How many times rt_sound_write reads mailbox 0 for the answer to the write before.
            PATIENCE = 256

            LIVE = "rt sound live" # 1 once the program was sent and started
            SENT = "rt sound sent" # the number of the last command sent, in mailbox 0
            DROPPED = "rt sound dropped" # writes dropped because the sound unit had not answered

            # THE WRITES WAITING TO GO, in a game with music: a ring of entries, the oldest at
            # QUEUE_HEAD and the next free at QUEUE_TAIL, both as offsets into it, so the two are equal
            # when it is empty. One entry is left free so that full and empty differ. A power of two.
            QUEUE = "rt sound queue"
            QUEUE_HEAD = "rt sound queue head"
            QUEUE_TAIL = "rt sound queue tail"
            QUEUE_ENTRIES = 128
            ENTRY_BYTES = 8
            QUEUE_MASK = (QUEUE_ENTRIES * ENTRY_BYTES) - 1
            ENTRY_COMMAND = 0
            ENTRY_REGISTER = 2
            ENTRY_VALUE = 4
            # An entry that is a whole note, for a voice: its register is the place's offset and its
            # value the recording's row, and it becomes NOTE_START_WRITES entries where it stood.
            START_NOTE = 4
            NOTE_START_WRITES = 9
            # The room a write leaves in the queue, so a note at the front can always become its writes.
            QUEUE_ROOM = (NOTE_START_WRITES + 1) * ENTRY_BYTES
            QUEUE_TAIL_KEPT = "rt sound queue tail kept"

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

            def reserve(memory, queued: false)
              if queued
                memory.reserve(QUEUE, QUEUE_ENTRIES * ENTRY_BYTES)
                memory.reserve(QUEUE_HEAD, 2)
                memory.reserve(QUEUE_TAIL, 2)
                memory.reserve(QUEUE_TAIL_KEPT, 2)
              end
              memory.reserve(LIVE, 2)
              memory.reserve(SENT, 2)
              memory.reserve(DROPPED, 2)
              memory.reserve(LOGGED, 2)
              memory.reserve(LOG, LOG_LENGTH * 2)
              memory.reserve(LOGGED_BY_PASS, Frame::STEPS_KEPT * LOGGED_SLOT_BYTES)
              memory.reserve(TICKS_LEFT, 2)
            end

            # Everything sent across at power-on, from DRIVER_AT: the program, then from TABLE_AT the
            # sample table and the recordings, the game's +waves+ and then its own +recordings+
            # (Samples.recording's pairs) last (Samples.image). #sections and #emit are each handed the
            # same lists, since rt_sound_start sends as many bytes as it says. What does not fit in the
            # sound unit's memory, below the part its built-in program is kept in, is refused.
            def image(waves, recordings: [])
              program = driver.assembled.bytes
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

            # The program the SPC700 runs once it has been sent.
            def driver
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
                bne "answer"
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
              spc
            end

            # What is sent across, in the cartridge, for rt_sound_start to send.
            def sections(waves, recordings: [])
              asm = W65816.new("sound driver")
              asm.label("sound driver")
              asm.data_bytes(image(waves, recordings: recordings))
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
              asm.lda(asm.abs(memory[Frame::PASSES]))
              asm.and_a(Frame::STEPS_KEPT - 1)
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.abs(memory[LOGGED]))
              asm.sta(asm.abs_x(memory[LOGGED_BY_PASS], 2))
              asm.lda(asm.abs(memory[Frame::PASSES]))
              asm.sta(asm.abs_x(memory[LOGGED_BY_PASS]))
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
              asm.sta(asm.abs_x(memory[LOG]))
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
              DSPWrites.at_power_on(TABLE_AT >> 8).each do |register, value|
                asm.lda(register)
                asm.sta(asm.direct(R0))
                asm.lda(value)
                asm.sta(asm.direct(R1))
                asm.jsl(asm.long("rt_sound_write"))
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
            # or dropped and counted when it is not answered in time. Nothing at all before the
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
              asm.beq("rt_sound_write_done")
              memory.reserved?(QUEUE) ? emit_queued_write(asm, memory) : emit_write_at_once(asm, memory)
              asm.label("rt_sound_write_done")
              asm.rtl
              emit_queue_sending(asm, memory, samples) if memory.reserved?(QUEUE)
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

            # The command at the end of the queue, for #emit_queue_sending's rt_sound_send_queued to send.
            def emit_queued_write(asm, memory)
              asm.lda(asm.abs(memory[QUEUE_TAIL]))
              emit_next_entry(asm)
              asm.pha
              emit_queue_room_left(asm, memory, 1)
              asm.bcs("rt_sound_queue_has_room")
              asm.jsr(asm.abs("rt_sound_queue_make_room"))
              asm.label("rt_sound_queue_has_room")
              asm.ldx(asm.abs(memory[QUEUE_TAIL]))
              asm.pla
              asm.sta(asm.abs(memory[QUEUE_TAIL]))
              asm.lda(asm.direct(R2))
              asm.sta(asm.abs_x(memory[QUEUE], ENTRY_COMMAND))
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs_x(memory[QUEUE], ENTRY_REGISTER))
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs_x(memory[QUEUE], ENTRY_VALUE))
            end

            # A = the place in the queue after the place A holds, round from its end to its start.
            def emit_next_entry(asm)
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
              asm.cmp(QUEUE_ROOM)
            end

            # rt_sound_send_queued (JSL): the oldest entry sent if the one before it has been answered,
            # with no waiting at all, or, for a whole note, made into its writes. Y stays as it was.
            #
            # rt_sound_queue_make_room, with the queue nearly full and the place past its end on the
            # stack: the oldest sent, however long the sound unit takes, up to PATIENCE tries, or
            # dropped and counted. A game that never waits for the screen goes on this way, a command
            # at a time, as it would have with no queue.
            def emit_queue_sending(asm, memory, samples)
              h = Console::SNESHardware
              asm.label("rt_sound_queue_make_room")
              asm.phy
              asm.ldy(PATIENCE)
              asm.label("rt_sound_queue_make_room_try")
              asm.jsl(asm.long("rt_sound_send_queued"))
              emit_queue_room_left(asm, memory, 5) # the Y kept, then this routine's way back
              asm.bcs("rt_sound_queue_room_made")
              asm.dey
              asm.bne("rt_sound_queue_make_room_try")
              asm.inc(asm.abs(memory[DROPPED]))
              asm.lda(asm.abs(memory[QUEUE_HEAD]))
              emit_next_entry(asm)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              asm.label("rt_sound_queue_room_made")
              asm.ply
              asm.rts

              asm.label("rt_sound_send_queued")
              asm.ldx(asm.abs(memory[QUEUE_HEAD]))
              asm.cpx(asm.abs(memory[QUEUE_TAIL]))
              asm.beq("rt_sound_send_queued_done")
              if samples
                asm.lda(asm.abs_x(memory[QUEUE], ENTRY_COMMAND))
                asm.cmp(START_NOTE)
                asm.bne("rt_sound_send_queued_write")
                asm.jmp(asm.abs("rt_sound_note_into_writes"))
                asm.label("rt_sound_send_queued_write")
              end
              asm.sep(0x20)
              asm.lda(asm.abs(h::APUIO0))
              asm.cmp(asm.abs(memory[SENT]))
              asm.bne("rt_sound_send_queued_unanswered")
              asm.lda(asm.abs_x(memory[QUEUE], ENTRY_REGISTER))
              asm.sta(asm.abs(h::APUIO2))
              asm.lda(asm.abs_x(memory[QUEUE], ENTRY_VALUE))
              asm.sta(asm.abs(h::APUIO3))
              asm.lda(asm.abs_x(memory[QUEUE], ENTRY_COMMAND))
              asm.sta(asm.abs(h::APUIO1))
              asm.lda(asm.abs(memory[SENT]))
              asm.inc
              asm.sta(asm.abs(memory[SENT]))
              asm.sta(asm.abs(h::APUIO0))
              asm.rep(0x20)
              asm.txa
              emit_next_entry(asm)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              asm.rtl
              asm.label("rt_sound_send_queued_unanswered")
              asm.widths(a16: false, xy16: true) # reached by the branch above, with A still 8 bits wide
              asm.rep(0x20)
              asm.label("rt_sound_send_queued_done")
              asm.rtl
              emit_note_into_writes(asm, memory) if samples
            end

            # THE WHOLE NOTE AT THE FRONT OF THE QUEUE BECOMES ITS WRITES, in the place it stood and
            # before anything queued after it: the front of the queue moves back by as many entries
            # as there are writes, its end is put there for as long as they take to queue, and then
            # goes back to where it was. QUEUE_ROOM is what keeps those entries free. What the routine
            # uses is the game's, if the game is in the middle of queueing a write, so it is kept.
            def emit_note_into_writes(asm, memory)
              kept = [Recordings::PLACE, Recordings::ROW, Recordings::REGISTERS, Recordings::BEST]
              scratch = [R0, R1, R2]
              asm.label("rt_sound_note_into_writes")
              asm.phy
              scratch.each do |register|
                asm.lda(asm.direct(register))
                asm.pha
              end
              kept.each do |name|
                asm.lda(asm.abs(memory[name]))
                asm.pha
              end
              asm.lda(asm.abs_x(memory[QUEUE], ENTRY_REGISTER))
              asm.sta(asm.abs(memory[Recordings::PLACE]))
              asm.lda(asm.abs_x(memory[QUEUE], ENTRY_VALUE))
              asm.sta(asm.abs(memory[Recordings::ROW]))
              asm.lda(asm.abs(memory[QUEUE_TAIL]))
              asm.sta(asm.abs(memory[QUEUE_TAIL_KEPT]))
              asm.txa
              asm.sec
              asm.sbc((NOTE_START_WRITES - 1) * ENTRY_BYTES)
              asm.and_a(QUEUE_MASK)
              asm.sta(asm.abs(memory[QUEUE_HEAD]))
              asm.sta(asm.abs(memory[QUEUE_TAIL]))
              asm.jsl(asm.long("rt_recordings_voice_start"))
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
