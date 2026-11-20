# frozen_string_literal: true

module VBlank
  module Live
    # A DEVICE WITH NO SCREEN: it keeps every picture it is shown and every frame's sound it is
    # handed, holds the buttons a script gives it by frame (+buttons+, frame number to the buttons
    # held on it), and stops the play after +frames+ pictures.
    #
    # ITS CLOCK MOVES ONLY WHEN SOMETHING MOVES IT, so a test never waits for real time.
    # Waiting moves it straight to the moment waited for, and every pass then takes
    # +pass_seconds+ — none unless the test asks otherwise, a machine infinitely fast — or, given
    # something callable, what it answers for the pass's number (1, 2, 3, …). Kept as an exact
    # fraction, so a pass set to take two frames takes two and not a hair more.
    #
    # WITH +speaker: true+ IT HAS A SPEAKER, which plays what it is handed on the same clock, a
    # second of samples in a second: #sound_waiting is how much is left to play, #gaps how many
    # times sound arrived after the speaker had run out (a gap a person would hear), and
    # #most_waiting the most there ever was waiting. Without one, #sound_waiting is nil.
    #
    # +buttons+ is a Hash from a picture's number to the buttons held on it, or a list of buttons held on every
    # picture. +on_notice+ is called with each line the match says (#notice).
    #
    # +pauses+ maps a picture's number to the seconds the player pauses for after it is shown, and
    # +fast_forward+ holds the numbers of the passes (1, 2, 3, …) fast forward is held through, at
    # +fast_forward_speed+.
    #
    # IT IS ASKED WHAT THE WINDOW (SDL) IS ASKED, so a play that passes here does not stop in a
    # window over a question only the window put to the game. It is told how many players each play
    # seats (#seat_counts), keeps the game's save memory as the window's save file does (#saved;
    # +save+ is what an earlier play left), and, given the +screen+ the window would be opened at
    # ([width, height]), refuses a picture of another size as the window does. A picture whose
    # pixels are not its width times its height is refused with or without one. +keeps_save+ false
    # keeps no save memory, as the window keeps none in a match with other players. A shell's window
    # keeps one only while its game plays (SDL#offer_states); Headless keeps one throughout, which
    # comes to the same, since the session keeps no save for a play with no save memory (the menu's
    # and the unpacking's).
    #
    # It never asks for a save state (Session#take_state_request is nil without asking), as a
    # window nobody presses the keys of never does; a test that wants one subclasses it to answer
    # take_state_request, state_saved, state_to_load, state_loaded and state_refused.
    class Headless
      Picture = Data.define(:pixels, :width, :height)

      # THE GAME'S SAVE MEMORY, kept as bytes where the window keeps it in a file (SaveFile): the
      # session reads it as the game starts and writes it soon after it changes and as the play ends.
      class SaveMemory
        # +bytes+ are what an earlier play left, or nil for a new cartridge.
        def initialize(bytes) = @bytes = bytes&.b

        # The bytes last written, else those it was made with.
        attr_reader :bytes

        # The bytes kept, or nil for none; SaveFile::NotThisGamesSave, as the window's file raises,
        # when they are not +size+ bytes.
        def read(size)
          return @bytes if @bytes.nil? || @bytes.bytesize == size

          raise SaveFile::NotThisGamesSave, "The save given to the headless device is #{@bytes.bytesize} bytes. It is " \
                                            "not a save of this game, whose save is #{size} bytes."
        end

        def write(bytes) = @bytes = bytes.b
      end

      # +sounds+ is each frame's samples, in the order they were handed over, and +sound_rate+ the
      # samples a second they were made at. +seat_counts+ is the most players each play seats (0 for
      # a game that names none), one a play, in the order they were played.
      attr_reader :pictures, :sounds, :sound_rate, :now, :gaps, :most_waiting, :notices, :seat_counts

      # The lines shown while the window waited for its game (#show_waiting), a list a frame.
      attr_reader :waiting

      # The game's save memory (a SaveMemory), or nil when +keeps_save+ is false. The session asks
      # for it as each play starts (Session#read_save_file), as it asks the window for its SaveFile.
      attr_reader :save_file

      def initialize(frames:, buttons: {}, pass_seconds: 0, speaker: false, pauses: {}, fast_forward: [],
                     fast_forward_speed: 4, on_notice: nil, save: nil, keeps_save: true, screen: nil)
        raise ArgumentError, "A headless device that keeps no save cannot be given one. Drop save: or keeps_save: false." if save && !keeps_save

        @frames = frames
        @screen = screen
        @save_file = SaveMemory.new(save) if keeps_save
        @seat_counts = []
        @buttons = buttons
        @on_notice = on_notice
        @pauses = pauses
        @fast_forward = fast_forward
        @fast_forward_speed = fast_forward_speed
        @held_after = nil # the picture the last pause came after
        @pass_seconds = pass_seconds.respond_to?(:call) ? pass_seconds : ->(_pass) { pass_seconds }
        @speaker = speaker
        @pictures = []
        @waiting = []
        @notices = []
        @sounds = []
        @sound_rate = nil # until the first frame's sound gives it
        @now = 0r
        @passes = 0
        @gaps = 0
        @most_waiting = 0r
        @speaker_done_at = nil # when what the speaker holds has all been played; nil before any sound
      end

      # Lines of words in place of a picture, while a game is built elsewhere (BuildWatch): kept,
      # and counted among the frames this device shows.
      def show_waiting(lines) = @waiting << lines.dup

      # The picture is the game's own and is drawn over next frame, so a copy is kept.
      def show(pixels, width, height)
        refusal = SDL.picture_refusal_message(pixels, width, height, screen: @screen) and raise ArgumentError, refusal
        @pictures << Picture.new(pixels: pixels.dup, width: width, height: height)
      end

      # The game's save memory as it stands: the bytes it last wrote, else those +save+ handed in, else nil.
      def saved = @save_file&.bytes

      # The game seats +most_players+ (0 for none named), told by the session before the first pass.
      def seat_players(most_players) = @seat_counts << most_players

      # The left speaker's sound is kept. The right one's is as long, so it shows nothing more about
      # when the speaker runs out. The sound is the game's own and is written over next frame, so a
      # copy is kept.
      def play_sound(samples, rate, _right = samples)
        @sounds << samples.dup
        @sound_rate = rate
        return unless @speaker

        @gaps += 1 if @speaker_done_at && @speaker_done_at < @now
        @speaker_done_at = [@speaker_done_at || @now, @now].max + Rational(samples.length, rate)
        @most_waiting = [@most_waiting, sound_waiting].max
      end

      # Seconds of sound the speaker has still to play, or nil with no speaker.
      def sound_waiting
        return nil unless @speaker

        @speaker_done_at ? [@speaker_done_at - @now, 0r].max : 0r
      end

      def held_buttons(frame) = @buttons.is_a?(Hash) ? @buttons.fetch(frame, []) : @buttons

      # A line about the match, kept in the order it came.
      def notice(words)
        @notices << words
        @on_notice&.call(words)
      end

      def stop? = @pictures.size + @waiting.size >= @frames

      def fast_forward_speed(pass) = @fast_forward.include?(pass) ? @fast_forward_speed : 1

      # Held for the seconds +pauses+ gives the picture just shown, once, with the speaker emptied
      # as the pause begins.
      def hold_while_paused
        seconds = @pauses[@pictures.size] or return false
        return false if @held_after == @pictures.size

        @held_after = @pictures.size
        @speaker_done_at = nil
        @now += seconds.to_r
        true
      end

      # The next pass starts the moment this returns, so it is where the pass's time is spent.
      def wait_until(seconds)
        @passes += 1
        @now = [@now, seconds.to_r].max + @pass_seconds.call(@passes).to_r
      end
    end
  end
end
