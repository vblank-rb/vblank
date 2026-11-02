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
    # Which routines took the time comes from the emulator: bsnes adds up the clocks each
    # instruction took by the address it started at (Core#take_processor_time), DMA included, and
    # every address is in a routine, one of the game's, which the build recorded the addresses of
    # (SNES::Places#routines), or one of the runtime's, found by the runtime's label before it. The
    # game waits for the screen by sending its sound queue, so WAITS are the runtime's routines that
    # are only waiting: time there is time the game had to spare, and the fewest lines of it in any
    # frame is how near that frame came to running over.
    class SNESProfiler
      SETTLE = 20
      FRAMES = 60

      # The console draws this many frames a second.
      FRAME_RATE = 60.1

      # Master clocks in one line of the picture, and in one frame of 262 of them.
      LINE_CLOCKS = 1364

      # A game that has not reached its passes by now has stopped trying to.
      MOST_FRAMES_TO_SETTLE = 3600

      # The labels of what runs while the game has nothing to do but wait for the screen.
      WAITS = /\Art_(sleep_until_vblank|sleep_unless_in_blank|stopped|sound_send_queued|sound_move_ahead|sound_front_counted|
                     sound_entry_into_writes|recordings_voice_|recordings_loudness)/x

      # One routine and its share of every clock measured, from 0 to 1.
      Spent = Data.define(:routine, :share)

      # What a run came to: the +passes+ measured, the +frames+ they took, the frame rate that is,
      # the frames the slowest took and which pass of the game it was, and how many passes took
      # each number of frames; how much of the time went on waiting, the fewest lines any frame
      # had to spare, and the routines by share, the game's and the runtime's apart.
      Result = Data.define(:passes, :frames, :fps, :slowest_frames, :slowest_pass, :passes_by_frames,
                           :idle_share, :fewest_lines_spare, :game, :runtime) do
        def to_h = super.merge(game: game.map(&:to_h), runtime: runtime.map(&:to_h))
      end

      # +rom+ is an SNESROM built with its record (SNES::Places). +keys+ are held from power-on,
      # and +settle+ passes run before the +frames+ passes measured.
      def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
        built = rom.built or raise ArgumentError, "this cartridge carries no record of its build to play it from"
        run = IR::Backends::SNES::HeadlessRun.new.hold(*keys).run(built.source_program, frames: settle + frames + 1)
        took = ((settle + 1)..(settle + frames)).to_h { |pass| [pass, run.frames_took(pass)] }
        Emulator.load_snes!
        new(rom).measure(took, frames: frames, settle: settle, keys: keys)
      end

      def initialize(rom)
        @rom = rom
        @places = rom.built
        @labels = @places.code.map { |label, address| [address, label] }.sort
        @starts = @labels.map(&:first)
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "Super Nintendo: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second), waiting #{percent(result.idle_share)} of the time. " \
                 "The tightest frame had #{result.fewest_lines_spare} lines to spare."
        out.puts "The slowest pass took #{result.slowest_frames} frames: pass #{result.slowest_pass}." if result.slowest_frames > 1
        result.passes_by_frames.each do |frames, passes|
          out.puts format("  %4d of them took %d %s", passes, frames, frames == 1 ? "frame" : "frames")
        end
        { "Your routines" => result.game, "The runtime" => result.runtime }.each do |heading, spent|
          next if spent.empty?

          out.puts "", "#{heading}:"
          spent.first(12).each { |row| out.puts format("  %6s  %s", percent(row.share), row.routine) }
        end
      end

      def self.percent(share) = format("%.1f%%", share * 100)

      # The time of the frames after +settle+, in routines, beside what the frames each pass took
      # (+took+, by pass) come to.
      def measure(took, frames:, settle:, keys:)
        Emulator.with_cartridge(@rom, file_name: "game.sfc") do |core|
          buttons = keys.map(&:to_sym)
          core.set_buttons(buttons)
          # Settled by passes, as the frames each took are: sending the recordings across at power-on
          # takes many frames before the game has played one.
          core.run_frame while core.frames < MOST_FRAMES_TO_SETTLE && core.wram_read32(@places.waits_counted_at) <= settle
          core.take_processor_time # the first ask starts the count
          by_frame = Array.new(frames) do
            core.run_frame
            core.take_processor_time
          end
          result_of(took, by_frame)
        end
      end

      private

      def result_of(took, by_frame)
        frames = took.values.sum
        counted, slowest_frames = took.max_by { |pass, count| [count, -pass] }
        game = Hash.new(0)
        runtime = Hash.new(0)
        by_frame.each do |spent|
          spent.each do |address, clocks|
            routine = routine_at(address)
            routine ? game[routine] += clocks : runtime[runtime_part_at(address)] += clocks
          end
        end
        total = (game.values.sum + runtime.values.sum).to_f
        waiting = runtime.select { |part, _| part.match?(WAITS) }
        # The runtime counts the wait before the game's first pass as a pass of its own.
        Result.new(passes: took.size, frames: frames, fps: FRAME_RATE * took.size / frames,
                   slowest_frames: slowest_frames, slowest_pass: counted - 1,
                   passes_by_frames: took.values.tally.sort.to_h,
                   idle_share: waiting.values.sum / total, fewest_lines_spare: fewest_lines_spare(by_frame),
                   game: by_share(game, total), runtime: by_share(runtime.except(*waiting.keys), total))
      end

      def fewest_lines_spare(by_frame)
        by_frame.map do |spent|
          spent.sum { |address, clocks| !routine_at(address) && runtime_part_at(address).match?(WAITS) ? clocks : 0 } / LINE_CLOCKS
        end.min
      end

      def by_share(clocks_by_routine, total)
        clocks_by_routine.sort_by { |_, clocks| -clocks }.map { |routine, clocks| Spent.new(routine: routine, share: clocks / total) }
      end

      # The name the game knows the routine at +address+ by, or nil for the runtime's.
      def routine_at(address) = @places.routines.find { |each| each.addresses.cover?(address) }&.routine

      # The part of the runtime an instruction at +address+ is in: the runtime's label before it.
      def runtime_part_at(address)
        at = (@starts.bsearch_index { |start| start > address } || @starts.length) - 1
        at.negative? ? "somewhere with no label" : @labels[at][1]
      end
    end
  end
end
