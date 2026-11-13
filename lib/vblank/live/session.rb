# frozen_string_literal: true

module VBlank
  module Live
    # A GAME PLAYED LIVE, A PASS AT A TIME, THROUGH A DEVICE. The game is built as Ruby and run in
    # this process (IR::Backends::Ruby#live_game). At the end of each of its frames it hands the
    # session the picture and the frame's sound; the session waits for that frame to end, shows
    # the device the picture, hands it the sound, asks it whether to stop, and gives the game the
    # buttons for the next pass. The play ends when the device asks to stop, or when the game itself ends.
    #
    # A device answers:
    #
    #   show(pixels, width, height)  the picture, as the screen shows it (15-bit colours, a row at a time),
    #                                which the game draws over next frame: a device that keeps it copies it
    #   play_sound(left, rate, right) the sound of the frame just shown, the left speaker's 16-bit
    #                                samples and the right's, +rate+ a second each
    #   sound_waiting                seconds of sound the speaker has still to play, or nil for a
    #                                device with no speaker (yet)
    #   held_buttons(pass)           the buttons held as picture number +pass+ is shown (1, 2, 3, …),
    #                                for the pass that starts then
    #   fast_forward_speed(pass)     how many of the game's frames to play in the time of one through
    #                                pass number +pass+: 1, or more while the player holds fast
    #                                forward; asked before the pass is played (never, played uncapped)
    #   hold_while_paused            asked once a pass, after the picture: returns false at once unless
    #                                the player paused; otherwise returns true once they carry on or
    #                                stop, with what was waiting for the speaker thrown away
    #   stop?                        asked once a pass, after the pause
    #   watch(game, player:, players:, input_delay:)
    #                                optional: a device with nobody at the controls is told which game it plays
    #                                (answering `state`), and how the match is set up, before the first pass
    #   seat_players(most_players)   optional: the most players the game seats (0 for none named), told
    #                                before the first pass, for a window that seats several (Seats)
    #   notice(words)                a line for the person about the match (a player left), said
    #                                where the device can, in a match over a network only
    #   now                          the time, in seconds, from any start that does not move back
    #   wait_until(seconds)          returns at that time, or at once if it has gone; the next pass starts then
    #
    # A DEVICE WITH A SPEAKER IS PACED BY IT (#wait_for_speaker): the speaker plays a second of
    # sound in a second, so the play waits on it, a frame a pass, keeping a few frames of sound
    # waiting. That is what keeps the sound whole: on the clock's beat below, a pass that missed
    # its frame skips one, and the speaker is a frame's sound short.
    #
    # WITH NO SPEAKER, THE FRAMES KEEP THE CONSOLE'S BEAT. On the console the screen ends a frame
    # every sixtieth of a second or so whether the game is ready or not: a pass that finishes early
    # waits for the end of its frame, and one that finishes late has missed the end of one or more
    # and waits for the next. The session keeps the time the current frame began on that even
    # beat, and as each pass ends counts how many frames have begun since — at least the one the
    # pass ran in — moves the beat on by that many and waits for it. A machine faster than the
    # console waits, and plays exactly as fast; a slower one shows fewer pictures, and the game,
    # which counts one frame a pass, runs that much slower.
    #
    # UNCAPPED, for measuring, there is no beat: each pass starts the moment the last one ends, a
    # frame a pass, so the rate is how fast the machine can play the game.
    class Session
      # Frames of sound kept waiting for the speaker while it paces the play: enough that a pass
      # that runs late — a scene setting itself up as it arrives can take four frames over one —
      # or a wait that wakes late, uses up some of it and never empties it; and few, since what is
      # waiting is how far what a person sees and hears trails the buttons they press.
      SPEAKER_AHEAD_FRAMES = 4

      # THE PASS THE GAME SETS ITSELF UP IN, which the play's speed leaves out (Rate): its pass, the
      # frames it took and the seconds to their end. A first pass played in fast forward shares its
      # frame with the passes after it, so none is left out.
      Setup = Data.define(:passes, :frames, :seconds)
      NO_SETUP = Setup.new(passes: 0, frames: 0, seconds: 0)

      # The game is built as Ruby here from +program+, before any device is opened, so a game the
      # Ruby runtime cannot play yet is refused (IR::Backends::Ruby::RuntimeGap) before a window
      # comes up.
      # +stop_after_passes+ is how many passes to play at most, whatever the device asks. +game+, in
      # place of a program, is a game built as Ruby already (IR::Backends::Ruby::LiveGame), which is
      # how a game written out as one Ruby file (Ruby#script) plays with no builder to hand.
      # +collect_garbage+ runs one full collection once the game has set itself up
      # (#collect_garbage_after_setup); vblank run and a script turn it on, and uncapped it does nothing.
      # +keep_last_picture+ false ends the play as soon as the game stops itself, for a game a shell
      # plays before another (Live::Shell), rather than keeping its picture up until the device stops.
      def initialize(program = nil, game: nil, uncapped: false, stop_after_passes: nil, network: nil, collect_garbage: false,
                     keep_last_picture: true)
        refuse_match_for_one_player!(program) if network && program
        @game = game || IR::Backends::Ruby.new.live_game(program)
        @keep_last_picture = keep_last_picture
        @network = network
        @uncapped = uncapped
        @collect_garbage = collect_garbage && !uncapped
        @stop_after_passes = stop_after_passes
        @frame_seconds = @game.frame_seconds
        @pass_buttons = IR::Buttons::PassButtons.new # each connected player's buttons, a pass at a time
        @events_announced = 0 # how many of the match's events the device has been told
      end

      # Whether this play runs the full collection after setup: asked for, and not uncapped.
      def collects_garbage? = @collect_garbage

      # Plays once, on +device+, until it asks to stop or the game ends, and gives back how fast it
      # went (Rate). A game that does something its rules refuse (a push onto a full list) stops
      # the play with IR::ProgramError, in the words the interpreter would use.
      def play(device)
        begin_play(device)
        read_save_file
        @network&.begin_match
        watch_game_for_device
        stopped_on = @game.play(self, match_seed: @network&.seed, local_player: @network&.player)
        rate = Rate.new(passes: @passes, frames: @frames, seconds: @frame_began - @started - @seconds_paused,
                        stopped_itself: !stopped_on.nil?, lateness: @uncapped ? nil : @lateness.lateness,
                        setup_passes: @setup.passes, setup_frames: @setup.frames, setup_seconds: @setup.seconds)
        keep_showing(stopped_on) if stopped_on && @keep_last_picture
        rate
      ensure
        write_save_file_if_unwritten
        @network&.leave
      end

      # Ready to play on +device+. #play does this itself; a game that is stepped from outside, as a
      # watched playthrough is (Playthroughs::WindowStepper), calls this and then #buttons_after for
      # each frame.
      def begin_play(device)
        @device = device
        @passes = @frames = 0
        @paced_by_speaker = false
        @seconds_paused = 0
        @fast_frame_began = nil # when the frame being fast forwarded through began, or nil
        @fast_forward_passes = 0 # passes played in it
        @lateness = LatenessTally.new(frame_seconds: @frame_seconds)
        @pass_began = nil # when the game was handed the buttons for the pass it is playing; nil in the first
        @setup = NO_SETUP # the pass the game set itself up in, once it has been played (#record_setup)
        @started = @frame_began = @device.now
        @device.seat_players(@game.seats) if @device.respond_to?(:seat_players)
        @device.wait_until(@frame_began)
      end

      # Asked by the game as each of its frames ends, with the picture as the screen shows it and
      # the frame's sound: shows the device the picture, hands it the sound, and gives back the
      # buttons held for the pass that starts, one number a bit each for each connected player
      # (IR::Buttons.masks) — or nil when the device asks to stop. The
      # pass waits once: on the speaker, after its sound, where the device has one; on the clock,
      # for its frame to end, before its picture, where it has none.
      #
      # A speaker opens with the first frame's sound, so the first pass is played on the clock, and
      # paces the play from the second on. The first pass is the frame the game sets itself up in,
      # and counts the frames it took on the clock, which can be more than one.
      #
      # +left+ and +right+ are the two speakers' sound; a sound that is the same from both can be
      # handed over once.
      def buttons_after(pixels, left, right = left)
        speed = @uncapped ? 1 : @device.fast_forward_speed(@passes + 1)
        record_pass_time(speed)
        collect_garbage_after_setup if @collect_garbage && @passes.zero?
        write_save_file if @save_file && @game.save_file_due?
        if speed > 1
          play_fast_forward(pixels, speed)
        else
          end_fast_forward if @fast_frame_began
          play_at_console_speed(pixels, left, right)
          record_setup if @passes == 1
        end
        leave_pause_out_of_pacing
        return nil if @device.stop? || @passes == @stop_after_passes

        held = @device.held_buttons(@passes)
        masks = @network ? exchange_buttons(held) : @pass_buttons.masks(held)
        @pass_began = @device.now
        @collection_began = LatenessTally.collection_clock
        masks
      end

      # SAVE STATES, which only a device with a person at it asks for (SDL's menu and keys). The game
      # asks at the top of each frame boundary, the one place a state can be taken or put back (the
      # runtime's rg_live_serve_state_request), and these hand the question to the device. Only a device
      # that has asked (#take_state_request gave a request) is handed the other four, so a device
      # that never asks needs none of them.
      #
      # What the device asked to save or load (a WindowMenu::StateRequest), once, or nil.
      def take_state_request = (@device.take_state_request if @device.respond_to?(:take_state_request))

      # The game's state, +text+, to keep in +slot+ (QUICK_SLOT or 1 to 10).
      def state_saved(slot, text) = @device.state_saved(slot, text)

      # The state kept in +slot+, or nil when the slot holds none (the device says so itself).
      def state_to_load(slot) = @device.state_to_load(slot)

      # The state in +slot+ was put back.
      def state_loaded(slot) = @device.state_loaded(slot)

      # The game cannot use the state, in these words.
      def state_refused(words) = @device.state_refused(words)

      private

      # THE GAME'S SAVE MEMORY, KEPT IN A FILE between runs when the device has one (SDL, a window with a
      # folder for the game: #save_file) and the game has save memory. The file's bytes go in as the game
      # starts, so a file that is not the size of the save stops the play before it begins, saying so. A
      # change is written soon after (Ruby's rg_save_file_is_due?) and the rest as the play ends.
      def read_save_file
        @save_file = (@device.save_file if @device.respond_to?(:save_file))
        @save_file = nil if @game.save_size.zero?
        return unless @save_file

        bytes = @save_file.read(@game.save_size)
        @game.load_save(bytes) if bytes
      end

      def write_save_file
        @save_file.write(@game.save_bytes)
        @game.save_file_written
      rescue SaveFile::CannotWrite => e
        # Said once; tried again when the file is next due.
        @device.notice(e.message) unless @save_failure_said
        @save_failure_said = true
      end

      def write_save_file_if_unwritten
        write_save_file if @save_file && @game.save_unwritten?
      end

      # Every connected player's buttons for the pass that starts, this machine's +held+ among them.
      def exchange_buttons(held)
        # Every gamepad and key at this machine is its one player in a match, whichever player the
        # window seated it as.
        local_mask = IR::Buttons.masks(held).reduce(0, :|)
        masks = @network.exchange(pass: @passes, local_mask: local_mask, game: @game)
        announce_new_events
        masks
      end

      # THE GAME'S OWN WORK OVER THE PASS JUST ENDED, from the buttons handed to it to now, and the
      # time Ruby spent collecting garbage inside it, into the play's Lateness. The pass the game
      # sets itself up in is left out, as is one played in fast forward: both are meant to run long.
      def record_pass_time(speed)
        return unless @pass_began
        return @lateness.record_fast_forward if speed > 1

        @lateness.record(work_seconds: @device.now - @pass_began,
                         collection_seconds: LatenessTally.seconds_collecting_since(@collection_began))
      end

      # ONE FULL COLLECTION, ONCE THE GAME HAS SET ITSELF UP. Ruby keeps young objects apart from old
      # ones and mostly looks only at the young; now and then it looks at every object it has, a full
      # collection, and how long that takes grows with everything alive. Building a big game leaves
      # a great many objects (the game's tree, its pictures, the setup's own), and left alone Ruby
      # gets round to a full look at them some way into play, where it stops one pass for many
      # frames. Run here, at the end of the pass the game set itself up in, which is late already,
      # it finds that work done when play starts. Measured on a big port, it took the one long stop
      # out of play; on a small game it costs a few milliseconds once and changes nothing after.
      #
      # It changes when Ruby collects, never what the game does. Ruby's own collecting stays on as
      # it was, so a game that makes garbage every pass never grows without limit. Compacting the
      # heap as well (GC.compact) was measured too, and made a small game collect far more often.
      def collect_garbage_after_setup
        began = LatenessTally.collection_clock
        GC.start(full_mark: true, immediate_sweep: true)
        @lateness.record_setup_collection(LatenessTally.seconds_collecting_since(began))
      end

      # A game for one player is built without what a match needs (IR::Program#several_players?), so it plays in none.
      def refuse_match_for_one_player!(program)
        return if program.several_players?

        raise ArgumentError, "This game is for one player, so it cannot play in a match. To fix this, say on " \
                             "VBlank.game how many players it takes, for example players: 1..2."
      end

      # A device with nobody at the controls (a bot) reads the game it plays: it is told which game, and how
      # the match is set up, before the first pass.
      def watch_game_for_device
        return unless @network && @device.respond_to?(:watch)

        @device.watch(@game, player: @network.player, players: @network.settings.players, input_delay: @network.input_delay)
      end

      # What happened in the match since the device was last told (a player left), said in a line a
      # person reads: the device shows it where it can (the window's title), and keeps it where it cannot.
      def announce_new_events
        events = @network.events
        events.drop(@events_announced).each { |event| @device.notice(event.words) }
        @events_announced = events.length
      end

      # A GAME THAT STOPPED ITSELF — it halted, or came to its end — leaves its last picture on the
      # screen, as the console does: the picture is shown a frame at a time, the window still read
      # and pause and its menu still working, until the device asks to stop. A play told how many
      # passes to go on for counts each picture shown here as one of them, so it still ends. The
      # game runs no pass, so none of this is in the play's rate.
      def keep_showing(pixels)
        shown = 0
        loop do
          @device.show(pixels, @game.width, @game.height)
          shown += 1
          @device.hold_while_paused
          break if @device.stop? || (@stop_after_passes && @passes + shown >= @stop_after_passes)

          @device.wait_until(@device.now + @frame_seconds)
        end
      end

      # The first pass has been played at the console's speed: it and the frames it took are the setup.
      def record_setup
        @setup = Setup.new(passes: 1, frames: @frames, seconds: @frame_began - @started)
      end

      def play_at_console_speed(pixels, left, right)
        wait_for_frame_end unless @paced_by_speaker
        @passes += 1
        @device.show(pixels, @game.width, @game.height)
        @device.play_sound(left, @game.sound_rate, right)
        if @paced_by_speaker
          wait_for_speaker
        else
          @paced_by_speaker = !@uncapped && !@device.sound_waiting.nil?
        end
      end

      # FAST FORWARD plays up to +speed+ of the game's frames for each picture shown, in the time
      # of one: a machine that can goes that many times the console's speed and no faster. A
      # picture is shown, and the next frame's time waited for, once that many passes
      # have been played or the frame's time is up, so a machine that cannot go that fast still
      # shows a picture a frame. The frames counted are the frames of time that went by, as on
      # the beat, and not the game's, which are its passes. The game's sound is not handed to the
      # speaker: it would be several times what the speaker can play, and heard later and later.
      # What the speaker holds as fast forward begins is a few frames, and plays out.
      def play_fast_forward(pixels, speed)
        @fast_frame_began ||= @frame_began
        @passes += 1
        @fast_forward_passes += 1
        if @fast_forward_passes >= speed || @device.now - @fast_frame_began >= @frame_seconds
          @device.show(pixels, @game.width, @game.height)
          frames = [((@device.now - @fast_frame_began) / @frame_seconds).ceil, 1].max
          @frames += frames
          @fast_frame_began += frames * @frame_seconds
          @fast_forward_passes = 0
          @device.wait_until(@fast_frame_began)
        else
          @device.wait_until(@device.now)
        end
        @frame_began = @fast_frame_began
      end

      # Back to the console's speed from fast forward. The speaker has had nothing for as long as
      # fast forward was held, so it has little or nothing waiting, as after a pause.
      def end_fast_forward = restart_pacing

      # The next frame begins now, and the pass that ends it is played on the clock, as the first
      # pass of all is, until the speaker has the game's sound again. Fast forward, if it is
      # still held, starts its frames afresh too.
      def restart_pacing
        @frame_began = @device.now
        @paced_by_speaker = false
        @fast_frame_began = nil
        @fast_forward_passes = 0
      end

      # A PAUSE holds the game between two passes, for as long as the device holds it. The time
      # held is not the game's: the next frame begins when the pause ends, so the beat does not
      # count it as frames missed, and the play's rate leaves it out. The device empties its
      # speaker as the pause begins, so the game carries on with nothing queued from before.
      def leave_pause_out_of_pacing
        held_from = @device.now
        return unless @device.hold_while_paused

        @seconds_paused += @device.now - held_from
        restart_pacing
      end

      # WITH A SPEAKER, THE SPEAKER PACES THE PLAY, as an emulator's sound sync does. Its own clock
      # plays a second of samples in a second, so once a frame's sound is handed to it the next pass
      # waits only while more than SPEAKER_AHEAD_FRAMES of sound are waiting. A pass is a frame:
      # no frame is skipped, and a late pass, or a wait that wakes late, only uses up some of what is
      # waiting.
      def wait_for_speaker
        @frames += 1
        over = (@device.sound_waiting || 0) - (SPEAKER_AHEAD_FRAMES * @frame_seconds)
        @device.wait_until(@device.now + (over.positive? ? over : 0))
        @frame_began = @device.now
      end

      # Moves the beat past the frames the pass just ended took, and waits for it. Uncapped, the
      # pass took one frame and the next starts now.
      def wait_for_frame_end
        if @uncapped
          @frames += 1
          @frame_began = @device.now
        else
          frames = [((@device.now - @frame_began) / @frame_seconds).ceil, 1].max
          @frame_began += frames * @frame_seconds
          @frames += frames
        end
        @device.wait_until(@frame_began)
      end
    end
  end
end
