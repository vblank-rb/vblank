# frozen_string_literal: true

module VBlank
  module Diagnostics
    # HOW MANY FRAMES A SEGA GENESIS CARTRIDGE'S PASSES TOOK, read from the running cartridge.
    #
    # A pass of the game loop is meant to fit in one frame. One that does not shows the same
    # picture twice and the game runs at half speed for that pass, with nothing on screen to say
    # why. The runtime counts the frames each pass took as its wait ends, so the numbers are the
    # ones the game really played at, and nothing is added to the cartridge to get them.
    #
    # It does not say which routines took the time: Genesis Plus GX is not asked for that yet, so this is
    # the first half of what the Advance's and the Color's profilers say.
    class GenesisProfiler
      SETTLE = 20
      FRAMES = 60

      # The console draws this many frames a second.
      FRAME_RATE = 59.9

      # What a run came to: the +passes+ measured, the +frames+ they took, the frame rate that is,
      # the frames the slowest took and which pass of the game it was, and how many passes took
      # each number of frames.
      Result = Data.define(:passes, :frames, :fps, :slowest_frames, :slowest_pass, :passes_by_frames)

      # +rom+ is a GenesisROM built with its record (Genesis::Places). +keys+ are held from power-on,
      # and +settle+ passes run before the +frames+ passes measured.
      def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
        built = rom.built or raise ArgumentError, "this cartridge carries no record of its build to play it from"
        run = IR::Backends::Genesis::HeadlessRun.new.hold(*keys).run(built.source_program, frames: settle + frames + 1)
        result_of(((settle + 1)..(settle + frames)).to_h { |pass| [pass, run.frames_took(pass)] })
      end

      # What the frames each pass took (+took+, by pass) come to.
      def self.result_of(took)
        frames = took.values.sum
        counted, slowest_frames = took.max_by { |pass, count| [count, -pass] }
        # The runtime counts the wait before the game's first pass as a pass of its own.
        Result.new(passes: took.size, frames: frames, fps: FRAME_RATE * took.size / frames,
                   slowest_frames: slowest_frames, slowest_pass: counted - 1,
                   passes_by_frames: took.values.tally.sort.to_h)
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "Genesis: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second)."
        out.puts "The slowest pass took #{result.slowest_frames} frames: pass #{result.slowest_pass}." if result.slowest_frames > 1
        result.passes_by_frames.each do |frames, passes|
          out.puts format("  %4d of them took %d %s", passes, frames, frames == 1 ? "frame" : "frames")
        end
      end
    end
  end
end
