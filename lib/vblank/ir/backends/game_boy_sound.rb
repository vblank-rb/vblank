# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # THE GAME BOY'S SOUND CHIP, which two consoles have: the Game Boy Advance kept the Color's
      # square, wave and noise voices when it was made. So the numbers a beep, a note or a hit
      # comes to are the same on both, and are worked out once, here, from the musical values
      # Audio::Sound resolves; where those numbers go is each console's own. The chip's registers
      # are named below for what each does, and each lowering says where it keeps them
      # (GBA::SoundRegisters, GBC::SoundRegisters). No other console has this chip, so no other
      # lowering reads this, and a test says so (test/all/vblank/audio/test_registers_seam.rb).
      #
      # Each method returns a list of [register, 16-bit value] pairs in the order they must be
      # written. A value holds two of the chip's byte-wide registers side by side, low byte first,
      # which is how the Advance keeps them; the Color takes the two bytes one at a time.
      module GameBoySound
        Sound = VBlank::Audio::Sound

        module_function

        # Wave shape → the 2-bit duty field the hardware wants.
        DUTY_CYCLES = {
          eighth: 0, quarter: 1, half: 2, square: 2, three_quarter: 3
        }.freeze

        # Noise pitch → the noise generator's shift-clock exponent. The hiss's
        # frequency divides down as the exponent grows, so a bigger number is a
        # lower, rumblier noise and a smaller one a higher hiss.
        NOISE_SHIFTS = Sound::NOISE_HIT_HALVINGS

        # The bit of the sound-power register that powers the chip on.
        POWER_ON = 0x0080

        # Every voice to both speakers, and both speakers at full volume.
        EVERY_VOICE_TO_BOTH_SPEAKERS = 0xFF77

        # The eight 16-bit words of the wave voice's memory.
        WAVE_WORDS = 8

        # The console tunes a channel by a period value, not a frequency:
        # freq_hz = 131072 / (2048 - value). Invert that and keep it in range.
        def frequency_value(freq_hz)
          Sound::SQUARE_LONGEST_WAVE - Sound.square_wave_ticks(freq_hz)
        end

        def duty_bits(duty)
          DUTY_CYCLES.fetch(duty) { raise ArgumentError, "unknown duty cycle #{duty.inspect}" }
        end

        def decay_step(decay) = Sound.fade_step(decay)

        # Power on the sound hardware: master enable, all four voices routed to both speakers at
        # full volume. Routing every channel rather than just the first two means a music voice on
        # channel 2 or a noise hit on channel 4 is actually heard; a channel stays silent until it
        # is triggered, so routing an unused one costs nothing.
        def enable
          [[:sound_power, POWER_ON], [:speakers, EVERY_VOICE_TO_BOTH_SPEAKERS]]
        end

        # A one-off sound effect on channel 2 (the SFX channel): duty + volume +
        # fade, then frequency with the trigger bit that restarts the note.
        def beep_writes(frequency:, duty:, decay:, volume:)
          control = (duty_bits(duty) << 6) | (volume << 12) | (decay_step(decay) << 8)
          trigger = 0x8000 | frequency_value(frequency)
          [[:square2_control, control], [:square2_trigger, trigger]]
        end

        # A single music note on one of the two square-wave voices (the music
        # channels): channel 1 or channel 2. A note holds its pitch until the next note
        # replaces it, so both voices of a layered tune hold between events; its loudness
        # holds too, unless +fade+ (an Audio::NoteFade) says it fades out or swells in.
        # A song's parts map to these in order; +channel+ is chosen by the backend, not
        # the score.
        def channel_note(channel, frequency:, duty:, volume:, fade: Audio::NoteFade::HOLD)
          case channel
          when 1 then channel1_note(frequency: frequency, duty: duty, volume: volume, fade: fade)
          when 2 then channel2_note(frequency: frequency, duty: duty, volume: volume, fade: fade)
          else raise ArgumentError, "no music voice on channel #{channel}"
          end
        end

        # A square voice's control value: its tone, the way it fades (the voice's four bits of it,
        # under the volume), and the volume it starts at.
        def square_control(duty, volume, fade) = (duty_bits(duty) << 6) | (fade.bits << 8) | (volume << 12)

        # A single music note on channel 1 (the first music voice). A frequency of 0
        # is a rest — silence the voice.
        def channel1_note(frequency:, duty:, volume:, fade: Audio::NoteFade::HOLD)
          return [[:square1_control, 0x0000], [:square1_trigger, 0x8000]] if frequency.zero?

          control = square_control(duty, volume, fade)
          trigger = 0x8000 | frequency_value(frequency)
          [
            [:square1_sweep, 0x0000], # no sweep
            [:square1_control, control],
            [:square1_trigger, trigger],
          ]
        end

        # A single music note on channel 2 (the second music voice), for a layered
        # tune's harmony/bass part. Same as channel 1, but this voice has no sweep
        # register, so it's just control + trigger. A frequency of 0 is a rest.
        # (Channel 2 doubles as the SFX voice; a two-part song and beeps can't both use
        # it at once.)
        def channel2_note(frequency:, duty:, volume:, fade: Audio::NoteFade::HOLD)
          return [[:square2_control, 0x0000], [:square2_trigger, 0x8000]] if frequency.zero?

          control = square_control(duty, volume, fade)
          trigger = 0x8000 | frequency_value(frequency)
          [[:square2_control, control], [:square2_trigger, trigger]]
        end

        # A SINGLE MUSIC NOTE ON THE WAVE VOICE (channel 3), for a song part that plays it.
        #
        # Two register values, like a square note, and for the same reason: the player copies two
        # halfwords out of the score and the waveform itself is already in wave RAM, uploaded once
        # when the tune started. The level holds the note and the trigger restarts the waveform.
        # A frequency of 0 is a rest, which mutes the voice without disturbing the table.
        #
        # It reaches LOWER than a square voice: this one tunes by a sample rate, so its bottom is
        # 32 Hz against the square voices' 64 — an octave further down, which is most of why a
        # tune puts its bass here.
        # +volume+ is 0..15, the same scale a square part's is written on — the wave voice has
        # four fixed levels and off rather than a range, so it is rounded to the nearest.
        def wave_note(frequency:, volume:)
          return [[:wave_level, 0x0000], [:wave_trigger, 0x0000]] if frequency.zero?

          [[:wave_level, WAVE_VOLUMES.fetch(Sound.wave_level(volume))],
           [:wave_trigger, 0x8000 | wave_rate(frequency)]]
        end

        # Put a waveform in wave RAM and switch the voice on — the once-per-tune half of the pair
        # above, split out because a note must not pay for it. Answers the eight halfwords the
        # table packs into; which register they go to, and in what order, is the player's to emit
        # (see Audio#emit_upload_wavetable): both banks get the table, so whichever one the voice
        # loops, it loops this waveform.
        def wavetable_halfwords(shape) = pack_wavetable(Sound.wavetable(shape))

        # A SINGLE MUSIC NOTE ON THE NOISE VOICE (channel 4), for a song part that plays it — the
        # drums. Two register values again, so the player copies two halfwords here too.
        #
        # WHAT A NOTE MEANS HERE is the one thing about this voice that has to be decided rather
        # than followed: the noise voice makes a hiss, not a tone, so there is no pitch in the way
        # a melody has one. What it does have is a CLOCK, and a faster clock is a higher, thinner
        # hiss where a slower one is a low rumble. So a note's pitch picks the clock nearest to it
        # (#noise_clock), which is what a tracker's noise channel does and what makes a low note a
        # kick and a high one a hat. A drum hit rings out as its part's +decay+ says, and is not
        # held until the next one — unless +fade+ (an Audio::NoteFade) says how this one fades.
        #
        # A frequency of 0 is a rest: the voice restarts at no volume at all, which stops a hit
        # that was still ringing.
        def noise_note(frequency:, decay:, volume:, metallic:, fade: nil, clock: nil)
          return [[:noise_control, 0x0000], [:noise_trigger, 0x8000]] if frequency.zero?

          divisor, shift = clock || noise_clock(frequency)
          control = (volume << 12) | ((fade ? fade.bits : decay_step(decay)) << 8)
          [[:noise_control, control],
           [:noise_trigger, 0x8000 | (shift << 4) | (metallic ? 0x0008 : 0x0000) | divisor]]
        end

        # The noise voice's clock is 524288 Hz divided by a small number and then halved +shift+
        # times over, so the rates it can make are a fixed ladder rather than a range. This finds
        # the rung nearest a wanted pitch. A divisor of 0 means a half, which is the one rung
        # above the rest of the ladder. The ladder itself is a fact about the voice that every
        # backend keeps (Sound.noise_rung); what is the chip's alone is that the two numbers
        # go into a register.
        NOISE_CLOCK = Sound::NOISE_CLOCK_HZ
        NOISE_DIVISORS = Sound::NOISE_DIVIDERS
        NOISE_SHIFT_RANGE = (Sound::NOISE_HALVINGS.first..Sound::NOISE_HALVINGS.last).freeze

        def noise_clock(frequency) = Sound.noise_rung(frequency)

        def noise_frequency(divisor, shift) = Sound.noise_rung_hz(divisor, shift)

        # A percussion / explosion hit on channel 4 (the noise voice). Channel 4
        # makes pseudo-random noise rather than a pitched tone: a control word sets
        # the starting volume and how fast it fades (the envelope, same layout as the
        # square channels), and a trigger word sets how high the hiss sits (the shift
        # clock), whether it's the tighter 7-bit "metallic" noise or the full 15-bit
        # hiss, and the restart bit. The envelope fades it to silence, so no note
        # length is needed.
        def noise_hit_writes(pitch:, decay:, volume:, metallic:)
          shift = NOISE_SHIFTS.fetch(pitch) { raise ArgumentError, "unknown noise pitch #{pitch.inspect}" }
          control = (volume << 12) | (decay_step(decay) << 8)  # fades out (envelope counts down)
          trigger = 0x8000 | (shift << 4) | (metallic ? 0x0008 : 0x0000)
          [[:noise_control, control], [:noise_trigger, trigger]]
        end

        # Channel 3's output levels — it has no envelope like the other channels,
        # just a fixed volume: full, three-quarter, half, quarter, or silent.
        WAVE_VOLUMES = {
          mute:          0x0000,
          full:          0x2000, # bits 13-14 = 1 (100%)
          half:          0x4000, # bits 13-14 = 2 (50%)
          quarter:       0x6000, # bits 13-14 = 3 (25%)
          three_quarter: 0x8000, # bit 15 forces 75%, which only the Advance has
        }.freeze

        # Play a wavetable on channel 3 (the wave voice). +samples+ is 32 values
        # (0-15) that the hardware loops as one waveform period. Unlike the square and
        # noise voices there's no envelope: the tone holds at +volume+ until it is
        # replaced or stopped.
        #
        # The waveform lives in a small block of "wave RAM" split into two banks on the Advance;
        # the CPU can reach one bank while the channel plays the other, which is a classic
        # source of silence (upload to the bank that isn't playing and you hear
        # nothing). To sidestep that entirely we write the same table to *both* banks,
        # so whichever one the channel loops, it loops our waveform.
        def wave_start_writes(samples, frequency:, volume:)
          level = WAVE_VOLUMES.fetch(volume) { raise ArgumentError, "unknown wave volume #{volume.inspect}" }
          halfwords = pack_wavetable(samples)

          writes = []
          writes << [:wave_switch, 0x0000]                 # DAC off, CPU reaches bank 0
          halfwords.each_with_index { |hw, i| writes << [wave_word(i), hw] }
          writes << [:wave_switch, 0x0040]                 # DAC off, CPU reaches bank 1
          halfwords.each_with_index { |hw, i| writes << [wave_word(i), hw] }
          writes << [:wave_switch, 0x0080]                 # DAC on, one 32-sample bank
          writes << [:wave_level, level]
          writes << [:wave_trigger, 0x8000 | wave_rate(frequency)] # restart bit + sample rate
          writes
        end

        # The register of word +index+ of the wave voice's memory.
        def wave_word(index) = :"wave_word_#{index}"

        # Silence the wave voice — switch its DAC off.
        def wave_stop
          [[:wave_switch, 0x0000]]
        end

        # Channel 3 tunes by a sample rate, and a 32-sample waveform completes one
        # cycle every 32 samples, so the tone works out to 65536/(2048-value) Hz.
        # Invert that for the register value and keep it in range.
        def wave_rate(freq_hz)
          Sound::WAVE_LONGEST_WAVE - Sound.wave_voice_ticks(freq_hz)
        end

        # Pack 32 four-bit samples into wave RAM's eight 16-bit words. Two samples to
        # a byte (the earlier sample in the high nibble), two bytes to a little-endian
        # word.
        def pack_wavetable(samples)
          bytes = samples.each_slice(2).map { |hi, lo| ((hi & 0xF) << 4) | (lo & 0xF) }
          bytes.each_slice(2).map { |low, high| ((high || 0) << 8) | low }
        end
      end
    end
  end
end
