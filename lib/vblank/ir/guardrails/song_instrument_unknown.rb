# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a song part, or one of its notes, that plays an instrument the game
        # never declared:
        #
        # > <The song> has a part that plays :<instrument>. This game has no instrument with
        # > that name. To fix this, declare it: `instrument :<instrument>, from:
        # > "<instrument>.wav"`. Or give the part the name of an instrument that the game has.
        #
        # A part's `plays:` names a recording, and the recording itself is declared with
        # `instrument`. A misspelt name, or a missing `instrument` line, leaves the notes with
        # nothing to play, so the build stops. Declare the instrument, or correct the name.
        #
        #--
        # A song part — or one note of it — that plays an instrument the game never declared.
        #
        # `voice :melody, plays: :piano` names the recording each note plays, and a note handed
        # over in a Score can name its own; the name is all the song has — the recording itself is
        # declared elsewhere, with `instrument`. Misspell it, or forget the declaration, and there
        # is nothing for the notes to play. Refused at build time, with the name, rather than left
        # to fail somewhere deep in the lowering.
        #++
        class SongInstrumentUnknown
          NAME = :song_instrument_unknown
          PLAIN_NAME = "a song part that plays an instrument the game does not have"

          def detect(program)
            declared = program.walk.filter_map { |node| node.name if node.kind == :sample }
            program.walk.select { |node| node.kind == :song }.flat_map do |song|
              missing = Tunes.instruments(song) - declared
              missing.map do |name|
                Finding.new(check: NAME, severity: :error, message: message(program, song, name), node: song)
              end
            end
          end

          private

          def message(program, song, instrument)
            "#{SongWords.song_capitalized(program, song)} has a part that plays :#{instrument}. This game has no instrument " \
              "with that name. To fix this, declare it: `instrument :#{instrument}, from: " \
              "\"#{instrument}.wav\"`. Or give the part the name of an instrument that the game has."
          end
        end
      end
    end
  end
end
