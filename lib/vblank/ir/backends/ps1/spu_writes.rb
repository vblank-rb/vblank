# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHAT A SOUND IS, ON A PLAYSTATION'S SOUND CHIP. This module gives which writes each of the
        # interpreter's sound-log entries means; the lowering makes them (Lowering::Sound), and the checked
        # run reads the chip's registers after every pass and holds them to what the log up to then says
        # (#after), so a write that never arrived, or arrived wrong, shows up in the chip itself.
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
        #   [:key_on, voice]               the voice started from its loop's start at the frame boundary
        #   [:key_off, voice]              the voice let go at the frame boundary
        module SPUWrites
          H = Console::PS1Hardware

          # The game's voices: the Advance's channels 1 and 2 (the squares), 3 (the wave) and 4 (noise).
          BEEP_VOICE = 0
          WAVE_VOICE = 2
          NOISE_VOICE = 3
          VOICES = 4
          CHANNEL_VOICES = { 1 => 0, 2 => 1, 3 => WAVE_VOICE, 4 => NOISE_VOICE }.freeze

          # THE LOUDNESS OF A VOICE AT FULL, as its volume register holds it: a quarter of the chip's
          # loudest, so the four voices together cannot go past what the speaker takes. A volume of 0 to
          # 15 is that many fifteenths of it.
          LOUDEST = 0x1000
          VOLUME_REGISTER = Ractor.make_shareable(Array.new(16) { |volume| (volume * LOUDEST) / 15 })

          PITCH_44100 = 0x1000
          PITCH_TOP = 0x3FFF
          SAMPLE_RATE = 44_100

          module_function

          def register(voice, which) = (voice * H::SPU_VOICE_BYTES) + which

          # The writes one sound-log entry means, its loops placed in +memory+ (a SoundMemory).
          def for_entry(entry, memory)
            case entry.first
            when :enabled then []
            when :beep then beep(entry.last, memory)
            when :noise then entry.last ? noise(entry.last, memory) : silence(NOISE_VOICE)
            when :wave then wave(entry.last, memory)
            when :stop_wave then [*volume_writes(WAVE_VOICE, 0), [:key_off, WAVE_VOICE]]
            else raise ArgumentError, "the PlayStation build does not play #{entry.first.inspect} yet"
            end
          end

          # A beep: the square of its width, read at its pitch, at its loudness, fading as it names.
          def beep(effect, memory)
            step = VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(effect.decay)
            [[:spu, register(BEEP_VOICE, H::SPU_START), memory.start_of(SoundMemory.square(effect.duty))],
             [:spu, register(BEEP_VOICE, H::SPU_PITCH), square_pitch(effect.frequency)],
             [:loud, BEEP_VOICE, effect.volume, -step], [:key_on, BEEP_VOICE]]
          end

          # A noise hit (Audio::Sound.resolve_noise's hash): the hiss or the rattle, read a sample a step at
          # the Advance's rate for its pitch.
          def noise(hit, memory)
            step = VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(hit[:decay])
            [[:spu, register(NOISE_VOICE, H::SPU_START), memory.start_of(SoundMemory.noise(hit[:metallic]))],
             [:spu, register(NOISE_VOICE, H::SPU_PITCH), noise_pitch(hit[:pitch])],
             [:loud, NOISE_VOICE, hit[:volume], -step], [:key_on, NOISE_VOICE]]
          end

          # THE WAVE VOICE PLAYING +params+ ({shape:, frequency:, volume:}, as the interpreter logs a wave):
          # its waveform's loop at its pitch, and its loudness, which on the Advance is one of five
          # (Audio::Sound.wave_level), as so many quarters of a voice's loudest.
          def wave(params, memory)
            volume = params[:volume]
            level = volume.is_a?(Symbol) ? volume : VBlank::Audio::Sound.wave_level(volume)
            quarters = VBlank::Audio::Sound.wave_level_quarters(level)
            [[:spu, register(WAVE_VOICE, H::SPU_START), memory.start_of(SoundMemory.wave(params[:shape]))],
             [:spu, register(WAVE_VOICE, H::SPU_PITCH), wave_pitch(params[:frequency])],
             *volume_writes(WAVE_VOICE, (quarters * LOUDEST) / 4), [:key_on, WAVE_VOICE]]
          end

          # A voice silenced: its loudness nought, and let go.
          def silence(voice) = [[:loud, voice, 0, 0], [:key_off, voice]]

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

          # WHAT THE CHIP'S REGISTERS HOLD AFTER THE SOUND LOG +entries+, by their distance from 1F801C00h.
          # Nothing reaches the chip until the game calls `enable_sound` (Runtime::Sound). A voice that is
          # moving its own loudness has none to answer for: the log does not say where it has got to. Key on
          # and key off are gathered and written at the frame boundary, so they are not here.
          def after(entries, memory)
            held = {}
            moving = {}
            enabled = false
            entries.each do |entry|
              enabled ||= entry.first == :enabled
              next unless enabled

              for_entry(entry, memory).each { |write| hold_write(held, moving, write) }
            end
            held
          end

          def hold_write(held, moving, write)
            case write.first
            when :spu then held[write[1]] = write[2]
            when :loud then hold_loudness(held, moving, write[1], write[2], !write[3].zero?)
            end
          end

          def hold_loudness(held, moving, voice, volume, moves)
            moving[voice] = moves
            keys = [register(voice, H::SPU_VOLUME_LEFT), register(voice, H::SPU_VOLUME_RIGHT)]
            if moves
              keys.each { |key| held.delete(key) }
            else
              keys.each { |key| held[key] = VOLUME_REGISTER.fetch(volume) }
            end
          end
        end
      end
    end
  end
end
