# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHAT A SOUND IS, IN THE S-DSP'S REGISTERS. The Super Nintendo's sound unit mixes eight
        # voices, and everything one of them does is a handful of registers: which recording it plays
        # (its source number, an entry in the sample table), how fast it reads through it (its
        # pitch), how loud it is on the left and on the right, how its loudness rises and falls (its
        # envelope), and the key-on register that starts it from the top. The console plays a sound
        # by writing those (Runtime::Sound's rt_sound_write); this module says which writes each of
        # the interpreter's sound-log entries means.
        #
        # The lowering writes them, and the checked run reads the emulator's registers after every
        # pass and holds them to the writes the interpreter's log up to then says (#after) — so a
        # write that never arrived, arrived late or arrived wrong shows up, in the sound unit itself.
        #
        # THE SQUARE VOICES. The Advance has two voices that play a square wave of their own, in four
        # widths. The S-DSP has none: it only plays recordings. So each width is a short looped
        # recording of a square wave (Samples), and a beep picks one by its source number: the one
        # whose wave is 32 samples long when the note is low enough, and the one of 8 samples above
        # that. Its pitch register, where $1000 reads 32000 samples a second (fullsnes, "SNES APU DSP
        # BRR Pitch"), is then the note's frequency * the wave's samples * $1000 / 32000.
        #
        # THE FADE. The Advance fades a beep a volume step at a time, a step every 1, 3 or 5 64ths of
        # a second (Audio::Sound::FADE_STEP_SIXTY_FOURTHS), so volume v fading :fast is gone in v/64
        # of a second, and a quiet beep sooner than a loud one. The S-DSP's envelope instead starts
        # each note at the top (the fastest attack, ADSR1 $8F) and, in its sustain mode, takes it
        # down a 256th of where it is, and one more, at every step (fullsnes, "SNES APU DSP ADSR/Gain
        # Envelope"); how loud the note is stays in its volume registers, eight steps a volume. So the
        # fade is chosen per beep: the step rate (fullsnes's table of them, RATE_SAMPLES) whose steps,
        # as many as it takes the envelope to fall from the top to where its top seven bits read
        # nought (#steps_to_silence), come nearest to the Advance's time for that volume and speed.
        # :none holds (rate nought).
        module DSPWrites
          # The voice beeps play on, as the Advance plays them on its second square voice, and the one
          # noise plays on, as the Advance's noise is its fourth voice.
          BEEP_VOICE = 1
          NOISE_VOICE = 3

          # THE WAVE VOICE, the Advance's third, plays the game's own 32-step waveforms (Samples.wave).
          # The Advance makes its four quieter loudnesses by cutting every step down, so each
          # loudness is a waveform of its own (#wave_steps), recorded at the loudness of a beep at
          # 15; the voice has no fade, so its envelope is a fixed gain at the top (ADSR1 bit 7 nought
          # and GAIN $7F) until stop_wave keys it off. A key-off holds until it is cleared, and a
          # key-on under it plays nothing (fullsnes, "KON/KOFF Notes"), so each wave clears it first.
          WAVE_VOICE = 2
          ADSR_OFF = 0x00 # ADSR1 with bit 7 nought: the envelope is GAIN's
          FIXED_TOP = 0x7F # GAIN with bit 7 nought: a fixed level, the most there is

          # NOISE. A hiss is the S-DSP's own noise generator, a register of fifteen random bits, as
          # the Advance's is: the noise voice's bit in NON switches it from its recording to the
          # generator, and the generator's clock is FLG's low five bits, one of the 32 rates (a rate
          # steps it 32000 / RATE_SAMPLES[rate] times a second, so 32000 at the most). A metallic
          # rattle is a recording instead (Samples::METALLIC), read one sample for each of the
          # Advance's steps. Both are clocked as the Advance clocks a hit: Audio::Sound's
          # NOISE_HIT_HALVINGS. The Advance clocks a :high hiss eight times as fast as a :mid one,
          # past the DSP's fastest; there the two come out only twice as far apart.
          #
          # THE GENERATOR IS LOUDER than a recording at the same volume: its output swings the whole
          # of $4000 either way (fullsnes, "NON"), and the recordings Samples makes swing 7 * 2^11 / 2.
          # The Advance's noise and square voices swing alike, so a hiss's volume registers are scaled
          # down by the two swings (HISS_SCALE), and a hiss is as loud as a beep at the same volume.
          #
          # FLG IS SHARED. Its top three bits mute the sound unit, hold every voice off and stop the
          # echo writing; its low five are the noise clock. So neither enable_sound nor a noise hit
          # writes all of FLG: each changes only its own bits, which the sound unit's program does
          # with the DSP's register in hand (Runtime::Sound's "set some bits" commands), written here
          # as [SET_BITS, FLAGS, mask, bits]. A hit before enable_sound sets the clock and leaves the
          # sound unit muted, as the Advance makes no sound before it either.
          #
          # KEY-OFF IS SHARED TOO, a bit a voice, and a voice's bit holds until something clears it: a
          # key-on under it plays nothing (fullsnes, "KON/KOFF Notes"). So a voice is let go by
          # setting its bit alone, and every key-on clears its own bit first (#key_on); writing all
          # of KOFF would let go of, or take back, another voice's note.
          SET_BITS = :set_bits
          SWITCHES = 0xE0
          NOISE_CLOCK = 0x1F
          GENERATOR_SWING = 0x4000
          HISS_SCALE = Rational(Samples::HIGH << Samples::SHIFT, 2 * GENERATOR_SWING)

          # A voice's registers, counted from its first ($x0).
          VOLUME_LEFT = 0x0
          VOLUME_RIGHT = 0x1
          PITCH_LOW = 0x2
          PITCH_HIGH = 0x3
          SOURCE = 0x4
          ADSR1 = 0x5
          ADSR2 = 0x6
          GAIN = 0x7

          # The registers for every voice at once (fullsnes, "SNES APU DSP Control Registers" and
          # "Volume Registers").
          MAIN_LEFT = 0x0C
          MAIN_RIGHT = 0x1C
          ECHO_LEFT = 0x2C
          ECHO_RIGHT = 0x3C
          PITCH_MODULATION = 0x2D
          NOISE_ON = 0x3D
          ECHO_ON = 0x4D
          KEY_ON = 0x4C
          KEY_OFF = 0x5C
          SAMPLE_TABLE = 0x5D
          FLAGS = 0x6C

          # FLG: not muted, not held in reset, and the echo never writing — its buffer would be
          # written over the sound unit's own memory, where the program is.
          SOUND_ON = 0x20
          # ...and as the sound unit starts: muted and every voice held off, said outright, since
          # what FLG reads before anything writes it is not to be relied on (fullsnes).
          SOUND_OFF = 0xE0
          # Main volume, the most there is (127, on both sides).
          MAIN_VOLUME = 0x7F

          # Fastest attack, ADSR on (ADSR1); the sustain level at the top (ADSR2's high three bits),
          # so the note goes straight to its sustain, whose rate (ADSR2's low five bits) is its fade.
          ATTACK = 0x8F
          SUSTAIN_AT_TOP = 0xE0

          # How many of the DSP's samples each of the 32 envelope rates waits between steps, by rate:
          # nought never steps (fullsnes, "ADSR/Gain (and Noise) Rates").
          RATE_SAMPLES = [nil, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80, 64, 48, 40,
                          32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1].freeze

          # The envelope's top, and the level below which its top seven bits (ENVX) read nought.
          ENVELOPE_TOP = 0x7FF
          ENVELOPE_SILENT = 0x10

          # Eight steps of the voice's volume register (0..127) a step of the game's (0..15).
          VOLUME_STEP = 8

          # The pitch register's scale, and the most it holds.
          PITCH_ONE = 0x1000
          DSP_RATE = 32_000
          PITCH_TOP = 0x3FFF

          module_function

          # What the sound unit is told once its program has been sent, before the game runs: where
          # the sample table is, and every voice quiet with no echo, noise or pitch modulation. FLG
          # is left as the sound unit starts it (muted and every voice held off) until enable_sound.
          def at_power_on(table_page)
            [[FLAGS, SOUND_OFF], [SAMPLE_TABLE, table_page], [ECHO_LEFT, 0], [ECHO_RIGHT, 0], [ECHO_ON, 0],
             [NOISE_ON, 0], [PITCH_MODULATION, 0], [KEY_OFF, 0]]
          end

          # A SONG'S PARTS play on the voices the Advance's are, by the channel the interpreter names
          # each by (Reference::Player#console_channel): the first square part on voice 0, the second
          # on voice 1, which beeps share as they share the Advance's second, a wave part on the wave
          # voice and a noise part on the noise voice. A square note holds at a fixed gain, as the
          # Advance's song notes hold their volume, and a rest lets the voice go. A wave or noise note
          # is logged as that voice's own entry too ([:wave ...], [:noise ...]), and those are its
          # writes. A tune that stops lets go of the voices its own parts play on and no other, as the
          # Advance's player does: a beep sounding beside a one-part tune is not cut off.
          SQUARE_VOICES = { 1 => 0, 2 => 1 }.freeze
          CHANNEL_VOICES = SQUARE_VOICES.merge(3 => WAVE_VOICE, 4 => NOISE_VOICE).freeze

          # WHAT A LOG ENTRY DOES NOT SAY. The interpreter logs a song's note as the voice set to a
          # frequency and volume, which is all the Advance's player writes; the square's width is the
          # part's, written once; and a tune stopping as [:stop_music], whichever tune it was. So the
          # writes are worked out with the game's +waves+ (its wave voice's waveforms, in the order its
          # build recorded them, Samples::FIRST_WAVE on), +parts+, each song's parts by [the song's
          # name, its channel] (a sound effect's among them), and +effects+, the names of the songs
          # that are sound effects.
          Voicing = Data.define(:waves, :parts, :effects) do
            def initialize(waves: [], parts: {}, effects: []) = super

            # The voices +song+'s parts play on, a bit each. A part that plays a recording plays in one of
            # Runtime::Recordings' places, which the tune lets go of itself.
            def song_voices(song)
              parts.keys.sum do |name, channel|
                name == song && !SNES::Music.recorded?(channel) ? 1 << CHANNEL_VOICES.fetch(channel) : 0
              end
            end
          end

          NO_VOICING = Voicing.new

          # The writes one sound-log entry means: [:enabled], [:beep, effect], [:noise, hit], [:wave,
          # params], [:stop_wave], a song's or a sound effect's [:note, ...] (nothing: the [:voice, ...]
          # after it is the note) and [:voice, channel, song, frequency, volume], [:sound_effect, name]
          # (nothing: its notes are its writes), and [:stop_music, name], the cartridge's, which lets go
          # of its voices but those a sound effect holds (+effect_voices+, a bit each). Each is
          # [register, value], or [SET_BITS, register, mask, bits].
          def for_entry(entry, voicing = NO_VOICING, song: nil, effect_voices: 0)
            case entry.first
            when :enabled then [[SET_BITS, FLAGS, SWITCHES, SOUND_ON], [MAIN_LEFT, MAIN_VOLUME], [MAIN_RIGHT, MAIN_VOLUME]]
            when :beep then beep(entry.last)
            when :noise then entry.last ? noise(entry.last) : key_off(1 << NOISE_VOICE)
            when :wave then wave(entry.last, voicing.waves)
            when :stop_wave then key_off(1 << WAVE_VOICE)
            when :note, :sound_effect, :sample, :stop_sample, :wobble, :duty then [] # a recording's voice is the count's (Runtime::Recordings), and a wobble's or a shape's note is #each_entry_writes's to know
            when :voice then song_note(*entry[1, 4], voicing.parts, fade: entry[FADE_OF_VOICE_ENTRY], duty: entry[DUTY_OF_VOICE_ENTRY])
            when :stop_music then key_off(voicing.song_voices(entry.fetch(1)) & ~effect_voices & 0xFF)
            when :loudness then loudness_at(entry[1], entry[2], voicing, song)
            else raise ArgumentError, "the Super Nintendo build does not play #{entry.first.inspect} yet"
            end
          end

          # Whether a song's or an effect's note on +channel+ makes a sound (Reference::Player#sounds?):
          # not a rest, not at volume nought, nor on the wave voice at a volume whose nearest of that
          # voice's loudnesses is none.
          def sounds?(channel, frequency, volume, fade = nil)
            return false unless frequency.positive?
            return true if fade&.swells_by_itself?
            return false unless volume.positive?

            CHANNEL_VOICES.fetch(channel) != WAVE_VOICE || VBlank::Audio::Sound.wave_level(volume) != :mute
          end

          # THE MUSIC VOLUME reaching +song+'s note on channel +channel+, now at +volume+ (0..15): a
          # square or noise voice's volume registers, as its note's are worked out; the wave voice,
          # whose loudness is in its recording, changed to the part's waveform at the nearest of the
          # Advance's five loudnesses to +volume+, as the Advance plays it.
          def loudness_at(channel, volume, voicing, song)
            part = voicing.parts.fetch([song, channel]) { raise ArgumentError, "no part of #{song.inspect} on #{channel}" }
            voice = CHANNEL_VOICES.fetch(channel)
            base = voice << 4
            if voice == WAVE_VOICE
              steps = wave_steps({ shape: part.wave, volume: volume })
              index = voicing.waves.index(steps) or raise ArgumentError, "the waveform #{steps.inspect} was not recorded"
              return [[base + SOURCE, Samples::FIRST_WAVE + index]]
            end

            level = volume * VOLUME_STEP
            level = (level * HISS_SCALE).round if voice == NOISE_VOICE && !part.metallic
            [[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level]]
          end

          # A song's note on channel +channel+: on a square voice, the note held at a fixed gain, or
          # the voice let go for a rest or a note at volume nought; on the wave or noise voice,
          # nothing, since the entry after it is the note. +fade+ is an Audio::NoteFade the note said.
          def song_note(channel, song, frequency, volume, parts, fade: nil, duty: nil)
            voice = SQUARE_VOICES[channel] or return []
            return key_off(1 << voice) unless sounds?(channel, frequency, volume, fade)

            duty = duty&.at(0) || parts.fetch([song, channel]) { raise ArgumentError, "no part of #{song.inspect} on #{channel}" }.duty
            base = voice << 4
            wave = wave_for(frequency)
            pitch = pitch_for(frequency, wave)
            level = volume * VOLUME_STEP
            note_envelope([[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level], [base + PITCH_LOW, pitch & 0xFF],
                           [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, Samples.source(duty, wave)],
                           [base + ADSR1, ADSR_OFF], [base + GAIN, FIXED_TOP]], volume, fade) + key_on(voice)
          end

          # A NOTE WOBBLING: the voice on +channel+ playing a +frequency+ Hz note +steps+ of the Advance's
          # pitch number from it (Audio::Vibrato), which the voice's pitch registers say on the wave
          # length the note is on. The note is not started again, so nothing else is written.
          def wobble(channel, frequency, steps)
            voice = CHANNEL_VOICES.fetch(channel)
            wave_voice = voice == WAVE_VOICE
            pitch_clock = wave_voice ? 65_536.0 : 131_072.0
            moved = pitch_clock / ((pitch_clock / frequency) - steps)
            pitch = pitch_for(moved, wave_voice ? Samples::LONG_WAVE : wave_for(frequency))
            [[(voice << 4) + PITCH_LOW, pitch & 0xFF], [(voice << 4) + PITCH_HIGH, pitch >> 8]]
          end

          # A SQUARE NOTE STEPPING ITS SHAPE: the voice on +channel+ reading the recording of +shape+
          # for a +frequency+ Hz note.
          def shape(channel, frequency, shape)
            [[(CHANNEL_VOICES.fetch(channel) << 4) + SOURCE, Samples.source(shape, wave_for(frequency))]]
          end

          # A NOTE SLIDING: the voice on +channel+ taken to the pitch of +count+ (Audio::PitchSlide),
          # the chip reading the recording for +shape+ when the slide has left the wave length of
          # +was+, the count before. The note is not started again, so nothing else is written. With
          # no +shape+, a note stepping through its shapes, whose steps are written for the wave
          # length of +from+, its first Hz: it stays on that one, and past the top of what that
          # reaches holds there.
          def slide_step(channel, count, was, shape, from:)
            frequency = slide_frequency(count)
            wave = wave_for(shape ? frequency : from)
            base = CHANNEL_VOICES.fetch(channel) << 4
            pitch = pitch_for(frequency, wave)
            [[base + PITCH_LOW, pitch & 0xFF], [base + PITCH_HIGH, pitch >> 8]] +
              (!shape || wave == wave_for(slide_frequency(was)) ? [] : [[base + SOURCE, Samples.source(shape, wave)]])
          end

          # The Hz of a voice's pitch count.
          def slide_frequency(count) = SQUARE_CLOCK / (VBlank::Audio::PitchSlide::COUNT_TOP - count)

          # The pitch count of a +frequency+ Hz note.
          def slide_count(frequency) = VBlank::Audio::PitchSlide::COUNT_TOP - (SQUARE_CLOCK / frequency).round

          SQUARE_CLOCK = 131_072.0

          # A SLIDE RUN OFF THE TOP: the voice silent at once. Only the envelope is written, since a
          # key-off held would stay in a register the sound log has an answer for.
          def slide_stop(channel)
            base = CHANNEL_VOICES.fetch(channel) << 4
            [[base + ADSR1, ADSR_OFF], [base + GAIN, 0]]
          end

          # Where a [:voice ...] entry says its fade, its slide and its shape (IR::Tunes.voice_entry).
          DUTY_OF_VOICE_ENTRY = 9
          FADE_OF_VOICE_ENTRY = 5
          SLIDE_OF_VOICE_ENTRY = 6

          # GAIN's mode that climbs a step at a time, 32 of the envelope's 0x7FF at each.
          GAIN_RISES = 0xC0
          GAIN_RISE_STEPS = 64

          # A NOTE THAT CHANGES ITS OWN LOUDNESS. The sound chip counts a voice's envelope by itself,
          # as the Advance's voice counts its volume, so a fade is one write: the envelope's rate. A
          # fade goes down the way a beep's does (#fade_rate). A swell climbs from nought to the top
          # of the envelope, with the voice's volume at the top, in the time the Advance's voice
          # takes to climb all fifteen steps; a note the Advance starts part way up starts at the
          # bottom here. +writes+ are a voice's, with its envelope said.
          def note_envelope(writes, volume, fade)
            return writes if fade.nil? || fade.step.zero?
            return swelling_envelope(writes, fade) if fade.swells?

            writes.flat_map do |write|
              register = write.first
              next [write] unless write.length == 2 && (register & 0x0F) == ADSR1

              [[register, ATTACK], [register - ADSR1 + ADSR2, SUSTAIN_AT_TOP | rate_to_silence(volume, fade.step)]]
            end.reject { |write| write.length == 2 && (write.first & 0x0F) == GAIN }
          end

          def swelling_envelope(writes, fade)
            top = swell_top(writes.first.first >> 4)
            rate = swell_rate(fade)
            writes.filter_map do |write|
              register = write.first
              next write unless write.length == 2

              case register & 0x0F
              when VOLUME_LEFT, VOLUME_RIGHT then [register, top]
              when ADSR1 then [register, ADSR_OFF]
              when ADSR2 then nil
              else write
              end
            end + [[(writes.first.first & 0xF0) + GAIN, GAIN_RISES | rate]]
          end

          def swell_rate(fade) = nearest_rate(fade.step * 15 * DSP_RATE / 64.0 / GAIN_RISE_STEPS)

          # The volume of +voice+ while its note swells: the most there is, as it climbs.
          def swell_top(voice) = voice == NOISE_VOICE ? (15 * VOLUME_STEP * HISS_SCALE).round : 15 * VOLUME_STEP

          # A SWELLING NOTE STRUCK AT THE MUSIC VOLUME, where the player's count says it is
          # (Reference::Player#step_swells): an +entry+ of [:loudness, channel, volume], with the
          # swell after it if it climbs on. Holding, the envelope stops at its top and the voice's
          # volume says the loudness, as any held note's does; the volume goes first, since the other
          # order is full volume for a moment. Climbing on, the envelope is put where the loudness
          # is and the voice's volume back at the top. The sound chip reads a register once a sample,
          # so the volume between the envelope's two writes is what gives it time to see the first.
          def swell_strike(entry, voicing, song)
            _, channel, volume, swelling = entry
            voice = CHANNEL_VOICES.fetch(channel)
            base = voice << 4
            return loudness_at(channel, volume, voicing, song) + [[base + GAIN, FIXED_TOP]] unless swelling

            top = swell_top(voice)
            [[base + GAIN, volume * FIXED_TOP / 15], [base + VOLUME_LEFT, top], [base + VOLUME_RIGHT, top],
             [base + GAIN, GAIN_RISES | swell_rate(swelling)]]
          end

          # The wave voice playing +params+ ({shape:, frequency:, volume:}, as the interpreter logs a
          # wave): its recording among +waves+, read at the note's pitch, held at a fixed gain.
          def wave(params, waves)
            base = WAVE_VOICE << 4
            steps = wave_steps(params)
            index = waves.index(steps) or raise ArgumentError, "the waveform #{steps.inspect} was not recorded for this game"
            pitch = pitch_for(params[:frequency], Samples::LONG_WAVE)
            level = VBlank::Audio::Sound::WAVE_STEP_MAX * VOLUME_STEP
            [[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level], [base + PITCH_LOW, pitch & 0xFF],
             [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, Samples::FIRST_WAVE + index], [base + ADSR1, ADSR_OFF],
             [base + GAIN, FIXED_TOP]] + key_on(WAVE_VOICE)
          end

          # Voice +voice+ started from the top: its key-off bit cleared, then its key-on.
          def key_on(voice) = [[SET_BITS, KEY_OFF, 1 << voice, 0], [KEY_ON, 1 << voice]]

          # The voices whose bits +voices+ holds let go, every other voice's key-off as it is.
          def key_off(voices) = [[SET_BITS, KEY_OFF, voices, voices]]

          # The 32 steps a wave plays, cut down to its loudness as the Advance cuts them
          # (Audio::Sound.wave_step_at): what its recording holds.
          def wave_steps(params)
            sound = VBlank::Audio::Sound
            volume = params[:volume]
            level = volume.is_a?(Symbol) ? volume : sound.wave_level(volume)
            sound.wavetable(params[:shape]).map { |step| sound.wave_step_at(step, level) }
          end

          # A beep: its voice's registers, and key-on last, which starts it from the top.
          def beep(effect)
            base = BEEP_VOICE << 4
            wave = wave_for(effect.frequency)
            pitch = pitch_for(effect.frequency, wave)
            loudness(base, effect.volume * VOLUME_STEP, effect.volume, effect.decay) +
              [[base + PITCH_LOW, pitch & 0xFF], [base + PITCH_HIGH, pitch >> 8],
               [base + SOURCE, Samples.source(effect.duty, wave)], *key_on(BEEP_VOICE)]
          end

          # A noise hit (Audio::Sound.resolve_noise's hash, or a song's noise note, whose pitch is a
          # frequency): the noise voice's loudness and fade, as a beep's; then the generator, its
          # clock set and the voice switched to it, or the metallic recording read at the clock; and
          # key-on last.
          def noise(hit)
            base = NOISE_VOICE << 4
            clock = noise_clock(hit[:pitch])
            if hit[:metallic]
              pitch = (clock * PITCH_ONE / DSP_RATE.to_f).round.clamp(1, PITCH_TOP)
              loudness(base, hit[:volume] * VOLUME_STEP, hit[:volume], hit[:decay]) +
                [[base + PITCH_LOW, pitch & 0xFF], [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, Samples::METALLIC],
                 [NOISE_ON, 0], *key_on(NOISE_VOICE)]
            else
              # The generator still reads a recording beside it, and one that ends would end the
              # noise (fullsnes, "NON"): a looping one, read at any pitch.
              loudness(base, (hit[:volume] * VOLUME_STEP * HISS_SCALE).round, hit[:volume], hit[:decay]) +
                [[base + PITCH_LOW, 0], [base + PITCH_HIGH, PITCH_ONE >> 8],
                 [base + SOURCE, Samples.source(:half, Samples::LONG_WAVE)],
                 [SET_BITS, FLAGS, NOISE_CLOCK, noise_rate(clock)], [NOISE_ON, 1 << NOISE_VOICE], *key_on(NOISE_VOICE)]
            end
          end

          # A voice's volume registers (+level+, left and right) and its envelope: the fastest attack,
          # and the fade for a note of +volume+ (0..15) at +decay+.
          def loudness(base, level, volume, decay)
            [[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level], [base + ADSR1, ATTACK],
             [base + ADSR2, SUSTAIN_AT_TOP | fade_rate(volume, decay)]]
          end

          # How many times a second the Advance steps its noise for +pitch+: a hit's word (:high, :mid,
          # :low), or a song note's frequency, at the rung nearest it (Audio::Sound.noise_rung).
          def noise_clock(pitch)
            sound = VBlank::Audio::Sound
            return sound.noise_rung_hz(0, sound::NOISE_HIT_HALVINGS.fetch(pitch)) if pitch.is_a?(Symbol)

            sound.noise_rung_hz(*sound.noise_rung(pitch))
          end

          # The noise generator's rate (1..31) nearest to stepping +clock+ times a second.
          def noise_rate(clock)
            (1...RATE_SAMPLES.size).min_by { |rate| (Math.log(DSP_RATE.to_f / RATE_SAMPLES[rate]) - Math.log(clock)).abs }
          end

          # The length of wave a +frequency+ Hz note is played on: the long one, unless the pitch
          # register cannot read it that fast.
          def wave_for(frequency) = raw_pitch(frequency, Samples::LONG_WAVE) <= PITCH_TOP ? Samples::LONG_WAVE : Samples::SHORT_WAVE

          # The pitch register for a +frequency+ Hz note on a wave of +wave+ samples, held to what the
          # register holds: a note above what the short wave reaches plays at the highest it can.
          def pitch_for(frequency, wave) = raw_pitch(frequency, wave).clamp(1, PITCH_TOP)

          def raw_pitch(frequency, wave) = ((frequency * wave * PITCH_ONE) / DSP_RATE.to_f).round

          # The sustain rate (0..31) that fades a note of +volume+ (0..15) at +decay+ in about the
          # Advance's time for it; nought, which never steps, for :none.
          def fade_rate(volume, decay)
            step = VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(decay)
            step.zero? ? 0 : rate_to_silence(volume, step)
          end

          # ...for a fade whose step is +step+ 64ths of a second.
          def rate_to_silence(volume, step) = nearest_rate(volume * step * DSP_RATE / 64.0 / steps_to_silence)

          # The envelope rate nearest a step every +samples+ of the DSP's.
          def nearest_rate(samples)
            (1...RATE_SAMPLES.size).min_by { |rate| (Math.log(RATE_SAMPLES[rate]) - Math.log([samples, 1].max)).abs }
          end

          # How many steps the sustain mode takes the envelope from the top to where ENVX reads nought:
          # each step takes off ((level - 1) >> 8) + 1 (fullsnes).
          def steps_to_silence
            level = ENVELOPE_TOP
            steps = 0
            while level >= ENVELOPE_SILENT
              level -= ((level - 1) >> 8) + 1
              steps += 1
            end
            steps
          end

          # THE WRITES A RUN OF THE LOG MEANS, in order, with what one entry says of the next:
          #
          # - the tune a [:loudness ...] for a held note reaches is the one whose note was logged last
          #   (or +song+ before any), since a tune plays its first frame's notes, rests included, as
          #   it starts — and a sound effect's notes are not a tune's. A stop says its tune itself, as
          #   the cartridge logs it ([:stop_music, name], Music.stop_entry; #misnamed_stop holds it to
          #   the log);
          # - a song's note on the wave or noise voice plays at the note's own volume, which its
          #   [:voice ...] entry carries, where the [:wave ...] or [:noise ...] entry after it carries
          #   the part's (Reference::Player#log_wave_or_noise), as the Color's player plays it;
          # - that note's [:loudness ...], logged before the voice's own entry, is written there, and
          #   the voice's entry leaves out what it wrote, so the note starts at the music volume: the
          #   wave voice reads a new recording only from its loop point (fullsnes, "SRCN"), so one
          #   written after the key-on would play the note's own once round first.
          def writes(entries, voicing = NO_VOICING, song: nil)
            each_entry_writes(entries, voicing, song: song).flat_map { |_, writes| writes }
          end

          # Each of +entries+ with the writes it means, as #writes works them out.
          def each_entry_writes(entries, voicing = NO_VOICING, song: nil)
            return enum_for(:each_entry_writes, entries, voicing, song: song) unless block_given?

            note_volume = nil
            loudness = [] # the registers a new note's loudness has just written
            previous = nil
            effect_voices = 0 # the voices a sound effect holds, a bit each
            side = nil # the speaker the note just logged plays from, nil for both
            fade = nil # the fade it said
            sounding = {} # what each channel's last note is, for a wobble of it
            rising = {} # whether each channel's last note is a song's that swells
            sides = {} # the speaker each channel's last note plays from, nil for both
            entries.each do |entry|
              sounding[entry[1]] = entry[3] if entry.first == :voice
              rising[entry[1]] = swelling_note?(entry, voicing) if entry.first == :voice
              sides[entry[1]] = entry[SIDE_OF_VOICE_ENTRY] if entry.first == :voice
              if entry.first == :loudness && rising[entry[1]]
                # A swell's own start writes nothing: the voice stays at its full volume, climbing.
                strike = previous == :voice ? [] : swell_strike(entry, voicing, song)
                yield entry, sides[entry[1]] ? heard_from_one_side(strike, sides[entry[1]]) : strike
                loudness = []
                previous = entry.first
                next
              end
              if entry.first == :wobble
                yield entry, wobble(entry[1], sounding.fetch(entry[1]), entry[2])
                next
              end
              if entry.first == :duty
                yield entry, shape(entry[1], sounding.fetch(entry[1]), entry[2])
                next
              end

              song = entry[1] if entry.first == :note && !voicing.effects.include?(entry[1])
              effect_voices = held_by_effects(effect_voices, entry, voicing) if entry.first == :voice
              played = note_volume && wave_or_noise_note?(entry) ? [entry.first, entry.last.merge(volume: note_volume)] : entry
              note_volume = entry[4] if entry.first == :voice && !SQUARE_VOICES.key?(entry[1])
              note_volume = nil unless %i[voice loudness].include?(entry.first)
              if entry.first == :voice
                side = entry[SIDE_OF_VOICE_ENTRY]
                fade = entry[FADE_OF_VOICE_ENTRY]
              end
              writes = for_entry(played, voicing, song: song, effect_voices: effect_voices)
              writes = writes.reject { |register, *| loudness.include?(register) } if voice_own_entry?(entry)
              writes = note_envelope(writes, entry.first == :noise ? entry.last[:volume] : 0, fade) if fade && noise_note?(entry)
              writes = heard_from_one_side(writes, side) if side && (entry.first == :voice || voice_own_entry?(entry))
              writes = heard_from_one_side(writes, sides[entry[1]]) if entry.first == :loudness && sides[entry[1]]
              # A note's loudness follows its [:voice ...]; one that does not is a held note's, at a new level.
              loudness = entry.first == :loudness && previous == :voice ? writes.map(&:first) : []
              previous = entry.first
              yield entry, writes
            end
          end

          # Whether a [:voice ...] +entry+ is a song's note the player holds at the music volume.
          def swelling_note?(entry, voicing)
            _, channel, who, frequency, _, fade = entry
            frequency.positive? && fade&.swells_by_itself? && CHANNEL_VOICES.fetch(channel) != WAVE_VOICE && !voicing.effects.include?(who)
          end

          # A [:noise ...] entry that plays a note: a drum's fade is said in the [:voice ...] before it.
          def noise_note?(entry) = entry.first == :noise && entry.last.is_a?(Hash)

          # Where a [:voice ...] entry says its side (IR::Tunes.voice_entry).
          SIDE_OF_VOICE_ENTRY = 8

          # A NOTE FROM ONE SPEAKER: each voice of the sound chip has a volume for each side, so the
          # other side's is nought (+side+ :left or :right).
          def heard_from_one_side(writes, side)
            silent = side == :left ? VOLUME_RIGHT : VOLUME_LEFT
            writes.map { |write| write.length == 2 && (write.first & 0x0F) == silent ? [write.first, 0] : write }
          end

          # +voices+, the voices sound effects hold, after a [:voice ...] +entry+: whoever's note it is
          # took the voice (only a note that takes it is logged), and holds it while it sounds
          # (Reference::Player#claim_channel) — so a sound effect's sounding note holds it for the
          # effect, and anything else lets it go from one.
          def held_by_effects(voices, entry, voicing)
            _, channel, who, frequency, volume, fade = entry
            bit = 1 << CHANNEL_VOICES.fetch(channel)
            voicing.effects.include?(who) && sounds?(channel, frequency, volume, fade) ? voices | bit : voices & ~bit
          end

          # A [:wave ...] or [:noise ...] entry that plays a note, not a rest.
          def wave_or_noise_note?(entry) = %i[wave noise].include?(entry.first) && entry.last.is_a?(Hash)

          # The wave or noise voice's own entry, which a song's note there logs after its loudness.
          def voice_own_entry?(entry) = !entry.nil? && %i[wave stop_wave noise].include?(entry.first)

          # The first of the voices a game's own recordings play on (Runtime::Recordings), past the
          # Advance's four; and the bits of KON and KOFF that are those four's, which the recordings
          # leave alone.
          FIRST_RECORDING_VOICE = 4
          CONSOLE_VOICE_BITS = (1 << FIRST_RECORDING_VOICE) - 1

          # +held+ (#after's registers) without what a recording the game plays shares: KON, which
          # holds whichever voice was keyed on last, and KOFF's bits past the console voices'.
          def console_voices_only(held)
            held.except(KEY_ON).tap { |kept| kept[KEY_OFF] &= CONSOLE_VOICE_BITS if kept.key?(KEY_OFF) }
          end

          # What the registers hold after the sound log +entries+, by register, for each one written,
          # and FLG and KOFF, which the sound unit starts as at_power_on says and whose bits an entry
          # changes only some of. +voicing+ as for #for_entry.
          # WHICH TUNE A STOP STOPPED is the cartridge's to say (Music.stop_entry), since the
          # interpreter's [:stop_music] does not. Where a tune has logged a note since the last stop,
          # the log says it too, and the two must agree: the index in +entries+ (the cartridge's log,
          # stops named) of the first stop that names another tune, or nil. With no note since the
          # last stop — a tune whose every voice an effect holds — the cartridge's word stands.
          def misnamed_stop(entries, voicing = NO_VOICING)
            heard = nil # the tune whose note was logged since the last stop
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

          def after(entries, voicing = NO_VOICING)
            held = { FLAGS => SOUND_OFF, KEY_OFF => 0 }
            writes(entries, voicing).each do |register, *value|
              if register == SET_BITS
                register, mask, bits = value
                held[register] = (held[register] & ~mask & 0xFF) | (bits & mask)
              else
                held[register] = value.first
              end
            end
            held.except(*slide_registers(entries))
          end

          # WHAT THE LOG CANNOT ANSWER FOR. A slide logs nothing as it moves, on the interpreter as on
          # the Advance, whose voice does the moving. So while the last note of a channel slides,
          # the registers the player moves it with have no expected value. A rest or a tune's stop
          # leaves them where the slide took them, so it is the last note that sounded that says.
          def slide_registers(entries)
            entries.select { |entry| entry.first == :voice && entry[3].positive? }.group_by { |entry| entry[1] }.flat_map do |channel, notes|
              next [] unless VBlank::Audio::PitchSlide.moves?(notes.last[SLIDE_OF_VOICE_ENTRY])

              base = CHANNEL_VOICES.fetch(channel) << 4
              [base + PITCH_LOW, base + PITCH_HIGH, base + SOURCE, base + ADSR1, base + GAIN]
            end
          end
        end
      end
    end
  end
end
