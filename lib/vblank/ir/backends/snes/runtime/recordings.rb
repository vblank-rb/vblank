# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE GAME'S OWN RECORDINGS (`play_sample`, `stop_sample`).
          #
          # The Advance's processor adds every recording a game plays into one stream, sixteen of them
          # at most, and the interpreter does the same sums (Reference::Mixer). The S-DSP needs none of
          # that: each recording plays on a voice of its own, read from the sound unit's memory
          # (Samples.recording). Four of its voices are always free, and the other four are the square,
          # wave and noise parts': each one the game never uses plays recordings too
          # (SNES::Music.recording_voices). So the first place plays on voice 4, the fourth on voice 7,
          # the next on the first voice the game left free, and a recording in a place past
          # those is counted and not heard.
          #
          # THE COUNT IS THE INTERPRETER'S. What the game can tell of a recording — the log saying it
          # came round again, its place coming free at its end — follows where it has got to, so each
          # place keeps that as the interpreter's mixer does: how far into the recording, in whole
          # samples and 65536ths, moved on once a frame by the samples a frame reads
          # (Console::SampleClock.on_voices), read back by its loop at its end, or freed.
          #
          # Each play the game writes is a row of the table "recording_plays" (Lowering::Sound): the
          # voice's source number, pitch and volume, the recording's length, how far back it reads at
          # its end (nought for one played once), how far it moves a frame, the number of its entry in
          # the sound log ([:sample, name]) and which recording it is.
          #
          # A SONG'S RECORDED PART plays its notes in the same places (rt_recordings_note), taking one
          # by the interpreter's rule (Reference::Mixer#start_music_note): the part's own, while it
          # still sounds a note; the first free; or the place of the lowest-ranked sound ranked below
          # the song — the game's own first, of those one that plays once before one that loops, and
          # the oldest. With none, the note is not played. A rest gives the part's place back
          # (rt_recordings_note_release), and so does the tune stopping (rt_recordings_release_music).
          module Recordings
            PLACES = Console::SUPER_NINTENDO.recordings_at_once

            # A play's row in the table, in bytes.
            SOURCE = 0
            PITCH = 2
            VOLUME = 4
            LENGTH = 6
            BACK = 10
            ADVANCE = 14
            ADVANCE_FRACTION = 18
            LOGGED = 20
            NAME = 22
            # ...and its shape (Audio::Envelope): its attack and decay, its sustain and release, a byte
            # each, two to a word; and 1 when it has one. In a game with a recording shaped by the
            # sound chip's own envelope bytes (CHIP_ENVELOPES), SHAPED's high byte is which row of
            # "recording_chip_envelopes" the note's voice is told: nought for a note with none.
            SHAPE_AD = 24
            SHAPE_SR = 26
            SHAPED = 28
            SHAPED_BIT = 0x00FF
            CHIP_ENVELOPE_BITS = 0xFF00
            # ...and for a song's note, how its end is found without counting its samples (#frames_left).
            FRAMES_LEFT = 30
            ROW_BYTES = 32

            # A place's state, PLACE_BYTES apart: which recording (its number plus one, nought when the
            # place is free), how far into it (whole samples, two words, and the fraction), and the
            # play's length, read-back, how far a frame and log entry, copied from its row.
            PLACES_STATE = "rt recordings places"
            HELD = 0
            POSITION = 2
            FRACTION = 6
            PLACE_LENGTH = 8
            PLACE_BACK = 12
            PLACE_ADVANCE = 16
            PLACE_ADVANCE_FRACTION = 20
            PLACE_LOGGED = 22
            # ...and whose it is: nought for the game's own, a part's OWNER number for a song's — its
            # place among the song's recorded parts, one up — and for a sound effect's the same in the
            # low byte under the effect's number, one up, in the high (EFFECT_OWNER and over); the
            # rank it holds the place at, the song's or effect's rank's place one up (nought for the
            # game's own, which rank below every song); and for the game's own, its TICKET — LOOPS set
            # for one that loops, and how many the game had started before it — which orders who
            # gives way first.
            OWNER = 24
            RANK = 26
            TICKET = 28
            PLACE_FRAMES_LEFT = 30
            # What FRAMES_LEFT holds besides a count: walk the samples, or the note never ends by itself.
            COUNTS_SAMPLES = 0
            NEVER_ENDS = 0xFFFF
            EFFECT_OWNER = 0x100
            # ...and its SHAPE (Reference::Mixer#step_envelopes): the row's two words of it, its level
            # (out of Audio::Envelope::FULL), which part of the shape it is in (PLAIN for a note with
            # none), and its volume as the row holds it, which the level scales.
            PLACE_AD = 32
            PLACE_SR = 34
            LEVEL = 36
            PHASE = 38
            LOUD = 40
            # ...and in a game with a sound queue, whether a word about its loudness is waiting there
            # (#emit_shapes).
            VOLUME_WAITING = 42
            # ...and its row's SHAPED word, in a game with CHIP_ENVELOPES.
            PLACE_SHAPED = 44
            PLACE_BYTES = 64
            LOOPS = 0x8000
            PLAIN = 0
            CLIMBING = 1
            HOLDING = 2
            FALLING = 3
            DONE = 4 # Fallen to nothing: the place comes free on the frame after
            FULL = Audio::Envelope::FULL
            # A row's LOGGED for a note of a song: nothing is logged as it comes round again.
            NOT_LOGGED = 0xFFFF
            # ...and, for each of the last Frame::STEPS_KEPT passes, by the pass's number less its
            # multiples of STEPS_KEPT, each place's recording as its wait ended: a byte a place; and its
            # level beside, in a table of its own.
            KEPT_BY_PASS = "rt recordings kept by pass"
            LEVELS_BY_PASS = "rt recordings levels by pass"
            # WHAT COULD NOT BE PLAYED (Reference::Mixer#drops): how many plays and notes found every
            # place busy, and the most places songs held at one of those moments.
            DROPS = "rt recordings drops"
            DROPS_MUSIC = "rt recordings drops music"

            # Where the row being played is, the place it takes, that place's voice's first register,
            # and which recording a stop names (or ALL) and its entry in the log.
            ROW = "rt recordings row"
            PLACE = "rt recordings place"
            REGISTERS = "rt recordings registers"
            STOP_NAME = "rt recordings stop name"
            STOP_LOGGED = "rt recordings stop logged"
            # How many of its own sounds the game has started (TICKET), and, while a note finds a place,
            # whose it is, its rank, and the best place found to take and its rank and ticket.
            TICKETS = "rt recordings tickets"
            NOTE_OWNER = "rt recordings note owner"
            NOTE_RANK = "rt recordings note rank"
            BEST = "rt recordings best"
            BEST_RANK = "rt recordings best rank"
            BEST_TICKET = "rt recordings best ticket"
            ALL = 0xFFFF
            # Kept in a game with a note that glides, whose runtime then carries what moves one.
            GLIDES = "rt recordings glides"

            # THE SOUND CHIP'S OWN ENVELOPE. A recording can be given the three bytes the S-DSP shapes
            # a voice by (Audio::SNESEnvelope: ADSR1, ADSR2, GAIN), and its voice is told them as
            # they are, so the chip shapes the note itself, as it did in the game they came from.
            #
            # The place still keeps a level and steps it every frame, by the ordinary envelope
            # nearest those bytes (the row's SHAPE_AD and SHAPE_SR), since that count is what the
            # interpreter keeps and what says when the place comes free. Only what the voice hears
            # differs: its volume registers hold the note's loudness whole, never scaled by the
            # level, and once the note has ended its voice is keyed off, where the chip takes the
            # level down itself.
            #
            # Kept in a game with such a recording, whose runtime then tells every note's voice the
            # three bytes of its row of "recording_chip_envelopes": row nought is ADSR off and GAIN
            # fixed at the top, what a note with none was always told.
            CHIP_ENVELOPES = "rt recordings chip envelopes"
            CHIP_ENVELOPE_BYTES = 4
            NO_CHIP_ENVELOPE = [DSPWrites::ADSR_OFF, 0, DSPWrites::FIXED_TOP, 0].freeze

            # WHERE A NOTE SITS BETWEEN THE SPEAKERS (Audio::Pan). Each voice of the S-DSP has a volume
            # for the left speaker and one for the right, so a recorded note off the middle is heard
            # there exactly: each side's register is the note's loudness times that side's share, out
            # of Audio::Pan::SHARE_FULL, to the nearest whole step, worked out by the console's own
            # multiplier each time the loudness is.
            #
            # Kept in a game with a recorded note off the middle, whose runtime then reads each row's
            # shares from "recording_sides", a word a row (Audio::Pan.shares_word), into the place's
            # PLACE_SIDES. A game with none writes the loudness to both, as it always did.
            SIDES = "rt recordings sides"
            PLACE_SIDES = 46

            module_function

            # A row of "recording_chip_envelopes" for +envelope+ (an Audio::SNESEnvelope).
            def chip_envelope_row(envelope) = [envelope.adsr1, envelope.adsr2, envelope.gain, 0]

            # A play's row of "recording_plays", as words: its voice's +source+, +pitch+ and +volume+;
            # the recording's +length+ and the +back+ it reads at its end (32 bits each); the +advance+
            # a frame, in samples and 65536ths (48 bits, of which the whole samples take 32); the
            # number of its +logged+ entry; the +name+'s number; and its +shape+ (an Audio::Envelope), or
            # nil for a note that sounds flat out from its first sample to its last. +walks+ counts its
            # samples whatever it is, for a note whose pitch can change part way through, so that no
            # count of frames made at the start holds. +chip_envelope+ is its row of
            # "recording_chip_envelopes", nought for a note with none.
            def row(source:, pitch:, volume:, length:, back:, advance:, logged:, name:, shape: nil, walks: false, chip_envelope: 0)
              words = Array.new(ROW_BYTES / 2, 0)
              words[FRAMES_LEFT / 2] = frames_left(length, back, advance) if logged == NOT_LOGGED && !walks
              { SOURCE => source, PITCH => pitch, VOLUME => volume, LENGTH => length & 0xFFFF, LENGTH + 2 => length >> 16,
                BACK => back & 0xFFFF, BACK + 2 => back >> 16, ADVANCE => (advance >> 16) & 0xFFFF,
                ADVANCE + 2 => advance >> 32, ADVANCE_FRACTION => advance & 0xFFFF, LOGGED => logged,
                NAME => name }.each { |at, value| words[at / 2] = value }
              if shape
                words[SHAPE_AD / 2] = shape.attack | (shape.decay << 8)
                words[SHAPE_SR / 2] = shape.sustain | (shape.release << 8)
                words[SHAPED / 2] = 1
              end
              words[SHAPED / 2] |= chip_envelope << 8
              words
            end

            # WALKING A RECORDING FORWARD is some twenty instructions a frame for each note sounding, and
            # all it is for is noticing the end. A note of a song logs nothing as it comes round, so a
            # note that holds has no end to notice, and one played once ends a number of frames after
            # its start that the build can work out: the frames it takes +advance+ a frame, in 65536ths
            # of a sample, to reach +length+. A count too big for a word goes on walking its samples.
            def frames_left(length, back, advance)
              return NEVER_ENDS if back.positive?
              return COUNTS_SAMPLES unless advance.positive?

              frames = [(length << 16).ceildiv(advance), 1].max
              frames < NEVER_ENDS ? frames : COUNTS_SAMPLES
            end

            def reserve(memory, glides: false, chip_envelopes: false, sides: false)
              memory.reserve(GLIDES, 2) if glides
              memory.reserve(CHIP_ENVELOPES, 2) if chip_envelopes
              memory.reserve(SIDES, 2) if sides
              [ROW, PLACE, REGISTERS, STOP_NAME, STOP_LOGGED, TICKETS, NOTE_OWNER, NOTE_RANK, BEST, BEST_RANK,
               BEST_TICKET, DROPS, DROPS_MUSIC].each { |name| memory.reserve(name, 2) }
              memory.reserve(PLACES_STATE, PLACES * PLACE_BYTES)
              memory.reserve(KEPT_BY_PASS, Frame::STEPS_KEPT * PLACES)
              memory.reserve(LEVELS_BY_PASS, Frame::STEPS_KEPT * PLACES)
            end

            # +voices+ is the sound chip's voices recordings play on, the first place's first.
            def emit(asm, memory, voices:)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              heard = voices.size * PLACE_BYTES
              emit_play(asm, at, memory, heard)
              emit_note(asm, at, memory, heard)
              emit_glide(asm, at, memory, heard) if memory.reserved?(GLIDES)
              emit_note_release(asm, at, memory, heard)
              emit_stop(asm, at, memory, heard)
              emit_frame(asm, at, memory)
              emit_kept_for_pass(asm, memory)
              emit_shapes(asm, at, memory, heard)
              emit_voice_of_place(asm, at, voices)
            end

            # rt_recordings_voice_of_place: A = the voice of the place at PLACE, one that has a voice.
            def emit_voice_of_place(asm, at, voices)
              asm.label("rt_recordings_voice_of_place")
              asm.lda(at.call(PLACE))
              voices.each_with_index do |voice, place|
                asm.cmp(place * PLACE_BYTES)
                asm.bne("rt_recordings_voice_of_place_#{place}")
                asm.lda(voice)
                asm.rts
                asm.label("rt_recordings_voice_of_place_#{place}")
              end
              asm.lda(voices.first)
              asm.rts
            end

            # rt_recordings_kept_for_pass: which recording each place holds (its byte of HELD) copied
            # into KEPT_BY_PASS for the pass whose wait is ending, for a reader of the run to hold to
            # the interpreter's mix at that pass's frame boundary (Sound's rt_sound_frame).
            def emit_kept_for_pass(asm, memory)
              asm.label("rt_recordings_kept_for_pass")
              asm.lda(asm.abs(memory[Frame::PASSES]))
              asm.and_a(Frame::STEPS_KEPT - 1)
              Music.emit_times(asm, PLACES)
              asm.tax
              asm.sep(0x20)
              PLACES.times do |place|
                asm.lda(asm.abs(memory[PLACES_STATE], (place * PLACE_BYTES) + HELD))
                asm.sta(asm.abs_x(memory[KEPT_BY_PASS], place))
                asm.lda(asm.abs(memory[PLACES_STATE], (place * PLACE_BYTES) + LEVEL))
                asm.sta(asm.abs_x(memory[LEVELS_BY_PASS], place))
              end
              asm.rep(0x20)
              asm.rts
            end

            # rt_recordings_play(row): the play's entry logged, and the recording in the first free
            # place from its start (Reference::Mixer#start); with none free, nothing more. In one of
            # a place with a voice it starts on that voice.
            def emit_play(asm, at, memory, heard)
              place = place_field(asm, memory)
              row = ->(field) { asm.long_x("recording_plays", field) }
              asm.label("rt_recordings_play")
              asm.lda(asm.direct(Sound::R0))
              Music.emit_times(asm, ROW_BYTES)
              asm.sta(at.call(ROW))
              asm.tax
              asm.lda(row.call(LOGGED))
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_sound_log"))
              asm.ldy(0)
              asm.label("rt_recordings_play_find")
              asm.lda(place.call(HELD))
              asm.beq("rt_recordings_play_found")
              asm.tya
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.tay
              asm.cpy(PLACES * PLACE_BYTES)
              asm.bcc("rt_recordings_play_find")
              asm.jsr(asm.abs("rt_recordings_quietest")) # none free: the quietest note falling away
              asm.bcc("rt_recordings_play_found")
              asm.jmp(asm.abs("rt_recordings_drop")) # every place busy: dropped, as the mixer drops it
              asm.label("rt_recordings_play_found")
              asm.lda(0) # the game's own, below every song, with the next ticket
              asm.sta(place.call(OWNER))
              asm.sta(place.call(RANK))
              asm.inc(at.call(TICKETS))
              asm.lda(at.call(TICKETS))
              asm.and_a(LOOPS - 1)
              asm.ldx(at.call(ROW))
              asm.sta(place.call(TICKET))
              asm.lda(row.call(BACK))
              asm.ora(row.call(BACK + 2))
              asm.beq("rt_recordings_take")
              asm.lda(place.call(TICKET))
              asm.ora(LOOPS)
              asm.sta(place.call(TICKET))

              # rt_recordings_take: the row at ROW into the place Y holds, from the recording's start,
              # on its voice for one of the first four places. A = 1 after.
              asm.label("rt_recordings_take")
              asm.sty(at.call(PLACE))
              asm.ldx(at.call(ROW))
              asm.lda(row.call(NAME))
              asm.inc
              asm.sta(place.call(HELD))
              if memory.reserved?(Sound::QUEUE) # a note counted in frames needs nothing to walk its samples
                asm.lda(row.call(FRAMES_LEFT))
                asm.sta(place.call(PLACE_FRAMES_LEFT))
                asm.branch_long(:bne, "rt_recordings_take_walked")
              end
              asm.lda(0)
              [POSITION, POSITION + 2, FRACTION].each { |field| asm.sta(place.call(field)) }
              { LENGTH => PLACE_LENGTH, LENGTH + 2 => PLACE_LENGTH + 2, BACK => PLACE_BACK, BACK + 2 => PLACE_BACK + 2,
                ADVANCE => PLACE_ADVANCE, ADVANCE + 2 => PLACE_ADVANCE + 2, ADVANCE_FRACTION => PLACE_ADVANCE_FRACTION,
                LOGGED => PLACE_LOGGED }.each do |from, to|
                asm.lda(row.call(from))
                asm.sta(place.call(to))
              end
              asm.label("rt_recordings_take_walked")
              copied = { SHAPE_AD => PLACE_AD, SHAPE_SR => PLACE_SR, VOLUME => LOUD }
              copied[SHAPED] = PLACE_SHAPED if memory.reserved?(CHIP_ENVELOPES)
              copied.each do |from, to|
                asm.lda(row.call(from))
                asm.sta(place.call(to))
              end
              if memory.reserved?(SIDES) # the row's word of "recording_sides", a word for each row's ROW_BYTES
                asm.txa
                (ROW_BYTES / 2).bit_length.pred.times { asm.lsr }
                asm.tax
                asm.lda(asm.long_x("recording_sides", 0))
                asm.sta(place.call(PLACE_SIDES))
                asm.ldx(at.call(ROW))
              end
              # Its shape: one with none sounds at full from its first sample; one with a shape starts at
              # nothing and climbs (Reference::Mixer#recording_fields).
              asm.lda(row.call(SHAPED))
              asm.and_a(SHAPED_BIT) if memory.reserved?(CHIP_ENVELOPES)
              asm.beq("rt_recordings_take_plain")
              asm.lda(0)
              asm.sta(place.call(LEVEL))
              asm.lda(CLIMBING)
              asm.sta(place.call(PHASE))
              asm.bra("rt_recordings_take_shaped")
              asm.label("rt_recordings_take_plain")
              asm.lda(FULL)
              asm.sta(place.call(LEVEL))
              asm.lda(PLAIN)
              asm.sta(place.call(PHASE))
              asm.label("rt_recordings_take_shaped")
              # Its voice, for a place with one: the voice's registers, and key-on last.
              asm.lda(at.call(PLACE))
              asm.cmp(heard)
              asm.bcc("rt_recordings_play_heard")
              asm.lda(1)
              asm.rtl
              asm.label("rt_recordings_play_heard")
              if memory.reserved?(Sound::QUEUE)
                # The note's start works its loudness out as it reaches the front of the queue, so it
                # stands for the word about loudness too: nothing more waits for this place until then.
                asm.lda(1)
                asm.sta(place.call(VOLUME_WAITING))
                emit_queued_entry(asm, at, Sound::START_NOTE)
                asm.lda(1)
                asm.rtl
                memory.reserved?(Sound::AHEAD) ? emit_whole_voice_routines(asm, at, memory, row, place) : emit_voice_routines(asm, at, memory, row, place)
              else
                emit_voice_start(asm, at, memory, row)
                asm.lda(1)
                asm.rtl
              end
            end

            # What the sound unit hears of a note is only what these write, so in a game with a sound
            # queue each waits there as one entry and is worked out while the game waits for the screen
            # (Sound's rt_sound_send_queued). rt_recordings_voice_start (JSL), with PLACE and ROW set:
            # the note, in Sound::NOTE_START_WRITES writes. rt_recordings_voice_volume (JSL), with
            # PLACE set: its loudness, in Sound::NOTE_VOLUME_WRITES.
            def emit_voice_routines(asm, at, memory, row, place)
              asm.label("rt_recordings_voice_start")
              emit_clear_loudness_waiting(asm, at, place)
              emit_voice_start(asm, at, memory, row)
              asm.rtl
              asm.label("rt_recordings_voice_volume")
              emit_clear_loudness_waiting(asm, at, place)
              emit_registers(asm, at)
              asm.jsr(asm.abs("rt_recordings_volume"))
              asm.rtl
            end

            # The same two where the sound unit's program writes the registers (Sound.driver): a note in
            # two commands, the pitch and then the rest, and a loudness in one. In a game with
            # CHIP_ENVELOPES a note is two commands more, its envelope's bytes ahead of it.
            def emit_whole_voice_routines(asm, at, memory, row, place)
              told = lambda do |command, first, second|
                first.call
                asm.and_a(0xFF)
                asm.sta(asm.direct(Sound::R0))
                second.call
                asm.and_a(0xFF)
                asm.sta(asm.direct(Sound::R1))
                command.call
                asm.jsl(asm.long("rt_sound_command"))
              end
              voice_command = lambda do |number|
                lambda do
                  asm.lda(at.call(REGISTERS))
                  asm.ora(number)
                end
              end
              pitch = lambda do
                asm.ldx(at.call(ROW))
                asm.lda(row.call(PITCH))
              end
              loudness = -> { asm.jsr(asm.abs("rt_recordings_loudness")) }

              asm.label("rt_recordings_voice_start")
              emit_clear_loudness_waiting(asm, at, place)
              emit_registers(asm, at)
              told.call(-> { asm.lda(Sound::HOLD_PITCH) }, pitch, lambda {
                pitch.call
                asm.xba
              })
              if memory.reserved?(CHIP_ENVELOPES)
                byte = ->(which) { -> { emit_chip_envelope_byte(asm, at, row, which) } }
                told.call(-> { asm.lda(Sound::HOLD_ENVELOPE) }, byte.call(0), byte.call(1))
                told.call(-> { asm.lda(Sound::HOLD_GAIN) }, byte.call(2), -> { asm.lda(0) })
              end
              # Off the middle, a note's two sides go ahead of it in one more command
              # (Sound::SIDES_COMMANDS), and the note told whole leaves its volume registers alone, so
              # its first sample is heard where it sits.
              emit_loudness_command = lambda do
                if memory.reserved?(SIDES)
                  side = lambda do |which|
                    lambda do
                      loudness.call
                      asm.sta(at.call(BEST))
                      emit_side_loudness(asm, at, place, which)
                    end
                  end
                  told.call(voice_command.call(Sound::VOICE_LOUDNESS), side.call(0), side.call(1))
                else
                  told.call(voice_command.call(Sound::VOICE_LOUDNESS), -> { asm.lda(0) }, loudness)
                end
              end
              emit_loudness_command.call if memory.reserved?(SIDES)
              told.call(voice_command.call(Sound::WHOLE_NOTE), lambda {
                asm.ldx(at.call(ROW))
                asm.lda(row.call(SOURCE))
              }, loudness)
              asm.rtl

              asm.label("rt_recordings_voice_volume")
              emit_clear_loudness_waiting(asm, at, place)
              emit_registers(asm, at)
              emit_loudness_command.call
              asm.rtl

              asm.label("rt_recordings_loudness")
              asm.ldy(at.call(PLACE))
              emit_whole_loudness_for_chip_envelope(asm, memory, place, "rt_recordings_loudness_whole")
              asm.lda(place.call(LEVEL))
              asm.cmp(FULL)
              asm.bne("rt_recordings_loudness_scaled")
              asm.label("rt_recordings_loudness_whole")
              asm.lda(place.call(LOUD))
              asm.rts
              asm.label("rt_recordings_loudness_scaled")
              asm.lda(place.call(LOUD))
              asm.jmp(asm.abs("rt_recordings_level_times"))
            end

            # The place at PLACE has no word about its loudness waiting in the queue any more: the
            # one that stood for it is being sent.
            def emit_clear_loudness_waiting(asm, at, place)
              asm.ldy(at.call(PLACE))
              asm.lda(0)
              asm.sta(place.call(VOLUME_WAITING))
            end

            # In a game with CHIP_ENVELOPES, on to +whole+ with the place Y holds when its note has a chip
            # envelope: its voice hears its loudness whole, whatever the place's level.
            def emit_whole_loudness_for_chip_envelope(asm, memory, place, whole)
              return unless memory.reserved?(CHIP_ENVELOPES)

              asm.lda(place.call(PLACE_SHAPED))
              asm.and_a(CHIP_ENVELOPE_BITS)
              asm.bne(whole)
            end

            # A = byte +which+ (0 ADSR1, 1 ADSR2, 2 GAIN) of the chip envelope of the row at ROW.
            def emit_chip_envelope_byte(asm, at, row, which)
              asm.ldx(at.call(ROW))
              asm.lda(row.call(SHAPED))
              asm.xba
              asm.and_a(0xFF)
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.long_x("recording_chip_envelopes", which))
            end

            # The place's voice told all about its note, key-on last.
            def emit_voice_start(asm, at, memory, row)
              emit_registers(asm, at)
              dsp = DSPWrites
              asm.jsr(asm.abs("rt_recordings_volume")) # the volume its level scales it to
              { dsp::PITCH_LOW => PITCH, dsp::SOURCE => SOURCE }.each do |register, field|
                emit_voice_write(asm, at, register) do
                  asm.ldx(at.call(ROW))
                  asm.lda(row.call(field))
                end
              end
              emit_voice_write(asm, at, dsp::PITCH_HIGH) do
                asm.ldx(at.call(ROW))
                asm.lda(row.call(PITCH))
                asm.xba
              end
              if memory.reserved?(CHIP_ENVELOPES)
                [dsp::ADSR1, dsp::ADSR2, dsp::GAIN].each_with_index do |register, which|
                  emit_voice_write(asm, at, register) { emit_chip_envelope_byte(asm, at, row, which) }
                end
              else
                emit_voice_write(asm, at, dsp::ADSR1) { asm.lda(dsp::ADSR_OFF) }
                emit_voice_write(asm, at, dsp::GAIN) { asm.lda(dsp::FIXED_TOP) }
              end
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R0))
              asm.stz(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_sound_key_off_bits")) # its key-off cleared...
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R1))
              asm.lda(dsp::KEY_ON)
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_sound_write")) # ...then key-on
            end

            # rt_recordings_note(row, owner, rank): a note of a song's recorded part, the row's recording
            # played in a place found by the interpreter's rule (Reference::Mixer#start_music_note): the
            # part's own (+owner+'s), the first free, or the place of the lowest-ranked sound ranked
            # below +rank+ — by its rank, then its ticket, the first of two alike. A = 1 when it found
            # one, nought when the note is not played.
            def emit_note(asm, at, memory, heard)
              place = place_field(asm, memory)
              asm.label("rt_recordings_note")
              asm.lda(asm.direct(Sound::R0))
              Music.emit_times(asm, ROW_BYTES)
              asm.sta(at.call(ROW))
              asm.lda(asm.direct(Sound::R1))
              asm.sta(at.call(NOTE_OWNER))
              asm.lda(asm.direct(Sound::R2))
              asm.sta(at.call(NOTE_RANK))
              # The part's own place, still sounding its note — unless that note has a shape: then it
              # is told to fall away there, and this note takes another place.
              asm.jsr(asm.abs("rt_recordings_sounding"))
              asm.bcs("rt_recordings_note_elsewhere")
              asm.lda(place.call(PHASE))
              asm.branch_long(:beq, "rt_recordings_note_found") # a plain note: taken over
              asm.lda(FALLING)
              asm.sta(place.call(PHASE))
              # The first free place.
              asm.label("rt_recordings_note_elsewhere")
              if memory.reserved?(Sound::AHEAD)
                emit_quick_free_place(asm, memory)
              else
                each_place(asm, "rt_recordings_note_free") do |next_place|
                  asm.lda(place.call(HELD))
                  asm.branch_long(:beq, "rt_recordings_note_found")
                  asm.bra(next_place)
                end
              end
              # The quietest note falling away.
              asm.jsr(asm.abs("rt_recordings_quietest"))
              asm.branch_long(:bcc, "rt_recordings_note_found")
              # The lowest-ranked place below the note's rank: BEST is the place offset one up, nought
              # while none is found.
              asm.stz(at.call(BEST))
              each_place(asm, "rt_recordings_note_low") do |next_place|
                asm.lda(place.call(RANK))
                asm.cmp(at.call(NOTE_RANK))
                asm.bcs(next_place) # not below the note
                asm.ldx(at.call(BEST))
                asm.beq("rt_recordings_note_low_best")
                asm.cmp(at.call(BEST_RANK))
                asm.bcc("rt_recordings_note_low_best") # ranked lower than the best yet
                asm.bne(next_place)
                asm.lda(place.call(TICKET))
                asm.cmp(at.call(BEST_TICKET))
                asm.bcs(next_place) # no older, or the same: the first stays
                asm.label("rt_recordings_note_low_best")
                asm.lda(place.call(RANK))
                asm.sta(at.call(BEST_RANK))
                asm.lda(place.call(TICKET))
                asm.sta(at.call(BEST_TICKET))
                asm.tya
                asm.inc
                asm.sta(at.call(BEST))
              end
              asm.lda(at.call(BEST))
              asm.bne("rt_recordings_note_lowest")
              asm.jmp(asm.abs("rt_recordings_drop")) # none: the note is not played, and A is nought
              asm.label("rt_recordings_note_lowest")
              asm.dec
              asm.tay
              asm.label("rt_recordings_note_found")
              if memory.reserved?(Sound::AHEAD)
                asm.lda(at.call(Sound::ASKING_AHEAD))
                asm.beq("rt_recordings_note_nothing_to_forget")
                asm.lda(0)
                asm.sta(place.call(VOLUME_WAITING)) # it is about to be forgotten
                asm.cpy(heard)
                asm.bcs("rt_recordings_note_bit_known") # no voice, and A still nought
                asm.sty(at.call(PLACE))
                asm.phy
                emit_voice_bit(asm, at)
                asm.ply
                asm.label("rt_recordings_note_bit_known")
                asm.jsl(asm.long("rt_sound_forget_place"))
                asm.label("rt_recordings_note_nothing_to_forget")
              end
              asm.lda(at.call(NOTE_OWNER))
              asm.sta(place.call(OWNER))
              asm.lda(at.call(NOTE_RANK))
              asm.sta(place.call(RANK))
              asm.lda(0)
              asm.sta(place.call(TICKET))
              asm.jmp(asm.abs("rt_recordings_take"))
            end

            # rt_recordings_glide(row, owner): the note +owner+'s part sounds, if it has one, reads on at
            # the row's pitch (Reference::Mixer#glide_music_note): how far a frame takes it, and its
            # voice's pitch registers, with no key-on, so its fade goes on where it was. A = 1
            # when it had a note, nought when not.
            def emit_glide(asm, at, memory, heard)
              place = place_field(asm, memory)
              row = ->(field) { asm.long_x("recording_plays", field) }
              asm.label("rt_recordings_glide")
              asm.lda(asm.direct(Sound::R0))
              Music.emit_times(asm, ROW_BYTES)
              asm.sta(at.call(ROW))
              asm.lda(asm.direct(Sound::R1))
              asm.sta(at.call(NOTE_OWNER))
              asm.jsr(asm.abs("rt_recordings_sounding"))
              asm.bcc("rt_recordings_glide_found")
              asm.lda(0)
              asm.rtl
              asm.label("rt_recordings_glide_found")
              asm.sty(at.call(PLACE))
              asm.ldx(at.call(ROW))
              { ADVANCE => PLACE_ADVANCE, ADVANCE + 2 => PLACE_ADVANCE + 2, ADVANCE_FRACTION => PLACE_ADVANCE_FRACTION }.each do |from, to|
                asm.lda(row.call(from))
                asm.sta(place.call(to))
              end
              asm.lda(at.call(PLACE))
              asm.cmp(heard)
              asm.bcs("rt_recordings_glide_done")
              emit_queued_entry(asm, at, Sound::NOTE_PITCH)
              asm.label("rt_recordings_glide_done")
              asm.lda(1)
              asm.rtl

              # rt_recordings_voice_pitch (JSL), with PLACE and ROW set: a new pitch for its voice, in
              # Sound::NOTE_PITCH_WRITES writes.
              asm.label("rt_recordings_voice_pitch")
              emit_registers(asm, at)
              dsp = DSPWrites
              emit_voice_write(asm, at, dsp::PITCH_LOW) do
                asm.ldx(at.call(ROW))
                asm.lda(row.call(PITCH))
              end
              emit_voice_write(asm, at, dsp::PITCH_HIGH) do
                asm.ldx(at.call(ROW))
                asm.lda(row.call(PITCH))
                asm.xba
              end
              asm.rtl
            end

            # rt_recordings_note_release(owner): the place +owner+'s part sounds a note in, if it has
            # one, freed and its voice let go (Reference::Mixer#release_music); A = 1 when it had one,
            # nought when not.
            # rt_recordings_release_music: every place a song's part holds freed so
            # (Reference::Mixer#release_all_music); a sound effect's are the effect's.
            def emit_note_release(asm, at, memory, heard)
              place = place_field(asm, memory)
              asm.label("rt_recordings_note_release")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(NOTE_OWNER))
              asm.jsr(asm.abs("rt_recordings_sounding"))
              asm.bcs("rt_recordings_note_release_none")
              asm.jsr(asm.abs("rt_recordings_end_note"))
              asm.lda(1)
              asm.rtl
              asm.label("rt_recordings_note_release_none")
              asm.lda(0)
              asm.rtl

              # rt_recordings_loud(volume): the place just taken, at PLACE, sounding at +volume+, as the
              # music volume sets (Reference::Player#song_loudness).
              asm.label("rt_recordings_loud")
              asm.ldy(at.call(PLACE))
              asm.lda(asm.direct(Sound::R0))
              asm.sta(place.call(LOUD))
              asm.jsr(asm.abs("rt_recordings_heard_volume"))
              asm.rtl

              # rt_recordings_rescale_place(owner, volume, place): the note +owner+'s part sounds now, at
              # +volume+; A = 1, or nought when it has none (Reference::Mixer#rescale_music).
              #
              # A MUSIC VOLUME FALLING tells every part this on one frame, and a walk over the places
              # for each part is most of what that frame would cost. So the player keeps the +place+
              # the part's last note took, as its offset one up, and only that one is asked: a part has
              # one note sounding at most, since its next note either takes the same place or leaves
              # the old one falling away, so if that place is no longer the part's, held and not
              # falling, the part has no note anywhere.
              asm.label("rt_recordings_rescale_place")
              asm.ldy(asm.direct(Sound::R2))
              asm.lda(place.call(HELD - 1))
              asm.beq("rt_recordings_note_release_none")
              asm.lda(place.call(OWNER - 1))
              asm.cmp(asm.direct(Sound::R0))
              asm.bne("rt_recordings_note_release_none")
              asm.lda(place.call(PHASE - 1))
              asm.cmp(FALLING)
              asm.bcs("rt_recordings_note_release_none")
              asm.dey
              asm.sty(at.call(PLACE))
              asm.lda(asm.direct(Sound::R1))
              asm.sta(place.call(LOUD))
              asm.jsr(asm.abs("rt_recordings_heard_volume"))
              asm.lda(1)
              asm.rtl

              # rt_recordings_heard_volume: the place at PLACE's voice told its volume, if it has a voice.
              asm.label("rt_recordings_heard_volume")
              asm.lda(at.call(PLACE))
              asm.cmp(heard)
              asm.bcs("rt_recordings_heard_volume_done")
              if memory.reserved?(Music::LEVEL_SET) # only a music volume moves many notes at once
                emit_told_new_volume(asm, at, memory, place, "rt_recordings_heard_volume_done")
              else
                emit_registers(asm, at)
                asm.jsr(asm.abs("rt_recordings_volume"))
              end
              asm.label("rt_recordings_heard_volume_done")
              asm.rts

              asm.label("rt_recordings_release_music")
              each_place(asm, "rt_recordings_release_music") do |next_place|
                asm.lda(place.call(HELD))
                asm.beq(next_place)
                asm.lda(place.call(OWNER))
                asm.beq(next_place) # the game's own
                asm.cmp(EFFECT_OWNER)
                asm.bcs(next_place) # a sound effect's
                asm.lda(place.call(PHASE))
                asm.cmp(FALLING)
                asm.bcs(next_place) # falling already: it carries on as it was
                asm.jsr(asm.abs("rt_recordings_end_note"))
              end
              asm.rtl

              # rt_recordings_end_note: the note in the place Y holds has ended — one with a shape falls
              # away there, one without stops. Keeps Y.
              asm.label("rt_recordings_end_note")
              asm.lda(place.call(PHASE))
              asm.branch_long(:beq, "rt_recordings_free")
              asm.lda(FALLING)
              asm.sta(place.call(PHASE))
              asm.rts

              # rt_recordings_sounding: Y = the place NOTE_OWNER's part sounds a note in now — held, its
              # own, and not falling away — with carry clear; carry set when it has none.
              asm.label("rt_recordings_sounding")
              if memory.reserved?(Sound::AHEAD)
                emit_quick_sounding_place(asm, at, memory)
              else
                each_place(asm, "rt_recordings_sounding") do |next_place|
                  asm.lda(place.call(HELD))
                  asm.beq(next_place)
                  asm.lda(place.call(OWNER))
                  asm.cmp(at.call(NOTE_OWNER))
                  asm.bne(next_place)
                  asm.lda(place.call(PHASE))
                  asm.cmp(FALLING)
                  asm.bcs(next_place)
                  asm.clc
                  asm.rts
                end
              end
              asm.sec
              asm.rts

              # rt_recordings_quietest: Y = the place of the quietest song's note falling away, the first
              # of two as quiet, with carry clear; carry set when no note is falling away
              # (Reference::Mixer#quietest_releasing_slot).
              asm.label("rt_recordings_quietest")
              asm.stz(at.call(BEST))
              quietest = lambda do |next_place, best|
                asm.lda(place.call(PHASE))
                asm.cmp(FALLING)
                asm.bcc(next_place)
                asm.lda(place.call(HELD))
                asm.beq(next_place)
                asm.lda(place.call(OWNER))
                asm.beq(next_place)
                asm.lda(at.call(BEST))
                asm.beq(best)
                asm.lda(place.call(LEVEL))
                asm.cmp(at.call(BEST_RANK))
                asm.bcs(next_place)
                asm.label(best)
                asm.lda(place.call(LEVEL))
                asm.sta(at.call(BEST_RANK))
                asm.tya
                asm.inc
                asm.sta(at.call(BEST))
              end
              if memory.reserved?(Sound::AHEAD)
                PLACES.times do |number|
                  asm.ldy(number * PLACE_BYTES)
                  quietest.call("rt_recordings_quietest_past_#{number}", "rt_recordings_quietest_best_#{number}")
                  asm.label("rt_recordings_quietest_past_#{number}")
                end
              else
                each_place(asm, "rt_recordings_quietest") { |next_place| quietest.call(next_place, "rt_recordings_quietest_best") }
              end
              asm.lda(at.call(BEST))
              asm.bne("rt_recordings_quietest_found")
              asm.sec
              asm.rts
              asm.label("rt_recordings_quietest_found")
              asm.dec
              asm.tay
              asm.clc
              asm.rts

              # rt_recordings_drop: a play or a note found no place (Reference::Mixer#record_drop):
              # counted, with the most places songs held at such a moment. A = nought, and back to the
              # caller's caller.
              asm.label("rt_recordings_drop")
              asm.inc(at.call(DROPS))
              asm.stz(at.call(BEST))
              each_place(asm, "rt_recordings_drop") do |next_place|
                asm.lda(place.call(HELD))
                asm.beq(next_place)
                asm.lda(place.call(OWNER))
                asm.beq(next_place)
                asm.inc(at.call(BEST))
              end
              asm.lda(at.call(BEST))
              asm.cmp(at.call(DROPS_MUSIC))
              asm.bcc("rt_recordings_drop_done")
              asm.sta(at.call(DROPS_MUSIC))
              asm.label("rt_recordings_drop_done")
              asm.lda(0)
              asm.rtl

              # rt_recordings_free: the place Y holds freed, and its voice let go if it is heard. Keeps Y.
              asm.label("rt_recordings_free")
              asm.lda(0)
              asm.sta(place.call(HELD))
              asm.sty(at.call(PLACE))
              asm.cpy(heard)
              asm.bcs("rt_recordings_free_done")
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R0))
              asm.sta(asm.direct(Sound::R1))
              asm.phy
              asm.jsl(asm.long("rt_sound_key_off_bits"))
              asm.ply
              asm.label("rt_recordings_free_done")
              asm.rts
            end

            # rt_recordings_shapes: one frame of every place's shape (Reference::Mixer#step_envelopes,
            # by Audio::Envelope#step's rule), after the frame's music: a place done falling comes free;
            # one climbing climbs by its attack to full, and then holds; one holding falls by its decay
            # to its sustain; one falling falls by its release, and once at nothing is done. A heard
            # place's voice is told its new volume.
            #
            # rt_recordings_volume: the voice of the place at PLACE (its registers at REGISTERS) told the
            # place's volume scaled by its level — the whole of it at full.
            #
            # A NOTE'S LOUDNESS CHANGES EVERY FRAME while it climbs or falls, and a game with no time
            # to spare empties the sound queue slowly. Seven notes would add seven entries a frame, it
            # would fill, and the game would wait for room. One word waiting about a place is enough,
            # since it is worked out from the level when it reaches the front of the queue.
            def emit_shapes(asm, at, memory, heard)
              place = place_field(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_recordings_shapes")
              each_place(asm, "rt_recordings_shapes") do |next_place|
                asm.lda(place.call(HELD))
                asm.branch_long(:beq, next_place)
                asm.lda(place.call(PHASE))
                asm.branch_long(:beq, next_place) # no shape
                asm.cmp(DONE)
                asm.bne("rt_recordings_shapes_step")
                asm.jsr(asm.abs("rt_recordings_free"))
                asm.brl(next_place)
                asm.label("rt_recordings_shapes_step")
                asm.cmp(CLIMBING)
                asm.bne("rt_recordings_shapes_holding")
                asm.lda(place.call(PLACE_AD))
                asm.and_a(0xFF) # the attack
                asm.clc
                asm.adc(place.call(LEVEL))
                asm.cmp(FULL)
                asm.bcc("rt_recordings_shapes_level")
                asm.lda(HOLDING)
                asm.sta(place.call(PHASE))
                asm.lda(FULL)
                asm.bra("rt_recordings_shapes_level")
                asm.label("rt_recordings_shapes_holding")
                asm.cmp(HOLDING)
                asm.bne("rt_recordings_shapes_falling")
                asm.lda(place.call(PLACE_SR))
                asm.and_a(0xFF) # the sustain
                asm.sta(at.call(BEST_RANK))
                asm.lda(place.call(LEVEL))
                asm.cmp(at.call(BEST_RANK))
                asm.branch_long(:bcc, next_place) # at the sustain or under it: held there
                asm.branch_long(:beq, next_place)
                asm.lda(place.call(PLACE_AD))
                asm.xba
                asm.and_a(0xFF) # the decay
                asm.jsr(asm.abs("rt_recordings_level_times"))
                asm.cmp(at.call(BEST_RANK))
                asm.bcs("rt_recordings_shapes_level")
                asm.lda(at.call(BEST_RANK)) # no lower than the sustain
                asm.bra("rt_recordings_shapes_level")
                asm.label("rt_recordings_shapes_falling")
                asm.lda(place.call(PLACE_SR))
                asm.xba
                asm.and_a(0xFF) # the release
                asm.jsr(asm.abs("rt_recordings_level_times"))
                asm.sta(place.call(LEVEL))
                asm.bne("rt_recordings_shapes_heard")
                asm.lda(DONE)
                asm.sta(place.call(PHASE))
                asm.bra("rt_recordings_shapes_heard")
                asm.label("rt_recordings_shapes_level")
                asm.sta(place.call(LEVEL))
                asm.label("rt_recordings_shapes_heard")
                asm.cpy(heard)
                asm.branch_long(:bcs, next_place)
                asm.sty(at.call(PLACE))
                emit_chip_envelope_heard(asm, at, memory, place, next_place)
                emit_told_new_volume(asm, at, memory, place, next_place)
                asm.ldy(at.call(PLACE))
              end
              asm.rts

              # rt_recordings_level_times: A = the level of the place Y holds times A (a byte), over 256.
              asm.label("rt_recordings_level_times")
              asm.sta(at.call(BEST_TICKET))
              asm.sep(0x20)
              asm.lda(place.call(LEVEL))
              asm.sta(asm.abs(h::WRMPYA))
              asm.lda(at.call(BEST_TICKET))
              asm.sta(asm.abs(h::WRMPYB))
              4.times { asm.nop } # the eight cycles the multiplier takes
              asm.rep(0x20)
              asm.lda(asm.abs(h::RDMPYL))
              asm.xba
              asm.and_a(0xFF)
              asm.rts

              asm.label("rt_recordings_volume")
              asm.ldy(at.call(PLACE))
              emit_whole_loudness_for_chip_envelope(asm, memory, place, "rt_recordings_volume_whole")
              asm.lda(place.call(LEVEL))
              asm.cmp(FULL)
              asm.bne("rt_recordings_volume_scaled")
              asm.label("rt_recordings_volume_whole")
              asm.lda(place.call(LOUD))
              asm.bra("rt_recordings_volume_now")
              asm.label("rt_recordings_volume_scaled")
              asm.lda(place.call(LOUD))
              asm.jsr(asm.abs("rt_recordings_level_times"))
              asm.label("rt_recordings_volume_now")
              asm.sta(at.call(BEST))
              [DSPWrites::VOLUME_LEFT, DSPWrites::VOLUME_RIGHT].each_with_index do |register, side|
                emit_voice_write(asm, at, register) do
                  memory.reserved?(SIDES) ? emit_side_loudness(asm, at, place, side) : asm.lda(at.call(BEST))
                end
              end
              asm.rts
              emit_side_times(asm, at) if memory.reserved?(SIDES)
            end

            # A = the loudness in BEST as side +side+ (0 the left, 1 the right) of the place at PLACE
            # hears it (SIDES).
            def emit_side_loudness(asm, at, place, side)
              asm.ldy(at.call(PLACE))
              asm.lda(place.call(PLACE_SIDES))
              asm.xba if side == 1
              asm.and_a(0xFF)
              asm.jsr(asm.abs("rt_recordings_side_times"))
            end

            # rt_recordings_side_times: A = the loudness in BEST times the share in A, out of
            # Audio::Pan::SHARE_FULL, to the nearest whole step. A share is at most SHARE_FULL and a
            # loudness at most 127, so the product fits the multiplier's sixteen bits.
            def emit_side_times(asm, at)
              h = Console::SNESHardware
              asm.label("rt_recordings_side_times")
              asm.sep(0x20)
              asm.sta(asm.abs(h::WRMPYA))
              asm.lda(at.call(BEST))
              asm.sta(asm.abs(h::WRMPYB))
              4.times { asm.nop } # the eight cycles the multiplier takes
              asm.rep(0x20)
              asm.lda(asm.abs(h::RDMPYL))
              asm.clc
              asm.adc(Audio::Pan::SHARE_ROUNDING)
              Audio::Pan::SHARE_SHIFT.times { asm.lsr }
              asm.rts
            end

            # In a game with CHIP_ENVELOPES, what a frame of its shape means to the voice of the place
            # at PLACE (Y that place) when its note has a chip envelope, and then on to +past+: nothing
            # while the note sounds, since the chip moves the level itself; and once the note has
            # ended, its key-off, from where the chip takes the level down. Any other note falls
            # through to be told its loudness.
            def emit_chip_envelope_heard(asm, at, memory, place, past)
              return unless memory.reserved?(CHIP_ENVELOPES)

              asm.lda(place.call(PLACE_SHAPED))
              asm.and_a(CHIP_ENVELOPE_BITS)
              asm.beq(scaled = "rt_recordings_shapes_scaled_#{asm.here}")
              asm.lda(place.call(PHASE))
              asm.cmp(FALLING)
              asm.branch_long(:bcc, past)
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R0))
              asm.sta(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_sound_key_off_bits"))
              asm.ldy(at.call(PLACE))
              asm.brl(past)
              asm.label(scaled)
            end

            # The voice of the place at PLACE told its loudness, with Y that place. In a game with a
            # sound queue that is one word waiting, or none if one is, so a music volume falling on
            # eight notes fills the queue no more than their shapes do. On to +past+ if one is.
            def emit_told_new_volume(asm, at, memory, place, past)
              unless memory.reserved?(Sound::QUEUE)
                emit_registers(asm, at)
                asm.jsr(asm.abs("rt_recordings_volume"))
                return
              end

              asm.lda(place.call(VOLUME_WAITING))
              asm.branch_long(:bne, past)
              asm.lda(1)
              asm.sta(place.call(VOLUME_WAITING))
              emit_queued_entry(asm, at, Sound::NOTE_VOLUME)
            end

            # THE TWO WALKS A CHORD MAKES MOST, written out a place at a time. Every note of a chord asks
            # after its part's place and then for a free one, and moving a counter on from place to
            # place takes longer than the look itself, so a chord of seven spends lines of the picture
            # on it. Read at each place's own address there is no counter to move. A game with sound
            # effects, which has to leave room for them beside a chord, is the one that pays the bytes.
            def emit_quick_free_place(asm, memory)
              PLACES.times do |number|
                past = "rt_recordings_note_free_past_#{number}"
                asm.lda(asm.abs(memory[PLACES_STATE], (number * PLACE_BYTES) + HELD))
                asm.bne(past)
                asm.ldy(number * PLACE_BYTES)
                asm.brl("rt_recordings_note_found")
                asm.label(past)
              end
            end

            # The place NOTE_OWNER's part sounds in, as #emit_note_release's walk finds it, asking first
            # what most places answer no to.
            def emit_quick_sounding_place(asm, at, memory)
              place = place_field(asm, memory)
              PLACES.times do |number|
                past = "rt_recordings_sounding_past_#{number}"
                asm.lda(asm.abs(memory[PLACES_STATE], (number * PLACE_BYTES) + OWNER))
                asm.cmp(at.call(NOTE_OWNER))
                asm.bne(past)
                asm.ldy(number * PLACE_BYTES)
                asm.lda(place.call(HELD))
                asm.beq(past)
                asm.lda(place.call(PHASE))
                asm.cmp(FALLING)
                asm.bcs(past)
                asm.clc
                asm.rts
                asm.label(past)
              end
            end

            # A walk over every place, Y each one's offset: the block's code for each, given the label
            # that goes on to the next.
            def each_place(asm, label)
              asm.ldy(0)
              asm.label("#{label}_place")
              yield "#{label}_next"
              asm.label("#{label}_next")
              asm.tya
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.tay
              asm.cpy(PLACES * PLACE_BYTES)
              asm.branch_long(:bcc, "#{label}_place")
            end

            # rt_recordings_stop(name, logged): every place playing recording +name+ (or every place,
            # for ALL) freed, a heard one's voice let go, and [:stop_sample] logged (Reference::Mixer#stop).
            def emit_stop(asm, at, memory, heard)
              place = place_field(asm, memory)
              asm.label("rt_recordings_stop")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(STOP_NAME))
              asm.lda(asm.direct(Sound::R1))
              asm.sta(at.call(STOP_LOGGED))
              asm.stz(at.call(PLACE))
              asm.label("rt_recordings_stop_next")
              asm.ldy(at.call(PLACE))
              asm.lda(place.call(OWNER))
              asm.bne("rt_recordings_stop_walk") # a song's note is the music's to stop
              asm.lda(place.call(HELD))
              asm.beq("rt_recordings_stop_walk")
              asm.dec
              asm.ldx(at.call(STOP_NAME))
              asm.cpx(ALL)
              asm.beq("rt_recordings_stop_it")
              asm.cmp(at.call(STOP_NAME))
              asm.bne("rt_recordings_stop_walk")
              asm.label("rt_recordings_stop_it")
              asm.lda(0)
              asm.sta(place.call(HELD))
              asm.tya
              asm.cmp(heard)
              asm.bcs("rt_recordings_stop_walk")
              emit_voice_bit(asm, at)
              asm.sta(asm.direct(Sound::R0))
              asm.sta(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_sound_key_off_bits"))
              asm.label("rt_recordings_stop_walk")
              asm.lda(at.call(PLACE))
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.sta(at.call(PLACE))
              asm.cmp(PLACES * PLACE_BYTES)
              asm.bcc("rt_recordings_stop_next")
              asm.lda(at.call(STOP_LOGGED))
              asm.sta(asm.direct(Sound::R0))
              asm.jml(asm.long("rt_sound_log"))
            end

            # rt_recordings_frame: each place playing moved on by a frame (Reference::Mixer#mix_voice):
            # the fraction, then the whole samples and what the fraction carried; past the recording's
            # end, back by its read-back as many times as it takes, logging each time round — or, for one
            # played once, the place freed.
            def emit_frame(asm, at, memory)
              place = place_field(asm, memory)
              asm.label("rt_recordings_frame")
              asm.ldy(0)
              asm.label("rt_recordings_frame_place")
              asm.lda(place.call(HELD))
              asm.branch_long(:beq, "rt_recordings_frame_next")
              if memory.reserved?(Sound::QUEUE)
                asm.lda(place.call(PLACE_FRAMES_LEFT))
                asm.beq("rt_recordings_frame_walk")
                asm.cmp(NEVER_ENDS)
                asm.branch_long(:beq, "rt_recordings_frame_next")
                asm.dec
                asm.sta(place.call(PLACE_FRAMES_LEFT))
                asm.branch_long(:bne, "rt_recordings_frame_next")
                asm.sta(place.call(HELD)) # over: A is nought
                asm.brl("rt_recordings_frame_next")
                asm.label("rt_recordings_frame_walk")
              end
              asm.clc
              asm.lda(place.call(FRACTION))
              asm.adc(place.call(PLACE_ADVANCE_FRACTION))
              asm.sta(place.call(FRACTION))
              asm.lda(place.call(POSITION))
              asm.adc(place.call(PLACE_ADVANCE))
              asm.sta(place.call(POSITION))
              asm.lda(place.call(POSITION + 2))
              asm.adc(place.call(PLACE_ADVANCE + 2))
              asm.sta(place.call(POSITION + 2))
              asm.label("rt_recordings_frame_end")
              asm.lda(place.call(POSITION + 2))
              asm.cmp(place.call(PLACE_LENGTH + 2))
              asm.bcc("rt_recordings_frame_next")
              asm.bne("rt_recordings_frame_past")
              asm.lda(place.call(POSITION))
              asm.cmp(place.call(PLACE_LENGTH))
              asm.bcc("rt_recordings_frame_next")
              asm.label("rt_recordings_frame_past")
              asm.lda(place.call(PLACE_BACK))
              asm.ora(place.call(PLACE_BACK + 2))
              asm.bne("rt_recordings_frame_back")
              asm.sta(place.call(HELD)) # played once, and over: A is nought
              asm.bra("rt_recordings_frame_next")
              asm.label("rt_recordings_frame_back")
              asm.sec
              asm.lda(place.call(POSITION))
              asm.sbc(place.call(PLACE_BACK))
              asm.sta(place.call(POSITION))
              asm.lda(place.call(POSITION + 2))
              asm.sbc(place.call(PLACE_BACK + 2))
              asm.sta(place.call(POSITION + 2))
              asm.lda(place.call(PLACE_LOGGED))
              asm.cmp(NOT_LOGGED) # a song's note: nothing logged as it comes round
              asm.beq("rt_recordings_frame_end")
              asm.sta(asm.direct(Sound::R0))
              asm.phy
              asm.jsl(asm.long("rt_sound_log"))
              asm.ply
              asm.bra("rt_recordings_frame_end")
              asm.label("rt_recordings_frame_next")
              asm.tya
              asm.clc
              asm.adc(PLACE_BYTES)
              asm.tay
              asm.cpy(PLACES * PLACE_BYTES)
              asm.branch_long(:bcc, "rt_recordings_frame_place")
              asm.rts
            end

            # One entry in the sound queue for what a place's voice is to be told, which PLACE and ROW name.
            def emit_queued_entry(asm, at, command)
              asm.lda(at.call(PLACE))
              asm.sta(asm.direct(Sound::R0))
              asm.lda(at.call(ROW))
              asm.sta(asm.direct(Sound::R1))
              asm.lda(command)
              asm.jsl(asm.long("rt_sound_command"))
            end

            # A field of the place whose offset Y holds, as an operand.
            def place_field(asm, memory) = ->(field) { asm.abs_y(memory[PLACES_STATE], field) }

            # REGISTERS = the first register of the voice of the place at PLACE (one that has a voice).
            def emit_registers(asm, at)
              asm.jsr(asm.abs("rt_recordings_voice_of_place"))
              4.times { asm.asl }
              asm.sta(at.call(REGISTERS))
            end

            # A = the bit of the voice of the place at PLACE, in KON and KOFF.
            def emit_voice_bit(asm, _at)
              asm.jsr(asm.abs("rt_recordings_voice_of_place"))
              asm.tax
              asm.lda(1)
              asm.label(label = "rt_recordings_bit_#{asm.here}")
              asm.cpx(0)
              asm.beq("#{label}_done")
              asm.asl
              asm.dex
              asm.bra(label)
              asm.label("#{label}_done")
            end

            # One write to register +register+ of the voice at REGISTERS, its value from the block (in A).
            def emit_voice_write(asm, at, register)
              yield
              asm.and_a(0xFF)
              asm.sta(asm.direct(Sound::R1))
              asm.lda(at.call(REGISTERS))
              asm.clc
              asm.adc(register)
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_sound_write"))
            end
          end
        end
      end
    end
  end
end
