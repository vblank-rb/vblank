# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A GAME'S SONGS AND SOUND EFFECTS, AS THE SUPER NINTENDO'S PLAYER READS THEM (Runtime::Music):
        # the table is SongTable's, and what is the Super Nintendo's is here. A chip write is a write to
        # the S-DSP (DSPWrites), and the recordings a game plays share its eight voices.
        class Music < SongTable
          SONGS = W65816::Holding.new(what: SONGS_WHAT, fix: SONGS_FIX)

          # One part for each recording the Super Nintendo sounds at once.
          RECORDED_PARTS = Console::SUPER_NINTENDO.recordings_at_once
          PARTS = CONSOLE_PARTS + RECORDED_PARTS # A sound effect, the same

          LoweringError = SNES::LoweringError

          # THE SOUND CHIP'S VOICES RECORDINGS PLAY ON in +program+, the first place's first: the four
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

          # Each wave part's waveform at each volume its notes play it at, as a `wave` names them
          # (DSPWrites.wave_steps): a note's own volume, or the part's — and, in a game that follows
          # the music volume, at every one of the wave voice's loudnesses, which a level can take it to.
          def waves
            @songs.flat_map(&:voices).select { |part| IR::Tunes.part_kind(part) == :wave }.flat_map do |part|
              volumes = part.events.map { |_, _, _, volume| volume || part.volume }
              volumes += VBlank::Audio::Sound::WAVE_LEVEL_STEPS if follows_level?
              volumes.uniq.map { |volume| { shape: part.wave, volume: volume } }
            end
          end

          private

          def song_writes = DSPWrites
          def sound_command(write) = Runtime::Sound.command_for(write)
          def music_assembler = W65816.new("music", holds: SONGS)
          def not_made_yet_error = Lowering::NotMadeYet
          def console_title = "Super Nintendo"

          # A recorded note's voice volume: the mix's scale turned to the DSP's.
          def recording_volume(value) = (value * DSPWrites::MAIN_VOLUME / IR::Tunes::MIX_FULL.to_f).round
        end
      end
    end
  end
end
