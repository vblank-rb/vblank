# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHERE A SUPER NINTENDO CARTRIDGE'S FRAMES WENT, measured by running it.
    #
    # A pass of the game loop is meant to fit in one frame. One that does not shows the same
    # picture twice and the game runs at half speed for that pass, with nothing on screen to say
    # why. The runtime counts the frames each pass took as its wait ends, so those numbers are the
    # ones the game really played at, and nothing is added to the cartridge to get them.
    #
    # Which routines took the time comes from the emulator (TimeByRoutine): bsnes adds up the clocks
    # each instruction took, DMA included. The game waits for the screen by sending its sound queue,
    # so WAITS are the runtime's routines that are only waiting, or doing what can wait.
    class SNESProfiler
      SETTLE = 20
      FRAMES = 60

      # The console draws this many frames a second.
      FRAME_RATE = 60.1

      # Master clocks in one line of the picture.
      LINE_CLOCKS = 1364

      # A game that has not reached its passes by now has stopped trying to.
      MOST_FRAMES_TO_SETTLE = 3600

      # The labels of what runs while the game has nothing to do but wait for the screen.
      WAITS = /\Art_(sleep_until_vblank|sleep_unless_in_blank|stopped|sound_send_queued|sound_move_ahead|sound_front_counted|
                     sound_entry_into_writes|recordings_voice_|recordings_loudness)/x

      # What a run came to: the +passes+ measured, the +frames+ they took, the frame rate that is,
      # the frames the slowest took and which pass of the game it was, and how many passes took
      # each number of frames; TimeByRoutine::Report's four; and +measured_frames+, the frames the
      # time was read over, counted from 1 at power-on as a tape counts them.
      Result = Data.define(:passes, :frames, :fps, :slowest_frames, :slowest_pass, :passes_by_frames,
                           :idle_share, :fewest_lines_spare, :game, :runtime, :measured_frames) do
        def to_h = super.merge(game: game.map(&:to_h), runtime: runtime.map(&:to_h),
                               measured_frames: [measured_frames.begin, measured_frames.end])
      end

      # +rom+ is an SNESROM built with its record (SNES::Places). +keys+ are held from power-on,
      # and +settle+ passes run before the +frames+ passes measured.
      def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
        built = rom.built or raise ArgumentError, "this cartridge carries no record of its build to play it from"
        run = IR::Backends::SNES::HeadlessRun.new.hold(*keys).run(built.source_program, frames: settle + frames + 1)
        took = ((settle + 1)..(settle + frames)).to_h { |pass| [pass, run.frames_took(pass)] }
        Emulator.load_snes!
        result_of(took, *time_of(rom, frames: frames, settle: settle, keys: keys))
      end

      # +tape+ played on +rom+ from power-on, and each of +frames+ read by itself (TapeProfile).
      def self.run_tape(rom, tape:, frames:)
        places = rom.built or raise ArgumentError, "this cartridge carries no record of its build to play it from"
        Emulator.load_snes!
        TapeProfile.run(rom, tape: tape, frames: frames, time: time_by_routine(places), file_name: FILE_NAME,
                             shown_at: places.runtime.fetch(IR::Backends::SNES::Runtime::Frame::SHOWN),
                             passes_at: places.waits_counted_at)
      end

      FILE_NAME = "game.sfc"

      # The time of the +frames+ after +settle+ passes, and which frames those were.
      def self.time_of(rom, frames:, settle:, keys:)
        places = rom.built
        Emulator.with_cartridge(rom, file_name: FILE_NAME) do |core|
          core.set_buttons(keys)
          # Settled by passes, as the frames each took are: sending the recordings across at power-on
          # takes many frames before the game has played one.
          core.run_frame while core.frames < MOST_FRAMES_TO_SETTLE && core.wram_read32(places.waits_counted_at) <= settle
          first = core.frames + 1
          core.take_processor_time # the first ask starts the count
          by_frame = Array.new(frames) do
            core.run_frame
            core.take_processor_time
          end
          [time_by_routine(places).report(by_frame), first..(first + frames - 1)]
        end
      end

      # Each address the emulator counts time at, to the routine it is in.
      def self.time_by_routine(places)
        routine_at = lambda do |address|
          places.routines.find { |each| each.addresses.cover?(address) }&.routine
        end
        TimeByRoutine.new(code: places.code, waits: WAITS, line: LINE_CLOCKS, routine_at: routine_at)
      end

      # What the frames each pass took (+took+, by pass) and the +time+ come to, over +measured_frames+.
      def self.result_of(took, time, measured_frames)
        frames = took.values.sum
        counted, slowest_frames = took.max_by { |pass, count| [count, -pass] }
        # The runtime counts the wait before the game's first pass as a pass of its own.
        Result.new(passes: took.size, frames: frames, fps: FRAME_RATE * took.size / frames,
                   slowest_frames: slowest_frames, slowest_pass: counted - 1, passes_by_frames: took.values.tally.sort.to_h,
                   measured_frames: measured_frames, **time.to_h)
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "Super Nintendo: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second), waiting #{format('%.1f%%', result.idle_share * 100)} of " \
                 "the time. The tightest frame had #{result.fewest_lines_spare} lines to spare."
        out.puts "The time was measured over frames #{result.measured_frames.begin} to #{result.measured_frames.end} " \
                 "from power-on. A tape's frames are counted the same way: `rom.profile(tape:, frames:)` reads each one."
        out.puts "The slowest pass took #{result.slowest_frames} frames: pass #{result.slowest_pass}." if result.slowest_frames > 1
        result.passes_by_frames.each do |frames, passes|
          out.puts format("  %4d of them took %d %s", passes, frames, frames == 1 ? "frame" : "frames")
        end
        TimeByRoutine.render(result, out: out)
      end
    end
  end
end
