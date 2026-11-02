# frozen_string_literal: true

module VBlank
  module Audio
    # The shared meaning of the sound ops — the one place that knows what a "beep"
    # or a note *is*, so every backend agrees on it (the audio counterpart to how
    # Int32 pins arithmetic): named sound-effect presets, the rule for resolving a beep's
    # tone + overrides into concrete musical values — a frequency in Hz, a wave shape, a
    # fade, a volume — and what each kind of voice can actually do, which every backend has
    # to honour whether or not it writes a register (wave_level). It is hardware-free, so a
    # headless interpreter can use it to say "an 880 Hz blip played" without any notion of
    # registers. Turning those values into the writes a chip needs is each lowering's own
    # (Backends::GameBoySound for the two consoles with the Game Boy's chip), and a test says
    # so rather than leaving it to whoever edits next
    # (test/all/vblank/audio/test_registers_seam.rb).
    module Sound
      # One resolved beep, purely musical — no hardware in sight. The four parts are fixed
      # here rather than named by a caller, so it is a value object and asking it for anything
      # else says so.
      Effect = Data.define(:frequency, :duty, :decay, :volume)

      # Built-in sound-effect presets, as plain musical values. A game refers to
      # one by name (beep :blip) instead of spelling out the numbers.
      PRESETS = {
        high:  Effect.new(frequency: 880,  duty: :half,    decay: :fast,   volume: 15),
        low:   Effect.new(frequency: 220,  duty: :half,    decay: :fast,   volume: 15),
        blip:  Effect.new(frequency: 1200, duty: :quarter, decay: :fast,   volume: 12),
        thud:  Effect.new(frequency: 110,  duty: :half,    decay: :medium, volume: 15),
        score: Effect.new(frequency: 660,  duty: :half,    decay: :medium, volume: 15),
      }.freeze

      # What a bare-frequency beep uses for the parts the caller didn't specify — a beep with
      # everything settled but its pitch, which is what the caller is about to supply.
      DEFAULTS = Effect.new(frequency: nil, duty: :half, decay: :fast, volume: 15)

      # HOW MANY RECORDED SOUNDS PLAY AT ONCE, and it lives here because it is a promise the
      # backends make to each other rather than a fact about either one. Past this a new play
      # is dropped — safe and quiet — instead of cutting off one already sounding.
      #
      # It was written down twice, once in the lowering and once in the interpreter, each
      # saying in its comment that it matched the other. They did match, by the care of
      # whoever edited them last and nothing else: change one and the console would drop a
      # sound the interpreter still played, which shows up only on the one sound too many and
      # would be read as a mixing bug rather than as two numbers drifting apart.
      #
      # SIXTEEN IS THE FRAMEWORK'S NUMBER, NOT THE CONSOLE'S. The console has no count of
      # recordings at all: the CPU adds them together and the sound hardware plays the one
      # stream. What a voice costs is the mixing, and only while it sounds — an idle slot is a
      # check a frame — so the number is room, and sixteen is what the music being asked of the
      # framework needs: songs of up to twelve recorded parts, with sounds of the game's own
      # beside them. Written once, in the Advance's description, which the interpreter reads for
      # whichever console it plays a game as.
      MIXER_VOICES = Console::ADVANCE.recordings_at_once

      # THE NUMBERS THE MIX ADDS RECORDINGS TOGETHER WITH, kept here for the same reason: the
      # cartridge's mixer and the interpreter's work out the same bytes of sound, and a number
      # written in each would drift.
      #
      # A play's loudness, out of 512, by the name it was asked at. The mix multiplies by 256ths
      # (VOL_SHIFT divides by them), and a loudness keeps LOUDNESS_FRACTION bit under that: half
      # a 256th. That is the scale a cartridge's own sound engine keeps a voice at. It holds the
      # voice's right and left volumes and mixes by their SUM, so 17 + 16 is 33 512ths, and a
      # note handed over as 17 256ths would be louder than the engine's by the half it dropped.
      # Music decoded off one is given its notes' loudness as that engine had them: its
      # quietest notes are still heard, and its loudest, about half the recording, is that loud
      # here too.
      # A STEP, how far a voice reads through its recording for each sample of the mix, is
      # counted in 65536ths, so STEP_SHIFT bits of it are the part of a sample. What the mix
      # multiplies by is a voice's GAIN, its loudness in 256ths with GAIN_FRACTION bits of
      # fraction under it, which a note with a shape slides: sixteen is as many as fit, since a
      # gain of at most 256 is then 24 bits and a sample of at most 128 is 7 more, which the sign
      # bit has room for. A loudness's half a 256th is the top one of those sixteen. The slide is
      # a distance divided by the samples in a frame, done as a multiply by one sample's share
      # out of 1 << (2 * RAMP_SPLIT), with the distance shifted down RAMP_SPLIT bits before it and
      # the product after, so a whole gain's worth of distance stays inside 32 bits on the way.
      MIX_LEVELS = { full: 512, three_quarter: 384, half: 256, quarter: 128, mute: 0 }.freeze
      VOL_SHIFT = 8
      LOUDNESS_FRACTION = 1
      STEP_SHIFT = 16
      GAIN_FRACTION = 16
      LOUDNESS_TO_GAIN = GAIN_FRACTION - LOUDNESS_FRACTION # a loudness shifted up this far is its gain
      RAMP_SPLIT = 8

      # Resolve a beep into concrete musical values. +tone+ is either a preset name
      # (looked up first among the program's own +defined+ sounds, then the built-in
      # PRESETS) or a raw frequency in Hz. Any non-nil override replaces the base
      # value — which is all #with does, once the ones nobody gave are dropped.
      def self.resolve_effect(tone, duty: nil, decay: nil, volume: nil, defined: {})
        base =
          if tone.is_a?(Symbol)
            defined[tone] || PRESETS[tone] ||
              raise(ArgumentError, "unknown sound preset #{tone.inspect} — " \
                                   "built-in: #{PRESETS.keys.join(', ')}; " \
                                   "define your own with define_sound")
          else
            DEFAULTS.with(frequency: tone)
          end

        base.with(**{ duty: duty, decay: decay, volume: volume }.compact)
      end

      # Built-in noise presets — the percussion voice, as plain intent. A game says
      # `noise :explosion` and gets a rumble; the numbers are the framework's job.
      # +pitch+ is how high the hiss sits (:low rumble … :high hiss), +decay+ how
      # fast it fades, +metallic+ a tighter, more tonal rattle (for a snare/hat).
      NOISE_PRESETS = Ractor.make_shareable({
        hit:       { pitch: :mid,  decay: :fast,   volume: 12, metallic: false },
        kick:      { pitch: :low,  decay: :medium, volume: 15, metallic: false },
        snare:     { pitch: :mid,  decay: :fast,   volume: 13, metallic: true },
        hat:       { pitch: :high, decay: :fast,   volume: 8,  metallic: true },
        explosion: { pitch: :low,  decay: :slow,   volume: 15, metallic: false },
        zap:       { pitch: :high, decay: :medium, volume: 12, metallic: false },
      })

      # What an unnamed noise hit defaults to.
      NOISE_DEFAULT = :hit

      # Resolve a noise hit into concrete musical values. +preset+ names a built-in
      # (or is nil for the default hit); any non-nil override replaces the preset's
      # value. Purely musical — no hardware in sight.
      def self.resolve_noise(preset, pitch: nil, decay: nil, volume: nil, metallic: nil)
        base = NOISE_PRESETS.fetch(preset || NOISE_DEFAULT) do
          raise ArgumentError, "unknown noise preset #{preset.inspect} — " \
                               "built-in: #{NOISE_PRESETS.keys.join(', ')}"
        end

        {
          pitch:    pitch  || base[:pitch],
          decay:    decay  || base[:decay],
          volume:   volume || base[:volume],
          metallic: metallic.nil? ? base[:metallic] : metallic,
        }
      end

      # The wave voice (channel 3) plays a short looping waveform — a wavetable — so
      # it can make richer, non-square timbres than the two square channels. A shape
      # name resolves to 32 four-bit samples (0-15); the same table both backends use,
      # so they agree on the timbre. WAVE_SAMPLES is the table size the hardware loops.
      WAVE_SAMPLES = 32

      # ...and how loud one step can be. Four bits, so 0 is silence and 15 is the top.
      WAVE_STEP_MAX = 15

      # WHAT THE TWO KINDS OF VOICE CAN ACTUALLY DO. These are limits, not encodings, which is
      # why they sit out here with the musical half rather than inside a lowering: a backend that
      # never writes a register still has to honour them, or the two backends disagree about
      # what a game sounds like.
      #
      # The wave voice has FIVE loudnesses and not a range — off, and four steps — so a part
      # written at volume 6 of 15 plays at the nearest of them. Every backend rounds the same
      # way, and one that rounded 6 down to silence while another rounded it up would differ on
      # whether a note is heard at all.
      WAVE_LEVEL_STEPS = %i[mute quarter half three_quarter full].freeze

      # Round a 0..15 volume to the level the wave voice really has.
      def self.wave_level(volume)
        WAVE_LEVEL_STEPS[((volume.clamp(0, 15) * (WAVE_LEVEL_STEPS.size - 1)) / 15.0).round]
      end

      # WHAT A SQUARE VOICE SOUNDS LIKE, for a backend that has to make the sound itself rather
      # than tell a chip to: the pitch it really plays, how thin its tone is, and how fast it
      # fades. A cartridge writes these to the sound chip as bit patterns (Backends::GameBoySound); a
      # desktop build has no chip and builds the wave from the same three facts.
      #
      # THE PITCH IS A WHOLE NUMBER OF TICKS, not any frequency at all. The voice counts a clock
      # of 131,072 ticks a second and one wave lasts a whole number of them, 1 to 2048 — so 440 Hz
      # is played as 298 ticks a wave, a hair under 440. Every backend has to round the same way
      # or two voices in tune on one are a beat apart on the other. 2048 ticks is the bottom, 64 Hz,
      # which each console says for itself (Console::Description#lowest_square_hz). (The wave voice
      # reaches an octave lower, which is most of why a tune puts its bass there.)
      SQUARE_CLOCK_HZ = 131_072
      SQUARE_LONGEST_WAVE = 2048

      # How many ticks one wave of a +hz+ note lasts on a square voice.
      def self.square_wave_ticks(hz)
        SQUARE_LONGEST_WAVE - (SQUARE_LONGEST_WAVE - (SQUARE_CLOCK_HZ.to_f / hz)).round.clamp(0, SQUARE_LONGEST_WAVE - 1)
      end

      # How much of each wave is spent high, in eighths: a half wave is the full, hollow tone,
      # and the narrower ones are thinner and brighter.
      SQUARE_HIGH_EIGHTHS = { eighth: 1, quarter: 2, half: 4, square: 4, three_quarter: 6 }.freeze

      # How long a fading note holds each of its volume steps, in 64ths of a second — the pace
      # the voice counts its fade at. A note at volume 15 fading `:fast` is gone in 15/64 of a
      # second; `:none` never fades.
      FADE_STEP_SIXTY_FOURTHS = { fast: 1, medium: 3, slow: 5, none: 0 }.freeze

      # A fade or a swell said by its speed, or by the step itself (0 to 7, which a song converted
      # from another game's music arrives holding), as the step.
      def self.fade_step(speed)
        return speed if speed.is_a?(Integer) && speed.between?(0, 7)

        FADE_STEP_SIXTY_FOURTHS.fetch(speed) { raise ArgumentError, "unknown fade speed #{speed.inspect}" }
      end

      # WHAT THE WAVE VOICE SOUNDS LIKE, for the same backend: the pitch it really plays, and how
      # tall each step of its waveform comes out at each of its loudnesses.
      #
      # ITS PITCH IS A WHOLE NUMBER OF TICKS TOO, of a clock half as fast as the square voices':
      # 65,536 ticks a second, and one whole wave — all 32 steps of it — lasts 1 to 2048 of them.
      # A longer wave is a lower note, so this voice bottoms out at 32 Hz where a square voice
      # stops at 64, and a note below that is played AT 32 Hz.
      WAVE_CLOCK_HZ = 65_536
      WAVE_LONGEST_WAVE = 2048

      # How many ticks one whole wave of a +hz+ note lasts on the wave voice.
      def self.wave_voice_ticks(hz)
        WAVE_LONGEST_WAVE - (WAVE_LONGEST_WAVE - (WAVE_CLOCK_HZ.to_f / hz)).round.clamp(0, WAVE_LONGEST_WAVE - 1)
      end

      # ITS LOUDNESS CUTS EACH STEP DOWN, and what does not divide is dropped: the voice makes its
      # four loudnesses by taking so many quarters of a step, in whole numbers. So a step of 15
      # at half is 7 and not seven and a half, and a quiet waveform has fewer different heights
      # in it than a loud one — a quarter-loud triangle is a staircase of four treads.
      def self.wave_step_at(step, level)
        (step * wave_level_quarters(level)) / 4
      end

      # How many quarters of each step a loudness keeps: none for :mute, all four for :full.
      def self.wave_level_quarters(level)
        WAVE_LEVEL_STEPS.index(level) or raise ArgumentError, "unknown wave volume #{level.inspect}"
      end

      # WHAT THE NOISE VOICE SOUNDS LIKE, for the same backend.
      #
      # THE HISS IS A ROW OF BITS SHUFFLED ALONG ONE PLACE AT A TIME. Each step the voice is high
      # or low by the bit that falls off the end, and the bits left behind are stirred so the
      # pattern takes a long time to come round. How fast it steps is the pitch: fast is a thin
      # high hiss, slow a rumble.
      #
      # A STEP IS A WHOLE NUMBER OF TICKS of a clock of 524,288 a second. The voice has no free
      # choice of that number. It picks a divider (0 to 7, where 0 stands for a half) and how
      # many times to halve what the divider leaves (0 to 13), so a step lasts twice the divider,
      # doubled once for each halving — a ladder of rungs rather than a range.
      NOISE_CLOCK_HZ = 524_288
      NOISE_DIVIDERS = (0..7).to_a.freeze
      NOISE_HALVINGS = (0..13).to_a.freeze

      # How many ticks one step of the hiss lasts for a divider and a number of halvings.
      def self.noise_step_ticks(divider, halvings)
        (divider.zero? ? 1 : divider * 2) << halvings
      end

      # How many steps a second that rung of the ladder makes.
      def self.noise_rung_hz(divider, halvings)
        NOISE_CLOCK_HZ / (divider.zero? ? 0.5 : divider) / (2**(halvings + 1))
      end

      # The rung nearest a wanted pitch, as its divider and its halvings — what makes a low note
      # on the noise voice a kick and a high one a hat.
      def self.noise_rung(hz)
        NOISE_DIVIDERS.product(NOISE_HALVINGS).min_by do |divider, halvings|
          (noise_rung_hz(divider, halvings) - hz).abs
        end
      end

      # How long a step lasts for a note of +hz+ on the noise voice.
      def self.noise_note_step_ticks(hz) = noise_step_ticks(*noise_rung(hz))

      # A `noise` hit names its pitch with one of three words, and each is a number of halvings
      # of the fastest step there is.
      NOISE_HIT_HALVINGS = { high: 2, mid: 5, low: 8 }.freeze

      # How long a step lasts for a hit at one of those three pitches.
      def self.noise_hit_step_ticks(pitch)
        halvings = NOISE_HIT_HALVINGS.fetch(pitch) { raise ArgumentError, "unknown noise pitch #{pitch.inspect}" }
        noise_step_ticks(0, halvings)
      end

      # HOW MANY BITS ARE IN THE ROW: fifteen for a plain hiss, whose pattern is 32,767 steps
      # long and never heard to repeat, and seven for a metallic one, which comes round every
      # 127 steps — often enough to be heard as a pitch of its own, the rattle of a snare or a
      # hat.
      def self.noise_register_bits(metallic) = metallic ? 7 : 15

      # WHAT THE WAVE VOICE PLAYS, which is one of two things a game can say.
      #
      # A NAME is the usual answer — `wave :triangle, :C4`, `plays: :sine` — and the samples are
      # the framework's job. Four names cover the timbres most games reach for.
      #
      # THE STEPS THEMSELVES are the other, and they are here because the named shapes are a
      # convenience rather than the truth: the console's wave voice is not a set of timbres, it is
      # 32 steps of four bits that a game writes. A game whose music came from somewhere else —
      # decoded out of another cartridge, drawn in a tracker — arrives holding those 32 numbers,
      # and no name it could be given would be the waveform it actually has. A pulse is the common
      # case and is none of the four: played as a triangle it is a different instrument, which a
      # player hears without being able to name.
      #
      # So a list of 32 steps goes wherever a name goes. Name them in your own program
      # (`PULSE_50 = [15] * 16 + [0] * 16`) and the call site still reads like game code.
      def self.wavetable(shape)
        return wave_steps!(shape) if shape.is_a?(Array)

        case shape
        when :square
          Array.new(WAVE_SAMPLES) { |i| i < WAVE_SAMPLES / 2 ? 15 : 0 }
        when :sawtooth
          Array.new(WAVE_SAMPLES) { |i| (i * 15.0 / (WAVE_SAMPLES - 1)).round }
        when :triangle
          Array.new(WAVE_SAMPLES) do |i|
            up = i < WAVE_SAMPLES / 2
            pos = up ? i : (WAVE_SAMPLES - 1 - i)
            (pos * 15.0 / (WAVE_SAMPLES / 2 - 1)).round.clamp(0, 15)
          end
        when :sine
          Array.new(WAVE_SAMPLES) { |i| (7.5 + 7.5 * Math.sin(2 * Math::PI * i / WAVE_SAMPLES)).round.clamp(0, 15) }
        else
          raise ArgumentError, "The wave shape #{shape.inspect} is not known. Use :sine, :triangle, " \
                               ":sawtooth or :square. Or give #{WAVE_SAMPLES} steps of 0 to 15, to " \
                               "play a waveform of your own."
        end
      end

      # A WAVEFORM GIVEN AS ITS STEPS, checked and handed back. The two rules are the hardware's:
      # the voice loops exactly 32 steps, and each one is four bits. Both are said at the line
      # that wrote the waveform, because a list of numbers is the one thing here a person cannot
      # check by looking at it.
      def self.wave_steps!(steps)
        unless steps.length == WAVE_SAMPLES
          raise ArgumentError, "A waveform is #{WAVE_SAMPLES} steps. This one has #{steps.length}. " \
                               "The wave voice loops #{WAVE_SAMPLES} steps, so give that many."
        end

        bad = steps.find { |step| !step.is_a?(Integer) || !step.between?(0, WAVE_STEP_MAX) }
        return steps if bad.nil?

        raise ArgumentError, "A waveform step is a whole number from 0 to #{WAVE_STEP_MAX}. " \
                             "Step #{steps.index(bad)} is #{bad.inspect}."
      end
    end
  end
end
