# frozen_string_literal: true

module VBlank
  module Live
    # A SHELL'S UNPACKING PLAYED AWAY FROM THE WINDOW. The unpacking is a game of its own built as
    # Ruby (Live::Shell), and played on the window's thread it can show a frame only when it waits
    # for one: a routine that works for a second between writes (a port rendering music) freezes
    # the window for that second. So it plays in a Ractor of its own instead, on another core, as
    # fast as that core goes, and the window plays this in its place: a game that shows, each
    # frame, the newest picture the unpacking has drawn (its progress bar), and stops when the
    # unpacking does.
    #
    # The unpacking's own game is made inside the Ractor from its Ruby text, so nothing it holds is
    # shared with the window. What crosses between them is pictures, at most one a frame
    # (PictureSender), and at the end what the shell keeps (Outcome). Closing the window closes
    # the way the pictures come back, and the unpacking stops at its next frame and keeps nothing.
    #
    # It answers what Live::Session asks of a game (LiveGame's #play and the rest), so the window
    # plays it as it plays anything else: uncapped, since the pace is this loop's own, a picture
    # each time the unpacking sends one or a frame's time goes by without one.
    class BackgroundUnpacking
      # What the unpacking left once it stopped itself: +finished+ and +fault_kind+, the unpacking's
      # two numbers a shell checks, and +bytes+, the pack's bytes as a String.
      Outcome = Data.define(:finished, :fault_kind, :bytes)

      # The unpacking's size and pace, sent once its game is made.
      Facts = Data.define(:width, :height, :sound_rate, :frame_seconds)

      # Ruby's sound for a frame with nothing to hear: the unpacking makes none worth handing on.
      SILENCE = [].freeze

      # +source+ is the unpacking as Ruby (Backends::Ruby#live_source), +copy+ the copy's bytes,
      # and +names+ the unpacking's names a shell reads (ShellFacts::UnpackingNames). The Ractor
      # starts here, and this waits for its game to be made.
      def initialize(source, copy, names)
        @pictures = Ractor::Port.new
        @inbox = Thread::Queue.new
        @ractor = start_ractor(shareable_copy(source), shareable_copy(copy), Ractor.make_shareable(names))
        @receiver = Thread.new { receive_pictures }
        @outcome = nil
        message = next_message(nil)
        if message in [:facts, Facts => facts]
          @facts = facts
        else
          collect_outcome # raises what stopped the unpacking's game being made
          raise ArgumentError, "the unpacking stopped before it began"
        end
      end

      def width = @facts.width
      def height = @facts.height
      def sound_rate = @facts.sound_rate
      def frame_seconds = @facts.frame_seconds

      # The unpacking keeps no save memory.
      def save_size = 0
      def save_file_due? = false
      def save_unwritten? = false

      # What the unpacking left (Outcome), once #play has given back a picture.
      attr_reader :outcome

      # Shows +player+ the unpacking's newest picture each frame, until the unpacking stops, when
      # it gives back the last picture, or the player stops it, when it gives back nil.
      #
      # A STOPPED UNPACKING ENDS AT ITS NEXT FRAME, not at once: Ruby has no way to stop a Ractor
      # from outside, and the routine is checked only where it waits for a frame. Until then it
      # works on, keeping a core busy but not the window, and what it makes is thrown away.
      def play(player, match_seed: nil, local_player: nil) # rubocop:disable Lint/UnusedMethodArgument -- what Session hands a game
        shown = Array.new(width * height, 0)
        loop do
          case next_message(frame_seconds)
          in [:picture, pixels] then shown = pixels
          in [:done, nil]
            collect_outcome
            return shown
          in [:done, last]
            # Shown once, as the unpacking showed it before it stopped (a full bar).
            player.buttons_after(last, SILENCE, SILENCE)
            collect_outcome
            return last
          in nil then nil
          end
          return nil if player.buttons_after(shown, SILENCE, SILENCE).nil?
        end
      ensure
        stop_receiving
      end

      private

      # The unpacking's game, made and played in a Ractor, sending its facts, then its pictures,
      # then :done to +@pictures+; its value is the Outcome, or nil when the window stopped it.
      def start_ractor(source, copy, names)
        quiet_experimental_warning do
          Ractor.new(source, copy, names, @pictures) do |text, bytes, names, pictures|
            last = nil # the picture the unpacking stopped on, sent with :done, since PictureSender may have skipped it
            game = IR::Backends::Ruby::LiveGame.new(text).hand_file(bytes)
            pictures << [:facts, Facts.new(width: game.width, height: game.height, sound_rate: game.sound_rate,
                                            frame_seconds: game.frame_seconds)]
            last = game.play(PictureSender.new(pictures, game.frame_seconds))
            unless last.nil?
              state = game.state
              Outcome.new(finished: state.vars.fetch(names.finished), fault_kind: state.vars.fetch(names.fault_kind),
                          bytes: state.lists.fetch(names.bytes).map { |item| item & 0xFF }.pack("C*"))
            end
          ensure
            begin
              pictures << [:done, last]
            rescue Ractor::ClosedError
              nil # the window stopped listening
            end
          end
        end
      end

      # Ruby warns that Ractors are experimental the first time one starts. That is a line for the
      # person who wrote the program, not the player, so it is left out here alone.
      def quiet_experimental_warning
        was = Warning[:experimental]
        Warning[:experimental] = false
        yield
      ensure
        Warning[:experimental] = was
      end

      # +value+ as a Ractor may be handed it: itself where it is frozen already (a script's text is),
      # else a frozen copy.
      def shareable_copy(value) = Ractor.make_shareable(value.frozen? ? value : value.dup.freeze)

      # What the window sends itself to end #receive_pictures.
      STOP_RECEIVING = :stop_receiving

      # Every message from the Ractor into the inbox, until the window sends STOP_RECEIVING.
      def receive_pictures
        while (message = @pictures.receive) != STOP_RECEIVING
          @inbox << message
        end
      end

      # The window stops listening, once: the receiving thread is ended and the port closed, so the
      # unpacking's next picture finds it closed and stops the unpacking.
      #
      # Must end the thread with a message, not by closing the port: closing it does not wake a
      # thread that waits on it, which would wait for good.
      def stop_receiving
        return if @pictures.closed?

        @pictures << STOP_RECEIVING
        @receiver.join
        @pictures.close
      end

      # The newest message waiting, waiting up to +seconds+ for one (nil: as long as it takes); nil
      # when none came. Older pictures are passed over; :facts and :done never are, and nothing
      # comes after :done.
      def next_message(seconds)
        message = @inbox.pop(timeout: seconds)
        message = @inbox.pop while (message in [:picture, _]) && !@inbox.empty?
        message
      end

      # The unpacking stopped itself: its Outcome kept, or the error it stopped with raised as it
      # was (also where its game could not be made, before any picture).
      def collect_outcome
        @outcome = @ractor.value
      rescue Ractor::RemoteError => e
        raise e.cause
      ensure
        stop_receiving
      end

      # WHO PLAYS THE UNPACKING IN ITS RACTOR: it holds no buttons, and sends the window the picture
      # at most once every +seconds+, which is all a window can show; the rest of the unpacking's
      # frames are played as fast as they come. Once the window has closed the way, it stops the play.
      class PictureSender
        NO_BUTTONS = [].freeze

        def initialize(pictures, seconds)
          @pictures = pictures
          @seconds = seconds
          @sent_at = nil
        end

        def take_state_request = nil

        def buttons_after(pixels, _left, _right)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @sent_at.nil? || now - @sent_at >= @seconds
            @pictures << [:picture, pixels]
            @sent_at = now
          end
          NO_BUTTONS
        rescue Ractor::ClosedError
          nil
        end
      end
    end
  end
end
