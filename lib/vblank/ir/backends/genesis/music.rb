# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A GAME'S SONGS AND SOUND EFFECTS, AS THE GENESIS'S PLAYER READS THEM (Runtime::Music): the table
        # is SongTable's, and what is the Genesis's is here. A chip write is a write to one of its two
        # sound chips (ChipWrites), and every place in the table is a word.
        class Music < SongTable
          SONGS = M68000::Holding.new(what: SONGS_WHAT, fix: SONGS_FIX)

          SHAPE_FRAMES_MASK = Audio::Duty::FRAMES - 1 # a note's frame among the frames of its shapes

          # Parts that play recordings, which take turns on the one recording a Genesis sounds
          # (Runtime::Recordings).
          RECORDED_PARTS = 4
          PARTS = CONSOLE_PARTS + RECORDED_PARTS # ...and a sound effect, the same

          LoweringError = Genesis::LoweringError

          private

          def song_writes = ChipWrites
          def sound_command(write) = Runtime::Sound.command_for(write)
          def music_assembler = M68000.new("music", holds: SONGS)
          def not_made_yet_error = Lowering::NotMadeYet
          def console_title = "Genesis"

          def recording_volume(value) = value

          # The runtime climbs a swell here, from where the voice is set first.
          def swell_start_commands(channel, volume)
            [sound_command([:level, ChipWrites::CHANNEL_VOICES.fetch(channel), volume])]
          end

          # Every place in the table is a word, so all of it is within 64K.
          def refuse_table_too_long!(table)
            return if table.size * 2 <= 0x10000

            raise LoweringError, "This game's songs and sound effects come to more than the Genesis's song table holds. " \
                                 "To fix this, make its songs shorter, or use fewer of them."
          end
        end
      end
    end
  end
end
