# frozen_string_literal: true

module VBlank
  module DSL
    # Instruments
    #
    # An instrument plays notes from one recording: a piano, a synth pad, anything recorded.
    # VBlank covers the whole keyboard from that one recording by reading it faster for higher
    # notes and slower for lower ones. Several notes sound at once, so an instrument plays chords.
    # `instrument` hands one back.
    #
    # ```ruby
    # piano = instrument :piano, from: "piano_c4.wav", note: :C4
    # piano.play(:E4)                 # one note
    # piano.play(:C4, :E4, :G4)       # a chord: all three sound together
    # piano.play(:C4) if pressed(:a)  # a note played from a button
    # ```
    #
    # See Builder#instrument.
    #--
    # A thin layer over a Sample: each note becomes a pitched voice in the mixer, shifted from the
    # sample's own recorded note.
    #++
    class Instrument
      # Built by Builder#instrument, wrapping the sample it plays.
      def initialize(builder, sample)
        @builder = builder
        @sample = sample
      end

      # The instrument's name, as given to `instrument`.
      def name
        @sample.name
      end

      # Plays one or more notes at once, and returns the instrument so calls chain.
      #
      # One note is a single tone, and several make a chord. Each note sounds on a voice of its
      # own, so the notes do not cut each other off.
      #
      # ```ruby
      # piano.play(:C4, :E4, :G4, volume: :half)
      # ```
      #
      # * `notes` - the notes to play, such as `:C4` or `:Fs4`. At least one.
      # * `volume:` - how loud they play: `:full`, `:three_quarter`, `:half`, `:quarter` or `:mute`.
      def play(*notes, volume: :full)
        raise ArgumentError, "play a note — e.g. #{name}.play(:C4)" if notes.empty?

        notes.each { |note| @sample.play(pitch: note, volume: volume) }
        self
      end

      # Stops every note of the instrument still sounding, and returns the instrument.
      #
      # ```ruby
      # piano.stop
      # ```
      def stop
        @sample.stop
        self
      end
    end
  end
end
