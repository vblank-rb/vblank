# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE GAME'S SOUND, written as calls into runtime/rg_sound.h — mixed into Lowering the way
        # Picture is.
        #
        # What is played is a song's parts — on the console's two square-wave voices, its wave
        # voice and its noise voice, and on recordings through the mixer (runtime_features/mix/rg_mix.h) — as
        # the interpreter's music player walks them, whether the game names the song or picks it
        # from a list by number; the sound effects played over the song; the game's own
        # recordings; and the beeps, `wave`, `stop_wave`, `noise` and `enable_sound` the game asks for
        # itself. Each goes into the sound log a test reads, in the interpreter's words (see
        # SoundLog).
        #
        # THE RULES OF THE VOICES are written into the game from Audio::Sound and IR::Tunes, as
        # numbers the runtime reads, rather than copied into the C: how fast each voice's clock
        # ticks, how many ticks a note lasts, how loud the wave voice is at each volume. So the
        # desktop build and the cartridge can never drift apart on what a note is.
        module Sound
          # The kinds of part the runtime plays, by the number it knows each as.
          PART_KINDS = { square: 0, wave: 1, noise: 2, recorded: 3 }.freeze

          # Set beside a note's four bits of fade (Audio::NoteFade#bits) when the note or its part
          # set one, rather than leaving it to the voice (rg_sound.c's HAS_FADE).
          HAS_FADE = 16

          # ...and above them, set when the note or its part set a slide (Audio::PitchSlide#bits),
          # whose seven bits are above that again (rg_sound.c's HAS_SLIDE and SLIDE_AT).
          HAS_SLIDE = 32
          SLIDE_AT = 6

          # ...and above those, set when the note or its part set a wobble (Audio::Vibrato#bits),
          # whose sixteen bits are above that again (rg_sound.c's HAS_VIBRATO and VIBRATO_AT).
          HAS_VIBRATO = 1 << 13
          VIBRATO_AT = 14

          # ...and at the top, the speaker it plays from (Audio::Pan.bits_of), nought for both, so
          # it needs nothing set beside it (rg_sound.c's PAN_AT). The top bit is the sign's, so a
          # note on the right alone is a negative number.
          PAN_AT = 30

          # A note's sixth number is its shapes when it or its part named them (Audio::Duty#bits), with
          # HAS_DUTY beside them, and 0 for a note that plays its part's one shape (rg_sound.c's
          # HAS_DUTY).
          HAS_DUTY = 1 << 8
          # ...and above that, set when the note's vibrato carries its swing from the note before
          # (Audio::Vibrato#carries; rg_sound.c's CARRIES_VIBRATO).
          CARRIES_VIBRATO = 1 << 9
          # ...and set on a recorded note that carries on the one sounding (IR::Tunes.glides?).
          GLIDES = 1 << 10

          private

          def prepare_sound
            @sound_log = SoundLog.new(@program)
            @start_file_sound_numbers = [] # a play's numbers known once the start file is read (#start_file_sound_number)
            @start_file_note_rows = [] # the note rows that take a number from it (#note_sound_row)
            @start_file_note_fills = [] # the parts whose notes are made from it (#encoded_part_read_at_start)
            refuse_unknown_rate_setting_mix!
          end

          def lower_enable_sound(_node) = [eval_call("rg_sound_enabled")]
          def lower_beep(node) = [eval_call("rg_sound_beep", Statements::Int.new(@sound_log.beep_number(node)))]
          def lower_wave(node) = [eval_call("rg_sound_wave", Statements::Int.new(@sound_log.wave_number(node)))]
          def lower_stop_wave(_node) = [eval_call("rg_sound_stop_wave")]
          def lower_noise(node) = [eval_call("rg_sound_noise", Statements::Int.new(@sound_log.noise_number(node)))]
          # Named `this_frame: true`, the tune starts where it is named (rg_music_start_here).
          def lower_play_song(node)
            [eval_call("rg_music_request", Statements::Int.new(@sound_log.song_number(node.name))),
             *(eval_call("rg_music_start_here") if node.this_frame)]
          end
          def lower_stop_music(_node) = [eval_call("rg_music_stop")]
          def lower_hold_music(node) = [eval_call("rg_music_hold", Statements::Int.new(node.held ? 1 : 0))]

          # A song picked from a list by a number the game works out: the list is written as the
          # numbers of its songs, and the runtime picks one, or leaves the music alone for a
          # number naming none.
          def lower_play_from_list(node)
            [eval_call(node.this_frame ? "rg_music_start_here_one_of" : "rg_music_request_one_of", song_list_name(node.name),
                       Statements::Int.new(song_lists.fetch(node.name).songs.size), value(node.which))]
          end

          def song_lists = @song_lists ||= @program.walk.select { |node| node.kind == :song_list }.to_h { |node| [node.name, node] }
          def song_list_name(name) = @names.of(:song_list, name)

          # A sound effect picked from a list by a number the game works out, the same way: the
          # list is written as the numbers of its effects (SoundLog#effect_number).
          def lower_play_sound_effect(node)
            [eval_call(node.this_frame ? "rg_effect_start_here_one_of" : "rg_effect_request_one_of", effect_list_name(node.name),
                       Statements::Int.new(effect_lists.fetch(node.name).effects.size), value(node.which))]
          end

          def effect_lists
            @effect_lists ||= @program.walk.select { |node| node.kind == :sound_effect_list }.to_h { |node| [node.name, node] }
          end

          def effect_list_name(name) = @names.of(:sound_effect_list, name)

          # --- recordings, through the mixer (runtime_features/mix/rg_mix.h) ---

          # The game's own `play` of a recording. Everything about it is fixed when the game is
          # built — the pitch it reads at, how loud, how far back it reads at its end — so it is
          # worked out here, the interpreter's way (Reference::Mixer#start), and handed over as
          # numbers.
          #
          # A recording that reads its rate or the sample it holds from out of the start file has
          # no step or no way back until the file is read, so the play reads that number from the
          # game's own array of them (#start_file_sound_number).
          def lower_play_sample(node)
            sample = @sound_log.recording(node.name)
            info = Assets::Sample.of(sample)
            settings = sample.settings_from_file
            frequency = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
            step = if settings&.rate
                     start_file_sound_number(StartFileStep.new(recording: sample.name, frequency: frequency))
                   else
                     Statements::Int.new(Mixing.step(info, frequency, mix_clock.rate))
                   end
            back = if !node.loop
                     Statements::Int.new(0)
                   elsif settings&.holds_from
                     start_file_sound_number(StartFileHold.new(recording: sample.name))
                   else
                     Statements::Int.new(info.loop_length.positive? ? info.loop_length : info.length)
                   end
            levels = VBlank::Audio::Sound::MIX_LEVELS
            [eval_call("rg_mix_play", Statements::Int.new(@sound_log.recording_number(node.name)), step,
                       Statements::Int.new(levels.fetch(node.volume, levels[:full])), back,
                       Statements::Int.new(node.loop ? 1 : 0))]
          end

          # --- a recording's settings read from the start file (IR::StartFile::RecordingSettings) ---
          #
          # A recording's rate, the sample it holds from and its envelope are numbers the build
          # works a play and a note out from: the step a voice reads the recording at, how far
          # back it reads at its end, and the shape's four numbers. Where one of them is in the
          # start file, the build writes what it works out from a stand-in and the routine that
          # reads the file writes each number again from the file's:
          #
          #   rg_mix_fill_steps   the step of each play and each note's row, from the rate;
          #   rg_mix_fill_holds   how far back each reads, from the sample held from;
          #   rg_mix_fill_shapes  the recording's shape, and each row that takes it.
          #
          # They write into the game's own array for a play's numbers, and into the tables of
          # recordings and of note rows, which such a game declares as written.
          #
          # They are the mix feature's (RuntimeFeatures), which every game that declares a
          # recording is built with.

          # A number of a play that is known once the file is read: the step that sounds
          # +recording+ at +frequency+, or how far back +recording+ reads at its end.
          StartFileStep = Data.define(:recording, :frequency)
          StartFileHold = Data.define(:recording)

          # The entry of the game's array of such numbers that holds +number+, as a play reads it.
          def start_file_sound_number(number)
            entry = @start_file_sound_numbers.index(number) || (@start_file_sound_numbers << number).size - 1
            Statements::Index.new(start_file_sound_numbers_name, Statements::Int.new(entry))
          end

          def start_file_sound_numbers_name = @names.own("start_file_sound_numbers")

          # The array's declaration, which goes with the tables; nothing for a game with no such number.
          def start_file_sound_number_arrays
            return [] if @start_file_sound_numbers.empty?

            [Statements::StartFileArray.new(name: start_file_sound_numbers_name, type: "int32_t", count: @start_file_sound_numbers.length)]
          end

          # A row of the table of note rows that takes a number from the start file: the row of
          # +recording+ read at +pitch+, which takes its shape from the recording where +recording_shape+.
          StartFileNoteRow = Data.define(:row, :recording, :pitch, :recording_shape)

          # Where a row's step, the way back and the shape start in the table of note rows, and a
          # recording's shape in the table of recordings: past each table's count.
          NOTE_SOUND_NUMBERS = 8
          NOTE_SOUND_STEP_AT = 1
          NOTE_SOUND_BACK_AT = 2
          NOTE_SOUND_SHAPE_AT = 3
          RECORDING_NUMBERS = 7
          RECORDING_SHAPE_AT = 2

          # How each runtime's rg_mix_fill_shapes is told an envelope is kept
          # (IR::StartFile::EnvelopeBytes#kept_as).
          ENVELOPES_KEPT_AS = Ractor.make_shareable({ envelope: 0 })

          def recordings_with_settings_in_start_file = @sound_log.recordings.select(&:settings_from_file)

          # The calls that fill every number worked out from a recording's settings in the file,
          # and then each part's notes that are in it (#build_start_file_note_fills).
          # The sound's tables are made first, since making them is what finds the note rows.
          def build_start_file_sound_fills
            sound_tables
            build_start_file_settings_fills + build_start_file_note_fills
          end

          def takes_runtime_feature?(name) = runtime_features.any? { |feature| feature.name == name }

          def build_start_file_settings_fills
            recordings_with_settings_in_start_file.flat_map do |sample|
              settings = sample.settings_from_file
              rows = @start_file_note_rows.select { |row| row.recording == sample.name }
              [*(start_file_step_fills(sample, rows) if settings.rate), *(start_file_hold_fills(sample, rows) if settings.holds_from),
               *(start_file_shape_fills(sample, rows) if settings.envelope)]
            end
          end

          # A whole number of 64 bits as two of 32, the high half first: how a runtime is handed a
          # number with a fraction (IEEE 754, the form C, JavaScript and Ruby all keep one in), so
          # each works a step out from exactly the number the build would.
          def double_halves(number) = [number.to_f].pack("G").unpack("l>l>")

          # The numbers that say where a Number is in the file and how it is kept.
          def start_file_number_rules(where)
            [where.at, Build::ELEMENT_BYTES.fetch(where.width), where.format.high_byte_first ? 1 : 0, where.signed ? 1 : 0]
          end

          # THE STEPS READ AT A RATE FROM THE FILE. A step is the rate against the mix's, times the
          # note against the one the recording was made at (IR::Mixing.step). The second part is
          # known here, so each step is handed over as that ratio, and the runtime does the rest of
          # the same sum once it has the rate.
          def start_file_step_fills(sample, rows)
            note = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(sample.note || :C4)
            head = [*start_file_number_rules(sample.settings_from_file.rate), *double_halves(mix_clock.rate)]
            plays = @start_file_sound_numbers.each_with_index.select { |number, _| number.is_a?(StartFileStep) && number.recording == sample.name }
            in_plays = plays.map { |number, entry| [entry, *double_halves(number.frequency.to_f / note)] }
            in_rows = rows.map { |row| [1 + (row.row * NOTE_SOUND_NUMBERS) + NOTE_SOUND_STEP_AT, *double_halves(row.pitch.to_f / note)] }
            start_file_sound_fill("rg_mix_fill_steps", "start_file_steps", head, in_plays, in_rows)
          end

          # HOW FAR BACK A HELD NOTE READS, from the sample it holds from in the file: the
          # recording's length less that sample (Assets::Sample#loop_length).
          def start_file_hold_fills(sample, rows)
            head = [*start_file_number_rules(sample.settings_from_file.holds_from), sample.bytes.bytesize]
            plays = @start_file_sound_numbers.each_index.select { |entry| @start_file_sound_numbers[entry] == StartFileHold.new(recording: sample.name) }
            in_rows = rows.map { |row| [1 + (row.row * NOTE_SOUND_NUMBERS) + NOTE_SOUND_BACK_AT] }
            start_file_sound_fill("rg_mix_fill_holds", "start_file_holds", head, plays.map { |entry| [entry] }, in_rows)
          end

          # THE SHAPE FROM THE FILE: the recording's own, and each row of a note that set none and
          # whose part set none, which takes the recording's (#note_sound_row).
          def start_file_shape_fills(sample, rows)
            where = sample.settings_from_file.envelope
            head = [where.at, ENVELOPES_KEPT_AS.fetch(where.kept_as), VBlank::Audio::Envelope::MOST]
            recording = [[1 + (@sound_log.recording_number(sample.name) * RECORDING_NUMBERS) + RECORDING_SHAPE_AT]]
            in_rows = rows.select(&:recording_shape).map { |row| [1 + (row.row * NOTE_SOUND_NUMBERS) + NOTE_SOUND_SHAPE_AT] }
            [eval_call("rg_mix_fill_shapes", @names.own("recordings"),
                       drawing_array("start_file_shapes", "int32_t", [*head, recording.size, *recording.flatten])),
             *(unless in_rows.empty?
                 [eval_call("rg_mix_fill_shapes", @names.own("note_sounds"),
                            drawing_array("start_file_shapes", "int32_t", [*head, in_rows.size, *in_rows.flatten]))]
               end)]
          end

          # One call for the numbers of a play (+in_plays+, into the game's own array) and one for
          # the note rows (+in_rows+, into their table); none for a list with nothing in it. Each
          # is handed +head+, how many entries follow, and the entries.
          def start_file_sound_fill(routine, rules_name, head, in_plays, in_rows)
            { start_file_sound_numbers_name => in_plays, @names.own("note_sounds") => in_rows }.filter_map do |array, entries|
              next if entries.empty?

              eval_call(routine, array, drawing_array(rules_name, "int32_t", [*head, entries.size, *entries.flatten]))
            end
          end

          # A game whose mix runs at the rate most of its recordings were made at
          # (IR::Mixing.requested_rate) lays its sound out from that rate, so a rate the build does
          # not know cannot be one of them. A console whose voices read at one rate whatever the
          # recordings' are needs no rate to lay its sound out.
          def refuse_unknown_rate_setting_mix!
            console = @program.described_console
            return if console.recording_voice_hz

            sample = @sound_log.recordings.find { |recording| recording.settings_from_file&.rate } or return
            raise LoweringError, "The recording #{sample.name.inspect} reads its rate from the #{@program.start_file.called} as the game " \
                                 "starts. On the #{console.title}, the sound is mixed at the rate that most recordings have, so " \
                                 "the build must know each rate. To fix this, give `rate:` a number, or build the game all-in-one."
          end

          # ...and its `stop`, of one recording or, with no name, of every one the game plays.
          def lower_stop_sample(node)
            [eval_call("rg_mix_stop", Statements::Int.new(node.name ? @sound_log.recording_number(node.name) : -1))]
          end

          # The rate the mix runs at and how many samples a frame holds: the console's own clock
          # for the rate the game's recordings ask for, as the interpreter takes it.
          def mix_clock = @mix_clock ||= @program.described_console.sample_clock(Mixing.requested_rate(@program))

          # How the mix runs (see the layout atop runtime_features/mix/rg_mix.c). Its voices are as many as the
          # console sounds recordings together (Console::Description#recordings_at_once), as the
          # interpreter's mixer has.
          def mix_table
            sound = VBlank::Audio::Sound
            envelope = VBlank::Audio::Envelope
            mixes = Mixing.mixes?(@program)
            samples = mixes ? mix_clock.samples_a_frame : 0
            sound_table("mix", [mixes ? 1 : 0, samples, Mixing.shapes_any_note?(@program) ? 1 : 0,
                                mixes ? Mixing.slide_share(samples) : 0, @program.described_console.recordings_at_once,
                                sound::VOL_SHIFT,
                                sound::STEP_SHIFT, sound::GAIN_FRACTION, sound::RAMP_SPLIT, envelope::FULL, envelope::SCALE,
                                sound::LOUDNESS_TO_GAIN, envelope::WHOLE_GAIN_SHIFT])
          end

          # Every recording the game declares, seven numbers each; and all their samples, in an
          # array of bytes of their own, since a sample is one and recordings can be most of a
          # game's sound.
          def recordings_tables
            recordings = @sound_log.recordings
            heads = recordings.map do |sample|
              info = Assets::Sample.of(sample)
              shape = info.envelope && !info.envelope.plain? ? info.envelope : nil
              [recording_starts.fetch(sample.name), info.length, shape ? 1 : 0,
               *(shape ? [shape.attack, shape.decay, shape.sustain, shape.release] : [0, 0, 0, 0])]
            end
            samples = kept_recordings.flat_map { |sample| sample.bytes.unpack("c*") }
            [sound_table("recordings", [recordings.size, *heads.flatten], writable: recording_shapes_read_from_start_file?),
             Statements::ConstArray.new(name: recording_samples_name, type: "int8_t", values: samples, exported: true,
                                        writable: recordings_read_from_start_file?)]
          end

          # WHERE EACH RECORDING'S SAMPLES START in the array of them all, by its name. A recording's
          # seven numbers carry where its samples are and everything else about it (its length and
          # its shape), so recordings declared under several names with the same samples, as one
          # instrument's recording shaped several ways is, start at the same place and the array
          # holds those samples once. Two that read their samples from the start file are the same
          # only when they read the same place in it: what the build holds for both is zeros.
          def recording_starts
            @recording_starts ||= begin
              at = 0
              starts = {}
              @sound_log.recordings.to_h do |sample|
                kept = [sample.bytes, sample.from_file]
                unless starts.key?(kept)
                  starts[kept] = at
                  at += sample.bytes.bytesize
                end
                [sample.name, starts.fetch(kept)]
              end
            end
          end

          # The recordings whose samples the array holds, in its order: the first of each that start
          # at one place (#recording_starts).
          def kept_recordings = @sound_log.recordings.uniq { |sample| recording_starts.fetch(sample.name) }

          def recording_samples_name = @names.own("recording_samples")

          # Whether a recording takes its samples from the file the program is handed as it starts. Its
          # samples are then zeros in the array above, which the runtime overwrites in place.
          def recordings_read_from_start_file? = @sound_log.recordings.any?(&:from_file)

          # Whether a recording takes its shape from that file, which the routine writes into the
          # table of recordings.
          def recording_shapes_read_from_start_file? = @sound_log.recordings.any? { |sample| sample.settings_from_file&.envelope }

          # rg_mix.h and rg_music.h declare each array const unless told it is written: the samples
          # when a recording reads them from the start file, the table of recordings when one reads
          # its shape from there, and the table of note rows when a row takes a number from there.
          # Must be asked once the sound's tables are made, which is what finds those rows.
          def written_sound_array_defines
            [("RG_RECORDING_SAMPLES_WRITABLE" if recordings_read_from_start_file?),
             ("RG_RECORDINGS_WRITABLE" if recording_shapes_read_from_start_file?),
             ("RG_NOTE_SOUNDS_WRITABLE" unless @start_file_note_rows.empty?),
             ("RG_MUSIC_WRITABLE" unless @start_file_note_fills.empty?)].compact.map { |name| Statements::Define.new(name) }
          end

          # Each recording that reads its samples from the file, written into its place in the array of
          # every recording's samples, as long as the zeros it holds.
          def build_start_file_recording_fills
            kept_recordings.filter_map do |sample|
              next unless sample.from_file

              start = recording_starts.fetch(sample.name)
              eval_call("rg_start_file_fill_bytes", recording_samples_name, Statements::Int.new(start),
                        Statements::Int.new(sample.bytes.bytesize), Statements::Int.new(sample.from_file))
            end
          end

          # Each song list a run can pick from, as the numbers of its songs.
          def song_list_tables
            picked = @reachable.filter_map { |node| node.name if node.kind == :play_from_list }.uniq
            picked.map do |name|
              Statements::ConstArray.new(name: song_list_name(name), type: "int32_t",
                                values: song_lists.fetch(name).songs.map { |song| @sound_log.song_number(song) })
            end
          end

          # Each sound effect list a run can play from, as the numbers of its effects.
          def effect_list_tables
            played = @reachable.filter_map { |node| node.name if node.kind == :play_sound_effect }.uniq
            played.map do |name|
              Statements::ConstArray.new(name: effect_list_name(name), type: "int32_t",
                                values: effect_lists.fetch(name).effects.map { |effect| @sound_log.effect_number(effect) })
            end
          end

          # Every sound effect, in the order declared, as the player reads it (see the layout atop
          # runtime/rg_sound.c): whether any of them plays the wave voice, which changes how that
          # voice's waveform is put in; then each one's song, where its notes are, rank, group,
          # priority and whether it keeps its voices; and then the effects again, highest rank
          # first, which is the order a frame plays them in.
          def effects_table
            songs = @sound_log.sound_effects.map { |name| @sound_log.song(name) }
            groups = songs.filter_map(&:group).uniq
            rows = songs.each_with_index.map do |song, order|
              rank = Tunes.effect_rank(song, order)
              [@sound_log.song_number(song.name), effect_notes_number(song.name), rank,
               song.group ? groups.index(song.group) : -1, Tunes.priority_of(rank), song.keeps_voices ? 1 : 0]
            end
            by_rank = Tunes.effects_by_rank(songs).map { |name, _| @sound_log.effect_number(name) }
            plays_wave = songs.any? { |song| Tunes.parts_on(song, :wave).positive? }
            sound_table("effects", [rows.size, plays_wave ? 1 : 0, *rows.flatten, *by_rank])
          end

          # The player reads the music volume the game keeps, when it keeps one: a game that never
          # names `music_volume` plays every part at its written volume with nothing worked out. A
          # game with no music feature has no player to tell.
          def sound_power_on
            return [] unless variable_names.include?(Tunes::LEVEL) && takes_runtime_feature?(:music)

            [eval_call("rg_music_follow_level", Statements::AddressOf.new(variable(Tunes::LEVEL)))]
          end

          # Everything about the game's sound that the runtime reads, as arrays of whole numbers
          # (their layouts are atop runtime/rg_sound.c).
          # Made once: the routine that reads the start file asks for them before they are written out,
          # to learn the note rows it fills.
          def sound_tables
            # The music is written first: writing it is what finds the rows of note_sounds_table.
            @sound_tables ||= [sound_rules_table, waveform_table, music_table, note_sounds_table, effects_table, beep_table,
                               wave_table, hit_table, mix_table, *recordings_tables, *song_list_tables, *effect_list_tables]
          end

          # +writable+ is for a table the routine that reads the start file writes into.
          def sound_table(name, values, writable: false)
            Statements::ConstArray.new(name: @names.own(name), type: "int32_t", values: values, exported: true, writable: writable)
          end

          # The rules every voice keeps: how fast each one's clock ticks, how often the program's
          # console hands its voices on to the speaker, the music volume a part sounds at in full
          # and how far to shift back down by it, the wave voice's loudness for each written
          # volume, the part of a rank that tells a sound effect from the song, and how much of a
          # 64th of a second a frame lasts, for a swell held under the music volume.
          def sound_rules_table
            sound = VBlank::Audio::Sound
            quarters = (0..15).map { |volume| sound.wave_level_quarters(sound.wave_level(volume)) }
            sound_table("sound_rules", [sound::SQUARE_CLOCK_HZ, sound::WAVE_CLOCK_HZ, sound::NOISE_CLOCK_HZ,
                                        @program.described_console.voice_output_hz, Tunes::FULL_LEVEL,
                                        Tunes::LEVEL_SHIFT, *quarters,
                                        Tunes::ORDER_MASK, Tunes::COUNTED_A_FRAME])
          end

          # Every different waveform the game can put on the wave voice, 32 steps each: the ones
          # its `wave`s name and the ones its songs' parts play.
          def waveforms
            @waveforms ||= begin
              said = @sound_log.waves.map { |wave| wave.fetch(:shape) }
              played = @sound_log.songs.flat_map { |song| song.voices.filter_map(&:wave) }
              (said + played).map { |shape| VBlank::Audio::Sound.wavetable(shape) }.uniq
            end
          end

          def waveform_number(shape) = waveforms.index(VBlank::Audio::Sound.wavetable(shape))

          def waveform_table = sound_table("waveforms", [waveforms.size, *waveforms.flatten])

          # How many beeps the game makes, and each as the runtime reads it: how long one wave
          # lasts, how much of it is high, the volume it starts at, and how long it holds each step
          # of volume as it fades.
          def beep_table
            rows = @sound_log.effects.map do |effect|
              [VBlank::Audio::Sound.square_wave_ticks(effect.frequency), VBlank::Audio::Sound::SQUARE_HIGH_EIGHTHS.fetch(effect.duty),
               effect.volume, VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(effect.decay)]
            end
            sound_table("beeps", [rows.size, *rows.flatten])
          end

          # Each different `wave` the game asks for: which waveform, how long one wave of it lasts,
          # and how many quarters of each step its loudness keeps.
          def wave_table
            sound = VBlank::Audio::Sound
            rows = @sound_log.waves.map do |wave|
              [waveform_number(wave.fetch(:shape)), sound.wave_voice_ticks(wave.fetch(:frequency)),
               sound.wave_level_quarters(wave.fetch(:volume))]
            end
            sound_table("waves", [rows.size, *rows.flatten])
          end

          # Each different hit the game makes with `noise`: how long a step of its hiss lasts, how
          # many bits its pattern comes out of, the volume it starts at, and how long it holds
          # each step of volume as it fades.
          def hit_table
            sound = VBlank::Audio::Sound
            rows = @sound_log.hits.map do |hit|
              [sound.noise_hit_step_ticks(hit.fetch(:pitch)), sound.noise_register_bits(hit.fetch(:metallic)),
               hit.fetch(:volume), sound::FADE_STEP_SIXTY_FOURTHS.fetch(hit.fetch(:decay))]
            end
            sound_table("hits", [rows.size, *rows.flatten])
          end

          # Every song, as the runtime reads them: how many there are, where each starts, and
          # then the songs.
          #
          # A part that reads its notes from the start file is written as room for them
          # (#encoded_part_read_at_start), and where that room is in the table is known only here, so
          # each such part's fill is kept with its place (#build_start_file_note_fills).
          def music_table
            songs = @sound_log.songs.map { |song| [song, Tunes.loop_passes(song), !Tunes.plays_once?(song)] }
            effects = @sound_log.sound_effects.map do |name|
              song = @sound_log.song(name)
              [song, effect_passes(song), false]
            end
            starts = []
            at = 1 + songs.size + effects.size # past the count and the starts themselves
            entries = (songs + effects).map do |song, passes, comes_round|
              @note_fills_of_entry = []
              numbers = encoded_song(song, passes, comes_round: comes_round)
              starts << at
              @note_fills_of_entry.each { |fill| @start_file_note_fills << fill.with(notes_at: at + fill.notes_at) }
              at += numbers.size
              numbers
            end
            sound_table("music", [entries.size, *starts, *entries.flatten], writable: !@start_file_note_fills.empty?)
          end

          # A SOUND EFFECT'S NOTES, written again after every song. It plays once and never comes
          # round, so each part is its notes as written, as the interpreter's player walks them —
          # where the same Score played as a tune (a game may name it in `play_song`) is put right
          # for coming round (Tunes.loop_passes), which can add a rest the effect does not have.
          def effect_passes(song) = song.voices.map { |part| Tunes::Pass.new(first: part.events, again: []) }

          # Where each effect's notes are in the music table: after every song, in the order the
          # effects were declared.
          def effect_notes_number(name) = @sound_log.songs.size + @sound_log.effect_number(name)

          # One song as numbers: its length, where it loops from, whether it plays once and ends,
          # its rank, and each part, with its notes the first time through and every time after
          # (+passes+). Every song the game declares is written, played or not, so the numbering is
          # the one SoundLog gives.
          # +comes_round+ is whether the entry is played again from its loop frame: a song that does
          # not play once, and never a sound effect's notes.
          def encoded_song(song, passes, comes_round:)
            lanes = 0
            numbers = [song.total_frames, Tunes.loop_frame(song), Tunes.plays_once?(song) ? 1 : 0, Tunes.song_rank(song),
                       song.voices.size]
            song.voices.each_with_index.zip(passes) do |(part, number), pass|
              lane = Tunes.part_kind(part) == :recorded ? (lanes += 1) - 1 : nil
              if part.from_file
                numbers.concat(encoded_part_read_at_start(song, part, number, lane, comes_round: comes_round, part_at: numbers.size))
              else
                numbers.concat(encoded_part(part, number, pass, lane))
              end
            end
            numbers
          end

          # A part: which kind of voice it plays on, which of its song's parts it is, the two
          # things that give what its voice sounds like, and its notes. A recorded part's +lane+ is
          # which of the song's recorded parts it is.
          def encoded_part(part, number, pass, lane)
            kind = Tunes.part_kind(part)
            [PART_KINDS.fetch(kind), number, *part_tone(kind, part, lane), pass.first.size, pass.again.size,
             *(pass.first + pass.again).flat_map { |note| encoded_note(note, part, kind) }]
          end

          # --- a part's notes read from the start file (IR::StartFile::Notes) ---
          #
          # The player walks a part's notes in the music table, so a part whose notes are in the
          # file is written as ROOM for them: as many notes as its records can make, each on frame
          # -1, a frame no song is ever on, so the player passes none of them. The routine that
          # reads the file then writes the notes the records make over the first of that room
          # (rg_music_fill_notes), and what is left over stays unplayed.
          #
          # The runtime makes the notes by IR::StartFile::Notes' rule, and everything in that rule
          # that is a number is worked out here and handed over: the frame each tick falls on
          # (#tick_frames_array), and for the part what each key, each instrument and each volume a
          # record can name comes to in a note's six numbers (#start_file_note_rules). So no runtime
          # tunes a key or times a tick.

          # What fills one part's room: where its first note is in the music table, the rules, and
          # what the array of the frame each tick falls on is made from (#tick_frames_array), which
          # is declared only by a game that makes the call.
          StartFileNotesFill = Data.define(:notes_at, :rules, :where, :total_frames)

          # A frame no song and no sound effect is ever on.
          NEVER_PLAYED = -1
          NUMBERS_PER_NOTE = 6
          NUMBERS_PER_PART = 6

          # +part_at+ is where the part starts in its song's numbers.
          def encoded_part_read_at_start(song, part, number, lane, comes_round:, part_at:)
            kind = Tunes.part_kind(part)
            where = part.from_file
            # One more than the records make where the song comes round: the rest or the held note
            # a part is put right with at its loop frame (IR::Tunes.loop_passes).
            first = where.most_events + (comes_round ? 1 : 0)
            again = comes_round ? where.most_events + 1 : 0
            rules = [first, again, where.at, where.count, song.total_frames, Tunes.loop_frame(song), comes_round ? 1 : 0,
                     *start_file_note_rules(part, kind, where)]
            @note_fills_of_entry << StartFileNotesFill.new(notes_at: part_at + NUMBERS_PER_PART, rules: rules, where: where,
                                                           total_frames: song.total_frames)
            [PART_KINDS.fetch(kind), number, *part_tone(kind, part, lane), first, again,
             *([NEVER_PLAYED, 0, 0, 0, 0, 0] * (first + again))]
          end

          # WHAT A RECORD COMES TO ON THIS PART, as the numbers of a note (#encoded_note): what a
          # rest's fourth number is; the fifth and sixth of a note that sounds, which are the
          # part's; how many instruments the part names; then the third number for each volume
          # from 0 to 15 and for the part's own; for each instrument, the first that names the
          # same recording, which is how two notes are known to play the same one; the second
          # number for each key; and the fourth for each key, on the part's own instrument and
          # then on each it names (a part on a voice of the console's has the one list).
          def start_file_note_rules(part, kind, where)
            events = where.key_events
            recorded = kind == :recorded
            sounding = encoded_note([0, events.first[1], nil, nil, nil], part, kind)
            heard = [*(0..StartFile::MOST_VOLUME), part.volume].map { |volume| recorded ? Tunes.mix_loudness(volume) : volume }
            lasts = if recorded
                      [nil, *where.instruments].map { |name| events.map { |event| note_sound_row([0, event[1], name, nil, nil], part) } }
                    else
                      [events.map { |event| note_ticks(kind, event[1]) }]
                    end
            [recorded ? -1 : 0, sounding[4], sounding[5], where.instruments.size, *heard,
             *where.instruments.map { |name| where.instruments.index(name) },
             *events.map { |event| @sound_log.pitch_number(event[1]) }, *lasts.flatten]
          end

          # The most ticks a record can name: where a note starts, and how long it lasts.
          MOST_TICKS = 2 * 0xFFFF # Original::PackNote keeps each in two bytes

          # THE FRAME EACH TICK FALLS ON, for every tick before the song's end, as an array of the
          # game's: one for each different timing and length among the game's Scores.
          def tick_frames_array(where, total_frames)
            timing = where.timing
            (@tick_frames_arrays ||= {})[[where.tempo, where.ticks_per_beat, total_frames]] ||= begin
              frames = []
              (0..MOST_TICKS).each do |tick|
                frame = timing.at(tick)
                break if frame >= total_frames

                frames << frame
              end
              [drawing_array("tick_frames", "int32_t", frames), frames.size]
            end
          end

          # A call for each part that reads its notes from the file: the rules begin with where the
          # part's room is in the music table, and how many ticks the array of frames holds.
          # None for a game with no music feature, which declares songs and plays none: it has no
          # player to walk the notes, and no rg_music_fill_notes to make them.
          def build_start_file_note_fills
            return [] unless takes_runtime_feature?(:music)

            @start_file_note_fills.map do |fill|
              frames, ticks = tick_frames_array(fill.where, fill.total_frames)
              eval_call("rg_music_fill_notes", @names.own("music"),
                        drawing_array("start_file_notes", "int32_t", [fill.notes_at, ticks, *fill.rules]), frames)
            end
          end

          # What a part's voice sounds like, as two numbers. A square part: how many eighths of
          # its wave are high. A wave part: which waveform. A noise part: how many bits its hiss
          # comes out of, and how long a hit holds each step of volume as it fades. A recorded
          # part: its lane, since each note sets what it sounds like.
          def part_tone(kind, part, lane)
            sound = VBlank::Audio::Sound
            case kind
            when :square then [sound::SQUARE_HIGH_EIGHTHS.fetch(part.duty), 0]
            when :wave then [waveform_number(part.wave), 0]
            when :noise then [sound.noise_register_bits(part.metallic), sound.fade_step(part.decay)]
            when :recorded then [lane, 0]
            end
          end

          # A note as the runtime reads it: when it starts, which of the songs' pitches it is (0 is
          # a rest; see SoundLog#pitch_number), its volume, and how many ticks of its voice's
          # clock it lasts — one wave of it on a square voice or the wave voice, one step of the
          # hiss on the noise voice — or, on a recorded part, the row of note_sounds_table it
          # sounds. A recorded note's volume is written as its loudness on the mixer, since it can
          # hold a fraction. Then how it fades or swells, when its part or the note asked for it
          # (IR::Tunes.said_fade): the voice's four bits of it, and HAS_FADE beside them; 0 for a
          # note that leaves it to the voice, and for a rest. With them, in the same number, how it
          # slides its pitch when it or its part asked for it (IR::Tunes.said_slide), how it wobbles
          # (IR::Tunes.said_vibrato), and which speaker it plays from (IR::Tunes.note_side). And
          # after that number, a square note's shapes (IR::Tunes.said_duty; see HAS_DUTY).
          def encoded_note(note, part, kind)
            at, pitch, _, volume = note
            volume ||= part.volume
            heard, last = if kind == :recorded
                            [Tunes.mix_loudness(volume), pitch.zero? ? -1 : note_sound_row(note, part)]
                          else
                            [volume, pitch.zero? ? 0 : note_ticks(kind, pitch)]
                          end
            fade = Tunes.said_fade(part, note) unless pitch.zero?
            slide = Tunes.said_slide(part, note) unless pitch.zero?
            wobble = Tunes.said_vibrato(part, note) unless pitch.zero?
            flags = (fade ? HAS_FADE | fade.bits : 0) | (slide ? HAS_SLIDE | (slide.bits << SLIDE_AT) : 0) |
                    (wobble ? HAS_VIBRATO | (wobble.bits << VIBRATO_AT) : 0)
            side = pitch.zero? ? 0 : Audio::Pan.bits_of(Tunes.note_side(part, note))
            shapes = Tunes.said_duty(part, note) unless pitch.zero?
            [at, @sound_log.pitch_number(pitch), heard, last, Int32.wrap(flags | (side << PAN_AT)),
             (shapes ? HAS_DUTY | shapes.bits : 0) | (wobble&.carries ? CARRIES_VIBRATO : 0) | (Tunes.glides?(note) ? GLIDES : 0)]
          end

          # EVERYTHING A RECORDED NOTE IS BUT HOW LOUD, the interpreter's way
          # (Reference::Player#play_song_frame and Mixer#start_music_note): the recording — the
          # note's own, else its part's — read at the note's pitch, going back as far as it holds,
          # and shaped by the note's own shape, else its part's, else its recording's. Notes alike
          # share a row.
          #
          # A recording that reads a setting from the start file has a stand-in for it here, so two
          # of its notes at different pitches could come to one row and be two once the file is
          # read: its rows are told apart by their pitch as well, and each is filled from the file
          # (#build_start_file_sound_fills).
          def note_sound_row(note, part)
            _, pitch, instrument, _, envelope = note
            sample = @sound_log.recording(instrument || part.instrument)
            info = Assets::Sample.of(sample)
            own_shape = envelope || part.envelope
            shape = own_shape || info.envelope
            shape = nil if shape&.plain?
            row = [@sound_log.recording_number(sample.name), Mixing.step(info, pitch, mix_clock.rate), info.loop_length,
                   shape ? 1 : 0, *(shape ? [shape.attack, shape.decay, shape.sustain, shape.release] : [0, 0, 0, 0])]
            settings = sample.settings_from_file
            kept = settings ? [row, pitch, own_shape.nil?] : row
            at = note_sound_rows_kept.index(kept)
            return at if at

            note_sound_rows_kept << kept
            note_sounds << row
            if settings
              @start_file_note_rows << StartFileNoteRow.new(row: note_sounds.size - 1, recording: sample.name, pitch: pitch,
                                                            recording_shape: own_shape.nil?)
            end
            note_sounds.size - 1
          end

          def note_sounds = @note_sounds ||= []

          # What tells each row of note_sounds from the others, in the rows' order.
          def note_sound_rows_kept = @note_sound_rows_kept ||= []

          def note_sounds_table
            sound_table("note_sounds", [note_sounds.size, *note_sounds.flatten], writable: !@start_file_note_rows.empty?)
          end

          def note_ticks(kind, pitch)
            sound = VBlank::Audio::Sound
            case kind
            when :square then sound.square_wave_ticks(pitch)
            when :wave then sound.wave_voice_ticks(pitch)
            when :noise then sound.noise_note_step_ticks(pitch)
            end
          end
        end
      end
    end
  end
end
