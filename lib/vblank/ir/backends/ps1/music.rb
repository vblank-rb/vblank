# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # A GAME'S SONGS AND SOUND EFFECTS, AS THE PLAYSTATION'S PLAYER READS THEM (Runtime::Music): the
        # table is SongTable's, and what is the PlayStation's is here. A chip write is a write to the sound
        # chip (SPUWrites), sent as one of Runtime::Sound's commands, and every place in the table is a
        # halfword, as on the Genesis.
        class Music < SongTable
          SONGS = R3000::Holding.new(what: SONGS_WHAT, fix: SONGS_FIX)

          # Parts that play recordings: as many as recordings sound at once.
          RECORDED_PARTS = Console::PLAYSTATION.recordings_at_once
          PARTS = CONSOLE_PARTS + RECORDED_PARTS # A sound effect, the same

          SHAPE_FRAMES_MASK = Audio::Duty::FRAMES - 1 # A note's frame among the frames of its shapes

          LoweringError = PS1::LoweringError

          # The loops a game's songs play beside its own sounds: each wave part's waveform, and the noise
          # when a song has a drum part (SoundMemory).
          def self.waveforms(program)
            IR::Tunes.declared_songs(program).flat_map(&:voices).select { |part| IR::Tunes.part_kind(part) == :wave }.map(&:wave)
          end

          def self.drums?(program) = IR::Tunes.declared_songs(program).flat_map(&:voices).any? { |part| IR::Tunes.part_kind(part) == :noise }

          # The section the table is kept in, labelled "music_data": its 16-bit words as halfwords, low byte
          # first (a word of the R3000's is 32 bits).
          def section(words)
            asm = music_assembler
            asm.label("music_data")
            asm.data_halves(words)
            asm.section
          end

          private

          def song_writes = SPUWrites
          def sound_command(write) = Runtime::Sound.command_for(write)
          def music_assembler = R3000.new("music", holds: SONGS)
          def not_made_yet_error = Lowering::NotMadeYet
          def console_title = "PlayStation"

          def recording_volume(value) = value

          # Every place in the table is a halfword, so all of it is within 64K.
          def refuse_table_too_long!(table)
            return if table.size * 2 <= 0x10000

            raise LoweringError, "This game's songs and sound effects come to more than the PlayStation's song table holds. " \
                                 "To fix this, make its songs shorter, or use fewer of them."
          end
        end
      end
    end
  end
end
