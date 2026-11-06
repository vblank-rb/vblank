# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # WHAT A SOUND IS, ON A GENESIS'S TWO SOUND CHIPS. The console plays a game's sounds on the PSG, a
        # small chip with three square voices and a noise voice, and on the YM2612, a chip of six FM voices.
        # This module says which writes each of the interpreter's sound-log entries means; the lowering
        # makes them (Lowering::Sound), the player sends them (Runtime::Music), and the checked run reads
        # the chips after every pass and holds them to what the log up to then says (#after), so a write
        # that never arrived, or arrived wrong, shows up in the chip itself.
        #
        # THE SQUARE VOICES. The game's two square voices are the PSG's first two. A PSG voice is a length
        # of wave, ten bits of it counted in 32 ticks of the chip's clock, and a loudness. It has no width of
        # wave (every square is half up and half down), no speaker of its own and no way to fade, so the
        # width and the speaker a game says are not heard. Fades are the runtime's (Runtime::Sound): a
        # voice's loudness is kept in work RAM and moved a step at a time, as the Advance's voice moves
        # its own.
        #
        # LOUDNESS. A game's volume runs up in even steps, and the PSG's loudness down in steps of 2
        # decibels each, so a volume is written as the step nearest it (ATTENUATION).
        #
        # NOISE. The PSG's fourth voice hisses, or for a metallic hit rattles, and either can be stepped by
        # its third square voice, whose own sound stays off, so a hit can be at any pitch and not only the
        # noise voice's three.
        #
        # THE WAVE VOICE. A Genesis has no voice that plays 32 steps of a game's own, so the first FM voice
        # plays each waveform as a tone: its four operators each make a sine wave, at one, two, three and
        # four times the note's pitch, each as loud as that part of the waveform is (#operator_levels).
        # FM voices read loudness as how far down each operator is.
        #
        # Writes are:
        #   [:tone, voice, length]         a PSG voice's length of wave
        #   [:noise_setting, bits]         the noise voice's setting (NOISE_CLOCKED_BY_TONE with its bit for a hiss)
        #   [:fm, register, value]         a register of the FM chip, the second part's at $100 and up
        #   [:loud, voice, volume, step]   a PSG voice set to +volume+, then moved a step every +step+ 64ths of
        #                                  a second (up when +step+ is above nought, down when it is below)
        #   [:level, voice, volume]        a PSG voice set to +volume+, going on as it was
        #   [:silence, voices]             the voices whose bits are set stopped
        module ChipWrites
          # The game's voices, by the bit each has in a tune's voices and the number the runtime keeps a
          # PSG voice's loudness by. The wave voice is no PSG voice: its bit is the third, the place the
          # PSG's third voice would have, which plays no sound of its own here.
          BEEP_VOICE = 1
          WAVE_VOICE = 2
          NOISE_VOICE = 3
          NOISE_CLOCK_VOICE = 2 # The PSG voice that steps the noise voice

          SQUARE_VOICES = { 1 => 0, 2 => 1 }.freeze
          CHANNEL_VOICES = SQUARE_VOICES.merge(3 => WAVE_VOICE, 4 => NOISE_VOICE).freeze

          # What the noise voice's setting holds: the third voice's length of wave steps it, and the top bit
          # makes it a hiss rather than a rattle.
          NOISE_CLOCKED_BY_TONE = 3
          HISS = 4

          PSG_CLOCK = 3_579_545
          PSG_TOP = 1023 # The longest wave its ten bits hold

          # The loudest a volume can be written, and each volume's step down from that.
          SILENT = 15
          ATTENUATION = Ractor.make_shareable(Array.new(16) do |volume|
            volume.zero? ? SILENT : (-10 * Math.log10(volume / 15.0)).round
          end)

          # THE FM CHIP'S CLOCK, as a note's pitch is worked out from it: a voice counts by its frequency
          # number, up to eleven bits, at one of eight octaves (#fm_pitch).
          FM_RATE = 53_267.0
          FM_TOP = 2047

          # Its registers: the whole chip's, and a voice's, here the first voice's.
          KEY = 0x28
          DAC_ON = 0x2B
          DAC_SAMPLE = 0x2A
          KEY_ON = 0xF0
          KEY_OFF = 0x00
          OPERATOR_SETTINGS = 0x30 # The pitch multiple
          OPERATOR_LEVEL = 0x40 # How far down it is
          OPERATOR_ATTACK = 0x50
          OPERATOR_DECAY = 0x60
          OPERATOR_SUSTAIN = 0x70
          OPERATOR_RELEASE = 0x80
          OPERATOR_SHAPE = 0x90
          FREQUENCY_LOW = 0xA0
          FREQUENCY_HIGH = 0xA4
          ALGORITHM = 0xB0
          SPEAKERS = 0xB4
          BOTH_SPEAKERS = 0xC0
          LEFT_SPEAKER = 0x80
          RIGHT_SPEAKER = 0x40
          FOUR_SINES = 7 # The algorithm that adds the four operators, none changing another
          FASTEST_ATTACK = 31
          FASTEST_RELEASE = 0x0F
          # The chip keeps its operators in the order first, third, second, fourth.
          OPERATOR_PLACES = [0, 8, 4, 12].freeze
          QUIETEST = 127
          # What the wave voice is taken down by so a waveform at the top is about as loud as a square,
          # and a step of the chip's in decibels.
          WAVE_FLOOR = 10
          DECIBELS_A_STEP = 0.75

          # A SONG'S PARTS, as on the Super Nintendo (DSPWrites), say what a log entry does not: +parts+,
          # each song's parts by [the song's name, its channel] (a sound effect's among them), and
          # +effects+, the names of the songs that are sound effects.
          Voicing = Data.define(:parts, :effects) do
            def initialize(parts: {}, effects: []) = super

            # The voices +song+'s parts play on, a bit each. A part that plays a recording plays in
            # Runtime::Recordings' place, which the tune lets go of itself.
            def song_voices(song)
              parts.keys.sum do |name, channel|
                name == song && !Genesis::Music.recorded?(channel) ? 1 << CHANNEL_VOICES.fetch(channel) : 0
              end
            end
          end

          NO_VOICING = Voicing.new

          module_function

          # The writes one sound-log entry means.
          def for_entry(entry, voicing = NO_VOICING, song: nil, effect_voices: 0)
            case entry.first
            when :enabled then []
            when :beep then beep(entry.last)
            when :noise then entry.last ? noise(entry.last) : [[:silence, 1 << NOISE_VOICE]]
            when :wave then wave(entry.last)
            when :stop_wave then [[:silence, 1 << WAVE_VOICE]]
            when :note, :sound_effect, :sample, :stop_sample, :wobble, :duty then [] # a recording is Runtime::Recordings', and a wobble's or a shape's note #each_entry_writes's to know
            when :voice then song_note(*entry[1, 4], fade: entry[FADE_OF_VOICE_ENTRY])
            when :stop_music then [[:silence, voicing.song_voices(entry.fetch(1)) & ~effect_voices & 0xF]]
            when :loudness then entry[1].is_a?(Array) ? [] : loudness_at(entry[1], entry[2], voicing, song)
            else raise ArgumentError, "the Genesis build does not play #{entry.first.inspect} yet"
            end
          end

          # Whether a song's or an effect's note on +channel+ makes a sound (Reference::Player#sounds?).
          def sounds?(channel, frequency, volume, fade = nil)
            return false unless frequency.positive?
            return true if fade&.swells_by_itself?
            return false unless volume.positive?

            CHANNEL_VOICES.fetch(channel) != WAVE_VOICE || VBlank::Audio::Sound.wave_level(volume) != :mute
          end

          # THE MUSIC VOLUME reaching +song+'s note on +channel+, now at +volume+: a PSG voice's loudness,
          # or how far down the wave voice's four operators are.
          def loudness_at(channel, volume, voicing, song)
            part = voicing.parts.fetch([song, channel]) { raise ArgumentError, "no part of #{song.inspect} on #{channel}" }
            voice = CHANNEL_VOICES.fetch(channel)
            return wave_levels(part.wave, VBlank::Audio::Sound.wave_level(volume)) if voice == WAVE_VOICE

            [[:level, voice, volume]]
          end

          # A song's note on a square voice, or the voice stopped for a rest; on the wave or noise voice
          # nothing, since the entry after it is the note. +fade+ is an Audio::NoteFade the note said.
          def song_note(channel, _song, frequency, volume, fade: nil)
            voice = SQUARE_VOICES[channel] or return []
            return [[:silence, 1 << voice]] unless sounds?(channel, frequency, volume, fade)

            [[:tone, voice, tone_length(frequency)], [:loud, voice, volume, signed_step(fade)]]
          end

          # A NOTE WOBBLING: the voice on +channel+ playing a +frequency+ Hz note +steps+ of the Advance's
          # pitch number from it (Audio::Vibrato). The note is not started again.
          def wobble(channel, frequency, steps)
            voice = CHANNEL_VOICES.fetch(channel)
            pitch_clock = voice == WAVE_VOICE ? 65_536.0 : 131_072.0
            moved = pitch_clock / ((pitch_clock / frequency) - steps)
            return fm_frequency(moved) if voice == WAVE_VOICE
            return [] if voice == NOISE_VOICE

            [[:tone, voice, tone_length(moved)]]
          end

          # A square note stepping its shape: nothing to write, since a PSG voice has only the one.
          def shape(_channel, _frequency, _shape) = []

          # A NOTE SLIDING: the voice on +channel+ taken to the pitch of +count+ (Audio::PitchSlide).
          def slide_step(channel, count, _was, _shape, from:)
            _ = from
            [[:tone, CHANNEL_VOICES.fetch(channel), tone_length(slide_frequency(count))]]
          end

          SQUARE_CLOCK = 131_072.0

          # The Hz of a voice's pitch count, and the pitch count of a +frequency+ Hz note.
          def slide_frequency(count) = SQUARE_CLOCK / (VBlank::Audio::PitchSlide::COUNT_TOP - count)
          def slide_count(frequency) = VBlank::Audio::PitchSlide::COUNT_TOP - (SQUARE_CLOCK / frequency).round

          # A slide run off the top: the voice silent at once.
          def slide_stop(channel) = [[:silence, 1 << CHANNEL_VOICES.fetch(channel)]]

          # Where a [:voice ...] entry says its fade, its slide and its side (IR::Tunes.voice_entry).
          FADE_OF_VOICE_ENTRY = 5
          SLIDE_OF_VOICE_ENTRY = 6
          SIDE_OF_VOICE_ENTRY = 8

          # A SWELLING NOTE STRUCK AT THE MUSIC VOLUME, where the player's count says it is
          # (Reference::Player#step_swells): an +entry+ of [:loudness, channel, volume], with the swell
          # after it if it climbs on. Here the climbing is the runtime's already, so it is told where the
          # note is and how it goes on.
          def swell_strike(entry, _voicing, _song)
            _, channel, volume, swelling = entry
            [[:loud, CHANNEL_VOICES.fetch(channel), volume, swelling ? swelling.step : 0]]
          end

          # A note from one speaker: only an FM voice has speakers. +side+ is :left or :right.
          def heard_from_one_side(writes, side)
            writes.map do |write|
              next write unless write.first == :fm && write[1] == SPEAKERS

              [:fm, SPEAKERS, side == :left ? LEFT_SPEAKER : RIGHT_SPEAKER]
            end
          end

          # A beep: its voice's length of wave and its loudness.
          def beep(effect)
            step = VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(effect.decay)
            [[:tone, BEEP_VOICE, tone_length(effect.frequency)], [:loud, BEEP_VOICE, effect.volume, -step]]
          end

          # A noise hit (Audio::Sound.resolve_noise's hash, or a song's noise note, whose pitch is a
          # frequency): the third voice's length of wave stepping it, the setting, and its loudness.
          def noise(hit)
            step = VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(hit[:decay])
            setting = NOISE_CLOCKED_BY_TONE | (hit[:metallic] ? 0 : HISS)
            [[:tone, NOISE_CLOCK_VOICE, noise_length(hit[:pitch])], [:noise_setting, setting],
             [:loud, NOISE_VOICE, hit[:volume], -step]]
          end

          # How many times a second the Advance steps its noise for +pitch+: a hit's word (:high, :mid,
          # :low), or a song note's frequency, at the rung nearest it (Audio::Sound.noise_rung).
          def noise_clock(pitch)
            sound = VBlank::Audio::Sound
            return sound.noise_rung_hz(0, sound::NOISE_HIT_HALVINGS.fetch(pitch)) if pitch.is_a?(Symbol)

            sound.noise_rung_hz(*sound.noise_rung(pitch))
          end

          def noise_length(pitch) = (PSG_CLOCK / (32.0 * noise_clock(pitch))).round.clamp(1, PSG_TOP)

          # A PSG voice's length of wave for a +frequency+ Hz note, held to what it holds.
          def tone_length(frequency) = (PSG_CLOCK / (32.0 * frequency)).round.clamp(1, PSG_TOP)

          # A fade as the runtime's step: above nought for a swell, below for a fade, nought for none.
          def signed_step(fade)
            return 0 unless fade

            fade.swells? ? fade.step : -fade.step
          end

          # THE WAVE VOICE PLAYING +params+ ({shape:, frequency:, volume:}, as the interpreter logs a wave):
          # stopped, set to the waveform's tone, and started.
          def wave(params)
            volume = params[:volume]
            level = volume.is_a?(Symbol) ? volume : VBlank::Audio::Sound.wave_level(volume)
            settings = OPERATOR_PLACES.each_with_index.flat_map do |place, operator|
              [[OPERATOR_SETTINGS, operator + 1], [OPERATOR_ATTACK, FASTEST_ATTACK], [OPERATOR_DECAY, 0], [OPERATOR_SUSTAIN, 0],
               [OPERATOR_RELEASE, FASTEST_RELEASE], [OPERATOR_SHAPE, 0]].map { |register, value| [:fm, register + place, value] }
            end
            [[:fm, KEY, KEY_OFF], *settings, [:fm, ALGORITHM, FOUR_SINES], [:fm, SPEAKERS, BOTH_SPEAKERS],
             *wave_levels(params[:shape], level), *fm_frequency(params[:frequency]), [:fm, KEY, KEY_ON]]
          end

          # How far down each of the wave voice's operators is for the waveform +shape+ at +level+
          # (Audio::Sound::WAVE_LEVEL_STEPS).
          def wave_levels(shape, level)
            down = level_down(level)
            operator_levels(shape).zip(OPERATOR_PLACES).map do |operator_down, place|
              [:fm, OPERATOR_LEVEL + place, (operator_down + down + WAVE_FLOOR).clamp(0, QUIETEST)]
            end
          end

          # The chip's steps down a quarter, a half and three quarters of full are, none for full, and
          # the whole way for :mute.
          def level_down(level)
            quarters = VBlank::Audio::Sound.wave_level_quarters(level)
            return QUIETEST if quarters.zero?

            (-20 * Math.log10(quarters / 4.0) / DECIBELS_A_STEP).round
          end

          # How far down each of four sines at the first four multiples of the note is, for the 32 steps
          # of +shape+: each is as loud as that multiple is in the waveform (a Fourier series, cut off at
          # the fourth), the loudest at nought.
          def operator_levels(shape)
            steps = VBlank::Audio::Sound.wavetable(shape)
            sizes = (1..4).map do |multiple|
              along = steps.each_with_index.sum { |step, i| step * Math.cos(2 * Math::PI * multiple * i / steps.size) }
              across = steps.each_with_index.sum { |step, i| step * Math.sin(2 * Math::PI * multiple * i / steps.size) }
              Math.hypot(along, across)
            end
            loudest = sizes.max
            sizes.map do |size|
              next QUIETEST if loudest.zero? || size < loudest / 1000.0

              (-20 * Math.log10(size / loudest) / DECIBELS_A_STEP).round.clamp(0, QUIETEST)
            end
          end

          # The FM chip's two pitch registers for a +frequency+ Hz note, the high one first, since the
          # low one is what the chip takes them up on.
          def fm_frequency(frequency)
            block, number = fm_pitch(frequency)
            [[:fm, FREQUENCY_HIGH, (block << 3) | (number >> 8)], [:fm, FREQUENCY_LOW, number & 0xFF]]
          end

          # The octave and frequency number of a +frequency+ Hz note: the lowest octave that holds it,
          # which keeps the most bits of the pitch.
          def fm_pitch(frequency)
            block = (0..7).find { |octave| number_at(frequency, octave) <= FM_TOP } || 7
            [block, number_at(frequency, block).clamp(1, FM_TOP)]
          end

          def number_at(frequency, block) = (frequency * (1 << (21 - block)) / FM_RATE).round

          # THE WRITES A RUN OF THE LOG MEANS, in order, with what one entry says of the next, as
          # DSPWrites works them out: the tune a held note's [:loudness ...] reaches is the one whose
          # note was logged last; a song's note on the wave or noise voice plays at the note's own
          # volume, which its [:voice ...] entry carries; and that note's [:loudness ...], logged before
          # the voice's own entry, stands over it, so the note starts at the music volume.
          def writes(entries, voicing = NO_VOICING, song: nil)
            each_entry_writes(entries, voicing, song: song).flat_map { |_, writes| writes }
          end

          # Each of +entries+ with the writes it means.
          def each_entry_writes(entries, voicing = NO_VOICING, song: nil)
            return enum_for(:each_entry_writes, entries, voicing, song: song) unless block_given?

            note_volume = nil
            loudness = [] # what a new note's loudness has just written
            previous = nil
            effect_voices = 0 # the voices a sound effect holds, a bit each
            side = nil # the speaker the note just logged plays from
            fade = nil # the fade it said
            sounding = {} # what each channel's last note is, for a wobble of it
            rising = {} # whether each channel's last note is a song's that swells
            sides = {} # the speaker each channel's last note plays from
            entries.each do |entry|
              if entry.first == :voice
                sounding[entry[1]] = entry[3]
                rising[entry[1]] = swelling_note?(entry, voicing)
                sides[entry[1]] = entry[SIDE_OF_VOICE_ENTRY]
              end
              if entry.first == :loudness && rising[entry[1]]
                # A swell's own start only sets where it starts: the voice climbs by itself from there.
                strike = previous == :voice ? loudness_at(entry[1], entry[2], voicing, song) : swell_strike(entry, voicing, song)
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
                yield entry, []
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
              writes = under_loudness(writes, loudness) if voice_own_entry?(entry)
              writes = with_fade(writes, fade) if fade && noise_note?(entry)
              writes = heard_from_one_side(writes, side) if side && voice_own_entry?(entry)
              loudness = entry.first == :loudness && previous == :voice ? writes : []
              previous = entry.first
              yield entry, writes
            end
          end

          # A voice's own entry after its note's loudness: the operators' levels stay as the loudness
          # wrote them, and a PSG voice starts at the loudness's volume.
          def under_loudness(writes, loudness)
            levels = loudness.select { |write| write.first == :fm }.map { |write| write[1] }
            volume = loudness.find { |write| write.first == :level }&.last
            writes.reject { |write| write.first == :fm && levels.include?(write[1]) }.map do |write|
              write.first == :loud && volume ? [:loud, write[1], volume, write[3]] : write
            end
          end

          # A drum's fade, said in the [:voice ...] before it, in place of the part's.
          def with_fade(writes, fade)
            writes.map { |write| write.first == :loud ? [:loud, write[1], write[2], signed_step(fade)] : write }
          end

          # Whether a [:voice ...] +entry+ is a song's note the player holds at the music volume.
          def swelling_note?(entry, voicing)
            _, channel, who, frequency, _, fade = entry
            frequency.positive? && fade&.swells_by_itself? && CHANNEL_VOICES.fetch(channel) != WAVE_VOICE && !voicing.effects.include?(who)
          end

          # A [:noise ...] entry that plays a note: a drum's fade is said in the [:voice ...] before it.
          def noise_note?(entry) = entry.first == :noise && entry.last.is_a?(Hash)

          # +voices+, the voices sound effects hold, after a [:voice ...] +entry+ (DSPWrites.held_by_effects).
          def held_by_effects(voices, entry, voicing)
            _, channel, who, frequency, volume, fade = entry
            bit = 1 << CHANNEL_VOICES.fetch(channel)
            voicing.effects.include?(who) && sounds?(channel, frequency, volume, fade) ? voices | bit : voices & ~bit
          end

          # A [:wave ...] or [:noise ...] entry that plays a note, not a rest.
          def wave_or_noise_note?(entry) = %i[wave noise].include?(entry.first) && entry.last.is_a?(Hash)

          # The wave or noise voice's own entry, which a song's note there logs after its loudness.
          def voice_own_entry?(entry) = !entry.nil? && %i[wave stop_wave noise].include?(entry.first)

          # WHICH TUNE A STOP STOPPED, the cartridge's to say and held to the log where the log says it too
          # (DSPWrites.misnamed_stop): the index in +entries+ of the first stop that names another tune.
          def misnamed_stop(entries, voicing = NO_VOICING)
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

          # The PSG's register that holds each voice's loudness, and each voice's length of wave.
          def psg_volume_register(voice) = (voice * 2) + 1
          def psg_tone_register(voice) = voice * 2
          PSG_NOISE_SETTING_REGISTER = 6

          # WHAT THE CHIPS HOLD AFTER THE SOUND LOG +entries+, as [:psg, register] or [:fm, register] and
          # the value. Nothing reaches a chip until the game says `enable_sound` (Runtime::Sound). A voice
          # that is moving its own loudness has none to answer for, nor a note that slides its pitch: the
          # log does not say where they have got to.
          def after(entries, voicing = NO_VOICING)
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
            when :tone then held[[:psg, psg_tone_register(write[1])]] = write[2]
            when :noise_setting then held[[:psg, PSG_NOISE_SETTING_REGISTER]] = write[1]
            when :fm then held[[:fm, write[1]]] = write[2]
            when :loud then hold_loudness(held, moving, write[1], write[2], !write[3].zero?)
            when :level then hold_loudness(held, moving, write[1], write[2], moving[write[1]])
            when :silence then hold_silence(held, moving, write[1])
            end
          end

          def hold_loudness(held, moving, voice, volume, moves)
            moving[voice] = moves
            key = [:psg, psg_volume_register(voice)]
            moves ? held.delete(key) : held[key] = ATTENUATION.fetch(volume)
          end

          def hold_silence(held, moving, voices)
            [0, 1, NOISE_VOICE].each { |voice| hold_loudness(held, moving, voice, 0, false) if voices[voice] == 1 }
            held[[:fm, KEY]] = KEY_OFF if voices[WAVE_VOICE] == 1
          end

          # WHAT THE LOG CANNOT ANSWER FOR. A slide logs nothing as it moves, so while the last note of a
          # channel slides, its voice's pitch has no expected value.
          def slide_registers(entries)
            entries.select { |entry| entry.first == :voice && entry[3].positive? }.group_by { |entry| entry[1] }.flat_map do |channel, notes|
              next [] unless VBlank::Audio::PitchSlide.moves?(notes.last[SLIDE_OF_VOICE_ENTRY])

              voice = CHANNEL_VOICES.fetch(channel)
              [[:psg, psg_tone_register(voice)], [:psg, psg_volume_register(voice)]]
            end
          end
        end
      end
    end
  end
end
