# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHERE EACH FRAME WENT WHILE A TAPE PLAYED, for a console whose emulator counts time by address
    # (TimeByRoutine: the Super Nintendo and the Genesis).
    #
    # `rom.profile` measures a game standing still, or holding the same buttons the whole time, and
    # adds every frame it measured into one report. The frame worth looking at is usually one a
    # player made slow: three enemies on screen, a chain of bombs going off. A tape (Playthroughs::Tape)
    # gets there by the same presses every time, and this plays it from power-on and reads every frame
    # asked for on its own: how many lines it had to spare, and which routines took its time.
    #
    # WHICH WORK HELD THE PICTURE. A frame is a picture shown. The game's pass ends; the runtime then
    # works out what the pass changed in the picture, waits for the blank, and copies it to the
    # console there, a blank at a time when it is more than one blank holds. Only then is the new
    # picture up. So a frame that shows no new picture lost it in one of two places, and the fix is
    # different for each:
    #
    #   :pass   the pass had not ended yet: the game's own work ran past the blank. Do less in a pass.
    #   :gap    the pass had ended a frame before, and the work after it was still going on: the gap
    #           between passes ran past the blank. Change less of the picture at once.
    #
    # Both come from two words the runtime keeps (Frame::PASSES, how many passes have ended, which
    # rises the moment a pass's own work is done, and Frame::SHOWN, the pass whose picture is up),
    # read at the end of every frame: a pass that had ended when a frame began and is still not
    # shown when it ends was held by its gap. That holds wherever the emulator's frame begins
    # against the blank.
    #
    # THE EMULATOR RUNS THE PROCESSOR A LITTLE AHEAD OF THE PICTURE when nothing makes it wait, so a
    # frame that starts a long stretch of the game's own work can count some of the next frame's
    # time as well (it then counts more than a frame's worth of time), and the two words can
    # be read a little early. `rom.profile` adds frames up the same way, so the two agree.
    class TapeProfile
      # How many of a frame's routines a reading keeps, the game's and the runtime's each.
      ROUTINES_KEPT = 3

      # One frame: its number, counted from 1 at power-on as a tape counts them; the +buttons+ the
      # tape held on it; the +lines_spare+ the game waited through; how many passes of the game loop
      # ended in it; +picture_held_by+, nil when a new picture went up, else :pass, :gap or
      # :setting_up (the game has not reached its loop yet); and its routines by share of the
      # frame's time, the game's and the runtime's (TimeByRoutine::Spent).
      FrameReading = Data.define(:frame, :buttons, :lines_spare, :passes_ended, :picture_held_by, :game, :runtime) do
        def new_picture? = picture_held_by.nil?
        def to_h = super.merge(game: game.map(&:to_h), runtime: runtime.map(&:to_h))
      end

      # The +readings+ of the frames asked for, in order.
      Result = Data.define(:readings) do
        # The reading of frame +number+, or nil for a frame that was not measured.
        def frame(number) = readings.find { |reading| reading.frame == number }

        # The frames whose picture stood still.
        def held = readings.reject(&:new_picture?)

        def to_h = { frames: readings.map(&:to_h) }
      end

      # What `rom.profile(tape:, frames:)` does on a console whose +profiler+ answers run_tape: the
      # tape and the frames checked, played, and reported for a person or as JSON.
      def self.profile(rom, profiler, tape:, frames:, keys:, settle:, format:, out:)
        refuse_unplayable!(tape, frames, keys: keys, settle: settle)
        raise ArgumentError, "unknown profile format #{format.inspect} (use :human or :json)" unless %i[human json].include?(format)

        result = profiler.run_tape(rom, tape: tape, frames: frames)
        format == :human ? render(result, out: out) : out.puts(JSON.generate(result.to_h))
        result
      end

      # Plays +tape+ on +rom+ from power-on and reads each of +frames+, a range counted from 1.
      # +time+ is the console's TimeByRoutine, +file_name+ what the cartridge is written as for its
      # emulator, and +shown_at+ and +passes_at+ where its runtime keeps Frame::SHOWN and
      # Frame::PASSES.
      def self.run(rom, tape:, frames:, time:, file_name:, shown_at:, passes_at:)
        held_on = buttons_by_frame(tape, frames.end)
        Emulator.with_cartridge(rom, file_name: file_name) do |core|
          word = ->(address) { core.wram_read32(address) }
          before = [word.call(passes_at), word.call(shown_at)]
          readings = (1..frames.end).filter_map do |number|
            buttons = held_on[number - 1] || []
            hold(core, buttons)
            core.take_processor_time if number == frames.begin # the first ask starts the count
            core.run_frame
            spent = core.take_processor_time if number >= frames.begin
            now = [word.call(passes_at), word.call(shown_at)]
            reading = (read_frame(time, number, buttons, spent, before, now) if spent)
            before = now
            reading
          end
          Result.new(readings: readings)
        end
      end

      # What frame +number+ came to: +spent+ is what the emulator counted in it, and +before+ and +now+
      # the passes ended and the pass shown at its start and at its end.
      def self.read_frame(time, number, buttons, spent, before, now)
        report = time.report([spent])
        FrameReading.new(frame: number, buttons: buttons, lines_spare: report.fewest_lines_spare,
                         passes_ended: now.first - before.first, picture_held_by: picture_held_by(before, now),
                         game: report.game.first(ROUTINES_KEPT), runtime: report.runtime.first(ROUTINES_KEPT))
      end

      # nil when a new picture went up in the frame, or when the game has stopped and its last
      # picture is up (Frame::END_SHOWN, all ones); else which work held it (see the top).
      def self.picture_held_by(before, now)
        passes_before, shown_before = before
        shown = now.last
        return nil if shown != shown_before || shown == 0xFFFF_FFFF
        return :setting_up if passes_before.zero?

        passes_before > shown ? :gap : :pass
      end

      def self.hold(core, buttons)
        first, second = IR::Buttons.by_controller(buttons)
        core.set_buttons(first)
        core.set_buttons(second, port: 1) unless second.empty?
      end

      # The buttons the tape holds on each frame up to +last+, from frame 1; past its end, none.
      def self.buttons_by_frame(tape, last)
        tape.presses_within(1..last).flat_map { |stretch| Array.new(stretch.frames.size, stretch.buttons) }
      end

      # THE TAPE AND THE FRAMES, checked before the console is switched on. +keys+ and +settle+ are
      # what else the profile was given: a tape says the buttons and where to start.
      def self.refuse_unplayable!(tape, frames, keys:, settle:)
        unless tape.is_a?(Playthroughs::Tape)
          raise ArgumentError, "tape: must be a tape. To get one, take `played.tape` from a playthrough, or read a " \
                               "file with `VBlank::Playthroughs::Tape.read(path)`."
        end
        if tape.in_passes
          raise ArgumentError, "This tape counts passes. A profile plays a tape a frame at a time. To fix this, give " \
                               "a tape of frames: `tape.in_frames_on(cartridge)`."
        end
        if tape.recorded_from_save? || tape.recorded_after_lead_in?
          raise ArgumentError, "This tape starts from #{tape.starts_from}. A profile plays a tape from power-on, so " \
                               "it would play another game. To fix this, record the tape from power-on."
        end
        unless frames.is_a?(Range) && frames.begin.is_a?(Integer) && frames.end.is_a?(Integer) &&
               frames.begin >= 1 && !frames.exclude_end? && frames.end >= frames.begin
          raise ArgumentError, "With a tape, frames: must be a range of frames counted from 1, such as 2070..2080. " \
                               "It was #{frames.inspect}."
        end
        unless Array(keys).empty?
          raise ArgumentError, "A profile with a tape takes its buttons from the tape. To fix this, remove keys:, " \
                               "or put the buttons on the tape."
        end
        return if settle.nil?

        raise ArgumentError, "A profile with a tape plays from power-on and measures the frames you name. To fix " \
                             "this, remove settle:, and name the frames with frames:."
      end

      # Only a console whose profile reads each frame by itself can play a tape.
      def self.refuse_tape!(tape, console)
        return if tape.nil?

        raise ArgumentError, "A #{console} profile cannot play a tape yet. A Super Nintendo or a Genesis profile can. " \
                             "To fix this, remove tape:, and hold buttons with keys:."
      end

      # The readings, for a person: a line for each frame, and under it its busiest routines.
      def self.render(result, out: $stdout)
        held = result.held
        first = result.readings.first.frame
        last = result.readings.last.frame
        out.puts "Frames #{first} to #{last} of the tape: #{held.size} of #{result.readings.size} showed no new picture."
        result.readings.each { |reading| render_frame(reading, out) }
      end

      def self.render_frame(reading, out)
        holding = reading.buttons.empty? ? "nothing held" : "holding #{reading.buttons.map(&:to_s).join(' + ').upcase}"
        out.puts "", "Frame #{reading.frame} (#{holding}): #{reading.lines_spare} lines to spare. #{picture_words(reading)}"
        { "yours" => reading.game, "runtime" => reading.runtime }.each do |whose, spent|
          next if spent.empty?

          out.puts "  #{whose}: #{spent.map { |row| format('%.1f%% %s', row.share * 100, row.routine) }.join(', ')}"
        end
      end

      def self.picture_words(reading)
        case reading.picture_held_by
        when nil then "A new picture went up."
        when :pass then "The picture stood still: the pass was still running at the blank. Do less in one pass."
        when :gap then "The picture stood still: the pass had ended, but the work after it, putting its picture " \
                       "on the screen, ran past the blank. Change less of the picture at once."
        when :setting_up then "The game was still setting up, before its game loop."
        end
      end
    end
  end
end
