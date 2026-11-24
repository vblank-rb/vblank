# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A game's songs and sound effects, as the Super Nintendo's player reads them (Runtime::Music):
        # the table is SongTable's, and what is the Super Nintendo's is here. A chip write is a write to
        # the S-DSP (DSPWrites), and the recordings a game plays share its eight voices.
        class Music < SongTable
          SONGS = W65816::Holding.new(what: SONGS_WHAT, fix: SONGS_FIX)

          # One part for each recording the Super Nintendo sounds at once.
          RECORDED_PARTS = Console::SUPER_NINTENDO.recordings_at_once
          PARTS = CONSOLE_PARTS + RECORDED_PARTS # A sound effect, the same

          LoweringError = SNES::LoweringError

          def initialize(program)
            super
            @whole_square_notes = !IR::Tunes.effect_clock_step(program, program.described_console).nil? &&
                                  !Lowering::Sound.chip_envelopes?(program) && !IR::Tunes.recorded_pans?(program)
          end

          # The sound chip's voices recordings play on in +program+, the first place's first: the four
          # past the square, wave and noise parts', and then each of those four the game never
          # sounds, so a game with no use for them has all eight. Asked of the whole program, since
          # a voice is either kept for those sounds everywhere or free everywhere.
          def self.recording_voices(program)
            kept = program.walk.flat_map { |node| console_voices_used_by(node) }.uniq
            DSPWrites::RECORDING_VOICES + (DSPWrites::CONSOLE_VOICES.to_a - kept)
          end

          def self.console_voices_used_by(node)
            case node.kind
            when :song
              kinds = node.voices.map { |part| IR::Tunes.part_kind(part) }
              squares = DSPWrites::SQUARE_VOICES.values.first(kinds.count(:square))
              squares + (kinds.include?(:wave) ? [DSPWrites::WAVE_VOICE] : []) + (kinds.include?(:noise) ? [DSPWrites::NOISE_VOICE] : [])
            when :beep then [DSPWrites::CHANNEL_VOICES.fetch(Reference::Player::BEEP_CHANNEL)]
            when :wave, :stop_wave then [DSPWrites::WAVE_VOICE]
            when :noise then [DSPWrites::NOISE_VOICE]
            else []
            end
          end

          # The bits of +voices+ in KON and KOFF.
          def self.voice_bits(voices) = voices.sum { |voice| 1 << voice }

          # Each waveform a wave part plays (its own, and any its notes name) at each volume its notes
          # play it at, as a `wave` names them (DSPWrites.wave_steps): a note's own volume, or the
          # part's — and, in a game that follows
          # the music volume, at every one of the wave voice's loudnesses, which a level can take it to.
          def waves
            @songs.flat_map(&:voices).select { |part| IR::Tunes.part_kind(part) == :wave }.flat_map do |part|
              volumes = part.events.map { |_, _, _, volume| volume || part.volume }
              volumes += VBlank::Audio::Sound::WAVE_LEVEL_STEPS if follows_level?
              IR::Tunes.waves_of(part).product(volumes.uniq).map { |shape, volume| { shape: shape, volume: volume } }
            end
          end

          private

          def song_writes = DSPWrites
          def sound_command(write) = Runtime::Sound.command_for(write)

          # A square or wave note's nine writes (DSPWrites#song_note, #wave) as two commands, in a game whose
          # effects are struck inside the frame: its pitch held (HOLD_PITCH), then the rest told whole
          # (WHOLE_NOTE), which the sound unit's program writes as those same registers. Each command is a
          # turn of the mailboxes, which carry a few dozen a frame, so a run of ticks' notes is sent in a
          # fraction of the turns and does not hold back the game's own sound behind it.
          def commands_for(writes)
            packed = (whole_note_commands(writes) if @whole_square_notes)
            packed || super
          end

          def whole_note_commands(writes)
            return unless writes.size == 9 && writes.first.size == 2

            dsp = DSPWrites
            base = writes.first.first & 0x70
            level, _, low, high, source = writes.first(5).map(&:last)
            bit = 1 << (base >> 4)
            expected = [[base + dsp::VOLUME_LEFT, level], [base + dsp::VOLUME_RIGHT, level], [base + dsp::PITCH_LOW, low],
                        [base + dsp::PITCH_HIGH, high], [base + dsp::SOURCE, source], [base + dsp::ADSR1, dsp::ADSR_OFF],
                        [base + dsp::GAIN, dsp::FIXED_TOP], *dsp.key_on(base >> 4)]
            return unless writes == expected && bit.positive?

            s = Runtime::Sound
            [[s::HOLD_PITCH, low, high], [s::WHOLE_NOTE | base, source, level]]
          end
          def music_assembler = W65816.new("music", holds: SONGS)
          def not_made_yet_error = Lowering::NotMadeYet
          def console_title = "Super Nintendo"

          # A recorded note's voice volume: the mix's scale turned to the DSP's.
          def recording_volume(value) = (value * DSPWrites::VOICE_VOLUME_LOUDEST / IR::Tunes::MIX_FULL.to_f).round
        end
      end
    end
  end
end
