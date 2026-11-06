# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A note on a square-wave part that is lower than the square-wave voice can play.
        #
        # A sound chip can tune a square-wave voice with a number that has a bottom, which the
        # console sets (Console::Description#lowest_square_hz; one with none is not asked). On the
        # Game Boys it is 64 Hz — between the B and the C two octaves below middle C. A lower note is played
        # AT the bottom: it still sounds, it is just a different note, and nothing about the
        # music shows it. A song block's note names start at C2 and never reach it, but a pitch
        # written in Hz can, and a Score's MIDI keys go all the way down to 0.
        #
        # A part that plays an instrument has no such bottom — a recording is simply read more
        # slowly — which is one of the two ways out the message offers.
        #
        # Music decoded off a cartridge is left alone when its Score sets `low_notes_intended: true`:
        # the cartridge's own sound engine played those notes at the bottom too, so every way out
        # would make it less like the original.
        class SquareNoteTooLow
          NAME = :square_note_too_low
          PLAIN_NAME = "a square-wave note lower than the voice can play"

          def detect(program)
            lowest = program.described_console.lowest_square_hz or return []

            program.walk.select { |node| node.kind == :song && !node.low_notes_intended }.flat_map do |song|
              song.voices.each_with_index.filter_map do |part, index|
                # Only the square voices have this bottom. A recording is read more slowly, and
                # the wave voice tunes by a sample rate, so it reaches an octave further down.
                next unless Tunes.part_kind(part) == :square

                low = part.events.map { |event| event[1] }.select { |hz| hz.positive? && hz < lowest }
                next if low.empty?

                Finding.new(check: NAME, severity: :warning, message: message(program, song, index, low, lowest), node: song)
              end
            end
          end

          private

          def message(program, song, index, low, floor)
            part = SongWords.part_phrase(program, song, index)
            count = low.size == 1 ? "" : " This part has #{low.size} notes that are too low."
            notes = low.size == 1 ? "this note" : "these notes"
            "#{part.sub(/\A./, &:upcase)} of #{SongWords.song_phrase(program, song)} plays a note at " \
              "#{low.min.round} Hz (MIDI key #{midi_key(low.min)}). The square-wave voice cannot play a note lower " \
              "than #{floor} Hz. It plays this note at #{floor} Hz, so you hear a different note.#{count} " \
              "The lowest note that the voice plays correctly is :#{note_name(lowest_key(floor))} (MIDI key " \
              "#{lowest_key(floor)}). To fix this, play #{notes} one or more octaves higher. Or write `plays: :wave` " \
              "on this part. The wave voice goes one octave lower. Or use `plays:` to give the part an instrument. " \
              "An instrument can play lower notes. If this music came from another cartridge, that cartridge also " \
              "played these notes at #{floor} Hz. For that music, write `low_notes_intended: true` on its " \
              "Score. The build then does not give this warning."
          end

          def midi_key(hz) = (69 + (12 * Math.log2(hz / 440.0))).round

          # The lowest MIDI key the square wave plays in tune above +floor+: key 36, :C2, on 64 Hz.
          def lowest_key(floor) = (69 + (12 * Math.log2(floor / 440.0))).ceil

          def note_name(key) = "#{%w[C Cs D Ds E F Fs G Gs A As B][key % 12]}#{(key / 12) - 1}"
        end
      end
    end
  end
end
