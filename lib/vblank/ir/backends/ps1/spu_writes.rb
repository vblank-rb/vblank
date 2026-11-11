# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHAT A SOUND IS, ON A PLAYSTATION'S SOUND CHIP. This module gives which writes each of the
        # interpreter's sound-log entries means; the lowering makes them (Lowering::Sound), the song player
        # sends them (Runtime::Music, from the table PS1::Music makes with them), and the checked run reads the
        # chip's registers after every pass and holds them to what the log up to then says (#after), so a
        # write that never arrived, or arrived wrong, shows up in the chip itself.
        #
        # THE GAME'S VOICES are four of the chip's 24, one for each of the Advance's: its two squares, its
        # wave voice and its noise voice (VOICES). Each plays a loop from sound memory (SoundMemory): which
        # one is its start register, and how fast it is read is its pitch register (1000h is 44100 samples
        # a second, and the chip reads no faster than 3FFFh, Beetle PSX spu.c).
        #
        # ITS ENVELOPE is set once, at power-on (Runtime::Sound::ADSR_LOW/HIGH): up to full at once, held
        # there, and gone at once when let go. A note's loudness is its volume register, and a note that
        # fades or swells is the runtime's work, moved a step at a time as the Advance's voice moves its
        # own (Runtime::Sound), so the fade keeps the interpreter's pace.
        #
        # A VOICE STARTS (key on) and STOPS (key off) at the frame boundary: the runtime gathers which ones
        # the pass asked for and writes them once (Runtime::Sound#emit_keys). The chip takes key on and
        # key off once a sample, and a second write in the same 44100th of a second takes the place of the
        # first (Beetle PSX spu.c SPU_Write: `VoiceOn &= 0xFFFF0000; VoiceOn |= V`), so two beeps in one
        # pass written straight to it would lose one.
        #
        # Writes are:
        #   [:spu, register, value]        a register, by its distance from 1F801C00h
        #   [:loud, voice, volume, step]   a voice set to +volume+ (0 to 15), then moved a step every +step+
        #                                  64ths of a second (up when above nought, down when below)
        #   [:level, voice, volume]        a voice set to +volume+, going on as it was
        #   [:key_on, voice]               the voice started from its loop's start at the frame boundary
        #   [:key_off, voice]              the voice let go at the frame boundary
        #   [:silence, voices]             each voice whose bit is set at nought and let go
        module SPUWrites
          H = Console::PS1Hardware

          # The game's voices: the Advance's channels 1 and 2 (the squares), 3 (the wave) and 4 (noise).
          BEEP_VOICE = 0
          WAVE_VOICE = 2
          NOISE_VOICE = 3
          VOICES = 4
          SQUARE_VOICES = { 1 => 0, 2 => 1 }.freeze
          CHANNEL_VOICES = SQUARE_VOICES.merge(3 => WAVE_VOICE, 4 => NOISE_VOICE).freeze

          # THE LOUDNESS OF A VOICE AT FULL, as its volume register holds it: a quarter of the chip's
          # loudest, so the four voices together cannot go past what the speaker takes. A volume of 0 to
          # 15 is that many fifteenths of it.
          LOUDEST = 0x1000
          VOLUME_REGISTER = Ractor.make_shareable(Array.new(16) { |volume| (volume * LOUDEST) / 15 })

          PITCH_44100 = 0x1000
          PITCH_TOP = 0x3FFF
          SAMPLE_RATE = 44_100

          # WHAT A LOG ENTRY DOES NOT SAY, and the writes need: +memory+, where each loop is in sound memory
          # (SoundMemory); and for a song's note, as on the Genesis (Genesis::ChipWrites::Voicing), +parts+,
          # each song's parts by [the song's name, its channel] (a sound effect's among them), and +effects+,
          # the names of the songs that are sound effects.
          Voicing = Data.define(:memory, :parts, :effects) do
            def initialize(memory:, parts: {}, effects: []) = super

            # The voices +song+'s parts play on, a bit each.
            def song_voices(song)
              parts.keys.sum { |name, channel| name == song && !SongTable.recorded?(channel) ? 1 << CHANNEL_VOICES.fetch(channel) : 0 }
            end
          end

          module_function

          def register(voice, which) = (voice * H::SPU_VOICE_BYTES) + which

          # The writes one sound-log entry means. +effect_voices+ is the voices sound effects hold, which a
          # tune's stop leaves alone.
          def for_entry(entry, voicing, effect_voices: 0)
            memory = voicing.memory
            case entry.first
            when :enabled then []
            when :beep then beep(entry.last, memory)
            when :noise then entry.last ? noise(entry.last, memory) : silence(1 << NOISE_VOICE)
            when :wave then wave(entry.last, memory)
            when :stop_wave then [*volume_writes(WAVE_VOICE, 0), [:key_off, WAVE_VOICE]]
            when :note, :sound_effect, :sample, :stop_sample, :wobble, :duty then []
            when :voice then song_note(entry, voicing)
            when :stop_music then silence(voicing.song_voices(entry.fetch(1)) & ~effect_voices & 0xF)
            when :loudness then entry[1].is_a?(Array) ? [] : loudness_at(entry[1], entry[2], voicing, nil)
            else raise ArgumentError, "the PlayStation build does not play #{entry.first.inspect} yet"
            end
          end

          # A beep: the square of its width, read at its pitch, at its loudness, fading as it names.
          def beep(effect, memory)
            square(BEEP_VOICE, effect.duty, effect.frequency, effect.volume,
                   -VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(effect.decay), memory)
          end

          def square(voice, duty, frequency, volume, step, memory)
            [[:spu, register(voice, H::SPU_START), memory.start_of(SoundMemory.square(duty))],
             [:spu, register(voice, H::SPU_PITCH), square_pitch(frequency)],
             [:loud, voice, volume, step], [:key_on, voice]]
          end

          # A noise hit (Audio::Sound.resolve_noise's hash, or a song's drum, whose pitch is a frequency): the
          # hiss or the rattle, read a sample a step at the Advance's rate for its pitch.
          def noise(hit, memory)
            step = VBlank::Audio::Sound.fade_step(hit[:decay] || :none)
            [[:spu, register(NOISE_VOICE, H::SPU_START), memory.start_of(SoundMemory.noise(hit[:metallic]))],
             [:spu, register(NOISE_VOICE, H::SPU_PITCH), noise_pitch(hit[:pitch])],
             [:loud, NOISE_VOICE, hit[:volume], -step], [:key_on, NOISE_VOICE]]
          end

          # THE WAVE VOICE PLAYING +params+ ({shape:, frequency:, volume:}, as the interpreter logs a wave):
          # its waveform's loop at its pitch, and its loudness, which on the Advance is one of five
          # (Audio::Sound.wave_level), as so many quarters of a voice's loudest.
          def wave(params, memory)
            [[:spu, register(WAVE_VOICE, H::SPU_START), memory.start_of(SoundMemory.wave(params[:shape]))],
             [:spu, register(WAVE_VOICE, H::SPU_PITCH), wave_pitch(params[:frequency])],
             *wave_levels(params[:volume]), [:key_on, WAVE_VOICE]]
          end

          # The wave voice's two volume registers at +volume+: a level's name, or 0 to 15.
          def wave_levels(volume)
            level = volume.is_a?(Symbol) ? volume : VBlank::Audio::Sound.wave_level(volume)
            volume_writes(WAVE_VOICE, (VBlank::Audio::Sound.wave_level_quarters(level) * LOUDEST) / 4)
          end

          # The voices whose bits are set silenced: at nought, and let go.
          def silence(voices) = voices.zero? ? [] : [[:silence, voices]]

          def volume_writes(voice, value) = [[:spu, register(voice, H::SPU_VOLUME_LEFT), value], [:spu, register(voice, H::SPU_VOLUME_RIGHT), value]]

          # THE PITCH REGISTER for a loop of +samples+ samples a wave played at +frequency+ waves a second.
          def pitch_for(frequency, samples) = ((frequency * samples * PITCH_44100) / SAMPLE_RATE).round.clamp(1, PITCH_TOP)

          # A square of +frequency+ Hz plays at the pitch the Advance's square voice really plays it at, a
          # whole number of its clock's ticks a wave (Audio::Sound.square_wave_ticks).
          def square_pitch(frequency)
            sound = VBlank::Audio::Sound
            pitch_for(sound::SQUARE_CLOCK_HZ.to_f / sound.square_wave_ticks(frequency), SoundMemory::SQUARE_SAMPLES)
          end

          # The loop holds seven waves, so a wave of the waveform is 32 samples of it.
          def wave_pitch(frequency)
            sound = VBlank::Audio::Sound
            pitch_for(sound::WAVE_CLOCK_HZ.to_f / sound.wave_voice_ticks(frequency), sound::WAVE_SAMPLES)
          end

          # The noise is read a sample a step, at the Advance's rate for +pitch+: a hit's word (:high, :mid,
          # :low), or a song note's frequency, at the rung nearest it (Audio::Sound.noise_rung).
          def noise_pitch(pitch)
            sound = VBlank::Audio::Sound
            rate = pitch.is_a?(Symbol) ? sound.noise_rung_hz(0, sound::NOISE_HIT_HALVINGS.fetch(pitch)) : sound.noise_rung_hz(*sound.noise_rung(pitch))
            pitch_for(rate, 1)
          end

          # --- a song's notes (SongTable asks these) ---

          # Whether a song's or an effect's note on +channel+ makes a sound (Reference::Player#sounds?).
          def sounds?(channel, frequency, volume, fade = nil)
            return false unless frequency.positive?
            return true if fade&.swells_by_itself?
            return false unless volume.positive?

            CHANNEL_VOICES.fetch(channel) != WAVE_VOICE || VBlank::Audio::Sound.wave_level(volume) != :mute
          end

          # Where a [:voice ...] entry holds its fade, its slide, its speaker and its shapes (IR::Tunes.voice_entry).
          FADE_OF_VOICE_ENTRY = 5
          SLIDE_OF_VOICE_ENTRY = 6
          SIDE_OF_VOICE_ENTRY = 8
          DUTY_OF_VOICE_ENTRY = 9

          # WHICH SPEAKERS A VOICE IS HEARD FROM, as the runtime keeps it beside its loudness: both, or one.
          BOTH_SIDES = 0
          SIDES = { left: 1, right: 2 }.freeze

          # A SONG'S NOTE on a square voice, or the voice silenced for a rest; on the wave or noise voice
          # nothing, since the entry after it is the note. The square of the note's width, or its part's.
          def song_note(entry, voicing)
            _, channel, who, frequency, volume = entry
            fade = entry[FADE_OF_VOICE_ENTRY]
            voice = SQUARE_VOICES[channel] or return []
            return silence(1 << voice) unless sounds?(channel, frequency, volume, fade)

            duty = entry[DUTY_OF_VOICE_ENTRY]&.at(0) || voicing.parts[[who, channel]]&.duty || :half
            square(voice, duty, frequency, volume, signed_step(fade), voicing.memory)
          end

          # A fade as the runtime's step: above nought for a swell, below for a fade, nought for none.
          def signed_step(fade)
            return 0 unless fade

            fade.swells? ? fade.step : -fade.step
          end

          # THE MUSIC VOLUME reaching a note on +channel+, now at +volume+: a square or noise voice's
          # loudness, going on as it was, or the wave voice's two volume registers.
          def loudness_at(channel, volume, _voicing, _song)
            voice = CHANNEL_VOICES.fetch(channel)
            return wave_levels(volume) if voice == WAVE_VOICE

            [[:level, voice, volume]]
          end

          # A NOTE FROM ONE SPEAKER (+side+ :left or :right): its loudness kept to that side, which the runtime
          # holds beside the voice's volume so a fade keeps to it too, and the wave voice's other volume
          # register nought.
          def heard_from_one_side(writes, side)
            code = SIDES.fetch(side)
            silent = register(WAVE_VOICE, side == :left ? H::SPU_VOLUME_RIGHT : H::SPU_VOLUME_LEFT)
            writes.map do |write|
              case write.first
              when :loud then [:loud, write[1], write[2], write[3], code]
              when :level then [:level, write[1], write[2], code]
              when :spu then write[1] == silent ? [:spu, silent, 0] : write
              else write
              end
            end
          end

          # A SWELLING NOTE STRUCK AT THE MUSIC VOLUME, where the player's count puts it
          # (Reference::Player#step_swells): an +entry+ of [:loudness, channel, volume], with the swell after
          # it if it climbs on, which the runtime's fade does from there.
          def swell_strike(entry, _voicing, _song)
            _, channel, volume, swelling = entry
            [[:loud, CHANNEL_VOICES.fetch(channel), volume, swelling ? swelling.step : 0]]
          end

          # A NOTE WOBBLING: the voice on +channel+ playing a +frequency+ Hz note +steps+ of the Advance's pitch
          # number from it (Audio::Vibrato). The note is not started again.
          def wobble(channel, frequency, steps)
            voice = CHANNEL_VOICES.fetch(channel)
            return [] if voice == NOISE_VOICE

            clock = voice == WAVE_VOICE ? VBlank::Audio::Sound::WAVE_CLOCK_HZ.to_f : VBlank::Audio::Sound::SQUARE_CLOCK_HZ.to_f
            moved = clock / ((clock / frequency).round - steps)
            [[:spu, register(voice, H::SPU_PITCH), voice == WAVE_VOICE ? wave_pitch(moved) : square_pitch(moved)]]
          end

          # A SQUARE NOTE STEPPING ITS SHAPE: the square of the new width as the voice's loop, which the chip
          # takes up as the one playing comes round (its repeat address; Beetle PSX spu.c: a write there holds
          # until the next key on, IgnoreSampLA).
          def shape(channel, _frequency, shape)
            voice = SQUARE_VOICES[channel] or return []
            [[:spu, register(voice, H::SPU_REPEAT), SoundMemory.square_start(shape)]]
          end

          # A NOTE SLIDING: the voice on +channel+ taken to the pitch of +count+ (Audio::PitchSlide).
          def slide_step(channel, count, _was, _shape, from:)
            _ = from
            [[:spu, register(CHANNEL_VOICES.fetch(channel), H::SPU_PITCH), square_pitch(slide_frequency(count))]]
          end

          # The Hz of a square voice's pitch count, and the pitch count of a +frequency+ Hz note.
          def slide_frequency(count) = VBlank::Audio::Sound::SQUARE_CLOCK_HZ.to_f / (VBlank::Audio::PitchSlide::COUNT_TOP - count)
          def slide_count(frequency) = VBlank::Audio::PitchSlide::COUNT_TOP - (VBlank::Audio::Sound::SQUARE_CLOCK_HZ.to_f / frequency).round

          # A slide run off the top: the voice silent at once.
          def slide_stop(channel) = silence(1 << CHANNEL_VOICES.fetch(channel))

          # THE WRITES A RUN OF THE LOG MEANS, in order, with what one entry says of the next, as
          # Genesis::ChipWrites works them out: the tune a held note's [:loudness ...] reaches is the one
          # whose note was logged last; a song's note on the wave or noise voice plays at the note's own
          # volume, which its [:voice ...] entry carries; and that note's [:loudness ...], logged before the
          # voice's own entry, stands over it, so the note starts at the music volume.
          def writes(entries, voicing, song: nil) = each_entry_writes(entries, voicing, song: song).flat_map { |_, writes| writes }

          # Each of +entries+ with the writes it means.
          def each_entry_writes(entries, voicing, song: nil)
            return enum_for(:each_entry_writes, entries, voicing, song: song) unless block_given?

            note_volume = nil
            loudness = [] # what a new note's loudness has just written
            previous = nil
            effect_voices = 0 # the voices a sound effect holds, a bit each
            fade = nil # the fade the note just logged named
            side = nil # the speaker it plays from
            sounding = {} # what each channel's last note is, for a wobble of it
            rising = {} # whether each channel's last note is a song's that swells
            sides = {} # the speaker each channel's last note plays from, which its loudness keeps to
            entries.each do |entry|
              if entry.first == :voice
                sounding[entry[1]] = entry[3]
                rising[entry[1]] = swelling_note?(entry, voicing)
                sides[entry[1]] = entry[SIDE_OF_VOICE_ENTRY]
              end
              if entry.first == :loudness && rising[entry[1]]
                # A swell's own start only sets where it starts: the voice climbs by itself from there.
                strike = previous == :voice ? loudness_at(entry[1], entry[2], voicing, song) : swell_strike(entry, voicing, song)
                strike = heard_from_one_side(strike, sides[entry[1]]) if sides[entry[1]]
                yield entry, strike
                loudness = []
                previous = entry.first
                next
              end
              if entry.first == :wobble
                yield entry, wobble(entry[1], sounding.fetch(entry[1]), entry[2])
                next
              end
              if entry.first == :duty
                yield entry, shape(entry[1], nil, entry[2])
                next
              end

              effect_voices = held_by_effects(effect_voices, entry, voicing) if entry.first == :voice
              played = note_volume && wave_or_noise_note?(entry) ? [entry.first, entry.last.merge(volume: note_volume)] : entry
              note_volume = entry[4] if entry.first == :voice && !SQUARE_VOICES.key?(entry[1])
              note_volume = nil unless %i[voice loudness].include?(entry.first)
              if entry.first == :voice
                fade = entry[FADE_OF_VOICE_ENTRY]
                side = entry[SIDE_OF_VOICE_ENTRY]
              end
              writes = for_entry(played, voicing, effect_voices: effect_voices)
              writes = under_loudness(writes, loudness) if voice_own_entry?(entry)
              writes = with_fade(writes, fade) if fade && noise_note?(entry)
              writes = heard_from_one_side(writes, side) if side && (entry.first == :voice || voice_own_entry?(entry))
              if entry.first == :loudness && !entry[1].is_a?(Array) && sides[entry[1]]
                writes = heard_from_one_side(writes, sides[entry[1]])
              end
              loudness = entry.first == :loudness && previous == :voice ? writes : []
              previous = entry.first
              yield entry, writes
            end
          end

          # Whether a [:voice ...] +entry+ is a song's note the player holds at the music volume.
          def swelling_note?(entry, voicing)
            _, channel, who, frequency, _, fade = entry
            frequency.positive? && fade&.swells_by_itself? && CHANNEL_VOICES.fetch(channel) != WAVE_VOICE && !voicing.effects.include?(who)
          end

          # A voice's own entry after its note's loudness: the wave voice's volume stays as the loudness
          # wrote it, and the noise voice starts at the loudness's volume.
          def under_loudness(writes, loudness)
            registers = loudness.select { |write| write.first == :spu }.map { |write| write[1] }
            volume = loudness.find { |write| write.first == :level }&.at(2)
            writes.reject { |write| write.first == :spu && registers.include?(write[1]) }.map do |write|
              write.first == :loud && volume ? [:loud, write[1], volume, write[3]] : write
            end
          end

          # A drum's fade, given in the [:voice ...] before it, in place of the part's.
          def with_fade(writes, fade)
            writes.map { |write| write.first == :loud ? [:loud, write[1], write[2], signed_step(fade)] : write }
          end

          # A [:noise ...] entry that plays a note: a drum's fade is given in the [:voice ...] before it.
          def noise_note?(entry) = entry.first == :noise && entry.last.is_a?(Hash)

          # +voices+, the voices sound effects hold, after a [:voice ...] +entry+.
          def held_by_effects(voices, entry, voicing)
            _, channel, who, frequency, volume = entry
            bit = 1 << CHANNEL_VOICES.fetch(channel)
            voicing.effects.include?(who) && sounds?(channel, frequency, volume, entry[FADE_OF_VOICE_ENTRY]) ? voices | bit : voices & ~bit
          end

          # A [:wave ...] or [:noise ...] entry that plays a note, not a rest.
          def wave_or_noise_note?(entry) = %i[wave noise].include?(entry.first) && entry.last.is_a?(Hash)

          # The wave or noise voice's own entry, which a song's note there logs after its loudness.
          def voice_own_entry?(entry) = !entry.nil? && %i[wave stop_wave noise].include?(entry.first)

          # WHICH TUNE A STOP STOPPED, the program's to name and held to the log where the log says it too
          # (Genesis::ChipWrites.misnamed_stop): the index in +entries+ of the first stop that names another tune.
          def misnamed_stop(entries, voicing)
            heard = nil
            entries.each_with_index do |entry, i|
              case entry.first
              when :note then heard = entry[1] unless voicing.effects.include?(entry[1])
              when :stop_music
                return i if heard && entry[1] != heard

                heard = nil
              end
            end
            nil
          end

          # WHAT THE CHIP'S REGISTERS HOLD AFTER THE SOUND LOG +entries+, by their distance from 1F801C00h.
          # Nothing reaches the chip until the game calls `enable_sound` (Runtime::Sound). A voice that is
          # moving its own loudness has none to answer for: the log does not say where it has got to; nor a
          # note that slides its pitch. Key on and key off are gathered and written at the frame boundary, so
          # they are not here.
          def after(entries, voicing)
            held = {}
            moving = {}
            enabled = false
            each_entry_writes(entries, voicing) do |entry, writes|
              enabled ||= entry.first == :enabled
              next unless enabled

              writes.each { |write| hold_write(held, moving, write) }
            end
            held.except(*slide_registers(entries))
          end

          def hold_write(held, moving, write)
            case write.first
            when :spu then held[write[1]] = write[2]
            when :loud then hold_loudness(held, moving, write[1], write[2], !write[3].zero?, write[4] || BOTH_SIDES)
            when :level then hold_loudness(held, moving, write[1], write[2], moving[write[1]], write[3] || BOTH_SIDES)
            when :silence then VOICES.times { |voice| hold_loudness(held, moving, voice, 0, false, BOTH_SIDES) if write[1][voice] == 1 }
            end
          end

          def hold_loudness(held, moving, voice, volume, moves, side)
            moving[voice] = moves
            left = register(voice, H::SPU_VOLUME_LEFT)
            right = register(voice, H::SPU_VOLUME_RIGHT)
            if moves
              held.delete(left)
              held.delete(right)
            else
              held[left] = side == SIDES.fetch(:right) ? 0 : VOLUME_REGISTER.fetch(volume)
              held[right] = side == SIDES.fetch(:left) ? 0 : VOLUME_REGISTER.fetch(volume)
            end
          end

          # WHAT THE LOG CANNOT ANSWER FOR. A slide logs nothing as it moves, so while the last note of a
          # channel slides, its voice's pitch and loudness have no expected value.
          def slide_registers(entries)
            entries.select { |entry| entry.first == :voice && entry[3].positive? }.group_by { |entry| entry[1] }.flat_map do |channel, notes|
              next [] unless VBlank::Audio::PitchSlide.moves?(notes.last[SLIDE_OF_VOICE_ENTRY])

              voice = CHANNEL_VOICES.fetch(channel)
              [register(voice, H::SPU_PITCH), register(voice, H::SPU_VOLUME_LEFT), register(voice, H::SPU_VOLUME_RIGHT)]
            end
          end
        end
      end
    end
  end
end
