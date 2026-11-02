# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHERE A SEGA GENESIS CARTRIDGE'S FRAMES WENT, measured by running it.
    #
    # A pass of the game loop is meant to fit in one frame. One that does not shows the same
    # picture twice and the game runs at half speed for that pass, with nothing on screen to say
    # why. The runtime counts the frames each pass took as its wait ends, so those numbers are the
    # ones the game really played at, and nothing is added to the cartridge to get them.
    #
    # Which routines took the time comes from the emulator (TimeByRoutine): Genesis Plus GX adds up
    # the cycles each instruction took. A Genesis build keeps no record of what each routine is to
    # the author, so the game's routines are named by the label before them too.
    class GenesisProfiler
      SETTLE = 20
      FRAMES = 60

      # The console draws this many frames a second.
      FRAME_RATE = 59.9

      # The emulator's cycles in one line of the picture.
      LINE_CYCLES = 3420

      # A game that has not reached its passes by now has stopped trying to.
      MOST_FRAMES_TO_SETTLE = 3600

      # The labels of what runs while the game has nothing to do but wait for the screen.
      WAITS = /\Art_(sleep_until_vblank|stopped)/

      # The labels of the game's own code, which is all the build says of whose it is.
      GAME_LABELS = /\A(routine |main\b)/

      # What a run came to: the +passes+ measured, the +frames+ they took, the frame rate that is,
      # the frames the slowest took and which pass of the game it was, and how many passes took
      # each number of frames; and TimeByRoutine::Report's four.
      Result = Data.define(:passes, :frames, :fps, :slowest_frames, :slowest_pass, :passes_by_frames,
                           :idle_share, :fewest_lines_spare, :game, :runtime) do
        def to_h = super.merge(game: game.map(&:to_h), runtime: runtime.map(&:to_h))
      end

      # +rom+ is a GenesisROM built with its record (Genesis::Places). +keys+ are held from power-on,
      # and +settle+ passes run before the +frames+ passes measured.
      def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
        built = rom.built or raise ArgumentError, "this cartridge carries no record of its build to play it from"
        run = IR::Backends::Genesis::HeadlessRun.new.hold(*keys).run(built.source_program, frames: settle + frames + 1)
        took = ((settle + 1)..(settle + frames)).to_h { |pass| [pass, run.frames_took(pass)] }
        Emulator.load_genesis!
        result_of(took, time_of(rom, frames: frames, settle: settle, keys: keys))
      end

      # The time of the +frames+ after +settle+ passes.
      def self.time_of(rom, frames:, settle:, keys:)
        places = rom.built
        Emulator.with_cartridge(rom, file_name: "game.md") do |core|
          core.set_buttons(keys)
          core.run_frame while core.frames < MOST_FRAMES_TO_SETTLE && core.wram_read32(places.waits_counted_at) <= settle
          core.take_processor_time # the first ask starts the count
          by_frame = Array.new(frames) do
            core.run_frame
            core.take_processor_time
          end
          TimeByRoutine.new(code: places.code, waits: WAITS, line: LINE_CYCLES, game_labels: GAME_LABELS).report(by_frame)
        end
      end

      # What the frames each pass took (+took+, by pass) and the +time+ come to.
      def self.result_of(took, time)
        frames = took.values.sum
        counted, slowest_frames = took.max_by { |pass, count| [count, -pass] }
        # The runtime counts the wait before the game's first pass as a pass of its own.
        Result.new(passes: took.size, frames: frames, fps: FRAME_RATE * took.size / frames,
                   slowest_frames: slowest_frames, slowest_pass: counted - 1, passes_by_frames: took.values.tally.sort.to_h,
                   **time.to_h)
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "Genesis: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second), waiting #{format('%.1f%%', result.idle_share * 100)} of " \
                 "the time. The tightest frame had #{result.fewest_lines_spare} lines to spare."
        out.puts "The slowest pass took #{result.slowest_frames} frames: pass #{result.slowest_pass}." if result.slowest_frames > 1
        result.passes_by_frames.each do |frames, passes|
          out.puts format("  %4d of them took %d %s", passes, frames, frames == 1 ? "frame" : "frames")
        end
        TimeByRoutine.render(result, out: out)
      end
    end
  end
end
