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
    #
    # A NOTE WITH ITS VOICE'S SETTINGS (`slots.voiced_notes`) is thirty-two bytes: the twelve above,
    # then what else a Score::Note can say of its voice, as a sound driver sets them for each note
    # it strikes. Each is the note's only where bytes 20 and 21 name it (a bit of NAMES), and else
    # the part's own:
    #
    #   12-13 pitch number the voice's own tuning, 0 to 2047, in place of the key's pitch (a
    #                      Score::Note's `pitch_number:`, the Color's period). The key byte must
    #                      still be 127 or less: past that the note is a rest.
    #   14    fade         how the voice counts the note's volume, as its envelope register keeps it
    #                      (Audio::NoteFade#bits): the step, 0 to 7, in the low three bits, and 8
    #                      for a swell (`swell:`) where it is not set for a fade (`decay:`)
    #   15    duty         the square's shape on each of four frames, two bits each, the first
    #                      frame's lowest (Audio::Duty#bits; `duty:`): 0 an eighth, 1 a quarter,
    #                      2 half, 3 three quarters, so one shape is that number four times
    #   16-17 vibrato      the depth in the low four bits, the speed less one in the next four,
    #                      the frames it waits in the high byte (Audio::Vibrato#bits); a depth of 0
    #                      is `vibrato: :none`. CARRIES in the names is `carries: true`
    #   18    slide        the first square's sweep register (Audio::PitchSlide#bits): the 128ths
    #                      each step waits in bits 4 to 6, 8 to slide down, the shift in the low
    #                      three; 0 is `slide_up: :none`
    #   19    shade        where the note sits between the speakers, in 64ths from the middle, a
    #                      signed byte from -64 (the left alone) to 64 (the right alone): `pan:`
    #                      of the shade over 64. It is the note's in place of byte 7's speaker,
    #                      on any part: a recorded part too
    #   20-21 names        which of these the note names, a bit each (NAMES), and CARRIES
    #   22-24 hz           a pitch between keys, in 16ths of a hertz, on a part that plays a
    #                      recording or the noise voice (a Score::Note's `hz:` of this over 16), in
    #                      place of the key's pitch; more than 0 and 524,288 Hz at most. The key byte
    #                      must still be 127 or less: past that the note is a rest
    #   (glides)           GLIDES in the names, on a part that plays a recording: the note does not
    #                      strike, and the one sounding carries on at its pitch (`glides: true`). Its
    #                      instrument, volume and loudness are the part's own (255, 255, 65535)
    #   25-31 (nothing yet: write 0)
    #
    # A voice that has no such setting leaves it as the part's own (a duty off the squares, a fade
    # on the wave voice, a slide off the song's first square), as does a number past the setting's
    # range, where a build holding the record refuses both.
    PackNote = Data.define(:at, :length, :key, :instrument, :volume, :pan, :loudness, :noise_clock,
                           :pitch_number, :fade, :duty, :vibrato, :slide, :shade, :carries, :hz, :glides)

    class PackNote
      def initialize(pitch_number: nil, fade: nil, duty: nil, vibrato: nil, slide: nil, shade: nil, carries: false, hz: nil,
                     glides: false, **)
        super
      end

      BYTES = 12
      VOICED_BYTES = 32
      # Bytes 12 to 24 of a voiced record: the settings, the names and the hz (three bytes, as a
      # number of two and one of one).
      VOICED_LAYOUT = "v C C v C c v v C"
      # The bits of the names, and the one that says a vibrato carries.
      NAMES = { pitch_number: 1, fade: 2, duty: 4, vibrato: 8, slide: 16, shade: 32, hz: 128, glides: 256 }.freeze
      CARRIES = 64
      # The highest pitch number, fade, slide and shade a record can name, and its hz in 16ths.
      MOST_PITCH_NUMBER = 2047
      MOST_FADE = 15
      MOST_SLIDE = 127
      MOST_SHADE = 64
      HZ_SIXTEENTHS = 16
      MOST_HZ = Audio::Sound::NOISE_CLOCK_HZ * HZ_SIXTEENTHS
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

      # The notes in +bytes+, up to the first that ends its part: records of twelve bytes, or of
      # VOICED_BYTES where +voiced+.
      def self.list_in(bytes, voiced: false)
        size = voiced ? VOICED_BYTES : BYTES
        (0...(bytes.bytesize / size)).lazy.map { |record| read(bytes.byteslice(record * size, size), voiced) }
                                       .take_while { |note| note.at != END_OF_PART }.to_a
      end

      def self.read(record, voiced)
        at, length, key, instrument, volume, pan, loudness, clock = record.unpack(LAYOUT.delete(" "))
        plain = { at: at, length: length, key: key, instrument: instrument, volume: volume, pan: pan, loudness: loudness,
                  noise_clock: clock }
        return new(**plain) unless voiced

        pitch, fade, duty, vibrato, slide, shade, names, hz_low, hz_high =
          record.byteslice(BYTES, VOICED_BYTES - BYTES).unpack(VOICED_LAYOUT.delete(" "))
        named = ->(field, value) { value if names.anybits?(NAMES.fetch(field)) }
        new(**plain, pitch_number: named.(:pitch_number, pitch), fade: named.(:fade, fade), duty: named.(:duty, duty),
                     vibrato: named.(:vibrato, vibrato), slide: named.(:slide, slide), shade: named.(:shade, shade),
                     carries: names.anybits?(CARRIES), hz: named.(:hz, hz_low | (hz_high << 16)),
                     glides: names.anybits?(NAMES.fetch(:glides)))
      end
      private_class_method :read

      # The bytes after a record's first twelve for +settings+, a Hash of what of NAMES a note
      # names (each the number its bytes keep, the hz in 16ths), `carries: true` and `glides:
      # true`. For a port's tests, and a routine of Ruby that writes a slot whole.
      def self.voiced_bytes_of(settings)
        names = settings.sum { |field, said| said ? NAMES.fetch(field, 0) : 0 } | (settings[:carries] ? CARRIES : 0)
        hz = settings[:hz] || 0
        [settings[:pitch_number] || 0, settings[:fade] || 0, settings[:duty] || 0, settings[:vibrato] || 0, settings[:slide] || 0,
         settings[:shade] || 0, names, hz & 0xFFFF, hz >> 16].pack(VOICED_LAYOUT.delete(" ")).ljust(VOICED_BYTES - BYTES, "\0")
      end

      # +notes+ as the bytes of a slot +count+ notes long: each [at, length, key, instrument,
      # volume], then the loudness, the pan and the noise clock where a note gives them (nil for
      # none), then a note that ends the part, then zeros. For a port's tests, and a routine of
      # Ruby that writes a slot whole. Where +voiced+, each note's ninth is the Hash of its voice's
      # settings (.voiced_bytes_of), nil for none.
      def self.bytes_of(notes, count:, voiced: false)
        records = notes.map do |at, length, key, instrument, volume, loudness, pan, clock, settings|
          plain = [at, length, key, instrument, volume, pan || PART_OWN, loudness || NO_LOUDNESS, clock || PART_OWN, 0]
          plain.pack(LAYOUT.delete(" ")) + (voiced ? voiced_bytes_of(settings || {}) : "".b)
        end
        size = voiced ? VOICED_BYTES : BYTES
        records << [END_OF_PART, 0, 0, 0, 0, 0, 0, 0, 0].pack(LAYOUT.delete(" ")).ljust(size, "\0") if records.length < count
        records.join.ljust(count * size, "\0")
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

      # WHAT A VOICED RECORD'S SETTINGS ARE, AS A SCORE::NOTE IS GIVEN THEM: a Hash of the words of
      # those it names (`pitch_number:`, `decay:` or `swell:`, `duty:`, `vibrato:`, `slide_up:` or
      # `slide_down:`, `pan:`, `hz:`, `glides:`), each left out where it names none. A number past its range is left out
      # by the file's reading (IR::StartFile) and refused by a build holding the record, which
      # asks .settings_out_of_range first.
      def score_settings
        settings = {}
        settings[:pitch_number] = pitch_number if pitch_number
        settings.merge!(fade_words) if fade
        settings[:duty] = Audio::Duty.from_bits(duty).shapes if duty
        settings[:vibrato] = vibrato_words if vibrato
        settings.merge!(slide_words) if slide
        settings[:pan] = Rational(shade, MOST_SHADE) if shade
        settings[:hz] = Rational(hz, HZ_SIXTEENTHS) if hz
        settings[:glides] = true if glides
        settings
      end

      # The names of the settings this record names past their range (MOST_PITCH_NUMBER and its
      # kin, and a slide whose wait or shift alone is 0).
      def settings_out_of_range
        out = []
        out << :pitch_number if pitch_number && pitch_number > MOST_PITCH_NUMBER
        out << :fade if fade && fade > MOST_FADE
        out << :slide if slide && !PackNote.slide_in_range?(slide)
        out << :shade if shade && shade.abs > MOST_SHADE
        out << :hz if hz && !hz.between?(1, MOST_HZ)
        out
      end

      # Whether a slide byte names a slide: 0 for none, or a wait and a shift of 1 or more each.
      def self.slide_in_range?(byte)
        return true if byte.zero?

        byte <= MOST_SLIDE && (byte >> Audio::PitchSlide::EVERY_AT).positive? && (byte & Audio::PitchSlide::THREE_BITS).positive?
      end

      def fade_words
        said = Audio::NoteFade.from_bits(fade)
        said.swells? ? { swell: said.step } : { decay: said.step }
      end

      def vibrato_words
        wobble = Audio::Vibrato.from_bits(vibrato)
        return :none unless wobble.moves?

        { depth: wobble.depth, speed: wobble.speed, after: wobble.after, carries: carries }
      end

      def slide_words
        return { slide_up: :none } if slide.zero?

        moved = Audio::PitchSlide.from_bits(slide)
        { :"slide_#{moved.direction}" => { every: moved.every, shift: moved.shift } }
      end
      private :fade_words, :vibrato_words, :slide_words
    end
  end
end
