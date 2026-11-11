# frozen_string_literal: true

module VBlank
  module Original
    # ONE NOTE OF MUSIC IN A DATA PACK, as eight bytes, low byte first:
    #
    #   0-1  at          the tick it starts on, from the start of the part
    #   2-3  length      how many ticks it lasts (0: until the next note starts)
    #   4    key         a MIDI note number, 0 to 127; REST (255) for a rest
    #   5    instrument  which of the part's instruments it plays, counting from 0, in the order
    #                    the game names them; PART_OWN (255) for the part's own
    #   6    volume      its loudness, 0 to 15; PART_OWN (255) for the part's own
    #   7    (nothing yet: write 0)
    #
    # A note whose +at+ is END_OF_PART (65535) ends the part: the slot holds as many notes as the longest
    # part of its kind can have, and a shorter one ends there.
    #
    # WHY A RECORD OF VBLANK'S OWN. A retail game keeps its music in its sound driver's own form,
    # commands a driver steps through, which no two games share. The port's unpacking routine
    # (`slots.fill_from_copy`) runs that form forward and writes the notes it plays here, so a
    # part reads the same record whatever the original was.
    PackNote = Data.define(:at, :length, :key, :instrument, :volume)

    class PackNote
      BYTES = 8
      REST = 255
      PART_OWN = 255
      END_OF_PART = 0xFFFF

      # The notes in +bytes+, up to the first that ends its part.
      def self.list_in(bytes)
        bytes.unpack("v v C C C C" * (bytes.bytesize / BYTES)).each_slice(6).map do |at, length, key, instrument, volume, _|
          new(at: at, length: length, key: key, instrument: instrument, volume: volume)
        end.take_while { |note| note.at != END_OF_PART }
      end
    end
  end
end
