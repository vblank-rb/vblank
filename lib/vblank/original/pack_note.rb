# frozen_string_literal: true

module VBlank
  module Original
    # ONE NOTE OF MUSIC IN A DATA PACK, as twelve bytes, low byte first:
    #
    #   0-1   at          the tick it starts on, from the start of the part
    #   2-3   length      how many ticks it lasts (0: until the next note starts)
    #   4     key         a MIDI note number, 0 to 127; REST (255) for a rest
    #   5     instrument  which of the part's instruments it plays, counting from 0, in the order
    #                     the game names them; PART_OWN (255) for the part's own
    #   6     volume      its loudness, 0 to 15; PART_OWN (255) for the part's own
    #   7     (nothing yet: write PART_OWN)
    #   8-9   loudness    on a part that plays a recording, its loudness in 512ths of the
    #                     recording's size, 0 to 512, in place of +volume+ (a Score::Note's
    #                     `volume: 15 * loudness / 512r`); NO_LOUDNESS (65535) to take +volume+
    #   10    (nothing yet: write PART_OWN)
    #   11    (nothing yet: write 0)
    #
    # A note whose +at+ is END_OF_PART (65535) ends the part: the slot holds as many notes as the longest
    # part of its kind can have, and a shorter one ends there.
    #
    # WHY A RECORD OF VBLANK'S OWN. A retail game keeps its music in its sound driver's own form,
    # commands a driver steps through, which no two games share. The port's unpacking routine
    # (`slots.fill_from_copy`) runs that form forward and writes the notes it plays here, so a
    # part reads the same record whatever the original was.
    #
    # WHY A LOUDNESS AS WELL AS A VOLUME. A cartridge's sound engine mixes a recording at one of
    # 512 loudnesses where a console voice has 16 volumes, and a song lifted from one keeps its
    # quiet notes heard only at that scale (`volume:` with a fraction, sound.md).
    PackNote = Data.define(:at, :length, :key, :instrument, :volume, :loudness)

    class PackNote
      BYTES = 12
      REST = 255
      PART_OWN = 255
      NO_LOUDNESS = 0xFFFF
      END_OF_PART = 0xFFFF
      # The most a loudness can be: the recording at its own size.
      FULL_LOUDNESS = 512
      LAYOUT = "v v C C C C v C C"

      # The notes in +bytes+, up to the first that ends its part.
      def self.list_in(bytes)
        bytes.unpack(LAYOUT.tr(" ", "") * (bytes.bytesize / BYTES)).each_slice(9).map do |at, length, key, instrument, volume, _, loudness, _, _|
          new(at: at, length: length, key: key, instrument: instrument, volume: volume, loudness: loudness)
        end.take_while { |note| note.at != END_OF_PART }
      end

      # +notes+ as the bytes of a slot +count+ notes long: each [at, length, key, instrument,
      # volume] or [..., volume, loudness], then a note that ends the part, then zeros. For a
      # port's tests, and a routine of Ruby that writes a slot whole.
      def self.bytes_of(notes, count:)
        records = notes.map { |at, length, key, instrument, volume, loudness| [at, length, key, instrument, volume, PART_OWN, loudness || NO_LOUDNESS, PART_OWN, 0] }
        records << [END_OF_PART, 0, 0, 0, 0, 0, 0, 0, 0] if records.length < count
        records.flatten.pack(LAYOUT.tr(" ", "") * records.length).ljust(count * BYTES, "\0")
      end
    end
  end
end
