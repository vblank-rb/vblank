# frozen_string_literal: true

module VBlank
  class Builder
    # Sound effects
    #
    # `enable_sound` turns the sound on, and then `beep`, `noise` and `wave` make a sound. A
    # `beep` is a short, plain tone such as a paddle hit or a pickup. A `noise` is a drum or a
    # crash, made from hiss instead of a pitched tone. A `wave` is a held tone with a richer
    # sound. `define_sound` names a beep you want to use again.
    #
    # ```ruby
    # enable_sound
    # define_sound :paddle_hit, frequency: 880, duty: :quarter, decay: :fast
    # beep :paddle_hit if ball.overlaps?(paddle)
    # noise :explosion
    # ```
    #
    # Without `enable_sound` every sound is silent, and calling one is an error. Songs are in
    # their own verbs, `song` and `play_song`.
    #--
    # The sound-effect verbs: turn the audio hardware on, name reusable presets, and fire one-off
    # beeps on the square-wave channel. Music (songs) is its own concern; these share only the
    # @sound_enabled flag the builder sets up. A concern of Builder, mixed in so
    # enable_sound/define_sound/beep are flat DSL verbs.
    #++
    module Sound
      # The rates `enable_sound mix_rate:` takes, in samples a second.
      MIX_RATES_HZ = (1000..65_536)

      # Turns the sound on. Write it once, at the top of the game.
      #
      # Without it every sound is silent, and calling one is an error. A game that hands over its
      # sounds as data, such as recordings, turns the sound on by itself.
      #
      # ```ruby
      # enable_sound
      # enable_sound main_volume: 0.5
      # ```
      #
      # * `mix_rate:` - how many samples a second the recordings are mixed at, from 1000 to
      #   65536. A game that names it gets that rate, or the nearest one the console keeps. Left
      #   out, the mix runs at the rate most recordings were made at.
      # * `main_volume:` - how loud everything the game plays is, songs and effects alike: a whole
      #   number from 0 to `MAIN_VOLUME_LOUDEST`, or a share of it from 0.0 to 1.0. Left out, the
      #   chip plays at its loudest. A console whose sound chip has no main volume ignores it.
      #--
      # A port whose recordings' rates come from its data pack names the rate its original mixed
      # at (most Advance games set one in their sound driver), since a build that reads the pack
      # as the game starts cannot work one out from rates it does not know. See
      # IR::Mixing.requested_rate. A sound chip with a main volume scales its whole mix by it,
      # after each voice's own volume, as a port's original sound driver sets it once. The program
      # keeps it as the whole number (IR::Nodes::Program#main_volume).
      #++
      def enable_sound(mix_rate: nil, main_volume: nil)
        raise ArgumentError, "enable_sound is already on. Call enable_sound one time only." if @sound_enabled && !@sound_on_by_itself
        unless mix_rate.nil? || (mix_rate.is_a?(Integer) && mix_rate.between?(MIX_RATES_HZ.first, MIX_RATES_HZ.last))
          raise ArgumentError, "`enable_sound mix_rate: #{mix_rate.inspect}` is not a rate the sound can be mixed at. " \
                               "Give a whole number of samples a second from #{MIX_RATES_HZ.first} to #{MIX_RATES_HZ.last}."
        end

        @program.mix_rate = mix_rate if mix_rate
        @program.main_volume = main_volume_steps(main_volume) unless main_volume.nil?
        @sound_on_by_itself = false
        return if @sound_enabled

        @sound_enabled = true
        record(Build.enable_sound)
      end

      # The most `enable_sound main_volume:` takes as a whole number: the loudest of the sound
      # chip's main volume steps, where a share of 1.0 lands.
      MAIN_VOLUME_LOUDEST = VBlank::Audio::Sound::MAIN_VOLUME_LOUDEST

      # +main_volume+ as the whole number of steps the program keeps: a whole number as it is, a
      # share of the loudest rounded to the nearest step.
      private def main_volume_steps(main_volume)
        case main_volume
        when Integer then return main_volume if main_volume.between?(0, MAIN_VOLUME_LOUDEST)
        when Float, Rational then return (main_volume * MAIN_VOLUME_LOUDEST).round if main_volume.between?(0, 1)
        end

        raise ArgumentError, "`enable_sound main_volume: #{main_volume.inspect}` is not a main volume. " \
                             "Give a whole number from 0 to #{MAIN_VOLUME_LOUDEST}, or a share from 0.0 to 1.0."
      end

      # SOUNDS HANDED OVER AS DATA TURN THE SOUND ON THEMSELVES, as a recording does: a game that
      # names them plainly means to hear them. At power-on, since a list can be declared in a scene.
      private def turn_sound_on
        return if @sound_enabled

        @sound_enabled = true
        @sound_on_by_itself = true
        at_boot(Build.enable_sound)
      end

      # Gives a name to a beep, so that `beep` can play it by name.
      #
      # ```ruby
      # define_sound :paddle_hit, frequency: 880, duty: :quarter, decay: :fast
      # define_sound :wall_bounce, frequency: 440
      # beep :wall_bounce
      # ```
      #
      # * `name` - the sound's name, as a symbol.
      # * `frequency:` - the pitch in hertz. 64 to 2048 is the useful range.
      # * `duty:` - the tone's shape: `:eighth`, `:quarter`, `:half` or `:three_quarter`.
      # * `decay:` - how fast it fades: `:fast`, `:medium`, `:slow` or `:none`.
      # * `volume:` - how loud it starts, from 0 to 15.
      def define_sound(name, frequency:, duty: :half, decay: :fast, volume: 15)
        record(Build.define_sound(name, frequency: frequency, duty: duty, decay: decay, volume: volume))
      end

      # Plays a short tone, such as a paddle hit or a pickup.
      #
      # Name a sound made with `define_sound`, or give a pitch in hertz.
      #
      # ```ruby
      # beep :high
      # beep :paddle_hit     # a sound from define_sound
      # beep 880
      # beep 440, duty: :quarter, decay: :slow
      # ```
      #
      # * `tone` - a sound's name, or its pitch in hertz.
      # * `duty:` - the tone's shape: `:eighth`, `:quarter`, `:half` (the default) or `:three_quarter`.
      # * `decay:` - how fast it fades: `:fast` (the default), `:medium`, `:slow` or `:none`.
      # * `volume:` - how loud it starts, from 0 to 15. The default is 15.
      #--
      # A beep plays on sound channel 2 (square wave, no sweep).
      #++
      def beep(tone, duty: nil, decay: nil, volume: nil)
        raise ArgumentError, "Sound is off. Call enable_sound before beep." unless @sound_enabled

        record(Build.beep(tone, duty: duty, decay: decay, volume: volume))
      end

      # Plays a drum or an explosion: a hit made from hiss instead of a pitched tone.
      #
      # ```ruby
      # noise :explosion
      # noise :hat
      # noise pitch: :low, decay: :slow, volume: 15
      # ```
      #
      # * `preset` - a built-in sound: `:hit`, `:kick`, `:snare`, `:hat`, `:explosion` or `:zap`.
      #   Leave it out for a plain hit.
      # * `pitch:` - how high the hiss sits: `:low`, `:mid` or `:high`.
      # * `decay:` - how fast it fades: `:fast`, `:medium`, `:slow` or `:none`.
      # * `volume:` - how loud it starts, from 0 to 15.
      # * `metallic:` - `true` for a tighter, more tonal rattle, as in a snare or a hat.
      #--
      # Plays on the noise voice (channel 4).
      #++
      def noise(preset = nil, pitch: nil, decay: nil, volume: nil, metallic: nil)
        raise ArgumentError, "Sound is off. Call enable_sound before noise." unless @sound_enabled

        record(Build.noise(preset, pitch: pitch, decay: decay, volume: volume, metallic: metallic))
      end

      # Plays a held tone with a chosen sound quality, richer than a beep.
      #
      # The tone holds until you call `wave` again or `stop_wave`. It does not fade.
      #
      # ```ruby
      # wave :triangle, :C4
      # wave :sine, 440, volume: :half
      # PULSE_50 = [15] * 16 + [0] * 16
      # wave PULSE_50, :C4
      # ```
      #
      # * `shape` - the sound quality: `:sine`, `:triangle`, `:sawtooth` or `:square`, or a
      #   waveform of your own as 32 steps from 0 to 15.
      # * `pitch` - a note name such as `:C4` or `:Fs4`, or a pitch in hertz.
      # * `volume:` - `:full` (the default), `:three_quarter`, `:half`, `:quarter` or `:mute`.
      #--
      # Plays on the wave voice (channel 3).
      #++
      def wave(shape, pitch, volume: :full)
        raise ArgumentError, "Sound is off. Call enable_sound before wave." unless @sound_enabled

        # ...checked here so a bad waveform is said at the line that wrote it. Spelled out
        # because a bare `Sound` inside this concern is the concern itself.
        VBlank::Audio::Sound.wave_steps!(shape) if shape.is_a?(Array)
        record(Build.wave(shape: shape, frequency: note_frequency(pitch), volume: volume))
      end

      # Stops the tone that `wave` is holding.
      def stop_wave
        record(Build.stop_wave)
      end

      private

      # A note name (:C4) or a raw frequency in Hz to a positive frequency.
      def note_frequency(pitch)
        case pitch
        when Symbol
          VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(pitch) do
            raise ArgumentError, "The note :#{pitch} is not known. " \
              "Available notes: #{VBlank::Audio::Music::NOTE_FREQUENCIES.keys.first(12).join(', ')}, ..."
          end
        when Integer
          raise ArgumentError, "The frequency must be positive. You gave #{pitch}." unless pitch.positive?

          pitch
        else
          raise ArgumentError, "The wave pitch must be a note name (:C4) or a frequency (440). You gave #{pitch.class}."
        end
      end
    end
  end
end
