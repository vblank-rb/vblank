# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # The software mixer — several recorded samples sounding at once. The console's
        # sampled-audio hardware plays one stream of bytes out of a small buffer; to get
        # background music under a handful of effects (and, later, chords), the CPU adds
        # the samples together itself. Each frame it builds the next little slice of sound
        # by summing every voice that's playing into a buffer, and the sound DMA plays that
        # buffer out. Two buffers take turns (a "double buffer"): the DMA plays one while
        # the CPU fills the other, then they swap — so the DMA never reads a half-written
        # buffer. All of this is hidden behind `play`/`stop`.
        #
        # A "voice" is one sounding sample: where its data is in the cartridge, how far it
        # has played, its length, whether it loops, and how fast it reads the recording (its
        # pitch). There are a fixed number of voice slots; `play` fills a free one, the mix
        # drains and retires it (or loops it), and `stop` clears a sample's slots. The mix runs
        # once per displayed frame, from the screen's own interrupt — so playing samples needs a
        # game loop, which is what arms that interrupt.
        #
        # The slots are shared between the game's sounds and the notes of songs and sound effects,
        # each taking one only while it sounds (see #emit_take_music_voice_routine for who gives way
        # when they run out). A slot's sounding word marks whose it is: 0 nobody's, OWNER_GAME the
        # game's, and a recorded part its own mark (Mixer.music_owner, or Mixer.ranked_owner in a
        # game whose sound effects play recordings).
        #
        # Owns the whole sampled-audio picture: registering samples as ROM data (asset
        # preparation, so it lives here beside the mix that uses what it prepares) and
        # the mix itself. @samples / @plays_samples are this object's own state, not
        # handed in — nothing outside sampled audio ever reads them.
        class Mixer
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[play_sample stop_sample].freeze

          def emit_statement(node)
            case node.kind
            when :play_sample then emit_play_sample(node)
            when :stop_sample then emit_stop_sample(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware

          # How many samples can sound at once — read from {Sound}, where the two backends
          # keep the promises they make to each other, rather than written down again here.
          MAX_VOICES = VBlank::Audio::Sound::MIXER_VOICES

          # The mix routine's inner loop runs once per output sample per voice — thousands
          # of times a frame. From ROM it would stall on a wait state at every instruction
          # fetch, so at boot the routine is copied into IWRAM (zero-wait-state internal RAM)
          # and called there. This is the IWRAM budget reserved for the copy; the build
          # fails if the emitted routine ever outgrows it.
          # Kept snug, because every byte of it is a byte the routines a frame spends its time in
          # do not get — this reservation and the game's own hot code come out of the same 32K.
          # The routine emits at 344 to 360 bytes (three of its immediates are the samples-per-frame
          # count or that count in words, each one instruction or two depending on the number, and a
          # game that shapes a note adds instructions to slide the gain), so this leaves a little
          # room to grow into. Outgrow it and the build says so by name rather than running over
          # whatever is next.
          #
          # It was 1024, which is four times what the routine has ever needed, and a real game
          # paid for it: on the Wolfenstein port the difference was exactly enough to push the routine
          # that draws every guard and every lamp out of the quick memory.
          MIX_ROUTINE_IWRAM_MAX = 384

          # How many output samples one pass of the inner loop mixes (see #emit_mix_routine). A
          # frame's samples are whole lots of the sound engine's, sixteen each, so this has to
          # divide sixteen. Two rather than four because each more is a copy of the body and of
          # its jump for a recording's end, in the quick memory: four would not fit the room
          # above, and growing the room takes it from every game that plays a recording, to
          # save a little under half as much again as two does.
          SAMPLES_A_PASS = 2

          # Timer 0 clocks the mixer's output rate (how fast the DMA hands bytes to the sound
          # FIFO).
          CLOCK_TIMER = 0

          # Timer 1 COUNTS those samples: it is chained to timer 0, so it goes up by one every
          # time the sound hardware takes a sample, and nothing else. It raises no interrupt and
          # costs nothing to run. What it is for is the hand-over, which reads it to learn exactly
          # how much of the last buffer the DMA has already taken (see #emit_mixer_handover).
          COUNT_TIMER = 1

          # While the mixer finds its feet at boot the sample clock runs this fast, in cycles a
          # sample, so the few lots it has to watch go by in a moment instead of a fraction of a
          # second (see #emit_find_lot_grid). Changing the clock's speed afterwards moves nothing
          # the watching found out, because that was counted in samples and not in time.
          CALIBRATION_PERIOD = 512

          # How late a hand-over can be and still play every lot in its place, in cycles. The
          # screen's interrupt waits for a DMA the game is in the middle of, and the longest one
          # the framework makes while a game runs is a whole-screen clear, about a fifth of a
          # frame. A third leaves room over. Each buffer carries this much sound past its end
          # (see #guard_lots), so this is what it costs: memory, and a copy of it once a frame.
          LATE_ROOM = Timers::FRAME_CYCLES / 3

          # Where the DMA's grid of lots falls against the sample count (0 to 15), found at boot.
          MIX_PHASE = :__mix_phase

          # Which lot, counting every lot the DMA has ever taken, the next hand-over's buffer is
          # meant to start at — kept less one, and shifted up to the top twelve bits so that the
          # counting wraps where the sample count does (see #emit_mixer_handover).
          MIX_LOT = :__mix_lot

          # A voice slot, in EWRAM: the sample's address in ROM, how far it has played (a whole
          # sample index), its length, how far back it goes at the end (0 for a sound that plays
          # once), whether it's sounding, its loudness (0..512), and — for pitch — a 16.16
          # fixed-point step (how many source samples to advance per output sample: 1.0 = 0x10000
          # plays at the recorded pitch, 2.0 an octave up) plus a FRAC accumulator carrying the
          # leftover fraction between frames, kept in its TOP 16 bits so that adding to it
          # overflows exactly when a whole sample is due (see #emit_mix_routine).
          #
          # Loop is a distance and not a flag, which is what lets a note be HELD: a piano
          # recorded for half a second and held for two reads round a point part way in rather
          # than starting over, so the attack is heard once and the body of the note goes on for
          # as long as the note does. A sound that loops in the ordinary way goes back by its
          # whole length, which is the same subtraction — so the mix has one case, not two, and
          # it is one instruction shorter than the flag was.
          #
          # A game sound's slot also keeps its TICKET — which play started it, counting up — so
          # the one playing longest can be told apart when a song's note needs its voice. A
          # sound that loops has the top bit set, which makes it later than every sound that
          # plays once, so it is the last to go.
          #
          # Then the envelope, for a voice that has one (see {VBlank::Audio::Envelope}): the four
          # numbers packed into ENV, where the level has climbed or fallen to, which phase of the
          # note it is in, GAIN — the loudness the mix actually multiplies by, which is VOL
          # scaled by that level — and ramp, how far the gain moves with each sample. ENV of 0
          # means no envelope at all, and then none of the four is ever read and the gain moves
          # only when the music volume does (see #emit_store_gain_unless_shaped).
          #
          # The level is worked out once a frame, by the pass before the mix. What the pass hands
          # the mix is not a new gain but a slide to it: how far the gain has to move by the end of
          # the frame, shared out over the frame's samples. A fade that took its steps at the frame
          # boundary would be a staircase, and every step of a staircase is a click — a fast
          # release falls most of the way in its first frame, so the first step is most of the
          # wave. Slid, the gain never moves further in one sample than a sixty-fourth of a frame's
          # worth of change, whatever fade was asked for.
          #
          # So the gain keeps a fraction under it (GAIN_FRACTION bits), which a slide needs: a
          # quiet fade moves the gain by far less than one whole step a sample. Each frame aims
          # at a whole loudness, and the next frame's slide starts from the whole loudness nearest
          # where the last one left the gain, so the rounding of one frame never carries into
          # the next (see #emit_envelope_step).
          SLOT_SRC = 0
          SLOT_POS = 4
          SLOT_LEN = 8
          SLOT_LOOP = 12
          SLOT_ACTIVE = 16
          SLOT_VOL = 20
          SLOT_STEP = 24
          SLOT_FRAC = 28
          SLOT_TICKET = 32
          SLOT_ENV = 36
          SLOT_LEVEL = 40
          SLOT_PHASE = 44
          SLOT_GAIN = 48
          SLOT_RAMP = 52
          SLOT_BYTES = 56

          # How many bits of fraction the gain keeps in a game that shapes a note, and how a
          # slide toward a gain is kept inside 32 bits — written down where the interpreter's mix
          # reads them too (see Sound::GAIN_FRACTION).
          GAIN_FRACTION = VBlank::Audio::Sound::GAIN_FRACTION
          RAMP_SPLIT = VBlank::Audio::Sound::RAMP_SPLIT

          # A slot's VOL is a loudness in 512ths and its GAIN 256ths with GAIN_FRACTION bits under
          # them: a loudness shifted up this far is its gain (see Sound::LOUDNESS_FRACTION).
          LOUDNESS_FRACTION = VBlank::Audio::Sound::LOUDNESS_FRACTION
          LOUDNESS_TO_GAIN = VBlank::Audio::Sound::LOUDNESS_TO_GAIN

          # The link register: where a routine returns to, and the one register the mix borrows
          # past r12 (see #emit_mix_routine).
          LR = 14

          # Which part of a note a voice is in. Climbing, then holding (which covers the fall to
          # the sustain level and the hold there — one test tells them apart, the level against
          # the sustain), then falling away after the note has ended — and then done, which is
          # the frame the gain spends sliding the last of the way to nothing. The voice is given
          # back at the END of that frame rather than the start of it, because a voice taken away
          # while its gain is still above nothing is the very click this is here to remove.
          PHASE_CLIMBING = 0
          PHASE_HOLDING = 1
          PHASE_FALLING = 2
          PHASE_DONE = 3

          # Whose a sounding slot is, in its sounding word: the game's, or a song's recorded part.
          OWNER_GAME = 1
          def self.music_owner(lane) = OWNER_GAME + 1 + lane

          # ...and in a game whose sound effects play recordings, whose it is and how it ranks
          # (IR::Tunes.song_rank), since a note of a song or an effect can then take the voice of
          # one ranked below it. The rank, one more so that every such mark sits above the game's,
          # goes above the part's own number. Comparing two marks shifted down by this many bits
          # compares their ranks, and two parts of one song or one effect rank the same, so never
          # take each other's voice.
          MARK_RANK_SHIFT = 5
          def self.ranked_owner(rank, lane) = ((rank + 1) << MARK_RANK_SHIFT) | lane

          TICKETS = :__mix_tickets # How many sounds the game has started, for the next ticket
          LOOPS_LAST = 0x8000_0000

          # What did not play, counted on the console so a run can be asked about it.
          #
          # A `play` that finds every voice busy is dropped — deliberately, rather than cutting
          # off a sound already sounding — and the console says nothing about it. Nothing on
          # screen does either: the game carries on, one sound quieter than the author wrote.
          # Whether it happens at all depends on play (a burst of explosions, a chord of music
          # under them), so no build can see it; only a run can, and a run is what `rom.profile`
          # reports on.
          #
          # Two words, both written on the drop path and nowhere else, so a game that never
          # runs out of voices pays for none of this beyond the miss branch it already had:
          #
          #   DROPS       — how many plays, and notes of songs and sound effects, found no voice.
          #   DROPS_MUSIC — the most voices songs and effects held at one of those moments. The count of
          #                 voices sounding needs no counting: a drop means every one of them
          #                 was. What the author cannot know without measuring is how the
          #                 music and the game's own sounds were splitting them, which is the
          #                 half they can do something about.
          DROPS = :__mix_drops
          DROPS_MUSIC = :__mix_drops_music

          # The fixed-point shift for STEP/FRAC: 16 fractional bits, so 1.0 == 1 << 16.
          STEP_SHIFT = VBlank::Audio::Sound::STEP_SHIFT
          STEP_ONE = 1 << STEP_SHIFT

          # One sounding voice, read back off a running console: which sample it is playing,
          # how far through it (a whole sample index), how long that sample is, how fast it
          # reads it (16.16 — STEP_ONE is the recorded pitch), whether it loops, its loudness
          # (0..512), and whose it is — :game, [:song, part] or [effect, part], the same answer the
          # interpreter's Reference#sound_owners gives. Values rather than addresses, so a test
          # asks what is playing and never learns where in memory it is kept.
          Voice = Data.define(:sample, :position, :length, :step, :loop, :volume, :owner)

          # Where the console keeps what it is playing, published by the build so the finished
          # cartridge can be asked about its own sound (see BuildRecord#voices).
          #
          # Nothing about the voices is hardware. The mixer is software this backend emits,
          # and it sums every voice into one sound channel before the hardware sees any of it,
          # so the only place the voices exist separately is this table in memory.
          # Reading it is reading what the lowering really did.
          #
          # The decoding lives here, beside the code that writes the table, so the slot layout
          # above is defined in one place and read in one place — a test that wants to know
          # what is sounding calls `verifier.voices` and never counts bytes into a slot.
          #
          # +sample_addresses+ maps each sample's name to where it landed in the cartridge,
          # which is how a slot's source address becomes a name again. Two samples with
          # identical bytes may share one address, and then a voice playing either reads back
          # as whichever was declared first.
          # +clock+ is the sample clock the build settled on (Timers.sample_clock), and it
          # belongs here because a voice's step is meaningless without it: a step of 1.0 means
          # "read the recording at this rate", so what pitch that comes out at depends on the
          # rate. It is also the one thing about the mixer an author might want to see, which
          # is why `rom.profile` reports it.
          #
          # +effect_marks+ turns the mark on a sound effect's voice back into [effect, part]. A game
          # with any has ranked marks (Mixer.ranked_owner) on its song's voices too.
          #
          # +mix_buffers+ is where the mix writes each frame, the two buffers it takes turns with, and
          # +front_at+ where it keeps which of them is playing (MIX_FRONT), so the newest frame of
          # mixed sound can be read off the console (#newest_mix). That is the cartridge's own sound,
          # byte for byte: what an emulator then hands its speaker is that sound resampled to the
          # emulator's own rate, at moments the emulator's timing settles, and a game's own transfers
          # into video memory move those moments a little, so two builds that mix alike can be heard
          # a little apart. Nil for a table made without them.
          VoiceTable = Data.define(:base, :count, :sample_addresses, :clock, :effect_marks, :mix_buffers, :front_at) do
            def initialize(effect_marks: {}, mix_buffers: nil, front_at: nil, **rest) = super

            # The frame of sound the mix wrote last, a signed sample each, read off the console a
            # byte at a time by the block given an address: the buffer that is not playing.
            def newest_mix
              buffer = yield(front_at).zero? ? mix_buffers[1] : mix_buffers[0]
              Array.new(clock.samples_a_frame) do |i|
                byte = yield(buffer + i) & 0xFF
                byte >= 128 ? byte - 256 : byte
              end
            end

            # The sounding voices, in slot order. The block reads one 32-bit word off the
            # console at the address it is given — the reader is handed in rather than owned,
            # so this can be tested against a plain Hash as easily as against an emulator.
            def read
              names = sample_addresses.invert
              (0...count).filter_map do |slot|
                at = base + (slot * SLOT_BYTES)
                mark = yield(at + SLOT_ACTIVE)
                next if mark.zero?

                Voice.new(sample: names[yield(at + SLOT_SRC)], position: yield(at + SLOT_POS),
                          length: yield(at + SLOT_LEN), step: yield(at + SLOT_STEP),
                          loop: !yield(at + SLOT_LOOP).zero?, volume: yield(at + SLOT_VOL),
                          owner: owner(mark))
              end
            end

            def owner(mark)
              return :game if mark == OWNER_GAME
              return effect_marks.fetch(mark) if effect_marks.key?(mark)
              return [:song, mark & ((1 << MARK_RANK_SHIFT) - 1)] unless effect_marks.empty?

              [:song, mark - Mixer.music_owner(0)]
            end
          end

          # Where the console counts what it could not play, published by the build the same
          # way the voice table is and for the same reason: the two words are hidden variables,
          # so their addresses exist only in the build and cannot be recovered from the
          # cartridge afterwards.
          #
          # +voices+ is how many there are in all, which is what makes the count mean something
          # — "12 dropped, the music held 9 of the 16" is a sentence; "12 dropped" is a number.
          DropTable = Data.define(:drops_at, :music_at, :voices) do
            # What the console has counted so far. The block reads one 32-bit word off it, the
            # same reader the voice table takes, so this can be read from a running emulator or
            # from a plain Hash.
            def read
              Diagnostics::SoundDrops::Reading.new(dropped: yield(drops_at), music_held: yield(music_at),
                                      voices: voices)
            end
          end

          # Volume level names → a 0..512 loudness the mix multiplies each sample by (then shifts
          # right by 9, i.e. divides by 512) — so :full leaves a sample unchanged and :half
          # halves it. The same words the other sound verbs use.
          MIX_LEVELS = VBlank::Audio::Sound::MIX_LEVELS
          VOL_SHIFT = VBlank::Audio::Sound::VOL_SHIFT # 2**8 = 256, a gain's whole steps (:full is 512 of a loudness's)

          # Which of the two output buffers the DMA is playing right now (0 or 1).
          MIX_FRONT = :__mix_front

          attr_reader :mix_buf0, :mix_buf1 # the two output buffers' addresses (a test reads them back)
          attr_reader :voice_base          # the voice slots' base address (a test reads a voice's state)

          def initialize(emitter:, memory:, timers:, primitives:)
            @emitter = emitter
            @memory = memory
            @timers = timers
            @primitives = primitives
            @samples = {}          # name -> { rate:, length: } (a Direct Sound PCM sample)
            @plays_samples = false # does the program play any sample (uses Direct Sound)?
            @music_takes_voices = false # does a song's or an effect's recorded part start notes in the slots?
            @songs_have_recorded_parts = false # ...a song's, in particular?
            @uses_envelopes = false # does any note in it have a shape (see #emit_envelope_step)?
            @effect_marks = {}      # a sound effect's part's mark -> [effect, part], when its notes rank
          end

          # The output rate the mix runs at, settled by #prepare_mixer.
          attr_reader :mixer_rate

          # Does the program play any sample (so the mixer needs bringing up)?
          def plays_samples?
            @plays_samples
          end

          # What a declared sample is — its rate, length and recorded note — for the music
          # player, which works out each note's step from them.
          def sample_info(name)
            @samples[name] ||
              raise(LoweringError, "play_sample of undefined sample #{name.inspect} — declare it with `sample`")
          end

          # A song's recorded parts start notes in the slots, so the mixer is brought up — and
          # the routine that finds a note its voice goes in the screen's interrupt.
          def music_takes_voices!
            @music_takes_voices = true
            @plays_samples = true
          end

          def music_takes_voices? = @music_takes_voices

          # ...asked for by a song's recorded part, as against a sound effect's (#ranks_voices!): its
          # marks come to the voice routines unranked in a game that ranks them (see
          # #emit_rank_song_mark).
          def songs_have_recorded_parts!
            music_takes_voices!
            @songs_have_recorded_parts = true
          end

          # Does a song's mark come to the voice routines with no rank, for them to put one on?
          def ranks_song_marks? = ranks_voices? && @songs_have_recorded_parts

          # ...and a sound effect's recorded parts do too, so every mark carries its rank
          # (Mixer.ranked_owner) and a note can take the voice of one ranked below it. +effect_marks+
          # is each effect part's mark, to [effect, part], for reading the voices back.
          def ranks_voices!(effect_marks)
            music_takes_voices!
            @effect_marks = effect_marks
          end

          def ranks_voices? = !@effect_marks.empty?

          # The slot nothing mixes, one past the last voice, kept in a game whose notes can find
          # no voice at all (#ranks_voices?): a note handed it is written there and never heard.
          # Every walk over the voices stops before it.
          def unmixed_slot_address = @voice_base + (MAX_VOICES * SLOT_BYTES)

          # +reg+ = the mark a voice of recorded lane +lane+ carries, from the rank already in +reg+
          # (Mixer.ranked_owner, worked out as the game runs).
          def emit_ranked_mark(reg, lane)
            @emitter.emit(ASM.add_imm(reg, reg, 1))
            @emitter.emit(ASM.lsl_imm(reg, reg, MARK_RANK_SHIFT))
            @emitter.emit(ASM.orr_imm(reg, reg, lane)) unless lane.zero?
          end

          # ...and a game that moves the music volume sets a part's note to the new level while it
          # sounds, so it needs to find the voice the note is on.
          def music_follows_level! = @music_follows_level = true

          # ...and that a recorded note can glide, bending the note its part has sounding, which
          # finds that note's voice the same way (Audio#emit_glide).
          def music_glides! = @music_glides = true

          # The routines that find a song's note a voice, stop it, and find the voice it is on
          # (#emit_music_voice_routines).
          MUSIC_VOICE = :__music_voice
          MUSIC_VOICE_OFF = :__music_voice_off
          MUSIC_VOICE_FIND = :__music_voice_find

          # Register the samples: embed each one's PCM data as a ROM blob and note the
          # program plays sound. #prepare_mixer reserves the timer and memory.
          def prepare_direct_sound(program)
            @main_volume = MainVolume.settings(program.main_volume)
            program.walk.each do |node|
              case node.kind
              when :sample
                @emitter.data_blobs[node.name] = node.bytes # embed the PCM data as a ROM blob
                @samples[node.name] = Assets::Sample.of(node)
              when :play_sample
                @plays_samples = true
              end
            end
          end

          # Decide the mixer's output rate and per-frame buffer size, and reserve its memory:
          # two output buffers and the voice slots in EWRAM, the running totals in IWRAM. The rate follows the
          # samples, so a single-rate game plays at its recorded pitch. Reserves only timer 0
          # (the sample clock) — the refill rides on the screen's own interrupt, not on a
          # second timer and not on the game loop.
          # What the mixing routine is called, and where it RUNS — which is not where it is
          # stored. It is copied into the console's quick memory at boot, like the divide
          # routines, because it runs over every sample of every sounding voice once a frame
          # and is one of the busiest things in a game that plays sampled sound.
          #
          # That is exactly why a measured profile has to be able to name it: on
          # the Wolfenstein port, which plays sampled audio, it is about a fifth of the frame, and
          # without this it reads as code nothing can account for.
          ROUTINE = :__mix_routine

          def mix_routine_addresses
            return {} unless @mix_routine_iwram

            { ROUTINE => @mix_routine_iwram...(@mix_routine_iwram + @emitter.routine_bytes(ROUTINE)) }
          end

          # Where the voices are kept and where each sample landed, for the build record to
          # carry — or nil for a program that plays no samples and so has no voices at all.
          # Valid after the program is laid out, when every sample's position is known. A
          # sample's run-time address is the same cartridge arithmetic a data load is patched
          # with: base, plus the header, plus where the blob sits.
          def voice_table
            return nil unless @voice_base

            VoiceTable.new(base: @voice_base, count: MAX_VOICES, clock: @sample_clock, effect_marks: @effect_marks,
                           mix_buffers: [@mix_buf0, @mix_buf1], front_at: @primitives.var_addr(MIX_FRONT),
                           sample_addresses: @samples.keys.to_h do |name|
                             [name, ROM_START + VBlank::Cartridge::ROM::ENTRY_OFFSET + @emitter.data_positions.fetch(name)]
                           end)
          end

          # Where the console counts the sounds it could not play, for the build record to
          # carry — or nil for a program that plays no samples, which can lose none.
          def drop_table
            return nil unless @voice_base

            DropTable.new(drops_at: @primitives.var_addr(DROPS),
                          music_at: @primitives.var_addr(DROPS_MUSIC), voices: MAX_VOICES)
          end

          def prepare_mixer(program)
            return unless @plays_samples

            @uses_envelopes = IR::Mixing.shapes_any_note?(program)

            # The clock and the samples-a-frame are one decision, not two: the hardware eats a
            # sample every time this timer overflows, so how many it eats in a frame is fixed
            # by the clock, and that is exactly how many the mix has to write. Asking for both
            # separately is how they came to disagree. See Timers.sample_clock.
            @sample_clock = Timers.sample_clock(IR::Mixing.requested_rate(program))
            @mixer_rate = @sample_clock.rate
            @mixer_spf = @sample_clock.samples_a_frame
            refuse_samples_not_whole_passes!
            @mix_buf0 = @memory.alloc_roomy(buffer_bytes)
            @mix_buf1 = @memory.alloc_roomy(buffer_bytes)
            # What goes in the quick memory is decided by how often the mix touches it. The
            # running total of every voice — a halfword per output sample, read and written
            # again for every voice at every sample — goes there. The voice slots do not: the
            # mix reads a sounding voice's slot once a frame and writes it back once, so they
            # cost the same in the roomy memory, and the room they would have taken is the room
            # the totals need.
            @mix_totals = @memory.alloc(@mixer_spf * 2)
            # ...and in a game whose notes can find no voice at all, one slot more past the end,
            # which nothing mixes: where such a note is written (see #unmixed_slot_address).
            @voice_base = @memory.alloc_roomy(Mixer.voice_slots_bytes(ranks_voices?))
            @mix_routine_iwram = @memory.alloc(MIX_ROUTINE_IWRAM_MAX) # the mix routine is copied here from ROM at boot
            @timers.reserve!(COUNT_TIMER + 1, because: "Sampled sound uses two of them: one to play the " \
                                                       "sound, and one to count how much of it has played.")
          end

          # The lots each buffer carries past its end: enough of the next buffer's start to cover
          # a hand-over LATE_ROOM late, rounded up to whole lots.
          def guard_lots = Mixer.guard_lots(@sample_clock)

          def self.guard_lots(clock)
            lot = Timers::DMA_SAMPLES_A_LOT * clock.period
            (LATE_ROOM + lot - 1) / lot
          end

          # One output buffer's bytes at +clock+: a frame's samples and the guard lots past them.
          def self.buffer_bytes(clock) = clock.samples_a_frame + (guard_lots(clock) * Timers::DMA_SAMPLES_A_LOT)

          # The voice slots' bytes, with the slot nothing mixes where notes are +ranked+ (#ranks_voices?).
          def self.voice_slots_bytes(ranked) = (MAX_VOICES + (ranked ? 1 : 0)) * SLOT_BYTES

          # How much of the roomy memory the mixer will keep for +program+, read off the program
          # before it is lowered, for the build's memory check (Roomy.reserved_by_build): the two
          # output buffers and the voice slots, as #prepare_mixer claims them, or nought for a
          # program that mixes nothing. +ranked+ is whether a sound effect's recorded part ranks
          # the voices (Audio#prepare_sound_effects calls #ranks_voices! for one).
          def self.roomy_bytes(program, ranked:)
            return 0 unless IR::Mixing.mixes?(program)

            clock = Timers.sample_clock(IR::Mixing.requested_rate(program))
            (2 * Memory.whole_words(buffer_bytes(clock))) + Memory.whole_words(voice_slots_bytes(ranked))
          end

          # How far off the next sample has to be, in cycles, for the hand-over to read the count
          # and re-arm the DMA before it comes. That is about fifteen instructions, and 512 cycles
          # is several times what they take even from the cartridge at its slowest timing; a
          # clock too fast to leave that much of a sample clear gets three quarters of one
          # instead. It has to stay short of a whole sample, or the wait would never end.
          def count_clearance = [@sample_clock.period * 3 / 4, 512].min

          def lots_a_frame = @mixer_spf / Timers::DMA_SAMPLES_A_LOT

          def buffer_bytes = Mixer.buffer_bytes(@sample_clock)

          # Bring the mixer up at boot: silence the voice slots and both buffers, power on
          # the sound hardware, point the DMA at the first buffer and the sample clock at the
          # mixer rate. From here the DMA plays silence until a voice is added.
          def emit_mixer_boot
            emit_zero_region(@voice_base, MAX_VOICES * SLOT_BYTES) # all voices idle
            emit_zero_region(@mix_totals, @mixer_spf * 2)          # the totals start at nothing
            emit_zero_region(@mix_buf0, buffer_bytes)              # buffers start silent...
            emit_zero_region(@mix_buf1, buffer_bytes)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MIX_FRONT)                  # ...playing buffer 0 first
            # Nothing has been lost yet, and this has to be written rather than assumed: the
            # console's memory is not zero at power-on, so a counter left unwritten reads as
            # whatever was there and a game that dropped nothing would report rubbish.
            @primitives.store_var(ACC, DROPS)
            @primitives.store_var(ACC, DROPS_MUSIC)
            # A lot half the count away from any the DMA could be on, so the first hand-over
            # finds it out of reach and starts the counting from wherever the DMA really is.
            @emitter.emit(ASM.load_immediate(ACC, 0x8000_0000))
            @primitives.store_var(ACC, MIX_LOT)

            @emitter.write_reg16(REG_SOUNDCNT_X, sound_power)           # master sound on (off at a main volume of nothing)
            @emitter.write_reg16(REG_SOUNDCNT_H, direct_sound_a_config) # channel A at the main volume, FIFO reset
            @emitter.emit(ASM.load_immediate(ACC, @mix_buf0))
            store_reg_ioreg(ACC, REG_DMA1SAD)                      # DMA source = buffer 0
            @primitives.store_word_immediate(REG_FIFO_A, REG_DMA1DAD) # DMA dest = the sound FIFO
            # ...feeding it continuously, and for now saying so each time it does (see below).
            @primitives.store_word_immediate(dma_fifo_control | DMA_IRQ, REG_DMA1CNT)

            # Timer 1 counts the samples from nothing. It is started first: chained, it waits
            # for timer 0, so it counts every sample timer 0 ever clocks.
            @emitter.write_reg16(@timers.timer_reg_l(COUNT_TIMER), 0)
            @emitter.write_reg16(@timers.timer_reg_h(COUNT_TIMER), TIMER_ENABLE | TIMER_CASCADE)
            @emitter.write_reg16(@timers.timer_reg_l(CLOCK_TIMER), 65_536 - CALIBRATION_PERIOD)
            @emitter.write_reg16(@timers.timer_reg_h(CLOCK_TIMER), TIMER_ENABLE | Timers::FINEST_PRESCALER)

            emit_find_lot_grid

            # Now timer 0 = the sample clock, written as the period the clock was chosen as rather
            # than by asking for its rate back: going through a rate would divide and truncate
            # a second time, and land a cycle or two off the period a frame divides. The new
            # period is taken up at the next sample, without restarting anything.
            @emitter.write_reg16(@timers.timer_reg_l(CLOCK_TIMER), 65_536 - @sample_clock.period)
            # Back to the start of buffer 0, with the DMA no longer announcing every lot.
            @emitter.emit(ASM.load_immediate(ACC, @mix_buf0))
            store_reg_ioreg(ACC, REG_DMA1SAD)
            emit_rearm_dma

            emit_copy_mix_routine_to_iwram
          end

          # Where the DMA's lots fall against the sample count — which of every sixteen samples
          # is the one the sound hardware asks for more on. The hand-over needs it to turn a
          # count of samples into a count of lots, and it is the one fact about the sound
          # hardware that cannot be written down ahead of time: the asking follows how full the
          # FIFO is, and a FIFO starting from empty asks a few times out of step before it
          # settles, differently on different hardware. Once settled it never moves.
          #
          # So it is watched. The DMA was told to raise its flag each time it moves a lot; this
          # waits for the flag, reads the sample count at once, and stops at the first two lots
          # exactly sixteen samples apart, which is the grid settled. The DMA's interrupt is not
          # armed, so nothing else clears the flag, and the count is read long before the next
          # sample: a turn of the loop is a few instructions, and a sample is CALIBRATION_PERIOD
          # cycles. In a game that reads frames since power-on the screen's interrupt is armed
          # already (GBA#emit_arm_frame_counting); its handler clears only the screen's flag, and
          # a frame landing between the flag and the read delays the read by the BIOS's way in and
          # out of an interrupt and that handler's few instructions, still well inside the sample.
          #
          # If the flag never comes — which it always does, but a boot that hangs is the one
          # failure nobody can see the cause of — it gives up after a while and takes 0. The sound
          # still plays; a game busy past the end of its frame may click where the guess is wrong.
          def emit_find_lot_grid
            e = @emitter
            wait = e.gensym
            found = e.gensym
            gave_up = e.gensym
            e.emit(ASM.push(4))
            e.emit(ASM.load_immediate(ADDR, REG_IF))
            e.emit(ASM.load_immediate(3, @timers.timer_reg_l(COUNT_TIMER)))
            e.emit(ASM.load_immediate(4, IRQ_DMA1))
            e.emit(ASM.load_immediate(2, 0x10000))     # the last lot's count: none yet
            e.emit(ASM.load_immediate(1, 0x10000))     # turns of the loop before giving up
            e.emit(ASM.store_halfword(4, ADDR))        # clear a flag left from before
            e.place_label(wait)
            e.emit(ASM.subs_imm(1, 1, 1))
            e.emit_branch(:bcond, gave_up, cond: :eq)
            e.emit(ASM.load_halfword(ACC, ADDR))
            e.emit(ASM.tst_imm(ACC, IRQ_DMA1))
            e.emit_branch(:bcond, wait, cond: :eq)     # no lot moved yet
            e.emit(ASM.load_halfword(ACC, 3))          # the count, the moment one did
            e.emit(ASM.store_halfword(4, ADDR))        # and clear its flag for the next
            e.emit(ASM.sub_reg(2, ACC, 2))
            e.emit(ASM.cmp_imm(2, Timers::DMA_SAMPLES_A_LOT))
            e.emit(ASM.mov_reg(2, ACC))
            e.emit_branch(:bcond, wait, cond: :ne)     # not a lot's worth since the last: not settled
            e.emit(ASM.and_imm(ACC, ACC, Timers::DMA_SAMPLES_A_LOT - 1))
            e.emit_branch(:b, found)
            e.place_label(gave_up)
            e.emit(ASM.load_immediate(ACC, 0))
            e.place_label(found)
            e.emit(ASM.pop(4))
            @primitives.store_var(ACC, MIX_PHASE)
          end

          # Copy the mix routine from ROM into IWRAM once, at boot, so its per-sample inner
          # loop runs with no ROM wait states. The routine is position-independent — relative
          # branches, immediates built with MOV/ORR (no PC-relative literal pool) — so it runs
          # correctly from either place, and the ARM7 has no instruction cache, so the copy
          # needs no flush. Copies whole words from the routine's start label up to its end.
          def emit_copy_mix_routine_to_iwram
            @emitter.emit_load_label_address(0, ROUTINE)                            # r0 = routine start in ROM
            @emitter.emit_load_label_address(1, DerivedNames.routine_end(ROUTINE))  # r1 = routine end in ROM
            @emitter.emit(ASM.load_immediate(2, @mix_routine_iwram)) # r2 = IWRAM destination
            copy = @emitter.gensym
            @emitter.place_label(copy)
            @emitter.emit(ASM.ldr(3, 0))                             # r3 = [r0]
            @emitter.emit(ASM.str(3, 2))                             # [r2] = r3
            @emitter.emit(ASM.add_imm(0, 0, 4))
            @emitter.emit(ASM.add_imm(2, 2, 4))
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, copy, cond: :lt)            # while r0 < r1
          end

          # play_sample: start a sample sounding by filling a free voice slot with it — its
          # ROM address, a fresh play position, its length, whether it loops, and its ticket.
          # If every slot is busy the play is dropped, rather than cutting off a sound already
          # playing.
          def emit_play_sample(node)
            sample = sample_info(node.name)
            holding_off_interrupts do
              @emitter.emit_load_data_address(4, node.name) # r4 = the sample's address in ROM
              emit_find_free_voice                          # r0 = a free slot's address, or none -> skip
              done = @emitter.gensym
              @emitter.emit(ASM.cmp_imm(0, 0))        # emit_find_free_voice leaves r0 = 0 when full
              @emitter.emit_branch(:bcond, done, cond: :eq)

              @emitter.emit(ASM.str(4, 0))                             # slot.src = address (SLOT_SRC = 0)
              @emitter.emit(ASM.load_immediate(TMP, 0))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_POS))          # slot.pos = 0
              @emitter.emit(ASM.load_immediate(TMP, sample.length))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_LEN))          # slot.len = length
              @emitter.emit(ASM.load_immediate(TMP, loop_back_distance(node, sample)))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_LOOP))         # how far back at the end
              @emitter.emit(ASM.load_immediate(TMP, MIX_LEVELS.fetch(node.volume, MIX_LEVELS[:full])))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_VOL))          # slot.volume (0..512 loudness)
              emit_start_envelope(0, TMP, sample.envelope, MIX_LEVELS.fetch(node.volume, MIX_LEVELS[:full])) if @uses_envelopes
              @emitter.emit(ASM.load_immediate(TMP, voice_step(node, sample)))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_STEP))         # slot.step (pitch + rate, 16.16)
              @emitter.emit(ASM.load_immediate(TMP, 0))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_FRAC))         # slot.frac = 0 (fresh)
              @primitives.load_var(2, TICKETS)
              @emitter.emit(ASM.add_imm(2, 2, 1))
              @primitives.store_var(2, TICKETS)                        # the next ticket...
              @emitter.emit(ASM.orr_imm(2, 2, LOOPS_LAST)) if node.loop # ...after every one-shot, if it loops
              @emitter.emit(ASM.str_offset(2, 0, SLOT_TICKET))
              @emitter.emit(ASM.load_immediate(TMP, OWNER_GAME))
              @emitter.emit(ASM.str_offset(TMP, 0, SLOT_ACTIVE))       # slot.active: the game's (now it sounds)
              @emitter.place_label(done)
            end
          end

          # How far back a voice goes when it reaches the end of its recording, or 0 for one that
          # plays once and stops. A sound asked to loop goes back to where the recording holds
          # from — which for a recording with no hold point is its very start, so the ordinary
          # loop is this same subtraction.
          def loop_back_distance(node, sample)
            return 0 unless node.loop

            held = sample.loop_length
            held.positive? ? held : sample.length
          end

          # The four numbers and where the sound starts, written onto a voice the game is about to
          # sound at +loudness+ (out of 512). A voice with no envelope writes 0 for the four, which
          # is what tells the pass before the mix to leave it alone — its gain is its loudness, and
          # moves only when the music volume does.
          #
          # A shaped sound starts its shape as it is played (Reference::Mixer#start): the game plays
          # in its pass, after the pass that moves the shapes and before the frame's mix, so one
          # started at nothing would be mixed once at nothing — a strike at full silent for a frame,
          # and a recording shorter than a frame never heard. So it starts one step up, at the level
          # its attack gives it, and its gain there with no slide (Audio::Envelope.whole_gain). The
          # shape and the volume are both known as the game is built, so the level, the phase and
          # the gain are numbers the build works out, and the voice is only told them.
          # +slot+ holds the voice's address and +scratch+ is a register free to be clobbered.
          def emit_start_envelope(slot, scratch, envelope, loudness)
            shape = envelope && !envelope.plain? ? envelope : nil
            level, phase = shape ? shape.step(0, VBlank::Audio::Envelope::CLIMBING) : [VBlank::Audio::Envelope::FULL, nil]
            @emitter.emit(ASM.load_immediate(scratch, shape ? shape.packed : 0))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_ENV))
            @emitter.emit(ASM.load_immediate(scratch, level))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_LEVEL))
            @emitter.emit(ASM.load_immediate(scratch, phase == VBlank::Audio::Envelope::HOLDING ? PHASE_HOLDING : PHASE_CLIMBING))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_PHASE))
            # The gain the mix reads, and no slide.
            @emitter.emit(ASM.load_immediate(scratch, 0))
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_RAMP))
            if shape
              @emitter.emit(ASM.load_immediate(scratch, VBlank::Audio::Envelope.whole_gain(loudness, level)))
            else
              @emitter.emit(ASM.ldr_offset(scratch, slot, SLOT_VOL))
              @emitter.emit(ASM.lsl_imm(scratch, scratch, LOUDNESS_TO_GAIN))
            end
            @emitter.emit(ASM.str_offset(scratch, slot, SLOT_GAIN))
          end

          # A note's loudness has moved and the voice at +slot+ is to play it at +loudness+: the
          # gain the mix reads becomes that loudness moved up into the gain's fraction — unless
          # the voice has a shape, whose pass before the mix works its gain out every frame.
          # Called only in a game that shapes notes; in one that shapes none the mix reads the
          # loudness itself. Clobbers +loudness+ (shifted up in place) and +scratch+.
          def emit_store_gain_unless_shaped(slot, loudness, scratch)
            shaped = @emitter.gensym
            @emitter.emit(ASM.ldr_offset(scratch, slot, SLOT_ENV))
            @emitter.emit(ASM.cmp_imm(scratch, 0))
            @emitter.emit_branch(:bcond, shaped, cond: :ne)
            @emitter.emit(ASM.lsl_imm(loudness, loudness, LOUDNESS_TO_GAIN))
            @emitter.emit(ASM.str_offset(loudness, slot, SLOT_GAIN))
            @emitter.place_label(shaped)
          end

          # The 16.16 step for a voice: how many source samples to advance per output sample.
          # It rolls the sample's own rate against the mixer's output rate (so an off-rate
          # clip still sounds right) and the pitch shift (playing at a note other than the
          # sample's recorded one reads it faster or slower). At least 1, so it never stalls.
          def voice_step(node, sample)
            notes = VBlank::Audio::Music::NOTE_FREQUENCIES
            step_at(sample, notes.fetch(node.pitch || sample.note || :C4))
          end

          # The 16.16 step that sounds +sample+ at +frequency+ Hz at the rate this mix runs at (see
          # IR::Mixing.step).
          def step_at(sample, frequency) = IR::Mixing.step(sample, frequency, @mixer_rate)

          # stop_sample: silence a sample by clearing every voice slot playing it (or every
          # slot, when no sample is named). Just flips each matching slot's "active" off. The
          # game's own sounds only: a note the music is playing is the music's to stop.
          def emit_stop_sample(node = nil)
            name = node && node.name
            holding_off_interrupts do
              @emitter.emit_load_data_address(4, name) if name # r4 = the sample's address to match
              @emitter.emit(ASM.load_immediate(1, @voice_base))                            # r1 = slot pointer
              @emitter.emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES))) # r2 = past the last
              loop_lbl = @emitter.gensym
              skip = @emitter.gensym
              @emitter.place_label(loop_lbl)
              @emitter.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
              @emitter.emit(ASM.cmp_imm(0, OWNER_GAME))
              @emitter.emit_branch(:bcond, skip, cond: :ne)              # not a sound of the game's
              if name
                @emitter.emit(ASM.ldr(0, 1))                             # r0 = slot.src
                @emitter.emit(ASM.cmp_reg(0, 4))                         # slot plays this sample?
                @emitter.emit_branch(:bcond, skip, cond: :ne)            # no -> leave it
              end
              @emitter.emit(ASM.load_immediate(0, 0))
              @emitter.emit(ASM.str_offset(0, 1, SLOT_ACTIVE))           # active = 0
              @emitter.place_label(skip)
              @emitter.emit(ASM.add_imm(1, 1, SLOT_BYTES))               # next slot
              @emitter.emit(ASM.cmp_reg(1, 2))
              @emitter.emit_branch(:bcond, loop_lbl, cond: :lt)
            end
          end

          # The game touches the voice table with interrupts held off. The screen's interrupt can
          # take a voice for a song's note between any two instructions, so a slot `play` has
          # just seen free, or one `stop` has just seen is the game's, could be the song's by the
          # time the game writes to it — and the game would start its sound over a note, or cut
          # the note off. With interrupts held off for the few dozen instructions the game
          # spends in the table, the interrupt waits and then sees it whole. r3 keeps what the
          # master switch was, so it is put back as it was found.
          def holding_off_interrupts
            @emitter.emit(ASM.load_immediate(TMP, REG_IME))
            @emitter.emit(ASM.load_halfword(3, TMP))
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
            yield
            @emitter.emit(ASM.load_immediate(TMP, REG_IME))
            @emitter.emit(ASM.store_halfword(3, TMP))
          end

          # A note of a song's recorded part needs a voice — the call the music player makes, from
          # the screen's interrupt, with the part's mark in r8. Leaves the voice in r7.
          def emit_take_music_voice
            emit_call_voice_routine(MUSIC_VOICE)
          end

          # ...and a part rests, or its tune stops: whichever voice has the part's mark (r8) goes
          # quiet.
          def emit_music_voice_off
            emit_call_voice_routine(MUSIC_VOICE_OFF)
          end

          # ...and the voice sounding the part's note (r8) is wanted in r7, or 0 when it has none.
          def emit_find_music_voice
            emit_call_voice_routine(MUSIC_VOICE_FIND)
          end

          # The calls above made from outside the screen's interrupt, for the length of the block:
          # +call+ is handed each routine's label and writes the call. The routines sit inside the
          # interrupt's own routine, which may be in the quick memory while the code calling them
          # is in the cartridge, too far apart for a plain jump (see Audio#emit_sound_effect_step_routine).
          def calling_voice_routines_through(call)
            @call_voice_routine = call
            yield
          ensure
            @call_voice_routine = nil
          end

          def emit_call_voice_routine(label)
            @call_voice_routine ? @call_voice_routine.call(label) : @emitter.emit_branch(:bl, label)
          end

          # The routines those call, emitted once inside the screen's interrupt.
          def emit_music_voice_routines
            emit_take_music_voice_routine
            emit_music_voice_off_routine
            emit_music_voice_find_routine if @music_follows_level || @music_glides
          end

          # A tune's mark comes without its rank, and each routine below puts it on as it starts,
          # in a game whose sound effects play recordings (see Audio#emit_song_mark for why it
          # is here and not at the places that call). A mark with a rank is an effect's, which
          # comes ranked already, and is left alone: every rank, one more than itself, sits
          # above the lane's bits. Uses r0 and r12, and only for a tune's mark.
          #
          # The mark is Mixer.ranked_owner's, which #emit_ranked_mark also writes; the rank goes
          # in shifted as it is ORed, one instruction fewer than working the ranked half out first.
          def emit_rank_song_mark
            e = @emitter
            ranked = e.gensym
            e.emit(ASM.cmp_imm(8, 1 << MARK_RANK_SHIFT))
            e.emit_branch(:bcond, ranked, cond: :hs)
            @primitives.load_var(0, Audio::MUSIC_RANK)
            e.emit(ASM.add_imm(0, 0, 1))
            e.emit(ASM.orr_reg_lsl(8, 8, 0, MARK_RANK_SHIFT))
            e.place_label(ranked)
          end

          # The voice sounding the part's note (r8's mark) into r7, or 0 when the part has none —
          # its recording ran out and the mix retired it, or it rested. A voice of the part's that
          # is falling away is an earlier note on its way out, not this one, and is passed over:
          # the same reading #emit_music_voice_off_routine makes. Uses r0, r1, r7, and r12 for a
          # tune's mark that comes unranked (#emit_rank_song_mark).
          def emit_music_voice_find_routine
            e = @emitter
            scan = e.gensym
            onward = e.gensym
            done = e.gensym
            e.place_label(MUSIC_VOICE_FIND)
            emit_rank_song_mark if ranks_song_marks?
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            e.emit_branch(:bcond, onward, cond: :ne)
            if @uses_envelopes
              e.emit(ASM.ldr_offset(0, 7, SLOT_PHASE))
              e.emit(ASM.cmp_imm(0, PHASE_FALLING))
              e.emit_branch(:bcond, onward, cond: :hs)
            end
            e.emit_branch(:b, done)
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.load_immediate(7, 0))
            e.place_label(done)
            e.emit(ASM.return)
          end

          # Stop the voice sounding the part's note (r8's mark) — or nothing, when the part has
          # none: its last note ran out, and the mix retired it. Uses r0, r1, r7, and r12 for a
          # tune's mark that comes unranked (#emit_rank_song_mark).
          #
          # A shaped note is not stopped here, it is only told to start falling. What ends it is
          # the pass before the mix, when its level has fallen away to nothing — which is the
          # whole point, because a note that stops leaves the speaker wherever the wave was and
          # that jump is a click. A voice with no envelope stops the moment it is told to, as it
          # always did.
          #
          # A voice of the part's that is already falling is passed over: that is an earlier note
          # on its way out, and the one to let go of is the note sounding now.
          def emit_music_voice_off_routine
            e = @emitter
            scan = e.gensym
            onward = e.gensym
            done = e.gensym
            e.place_label(MUSIC_VOICE_OFF)
            emit_rank_song_mark if ranks_song_marks?
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            e.emit_branch(:bcond, onward, cond: :ne)
            if @uses_envelopes
              stop = e.gensym
              e.emit(ASM.ldr_offset(0, 7, SLOT_PHASE))
              e.emit(ASM.cmp_imm(0, PHASE_FALLING))
              e.emit_branch(:bcond, onward, cond: :hs)        # an earlier note, already on its way out
              e.emit(ASM.ldr_offset(0, 7, SLOT_ENV))
              e.emit(ASM.cmp_imm(0, 0))
              e.emit_branch(:bcond, stop, cond: :eq)          # no envelope: it stops where it is
              e.emit(ASM.load_immediate(0, PHASE_FALLING))
              e.emit(ASM.str_offset(0, 7, SLOT_PHASE))        # ...otherwise it starts falling
              e.emit_branch(:b, done)
              e.place_label(stop)
            end
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 7, SLOT_ACTIVE))
            e.emit_branch(:b, done)
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.place_label(done)
            e.emit(ASM.return)
          end

          # Which voice a song's note gets — one routine, placed inside the screen's interrupt
          # (so it moves with it into the quick memory) and called by every recorded part.
          #
          # In one walk over the slots it looks for, in order of preference:
          #
          #   1. the part's own voice, still sounding its last note with no shape to it — the new
          #      note takes it over;
          #   2. the first voice nobody is using;
          #   3. the quietest voice whose note has ended and is falling away (a tail, below);
          #   4. with none of those, the voice of the game's sound that has been playing longest —
          #      one that plays once before one that loops, since a loop never ends by itself.
          #      That is the rule for who gives way: a song keeps playing right, and a sound the
          #      game started a while ago is cut short.
          #
          # A part's note that has a shape is not taken over. It is told its note has ended, and
          # falls away on the voice it has while the new note takes another. Taking it over would
          # start the new recording from its top on that voice, and the old wave would stop dead
          # wherever it was — which is the click the shape is there to remove, put back one note
          # later. A falling voice is the first thing to give way, being on its way out already,
          # and the quietest of them first, since cutting that one short is the smallest jump.
          #
          # There is always a 4 when there is no 1, 2 or 3 in a game with no sound effect that
          # plays a recording: a part has one note sounding at most, and a song has fewer recorded
          # parts than there are voices, so a table full of voices that are neither free nor
          # falling has a game sound in it. It runs in the interrupt, where the game cannot be in
          # the table — `play` and `stop` hold interrupts off while they are.
          #
          # In a game whose sound effects play recordings, a voice can be full of song and effect
          # notes, so the rule goes on (see Mixer.ranked_owner):
          #
          #   5. with no game sound either, the voice of the lowest-ranked note ranked below this
          #      one — the first of them, when two rank the same;
          #   6. and with none of those, no voice: r7 is the slot nothing mixes (#unmixed_slot_address),
          #      so the note is written where it is never heard, and it is counted with the
          #      sounds that did not play (#emit_count_dropped_sound). A slot rather than a 0
          #      to test for, because the test was written out again at every place a recorded
          #      part starts a note, and the slot is in the roomy memory, not the quick one.
          #
          # In: r8 = the part's mark. Out: r7 = the voice. Uses r0, r1, r9-r12 — and, in a game that
          # shapes a note, r2 and r3 as well, and in one that ranks its voices r2-r5, which it keeps
          # on the stack because the player needs them back. Returns through lr, which the
          # interrupt saved.
          def emit_take_music_voice_routine
            e = @emitter
            done = e.gensym
            scan = e.gensym
            busy = e.gensym
            onward = e.gensym
            ranked = e.gensym
            kept = ranks_voices? ? [2, 3, 4, 5] : @uses_envelopes ? [2, 3] : []
            e.place_label(MUSIC_VOICE)
            emit_rank_song_mark if ranks_song_marks?
            e.emit(ASM.push(*kept)) unless kept.empty?
            e.emit(ASM.load_immediate(7, @voice_base))
            e.emit(ASM.load_immediate(1, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.load_immediate(9, 0))                    # the first free voice, none yet
            e.emit(ASM.mvn_imm(11, 0))                          # the oldest ticket so far: none, the largest there is
            e.emit(ASM.load_immediate(10, 0))                   # ...and its voice
            if @uses_envelopes
              e.emit(ASM.mvn_imm(3, 0))                         # the quietest tail so far: none, the loudest there is
              e.emit(ASM.load_immediate(ADDR, 0))               # ...and its voice
            end
            if ranks_voices?
              e.emit(ASM.lsr_imm(5, 8, MARK_RANK_SHIFT))        # the lowest rank so far: none below this note's
              e.emit(ASM.load_immediate(4, 0))                  # ...and its voice
            end
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 7, SLOT_ACTIVE))
            e.emit(ASM.cmp_reg(0, 8))
            if @uses_envelopes
              emit_weigh_part_own_voice(onward, done)
            else
              e.emit_branch(:bcond, done, cond: :eq)            # 1. the part's own
            end
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, busy, cond: :ne)
            e.emit(ASM.cmp_imm(9, 0))
            e.emit(ASM.mov_reg_cond(:eq, 9, 7))                 # 2. the first free one
            e.emit_branch(:b, onward)
            e.place_label(busy)
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            other = ranks_voices? ? ranked : onward
            if @uses_envelopes
              emit_weigh_other_part_voice(onward, sounding: other)
            else
              e.emit_branch(:bcond, other, cond: :ne)           # another part's
            end
            e.emit(ASM.ldr_offset(0, 7, SLOT_TICKET))
            e.emit(ASM.cmp_reg(0, 11))
            e.emit(ASM.mov_reg_cond(:lo, 11, 0))                # 4. the game sound playing longest
            e.emit(ASM.mov_reg_cond(:lo, 10, 7))
            if ranks_voices?
              e.emit_branch(:b, onward)
              e.place_label(ranked)
              e.emit(ASM.lsr_imm(0, 0, MARK_RANK_SHIFT))
              e.emit(ASM.cmp_reg(0, 5))
              e.emit(ASM.mov_reg_cond(:lo, 5, 0))               # 5. the lowest rank below this note's
              e.emit(ASM.mov_reg_cond(:lo, 4, 7))
            end
            e.place_label(onward)
            e.emit(ASM.add_imm(7, 7, SLOT_BYTES))
            e.emit(ASM.cmp_reg(7, 1))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.mov_reg(7, 9))
            e.emit(ASM.cmp_imm(7, 0))
            e.emit_branch(:bcond, done, cond: :ne)
            if @uses_envelopes
              e.emit(ASM.mov_reg(7, ADDR))                      # 3. the quietest tail
              e.emit(ASM.cmp_imm(7, 0))
              e.emit_branch(:bcond, done, cond: :ne)
            end
            e.emit(ASM.mov_reg(7, 10))
            if ranks_voices?
              e.emit(ASM.cmp_imm(7, 0))
              e.emit_branch(:bcond, done, cond: :ne)
              e.emit(ASM.mov_reg(7, 4))
              e.emit(ASM.cmp_imm(7, 0))
              e.emit_branch(:bcond, done, cond: :ne)
              emit_count_dropped_sound                                    # 6. no voice at all
              e.emit(ASM.load_immediate(7, unmixed_slot_address))
            end
            e.place_label(done)
            e.emit(ASM.pop(*kept)) unless kept.empty?
            e.emit(ASM.return)
          end

          # 1, in a game that shapes a note: the part's own voice, with the flags of comparing its
          # mark still up. A sounding note with no shape is taken over; one with a shape is told its
          # note has ended and weighed as a tail like any other; and a voice of the part's that is
          # already falling is a tail already. Anything that is not the part's falls through to
          # the free and busy tests.
          def emit_weigh_part_own_voice(onward, done)
            e = @emitter
            others = e.gensym
            tail = e.gensym
            e.emit_branch(:bcond, others, cond: :ne)
            e.emit(ASM.ldr_offset(2, 7, SLOT_PHASE))
            e.emit(ASM.cmp_imm(2, PHASE_FALLING))
            e.emit_branch(:bcond, tail, cond: :hs)              # an earlier note of the part's, falling
            e.emit(ASM.ldr_offset(2, 7, SLOT_ENV))
            e.emit(ASM.cmp_imm(2, 0))
            e.emit_branch(:bcond, done, cond: :eq)              # no shape: the new note takes it over
            e.emit(ASM.load_immediate(2, PHASE_FALLING))
            e.emit(ASM.str_offset(2, 7, SLOT_PHASE))            # a shape: its note ends, and it falls away
            e.place_label(tail)
            emit_keep_quietest_fading_voice(onward)
            e.place_label(others)
          end

          # 3: another part's voice, with the flags of comparing its mark against the game's still
          # up. The game's own goes on to be weighed by its ticket; another part's is a tail if its
          # note is falling, and otherwise goes on to +sounding+.
          def emit_weigh_other_part_voice(onward, sounding:)
            e = @emitter
            game = e.gensym
            e.emit_branch(:bcond, game, cond: :eq)
            e.emit(ASM.ldr_offset(2, 7, SLOT_PHASE))
            e.emit(ASM.cmp_imm(2, PHASE_FALLING))
            e.emit_branch(:bcond, sounding, cond: :lo)          # another part's note, still sounding
            emit_keep_quietest_fading_voice(onward)
            e.place_label(game)
          end

          # Keep the voice in r7 as the quietest tail if it is quieter than the one kept so far —
          # the first of them, when two are as quiet. On to the next voice either way.
          def emit_keep_quietest_fading_voice(onward)
            e = @emitter
            e.emit(ASM.ldr_offset(2, 7, SLOT_LEVEL))
            e.emit(ASM.cmp_reg(2, 3))
            e.emit(ASM.mov_reg_cond(:lo, 3, 2))
            e.emit(ASM.mov_reg_cond(:lo, ADDR, 7))
            e.emit_branch(:b, onward)
          end

          # One frame of every sounding note's shape — the pass that moves each voice's envelope
          # level on, emitted in the screen's own interrupt between the tune's frame and the mix.
          #
          # Why it is here and not in the mix. The four numbers move the level once a frame, so
          # working the level out per sample would be the same answer thousands of times over.
          # What the mix does per sample is only the slide toward it — one addition — which this
          # pass works out as the gain the frame should END at, less where the gain is now,
          # shared out over the frame's samples. The dividing is done once, when the game is
          # built: a frame always has the same number of samples, so sharing out is a multiply by
          # a number worked out ahead of time.
          #
          # Between the tune and the mix, in that order, and both halves matter. After the tune,
          # so a note started this frame has climbed before anything is mixed and none of its
          # attack is lost. Before the mix, so the slice about to be built slides to the level
          # this frame is really at.
          #
          # A note's first frame does not slide. It starts at the level its attack gives it,
          # the way it always did: the recording starts from its own beginning, so there is no
          # sound before it to be smooth with, and sliding up from nothing would soften the
          # strike of every drum and every plucked string.
          #
          # A voice with no envelope is two instructions: its ENV is 0 and this pass leaves its gain alone.
          # r4 is the slot, r5 the voices left, r1 the four numbers, r2 the level, r6 the phase,
          # r7 whether this is the note's first frame, r0/r3 scratch — all free here, since the
          # console saves r0-r3 and r12 on the way in and the dispatcher r4-r11.
          def emit_envelope_step
            e = @emitter
            voice = e.gensym
            holding = e.gensym
            falling = e.gensym
            write = e.gensym
            retire = e.gensym
            onward = e.gensym
            e.emit(ASM.load_immediate(4, @voice_base))
            e.emit(ASM.load_immediate(5, MAX_VOICES))

            e.place_label(voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, onward, cond: :eq)          # nothing sounding here
            e.emit(ASM.ldr_offset(1, 4, SLOT_ENV))
            e.emit(ASM.cmp_imm(1, 0))
            e.emit_branch(:bcond, onward, cond: :eq)          # no envelope: nothing to climb
            e.emit(ASM.ldr_offset(2, 4, SLOT_LEVEL))
            e.emit(ASM.ldr_offset(6, 4, SLOT_PHASE))
            e.emit(ASM.load_immediate(7, 0))                  # not the note's first frame, until it is
            e.emit(ASM.cmp_imm(6, PHASE_DONE))
            e.emit_branch(:bcond, retire, cond: :eq)          # its gain reached nothing last frame
            e.emit(ASM.cmp_imm(6, PHASE_FALLING))
            e.emit_branch(:bcond, falling, cond: :eq)
            e.emit(ASM.cmp_imm(6, PHASE_CLIMBING))
            e.emit_branch(:bcond, holding, cond: :ne)

            # Climbing: the attack is added each frame until the note is as loud as it was asked
            # to be, and then the note is up and holding. A level of nothing here is a note that
            # has only just started, since an attack adds at least one.
            e.emit(ASM.cmp_imm(2, 0))
            e.emit(ASM.mov_imm_cond(:eq, 7, 1))
            e.emit(ASM.and_imm(0, 1, 0xFF))
            e.emit(ASM.add_reg(2, 2, 0))
            e.emit(ASM.cmp_imm(2, VBlank::Audio::Envelope::FULL))
            e.emit(ASM.mov_imm_cond(:ge, 2, VBlank::Audio::Envelope::FULL))
            e.emit(ASM.mov_imm_cond(:ge, 6, PHASE_HOLDING))
            e.emit_branch(:b, write)

            # Holding: the level falls toward the sustain level and stays there. The fall is a
            # MULTIPLY by a fraction, so it slows as it goes — which is what a struck note does.
            e.place_label(holding)
            e.emit(ASM.lsr_imm(3, 1, 16))
            e.emit(ASM.and_imm(3, 3, 0xFF))                   # r3 = the sustain level
            e.emit(ASM.cmp_reg(2, 3))
            e.emit_branch(:bcond, write, cond: :le)           # already there
            e.emit(ASM.lsr_imm(0, 1, 8))
            e.emit(ASM.and_imm(0, 0, 0xFF))                   # r0 = the decay
            e.emit(ASM.mul(2, 0, 2))
            e.emit(ASM.lsr_imm(2, 2, VBlank::Audio::Envelope::SCALE))
            e.emit(ASM.cmp_reg(2, 3))
            e.emit(ASM.mov_reg_cond(:lt, 2, 3))               # never below the sustain level
            e.emit_branch(:b, write)

            # Falling: the note has ended, so the level is multiplied down until there is none of
            # it left. Reaching nothing does not give the voice back on the same frame, and that
            # is deliberate: this frame is still mixed, now at no loudness at all, so what the
            # speaker hears last is silence rather than whatever the wave was doing. Then the
            # voice goes back. A voice taken away while its gain is still up is the very click
            # all of this is here to remove.
            e.place_label(falling)
            e.emit(ASM.lsr_imm(0, 1, 24))                     # r0 = the release
            e.emit(ASM.mul(2, 0, 2))
            e.emit(ASM.lsr_imm(2, 2, VBlank::Audio::Envelope::SCALE))
            e.emit(ASM.cmp_imm(2, 0))
            e.emit(ASM.mov_imm_cond(:eq, 6, PHASE_DONE))

            e.place_label(write)
            e.emit(ASM.str_offset(2, 4, SLOT_LEVEL))
            e.emit(ASM.str_offset(6, 4, SLOT_PHASE))
            # The loudness the frame ends at: what the note asked for, scaled by the level, as a
            # WHOLE number of 256ths. The level is a byte and the scale is out of 256, so the
            # level's own top bit is added back in: a full 255 counts as 256, exactly the loudness
            # asked for. The fraction of the product is dropped, the loudness's own half a 256th
            # with it, which is how a cartridge's own sound engine works a channel's loudness out
            # once a frame, (level x (right + left)) >> 9 — so a quiet note falls silent on the
            # frame its whole loudness reaches nothing, while its level is still above it (a note
            # held at full stays the loudness asked for, a step above the engine's, for the top bit
            # added back). Down by the scale's eight bits and the loudness's one to the whole
            # number, then up by the gain's sixteen of fraction.
            e.emit(ASM.ldr_offset(0, 4, SLOT_VOL))
            e.emit(ASM.add_reg_lsr(3, 2, 2, 7))
            e.emit(ASM.mul(0, 3, 0))
            e.emit(ASM.lsr_imm(0, 0, VBlank::Audio::Envelope::WHOLE_GAIN_SHIFT))
            e.emit(ASM.lsl_imm(0, 0, GAIN_FRACTION))
            e.emit(ASM.cmp_imm(7, 0))
            # Where the gain starts the frame: last frame's slide aimed at a whole loudness and,
            # shared out in whole steps, landed off it, so the gain is put on the whole number
            # nearest (see IR::Mixing.nearest_whole_gain) — a note at nothing is at nothing, where
            # a little below it rounds every sample below the middle down a step. On a note's
            # first frame it starts at the target itself.
            e.emit(ASM.ldr_offset(3, 4, SLOT_GAIN))
            e.emit(ASM.add_imm(3, 3, 1 << (GAIN_FRACTION - 1)))
            e.emit(ASM.asr_imm(3, 3, GAIN_FRACTION))
            e.emit(ASM.lsl_imm(3, 3, GAIN_FRACTION))
            e.emit(ASM.mov_reg_cond(:ne, 3, 0))               # a first frame: the target
            e.emit(ASM.str_offset(3, 4, SLOT_GAIN))
            # ...and the slide to it: how far, shared out over the frame. Shifted down before the
            # multiply and down again after, so the product fits: a whole gain's worth of distance
            # times the share for one sample is more than 32 bits can hold.
            e.emit(ASM.sub_reg(0, 0, 3))
            e.emit(ASM.asr_imm(0, 0, RAMP_SPLIT))
            e.emit(ASM.load_immediate(3, IR::Mixing.slide_share(@mixer_spf)))
            e.emit(ASM.mul(0, 3, 0))
            e.emit(ASM.asr_imm(0, 0, RAMP_SPLIT))
            e.emit(ASM.str_offset(0, 4, SLOT_RAMP))
            e.emit_branch(:b, onward)

            e.place_label(retire)
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            e.place_label(onward)
            e.emit(ASM.add_imm(4, 4, SLOT_BYTES))
            e.emit(ASM.subs_imm(5, 5, 1))
            e.emit_branch(:bcond, voice, cond: :ne)
          end

          # Does any voice in this program have a shape to its notes? A program with none emits
          # not one instruction of the pass above, and its voices sound exactly as they did.
          def shapes_notes? = @uses_envelopes

          # The slot field the mix takes its loudness from: the one the envelope pass works out,
          # or — for a game that shapes nothing — the note's own loudness, which is the field it
          # has always read.
          def gain_field = @uses_envelopes ? SLOT_GAIN : SLOT_VOL

          # The hand-over: point the DMA at the buffer the mix filled last frame, so it plays
          # now. Which buffer is which is held in a hidden variable and flipped each frame.
          #
          # Why it cannot simply point at the start. The DMA takes sixteen samples at a time,
          # whenever the sound hardware asks, and the asking falls on a grid the sample clock
          # fixes. Its read position only ever moves forward: this re-arm is the one thing that
          # brings it back to a buffer. So between two re-arms it takes as many lots as grid
          # points fell between them, and that is a frame's worth only if the re-arms are a frame
          # apart to the cycle. They are not. The screen's interrupt is answered at once when the
          # game is asleep at the end of its frame, and late when the game is in the middle of a
          # DMA of its own — a screen clear is one, a fifth of a frame long — which holds every
          # interrupt off until it is done, a different wait every frame. A re-arm that lands a
          # lot later than the last has taken a lot from past the end of the buffer; one that
          # lands a lot earlier has left the buffer's last lot unplayed. Either is a jump.
          #
          # So the hand-over counts instead of trusting its timing. Timer 1 counts every sample
          # the hardware has taken, and the grid of lots sits at a known place in that count
          # (MIX_PHASE), so the count gives exactly how many lots the DMA has taken, and so which
          # lot it takes next. A hand-over two lots late points the DMA two lots into the new
          # buffer, where the sound meant for that moment is. The two lots taken late came from
          # past the end of the buffer before it, which is why every buffer carries the start of
          # the next one there (see #emit_mixer_fill). Late by anything up to that, the sound
          # comes out whole.
          #
          # One case the count cannot settle by itself: a sample taken between reading the count
          # and re-arming the DMA, which might have been a request answered from either buffer.
          # So the count is read only with #count_clearance to go before the next sample, and a
          # hand-over that finds the next one closer than that waits for it to pass.
          #
          # Which lot a buffer is meant to start at is kept from one frame to the next and moves
          # on a frame's worth of lots each time. When the count puts the DMA out of reach of
          # the buffer — the first hand-over of all, one later than the room a buffer carries, or
          # one EARLIER than the hand-over the counting started from — it starts again from where
          # the DMA really is. That hand-over is a jump. Counting started on a late frame is
          # started again by the next prompt one, so a game settles on its prompt hand-overs
          # within its first frames, and after that only a hand-over later than LATE_ROOM jumps.
          #
          # Still the first thing in the screen's interrupt, before the tune and the note shapes
          # (the mix itself comes later still, as the next picture starts), which keeps a game asleep at the end of its frame at the same lot every
          # frame, and a busy one no later than it has to be. The cost is that a sound is heard at
          # the gap after it is mixed — every sound alike, so nothing moves against anything else.
          def emit_mixer_handover
            e = @emitter
            play_buf1 = e.gensym
            chosen = e.gensym
            wait = e.gensym
            @primitives.load_var(0, MIX_FRONT)      # r0 = the buffer that was playing
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, play_buf1, cond: :eq)
            e.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, MIX_FRONT)
            e.emit(ASM.load_immediate(3, @mix_buf0))
            e.emit_branch(:b, chosen)
            e.place_label(play_buf1)
            e.emit(ASM.load_immediate(ACC, 1))
            @primitives.store_var(ACC, MIX_FRONT)
            e.emit(ASM.load_immediate(3, @mix_buf1))
            e.place_label(chosen)                   # r3 = the buffer to play now

            # Everything the re-arm needs that is not the count, loaded before the count is read,
            # so the gap between the two is as short as it can be. The interrupt dispatcher saves
            # r4-r8 around this.
            @primitives.load_var(2, MIX_PHASE)
            @primitives.load_var(1, MIX_LOT)
            e.emit(ASM.load_immediate(ADDR, @timers.timer_reg_l(CLOCK_TIMER)))
            e.emit(ASM.load_immediate(4, REG_DMA1SAD))
            e.emit(ASM.load_immediate(5, dma_fifo_control))
            e.emit(ASM.load_immediate(6, 0))
            e.emit(ASM.load_immediate(7, 65_536 - count_clearance))

            e.place_label(wait)
            e.emit(ASM.load_halfword(ACC, ADDR))               # timer 0 counts up to the next sample
            e.emit(ASM.cmp_reg(ACC, 7))
            e.emit_branch(:bcond, wait, cond: :hs)            # the next sample is too near: let it pass
            e.emit(ASM.load_halfword_offset(ACC, ADDR, COUNT_TIMER * 4)) # samples taken
            e.emit(ASM.sub_reg(ACC, ACC, 2))
            e.emit(ASM.lsl_imm(ACC, ACC, 16))                 # top twelve bits: lots taken
            e.emit(ASM.sub_reg(8, ACC, 1))
            e.emit(ASM.lsr_imm(8, 8, 20))                     # how far into this buffer the next one is
            e.emit(ASM.cmp_imm(8, guard_lots + 1))
            e.emit(ASM.mov_imm_cond(:hs, 8, 0))               # out of reach: start from its beginning
            e.emit(ASM.lsl_imm(8, 8, 4))
            e.emit(ASM.add_reg(8, 8, 3))
            e.emit(ASM.str(8, 4))                             # the DMA's source
            e.emit(ASM.str_offset(6, 4, REG_DMA1CNT - REG_DMA1SAD)) # off...
            e.emit(ASM.str_offset(5, 4, REG_DMA1CNT - REG_DMA1SAD)) # ...and on, which reloads it

            # Out of reach, this buffer starts at the lot the DMA takes next. Either way the next
            # one starts a frame's worth of lots later.
            e.emit(ASM.lsr_imm(ACC, ACC, 20))
            e.emit(ASM.mov_reg_lsl_cond(:hs, 1, ACC, 20))
            e.emit(ASM.load_immediate(ACC, lots_a_frame << 20))
            e.emit(ASM.add_reg(1, 1, ACC))
            @primitives.store_var(1, MIX_LOT)
          end

          # The per-frame refill: fill the buffer that is not playing with the next slice of
          # mixed sound, which the next frame's hand-over plays.
          #
          # Emitted inside an interrupt of the screen's, not in the game loop, and that is the
          # whole of what keeps sound whole. Which one is the display starting its first line,
          # not the gap between frames: the gap is where the game writes its sprites, and a
          # heavy mix there pushed those writes into the next picture (see GBA#emit_irq_handler).
          # A game that bends a background a line at a time still mixes in the gap. This fills one frame of sound, and the
          # hardware plays it on the sample clock — in real time, which has nothing to do with
          # how long a pass of the game loop takes. Called once per pass, a game whose pass
          # spans two frames handed the hardware a frame of sound every two:
          # half of every sound missing, every other slice, for as long as the game
          # was late. Called from the interrupt it is exactly in step with what plays it,
          # whatever the game is doing, with nothing to predict and no deficit to carry.
          #
          # Safe to run from an interrupt, and both halves of that are worth writing down
          # because neither is obvious. The registers: the mix routine works in r0-r12 and lr,
          # and the dispatcher saves r4-r11 and lr while the BIOS saves r0-r3 and r12, so between
          # them every one is covered. The voice slots: `play` and `stop` hold interrupts off while
          # they are in the table (#holding_off_interrupts), so this never sees one half-written.
          # This can retire a voice but never start one; the music player, in the gap's interrupt
          # before this one, starts voices, and can take one of the game's (#emit_take_music_voice_routine).
          #
          # Then the start of what it mixed is copied past the end of the buffer now playing, as
          # far as a late hand-over can reach (see #emit_mixer_handover): those lots are the ones
          # the DMA takes from there when the next hand-over is late, and they are the lots that
          # come next.
          def emit_mixer_fill
            mix_buf0 = @emitter.gensym
            done = @emitter.gensym
            @primitives.load_var(0, MIX_FRONT)      # r0 = the buffer now playing
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, mix_buf0, cond: :ne)
            emit_call_mix(@mix_buf1)
            emit_copy_overrun_lots(from: @mix_buf1, to: @mix_buf0)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(mix_buf0)
            emit_call_mix(@mix_buf0)
            emit_copy_overrun_lots(from: @mix_buf0, to: @mix_buf1)
            @emitter.place_label(done)
          end

          # The mix waits for the game's gap writes. The mix is built in the display's line-match
          # interrupt at the first line of the picture (GBA#emit_irq_handler), so that the gap is
          # the game's. But a gap can run past its last line: a long copy, a long routine run once
          # a frame, a gap that started late. The game is then still writing its sprite table and
          # its colours as the picture starts, and an interrupt holds the main code off for as long
          # as it runs (GBATEK, interrupts: IME is cleared on entry and nothing here sets it again).
          # A mix taking most of the picture held those writes off for most of the picture, and
          # every row it reached showed last frame's sprites.
          #
          # So the game marks its gap: GAP_WRITES_RUNNING is counted up as it wakes from the wait and
          # down once its sprite table is written (SpriteDrawing#emit_present_objects). While it
          # is above nought, the line-match interrupt mixes nothing, and moves the line it waits for one on
          # (DISPSTAT bits 8-15, the line the match interrupt fires on; GBATEK, LCD I/O Interrupts
          # and Status). The first line after the writes end, it mixes, and puts the line back to
          # the first. The order is the one a game's own interrupt keeps: what the picture is made
          # of first, the sound after.
          #
          # A gap that is still running at MIX_LATEST_LINE is mixed over all the same: by then the
          # picture is torn either way, and the mix needs the rest of the picture to be done before
          # the next hand-over.
          #
          # It is a count, not a yes or no, because one gap can hold another. A timer's handler that
          # waits runs as the game wakes (FrameBoundaryCalls#emit_waiting_handlers), and so does a
          # routine run once a frame; when either waits, its own gap starts and ends inside the
          # frame's, and the frame's writes go on after it. Each wake counts one up and each written
          # sprite table one down, so the frame's gap is still marked when the inner one ends. The
          # count never goes below nought, so a table written with no wake before it cannot leave
          # the mix waiting on every frame after.
          GAP_WRITES_RUNNING = :__gap_writes_running
          MIX_LATEST_LINE = 32 # Leaves the mix four fifths of the picture it had from line 0

          def emit_gap_writes_started
            @primitives.load_var(ACC, GAP_WRITES_RUNNING)
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, GAP_WRITES_RUNNING)
          end

          def emit_gap_writes_ended
            kept = @emitter.gensym
            @primitives.load_var(ACC, GAP_WRITES_RUNNING)
            @emitter.emit(ASM.subs_imm(ACC, ACC, 1))
            @emitter.emit_branch(:bcond, kept, cond: :mi) # nought already: stays nought
            @primitives.store_var(ACC, GAP_WRITES_RUNNING)
            @emitter.place_label(kept)
          end

          # At power-on, no gap is running.
          def emit_no_gap_writes_running = @primitives.store_word_immediate(0, @primitives.var_addr(GAP_WRITES_RUNNING))

          # The line-match interrupt's body when the mix waits for the gap. Uses r0 to r2, which
          # the BIOS saved, before the mix, which may use any register.
          def emit_mixer_fill_after_gap_writes
            e = @emitter
            ask = e.gensym
            mix = e.gensym
            done = e.gensym
            e.place_label(ask)
            @primitives.load_var(ACC, GAP_WRITES_RUNNING)
            e.emit(ASM.cmp_imm(ACC, 0))
            e.emit_branch(:bcond, mix, cond: :eq)          # the gap's writes are done: mix
            e.emit(ASM.load_immediate(TMP, REG_VCOUNT))
            e.emit(ASM.load_halfword(ACC, TMP))            # r0 = the line being drawn
            e.emit(ASM.cmp_imm(ACC, MIX_LATEST_LINE))
            e.emit_branch(:bcond, mix, cond: :hs)          # as late as the mix can start: mix
            e.emit(ASM.add_imm(ACC, ACC, 1))
            e.emit(ASM.load_immediate(TMP, REG_DISPSTAT + 1))
            e.emit(ASM.strb(ACC, TMP))                     # ask again at the next line
            # ...unless the display reached that line while it was being asked for: a match
            # already passed would never come this frame, and the frame would get no mix. So
            # the line is read again, and if it is there already the question is asked anew.
            e.emit(ASM.load_immediate(TMP, REG_VCOUNT))
            e.emit(ASM.load_halfword(2, TMP))              # r2 = the line being drawn now
            e.emit(ASM.cmp_reg(2, ACC))
            e.emit_branch(:bcond, ask, cond: :hs)
            e.emit_branch(:b, done)
            e.place_label(mix)
            e.emit(ASM.load_immediate(ACC, 0))
            e.emit(ASM.load_immediate(TMP, REG_DISPSTAT + 1))
            e.emit(ASM.strb(ACC, TMP))                     # the next frame's match at the first line
            emit_mixer_fill
            e.place_label(done)
          end

          # Copy the first guard_lots of +from+ to just past the end of +to+, a word at a time.
          def emit_copy_overrun_lots(from:, to:)
            e = @emitter
            copy = e.gensym
            e.emit(ASM.load_immediate(0, from))
            e.emit(ASM.load_immediate(1, to + @mixer_spf))
            e.emit(ASM.load_immediate(2, guard_lots * Timers::DMA_SAMPLES_A_LOT / 4))
            e.place_label(copy)
            e.emit(ASM.ldr(3, 0))
            e.emit(ASM.add_imm(0, 0, 4))
            e.emit(ASM.str_post(3, 1, 4))
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, copy, cond: :ne)
          end

          # Call the IWRAM mix routine to fill +dest+ (one of the two output buffers) with the
          # next slice of mixed sound. The routine takes the destination buffer in r0, and it
          # lives in the quick memory, too far for a relative branch — so the call goes
          # through a register (see Emit#emit_call_through).
          def emit_call_mix(dest)
            @emitter.emit(ASM.load_immediate(0, dest))                 # r0 = destination buffer (the one param)
            @emitter.emit(ASM.load_immediate(ADDR, @mix_routine_iwram)) # r12 = routine's address in IWRAM
            @emitter.emit_call_through(ADDR)
          end

          # The main volume the game named, as the Advance's three settings of it (MainVolume).
          attr_reader :main_volume

          # Which bits of SOUNDCNT_H send the recorded sound to the speakers: channel A at the
          # main volume (all, or half), out to both, clocked by timer 0. They are asked for from
          # outside because SOUNDCNT_H is a shared register — its low bits are the PSG's volume —
          # and whoever writes it whole has to put these back or the recordings stop (see
          # Audio#emit_enable_sound). Nothing at all for a program that plays no recording.
          def direct_sound_routing
            return 0 unless plays_samples?

            (@main_volume.recordings_full ? DSOUND_A_VOLUME_FULL : 0) | DSOUND_A_LEFT | DSOUND_A_RIGHT | DSOUND_A_TIMER0
          end

          # SOUNDCNT_H's low bits: the Game Boy voices' share of the main volume (PSG_VOLUME_FULL at
          # the loudest).
          def psg_share = @main_volume.share_bits

          # SOUNDCNT_X: the sound switched on, unless the main volume is nothing.
          def sound_power = @main_volume.powered ? SOUND_MASTER_ENABLE : 0

          # Channel A's SOUNDCNT_H setup at boot: that routing, the PSG's share of the main
          # volume beside it, and A's FIFO reset so playback starts clean. The reset belongs to
          # boot alone — doing it again later would throw away whatever sound was queued.
          def direct_sound_a_config
            psg_share | direct_sound_routing | DSOUND_A_RESET_FIFO
          end

          # The DMA1 control word for feeding the sound FIFO: enabled, 32-bit transfers to a
          # fixed destination (the FIFO register), re-armed after each transfer, started on
          # a FIFO request ("special" timing). The transfer count is fixed by the hardware
          # in this mode, so none is set.
          def dma_fifo_control
            DMA_ENABLE | DMA_REPEAT | DMA_32BIT | DMA_DEST_FIXED | DMA_SPECIAL
          end

          def store_reg_ioreg(reg, address)
            @emitter.emit(ASM.load_immediate(TMP, address))
            @emitter.emit(ASM.str(reg, TMP))
          end

          # (Re)start channel A's DMA from the source last written. The DMA reloads its source
          # only when switched off and on.
          def emit_rearm_dma
            @primitives.store_word_immediate(0, REG_DMA1CNT)                # off
            @primitives.store_word_immediate(dma_fifo_control, REG_DMA1CNT) # on
          end

          # The mix routine, emitted once and copied into IWRAM at boot (see
          # #emit_copy_mix_routine_to_iwram). It fills the destination buffer — one frame of
          # bytes, passed in r0 — with the sum of every sounding voice, clamped to the 8-bit
          # range so loud moments don't wrap.
          #
          # In two passes, and that is most of what it costs. First each sounding voice adds
          # its next run of samples — scaled by its volume, stepped through the clip by its
          # fixed-point step so a pitched voice reads faster or slower — into a halfword
          # running total per output sample, kept in the quick memory; the voice is advanced,
          # and looped or retired at its end. Then one pass turns each total into the byte the
          # sound hardware plays, clamping it there, and clears the total for next frame.
          #
          # Summing into bytes instead — reading the output back, adding, clamping, writing it
          # out again for every voice — was twice the instructions per voice per sample, most
          # of them going to and from the slower memory the output lives in. A halfword holds
          # any sum there can be (every voice at full level is under 128 each), so clamping
          # once at the end loses nothing, and it is the better mix besides: a loud voice and
          # a loud voice of the other sign cancel, whatever order they were added in.
          #
          # STEPPING takes two instructions, the fraction kept in the top half of a register
          # so that adding the step's fraction overflows exactly when a whole sample is due —
          # the carry out of that add is the extra sample, and the add that moves the read
          # pointer takes it in. Where a voice is is its read pointer, compared against where
          # its recording ends; the whole-sample position the slot keeps is worked back out
          # when the voice is put away.
          #
          # The routine is self-contained and position-independent (relative branches, every
          # number built an instruction at a time, nothing read from a table beside it — it is
          # copied by its own two labels, unlike a routine of the game's, whose table goes with
          # it), so it runs the same from IWRAM as from ROM. The one
          # input, the destination buffer, arrives in r0 and is stashed on the stack for the
          # last pass. It returns with BX LR.
          #
          # Registers held across voices: r3 = the running totals, r4 = slot pointer, r5 =
          # voices left. Per voice: r2 = output samples left, r6 = read pointer, r7 = the total
          # being added to, r8 = whole samples a step, r9 = where the recording ends, r10 = the
          # step's fraction (top half), r11 = the fraction carried (top half), r12 = volume;
          # r0/r1 scratch. The last pass: r6 = the byte being written, r7 = its total, r4 =
          # -128 (the clamp floor; 127, the ceiling, rides in the instruction), r5 = 0.
          #
          # A game that shapes a note slides each voice's gain across the frame (see SLOT_RAMP),
          # which is one more register than there is — so lr carries the slide, and is kept on
          # the stack beside the destination until the routine returns through it. The gain in
          # r12 then keeps its fraction, and the sample is the multiply's second operand: the
          # console finishes a multiply sooner the smaller that one is, and a sample is a byte.
          def emit_mix_routine
            return unless @plays_samples

            e = @emitter
            e.refuse_open_number_table!("The mix routine")
            e.emit(ASM.loop_forever) # fall-through guard: the routine is only entered via the call
            e.place_label(ROUTINE)
            start = e.pos
            e.emit(ASM.push(0, *(LR if @uses_envelopes)))    # push {r0}: stash the destination buffer at [sp]
            e.emit(ASM.load_immediate(3, @mix_totals))        # the running totals
            e.emit(ASM.mov_reg(7, 3))                         # (still here after the voices = nothing sounded)
            e.emit(ASM.load_immediate(4, @voice_base))        # first slot
            e.emit(ASM.load_immediate(5, MAX_VOICES))         # voices to visit

            voice = e.gensym
            next_voice = e.gensym
            e.place_label(voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, next_voice, cond: :eq)      # idle slot -> skip
            e.emit(ASM.ldr_offset(6, 4, SLOT_SRC))            # r6 = where the recording starts
            e.emit(ASM.ldr_offset(9, 4, SLOT_LEN))
            e.emit(ASM.add_reg(9, 6, 9))                      # r9 = where it ends
            e.emit(ASM.ldr_offset(0, 4, SLOT_POS))
            e.emit(ASM.add_reg(6, 6, 0))                      # r6 = read pointer = start + position
            e.emit(ASM.ldr_offset(10, 4, SLOT_STEP))          # the step, 16.16...
            e.emit(ASM.lsr_imm(8, 10, STEP_SHIFT))            # ...r8 = its whole samples
            e.emit(ASM.lsl_imm(10, 10, STEP_SHIFT))           # ...r10 = its fraction, in the top half
            e.emit(ASM.ldr_offset(11, 4, SLOT_FRAC))          # r11 = the fraction carried in (top half)
            e.emit(ASM.ldr_offset(12, 4, gain_field))         # r12 = the gain it is sounding at
            e.emit(ASM.ldr_offset(LR, 4, SLOT_RAMP)) if @uses_envelopes # lr = how far it slides a sample
            e.emit(ASM.mov_reg(7, 3))                         # r7 = the first total
            e.emit(ASM.load_immediate(2, @mixer_spf))         # r2 = output samples to fill

            # SAMPLES_A_PASS samples each time round, not one. Counting down and jumping back is
            # two instructions, and the jump is the dearest thing in the loop, so done once for
            # every SAMPLES_A_PASS samples it costs that much less. A frame's samples are always
            # whole lots of the sound engine's, so they divide with nothing over (and the build
            # stops if they ever do not — #refuse_samples_not_whole_passes!). Each copy
            # of the body jumps to a place of its own when the recording reaches its end, and
            # comes back to just past itself.
            sample = e.gensym
            retire = e.gensym
            end_voice = e.gensym
            wraps = Array.new(SAMPLES_A_PASS) { [e.gensym, e.gensym] } # [where it jumps, where it comes back]
            e.place_label(sample)
            wraps.each do |wrapped, back|
              emit_mix_one_sample
              e.emit_branch(:bcond, wrapped, cond: :ge)       # reached (or passed) the end
              e.place_label(back)
            end
            e.emit(ASM.subs_imm(2, 2, SAMPLES_A_PASS))
            e.emit_branch(:bcond, sample, cond: :ne)          # more of the frame to fill
            e.emit_branch(:b, end_voice)

            # Reading back goes round as many times as it takes to be inside the recording again.
            # Once is enough unless a step is longer than the stretch the recording holds over —
            # a hold of a few samples read high — and then once leaves the pointer past the end,
            # where the next read is whatever the cartridge stores after the recording.
            wraps.each do |wrapped, back|
              again = e.gensym
              e.place_label(wrapped)
              e.emit(ASM.ldr_offset(0, 4, SLOT_LOOP))         # how far back at the end, 0 = play once
              e.emit(ASM.cmp_imm(0, 0))
              e.emit_branch(:bcond, retire, cond: :eq)
              e.place_label(again)
              e.emit(ASM.sub_reg(6, 6, 0))                    # back toward where it holds from
              e.emit(ASM.cmp_reg(6, 9))
              e.emit_branch(:bcond, again, cond: :ge)         # still at or past the end
              e.emit_branch(:b, back)
            end

            e.place_label(retire)                             # one-shot done: mark idle, stop adding
            e.emit(ASM.load_immediate(0, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_ACTIVE))

            e.place_label(end_voice)
            e.emit(ASM.ldr_offset(0, 4, SLOT_SRC))
            e.emit(ASM.sub_reg(0, 6, 0))
            e.emit(ASM.str_offset(0, 4, SLOT_POS))            # remember how far this voice has played
            e.emit(ASM.str_offset(11, 4, SLOT_FRAC))          # ...and the leftover fraction
            e.emit(ASM.str_offset(12, 4, SLOT_GAIN)) if @uses_envelopes # ...and where its gain slid to

            e.place_label(next_voice)
            e.emit(ASM.add_imm(4, 4, SLOT_BYTES))             # next slot
            e.emit(ASM.subs_imm(5, 5, 1))
            e.emit_branch(:bcond, voice, cond: :ne)

            # Nothing sounded: every total is still 0, so the frame is silence — written a word
            # at a time, which is a quarter of the stores the totals pass would make. A game is
            # silent more often than not, so this is the frame it has most. (The buffer is
            # whole words long, so rounding up to one writes nothing that is not its own.)
            silent = e.gensym
            e.emit(ASM.pop(6, *(LR if @uses_envelopes)))      # r6 = the destination (and the stack balanced)
            e.emit(ASM.load_immediate(5, 0))
            e.emit(ASM.cmp_reg(7, 3))
            e.emit_branch(:bcond, silent, cond: :eq)

            # Every voice is in the totals. Turn each into the byte the hardware plays, clamped
            # into [-128, 127] with no branch — movgt/movlt only fire when out of range — and
            # leave the total at 0 for next frame.
            e.emit(ASM.mov_reg(7, 3))
            e.emit(ASM.load_immediate(2, @mixer_spf))
            e.emit(ASM.mvn_imm(4, 127))                       # clamp floor = -128
            byte = e.gensym
            e.place_label(byte)
            e.emit(ASM.ldrsh(0, 7))
            e.emit(ASM.cmp_imm(0, 127))
            e.emit(ASM.mov_imm_cond(:gt, 0, 127))             # over 127  -> 127
            e.emit(ASM.cmp_reg(0, 4))
            e.emit(ASM.mov_reg_cond(:lt, 0, 4))               # under -128 -> -128
            e.emit(ASM.strb_post(0, 6, 1))
            e.emit(ASM.store_halfword_post(5, 7, 2))          # the total starts again at nothing
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, byte, cond: :ne)
            e.emit(ASM.return)                                # bx lr -> back to the caller

            e.place_label(silent)
            e.emit(ASM.load_immediate(2, (@mixer_spf + 3) / 4))
            quiet = e.gensym
            e.place_label(quiet)
            e.emit(ASM.str_post(5, 6, 4))
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, quiet, cond: :ne)
            e.emit(ASM.return)
            e.place_label(DerivedNames.routine_end(ROUTINE))

            size = @emitter.pos - start
            return unless size > MIX_ROUTINE_IWRAM_MAX

            raise LoweringError,
                  "the mix routine is #{size} bytes but only #{MIX_ROUTINE_IWRAM_MAX} are reserved for it " \
                  "(raise MIX_ROUTINE_IWRAM_MAX)"
          end

          private

          # The mix's inner loop counts down SAMPLES_A_PASS at a time and stops only at nought, so
          # a frame's samples that are not a whole number of passes would run it past the end of
          # the totals with nothing to say so. They always are today (see Timers.sample_clock);
          # this is what says so the day they are not.
          def refuse_samples_not_whole_passes!
            return if (@mixer_spf % SAMPLES_A_PASS).zero?

            raise LoweringError, "the mixer makes #{@mixer_spf} samples a frame, which is not a whole number of " \
                                 "its passes of #{SAMPLES_A_PASS}"
          end

          # One output sample of one voice into its total, and the read pointer moved on, ending
          # on the compare that finds whether the recording has reached its end.
          def emit_mix_one_sample
            e = @emitter
            e.emit(ASM.ldrsb(0, 6))                           # r0 = the voice's raw sample (signed)
            if @uses_envelopes
              e.emit(ASM.mul(1, 12, 0))                       # r1 = gain × sample
              e.emit(ASM.ldrsh(0, 7))                         # r0 = the total so far
              e.emit(ASM.add_reg_asr(0, 0, 1, VOL_SHIFT + GAIN_FRACTION)) # ...plus that ÷ 256, fraction and all
              e.emit(ASM.store_halfword_post(0, 7, 2))        # put it back, and on to the next total
              e.emit(ASM.add_reg(12, 12, LR))                 # the gain slides a sample's worth
            else
              e.emit(ASM.mul(1, 0, 12))                       # r1 = sample × volume
              e.emit(ASM.ldrsh(0, 7))                         # r0 = the total so far
              e.emit(ASM.add_reg_asr(0, 0, 1, VOL_SHIFT + LOUDNESS_FRACTION)) # ...plus sample × volume ÷ 512 (:full is unchanged)
              e.emit(ASM.store_halfword_post(0, 7, 2))        # put it back, and on to the next total
            end
            e.emit(ASM.adds_reg(11, 11, 10))                  # fraction += the step's; a carry is one more sample
            e.emit(ASM.adc_reg(6, 6, 8))                      # read pointer += whole samples + that carry
            e.emit(ASM.cmp_reg(6, 9))
          end

          # Leave r0 = the address of a free voice slot, or 0 if every one is busy. Uses r0/r1/r2
          # only, so the caller's r3 and r4 survive.
          def emit_find_free_voice
            @emitter.emit(ASM.load_immediate(1, @voice_base))
            @emitter.emit(ASM.load_immediate(2, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            scan = @emitter.gensym
            found = @emitter.gensym
            miss = @emitter.gensym
            @emitter.place_label(scan)
            @emitter.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, found, cond: :eq)        # active == 0 -> free
            @emitter.emit(ASM.add_imm(1, 1, SLOT_BYTES))
            @emitter.emit(ASM.cmp_reg(1, 2))
            @emitter.emit_branch(:bcond, scan, cond: :lt)
            emit_find_tail(miss) if @uses_envelopes               # nothing free: a note falling away gives way
            emit_count_dropped_sound                                        # nothing at all: write down what was lost
            @emitter.emit(ASM.load_immediate(0, 0))               # none free
            @emitter.emit_branch(:b, miss)
            @emitter.place_label(found)
            @emitter.emit(ASM.mov_reg(0, 1))                      # r0 = the free slot's address
            @emitter.place_label(miss)
          end

          # With every voice busy, a song's note that is falling away gives way to the game's sound,
          # the quietest of them first — the same rule a song's own note keeps
          # (#emit_take_music_voice_routine). A note falling away is on its way out, and it holds a voice
          # only because a shaped note keeps its voice to fade on; losing the game a sound it
          # would have had without that is not the trade anybody asked for.
          #
          # On the miss path only, so a game with a voice free pays nothing for it. Leaves the
          # voice in r0 and jumps to +taken+, or falls through with none. Uses r0/r1/r2 and r12,
          # the same registers the search already spends.
          def emit_find_tail(taken)
            e = @emitter
            scan = e.gensym
            keep = e.gensym
            onward = e.gensym
            e.emit(ASM.load_immediate(1, @voice_base))
            e.emit(ASM.load_immediate(2, 0))                      # r2 = the quietest so far, none yet
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            e.emit_branch(:bcond, onward, cond: :ls)              # free, or one of the game's
            e.emit(ASM.ldr_offset(0, 1, SLOT_PHASE))
            e.emit(ASM.cmp_imm(0, PHASE_FALLING))
            e.emit_branch(:bcond, onward, cond: :lo)              # a song's note, still sounding
            e.emit(ASM.cmp_imm(2, 0))
            e.emit_branch(:bcond, keep, cond: :eq)
            e.emit(ASM.ldr_offset(0, 1, SLOT_LEVEL))
            e.emit(ASM.ldr_offset(ADDR, 2, SLOT_LEVEL))
            e.emit(ASM.cmp_reg(0, ADDR))
            e.emit_branch(:bcond, onward, cond: :hs)              # no quieter than the one kept
            e.place_label(keep)
            e.emit(ASM.mov_reg(2, 1))
            e.place_label(onward)
            e.emit(ASM.add_imm(1, 1, SLOT_BYTES))
            e.emit(ASM.load_immediate(ADDR, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.cmp_reg(1, ADDR))
            e.emit_branch(:bcond, scan, cond: :lt)
            e.emit(ASM.mov_reg(0, 2))
            e.emit(ASM.cmp_imm(0, 0))
            e.emit_branch(:bcond, taken, cond: :ne)
          end

          # A sound was just lost: add one to the count, and remember how the voices were being
          # split if this is the worst it has been.
          #
          # Emitted on the miss path only, so a game that never runs out of voices pays nothing
          # for it — and a game that does pays it exactly when a sound is already being lost,
          # which is the cheapest moment there is to spend a few dozen instructions.
          #
          # The music's share is counted in a second walk of its own rather than as the search
          # above goes, because that search stops at the first free slot: on every play that
          # succeeds it would have counted part of the table and called it the whole. Here the
          # table is known to be full, so the walk is complete by construction.
          #
          # A slot's sounding word is 0 idle, OWNER_GAME the game's, and higher for a part of a
          # song or an effect — so "above OWNER_GAME" is "the music's", in one compare.
          # Uses r0/r1/r2 and r12, the same registers the search already spends.
          def emit_count_dropped_sound
            e = @emitter
            scan = e.gensym
            keep = e.gensym
            e.emit(ASM.load_immediate(1, @voice_base))
            e.emit(ASM.load_immediate(ADDR, @voice_base + (MAX_VOICES * SLOT_BYTES)))
            e.emit(ASM.load_immediate(2, 0))                      # r2 = voices a song is holding
            e.place_label(scan)
            e.emit(ASM.ldr_offset(0, 1, SLOT_ACTIVE))
            e.emit(ASM.cmp_imm(0, OWNER_GAME))
            e.emit(ASM.add_imm_cond(:gt, 2, 2, 1))                # a song's mark sits above the game's
            e.emit(ASM.add_imm(1, 1, SLOT_BYTES))
            e.emit(ASM.cmp_reg(1, ADDR))
            e.emit_branch(:bcond, scan, cond: :lt)

            @primitives.load_var(0, DROPS_MUSIC)
            e.emit(ASM.cmp_reg(2, 0))
            e.emit_branch(:bcond, keep, cond: :le)                # not the worst split so far
            @primitives.store_var(2, DROPS_MUSIC)
            e.place_label(keep)
            @primitives.load_var(0, DROPS)
            e.emit(ASM.add_imm(0, 0, 1))
            @primitives.store_var(0, DROPS)
          end

          # Zero +bytes+ bytes of memory starting at +addr+ (voice slots, output buffers).
          def emit_zero_region(addr, bytes)
            @emitter.emit(ASM.load_immediate(0, addr))
            @emitter.emit(ASM.load_immediate(1, 0))
            @emitter.emit(ASM.load_immediate(2, bytes))
            loop_lbl = @emitter.gensym
            @emitter.place_label(loop_lbl)
            @emitter.emit(ASM.strb(1, 0))
            @emitter.emit(ASM.add_imm(0, 0, 1))
            @emitter.emit(ASM.sub_imm(2, 2, 1))
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, loop_lbl, cond: :ne)
          end
        end
      end
    end
  end
end
