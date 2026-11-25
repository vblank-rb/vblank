# frozen_string_literal: true

module VBlank
  module Diagnostics
    # Which sound effects a running cartridge started on each frame, and which song it was on, by
    # the names the game gave them: what the interpreter's audio log says as `[:sound_effect, name]`
    # and `music_playing`, read off the cartridge. Verifier#watch_sound_names makes one, and
    # Verifier#sound_names_by_frame reads it.
    #
    # ### Why it watches writes rather than reading once a frame
    #
    # The sound player keeps, for each effect, a word saying what it is doing: the game writes
    # "asked for" there, and the player, running as the screen's picture ends, writes "sounding"
    # as it starts the effect. A reading once a frame cannot see everything that happens there. An
    # effect asked for again on the frame after it started reads "sounding" both times, and so
    # does one asked for again on the frame it would have ended; one started where it is asked,
    # `this_frame: true`, goes from asked to sounding inside the game's own pass. Being told of
    # every write that changes the word sees each start, however close together. An effect asked
    # for twice in one pass is one start, as it is in the interpreter, and one replaced by another
    # of its group in the same pass is never started at all, on either.
    #
    # ### Which frame a start belongs to
    #
    # The emulator counts a frame from the end of one picture to the end of the next, and the
    # player runs at the very start of that count, before the game's pass. So what the player
    # starts in the emulator's frame +n+ is the work of the frame that ended as +n+ began: the
    # interpreter's frame +n+ - 1. A start the game made itself, inside its pass (`this_frame:`),
    # belongs to the frame the pass ends, +n+. Such a start always follows the game's own ask in
    # the same emulator frame, and the player's never does, since it runs before the pass: that is
    # how the two are told apart. A song works the same way, with the number the game names it by
    # as the ask.
    class SoundNames
      # One frame: the effects started on it, in the order they started, and the song the player
      # was on at its end, or nil for none.
      Frame = Data.define(:frame, :effects, :song)

      # +player+ is the build's record of the sound player (Cartridge::BuildRecord::SoundPlayer),
      # nil for a game with none. +from+ is the first frame listed, and +song+ the number of the
      # song playing as the watch starts.
      def initialize(player, from:, song:)
        @player = player
        @from = from
        @song_at_start = song
        @started = Hash.new { |frames, frame| frames[frame] = [] }
        @songs = []         # [frame, number] for each change of song, in order
        @asked_on = {}      # an address the game asks at -> the emulator frame it last did
      end

      # The addresses to be told of: every effect's word, and the song's numbers.
      def watched_addresses
        return [] unless @player

        [*@player.effect_states.keys, @player.song_playing, @player.song_wanted].compact
      end

      # A change seen at a watched address in the emulator's frame +frame+ (RubyGBAEmulator::Change,
      # or anything with +address+ and +now+), in the order the changes were made.
      def record(change, frame)
        address = change.address
        if address == @player.song_wanted
          @asked_on[address] = frame
        elsif address == @player.song_playing
          @songs << [frame_of(frame, asked_at: @player.song_wanted), change.now]
        elsif @player.asked_states.include?(change.now)
          @asked_on[address] = frame
        elsif change.now == @player.sounding_state
          @started[frame_of(frame, asked_at: address)] << @player.effect_states.fetch(address)
        end
      end

      # Every frame from the first listed through +last+, as Frames.
      def frames(last)
        (@from..last).map do |frame|
          Frame.new(frame: frame, effects: @started.fetch(frame, []).dup, song: song_name(song_on(frame)))
        end
      end

      private

      # The interpreter's frame a write made in the emulator's frame +frame+ belongs to: that frame
      # when the game asked at +asked_at+ earlier in it, and the one before otherwise.
      def frame_of(frame, asked_at:) = @asked_on[asked_at] == frame ? frame : frame - 1

      def song_on(frame)
        @songs.reverse_each.find { |at, _| at <= frame }&.last || @song_at_start
      end

      def song_name(number)
        return if number.nil? || number.zero?

        @player.songs.fetch(number, number)
      end
    end
  end
end
