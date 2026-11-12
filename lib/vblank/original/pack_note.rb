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
    #   7     pan         on a part of the console's own voices, the speaker it plays from: 0 both,
    #                     1 the left alone, 2 the right alone (Audio::Pan's bits); PART_OWN (255),
    #                     or anything else, for the part's own
    #   8-9   loudness    on a part that plays a recording, its loudness in 512ths of the
    #                     recording's size, 0 to 512, in place of +volume+ (a Score::Note's
    #                     `volume: 15 * loudness / 512r`); NO_LOUDNESS (65535) to take +volume+
    #   10    noise clock on a part on the noise voice, the voice's own setting in place of the
    #                     key's pitch (a Score::Note's `noise_clock:`): the divider, 0 to 7, in the
    #                     low three bits and the halvings, 0 to 13, in the high four, as the
    #                     Advance's noise register keeps them (its bit 3 is not read); PART_OWN
    #                     (255), or halvings past 13, for the key's pitch
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
    #
    # A speaker means nothing on a part that plays a recording, which plays from both, and a noise
    # clock means nothing off the noise voice or on a part that is transposed (a transpose cannot
    # move the voice's own setting): there each is left as the part's own.
    PackNote = Data.define(:at, :length, :key, :instrument, :volume, :pan, :loudness, :noise_clock)

    class PackNote
      BYTES = 12
      REST = 255
      PART_OWN = 255
      NO_LOUDNESS = 0xFFFF
      END_OF_PART = 0xFFFF
      # The most a loudness can be: the recording at its own size.
      FULL_LOUDNESS = 512
      LAYOUT = "v v C C C C v C C"

      # The speaker each value of the pan byte names (Audio::Pan.bits_of, nought for both).
      SIDES = { 0 => :center, 1 => :left, 2 => :right }.freeze

      # Where the noise clock's halvings are in its byte, the divider's bits, and the most halvings
      # the voice has (Audio::Sound::NOISE_HALVINGS).
      CLOCK_HALVINGS_AT = 4
      CLOCK_DIVIDER_BITS = 7
      MOST_CLOCK_HALVINGS = 13
      # Every byte that names a noise clock, from 0 up: the halvings 13 or fewer.
      CLOCK_BYTES = (MOST_CLOCK_HALVINGS + 1) << CLOCK_HALVINGS_AT

      # The notes in +bytes+, up to the first that ends its part.
      def self.list_in(bytes)
        bytes.unpack(LAYOUT.tr(" ", "") * (bytes.bytesize / BYTES)).each_slice(9).map do |at, length, key, instrument, volume, pan, loudness, clock, _|
          new(at: at, length: length, key: key, instrument: instrument, volume: volume, pan: pan, loudness: loudness, noise_clock: clock)
        end.take_while { |note| note.at != END_OF_PART }
      end

      # +notes+ as the bytes of a slot +count+ notes long: each [at, length, key, instrument,
      # volume], then the loudness, the pan and the noise clock where a note gives them (nil for
      # none), then a note that ends the part, then zeros. For a port's tests, and a routine of
      # Ruby that writes a slot whole.
      def self.bytes_of(notes, count:)
        records = notes.map do |at, length, key, instrument, volume, loudness, pan, clock|
          [at, length, key, instrument, volume, pan || PART_OWN, loudness || NO_LOUDNESS, clock || PART_OWN, 0]
        end
        records << [END_OF_PART, 0, 0, 0, 0, 0, 0, 0, 0] if records.length < count
        records.flatten.pack(LAYOUT.tr(" ", "") * records.length).ljust(count * BYTES, "\0")
      end

      # The [divider, halvings] a noise clock byte names, or nil for one that names none.
      def self.clock_of(byte)
        return nil unless byte < CLOCK_BYTES

        [byte & CLOCK_DIVIDER_BITS, byte >> CLOCK_HALVINGS_AT]
      end

      # The speaker this note names (:left, :right or :center), or nil for the part's own.
      def side = SIDES[pan]

      # The [divider, halvings] this note's noise clock names, or nil for its key's pitch.
      def clock = PackNote.clock_of(noise_clock)

      # Whether the pan byte names a speaker or the part's own, as a build holding the record
      # takes it: anything else is a mistake there.
      def side_named? = pan == PART_OWN || SIDES.key?(pan)

      # Whether the noise clock byte names a clock or the key's pitch.
      def clock_named? = noise_clock == PART_OWN || noise_clock < CLOCK_BYTES
    end
  end
end
