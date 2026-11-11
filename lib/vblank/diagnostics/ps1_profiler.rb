# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHERE A PLAYSTATION PROGRAM'S FRAMES WENT, measured by running it.
    #
    # A pass of the game loop is meant to fit in one frame. One that does not shows the same picture
    # twice and the game runs at half speed for that pass, with nothing on screen to show why. The
    # runtime counts the frames each pass took as its wait ends (Runtime::Frame::STEPS), so those numbers
    # are the ones the game really played at, and nothing is added to the program to get them.
    #
    # Which routines took the processor's time comes from the emulator (TimeByRoutine): ruby-ps1-
    # emulator's patch to Beetle PSX adds up the cycles from each instruction's fetch to the next by the
    # address it was at, so a stall waiting on memory or on the graphics chip lands on the instruction
    # that waited. The build records where each of the game's routines went (PS1::GameRoutine); the
    # runtime's code is named by the label before it.
    #
    # THE GRAPHICS CHIP DRAWS WHILE THE PROCESSOR GOES ON. The runtime hands it a command and carries on
    # until the chip's queue is full, and only then waits (rt_gp0_word_wait and the waits beside it, in
    # the runtime's list). So the chip's work shows in two places: its own share, the cycles it spent
    # drawing out of all the time measured (+gpu_share+, the emulator's count of the time the chip was
    # paying back what each command cost it), and the processor's waits on it, which are the part of
    # that drawing the processor could not work beside.
    class PS1Profiler
      SETTLE = 20
      FRAMES = 60

      # The processor's clock, and the cycles of it one frame takes (Console::Description).
      CYCLES_A_SECOND = Console::PLAYSTATION.cycles_a_second
      CYCLES_A_FRAME = Console::PLAYSTATION.cycles_a_frame

      # The console draws this many frames a second.
      FRAME_RATE = CYCLES_A_SECOND.fdiv(CYCLES_A_FRAME)

      # An NTSC frame is 263 lines, so this many of the processor's cycles are one line of the picture.
      FRAME_LINES = 263
      LINE_CYCLES = CYCLES_A_FRAME / FRAME_LINES

      # A game that has not reached its passes by now has stopped trying to.
      MOST_FRAMES_TO_SETTLE = 3600

      # The labels of what runs while the game has nothing to do but wait for the screen.
      WAITS = /\Art_(sleep_until_vblank|stopped)/

      FILE_NAME = "game.exe"

      # The buttons a game names, as the PlayStation's core names the pad's.
      PAD_BUTTONS = IR::Backends::PS1::HeadlessRun::PAD_BUTTONS

      # What a run came to: the +passes+ measured, the +frames+ they took, the frame rate that is, the
      # frames the slowest took and which pass of the game it was, and how many passes took each number
      # of frames; TimeByRoutine::Report's four; +gpu_share+, the graphics chip's time drawing out of all
      # the time measured, 0 to 1; and +measured_frames+, the frames the time was read over, counted
      # from 1 at power-on as a tape counts them.
      #
      # A pass waits for the NEXT blank, so one that ends a line after a blank began while it ran waits a
      # whole frame for the one after. +lines_past_blank+ gives, by the frames each took, how many lines
      # past that blank each pass of more than a frame ran: the lines sooner it had to end to take a
      # frame fewer, in the order they ran. +late_passes+ is the same lines for the passes that went to
      # sleep inside the blank itself, a few lines late, as the Advance's profile has it
      # (Profiler::Result#late_passes): a game whose rate halves for a few lines of work says why there.
      # +slowest_pass_frames+ is the frames from power-on the slowest pass ran over, counted as a tape
      # counts them, so a tape reads them one by one.
      Result = Data.define(:passes, :frames, :fps, :slowest_frames, :slowest_pass, :slowest_pass_frames, :passes_by_frames,
                           :late_passes, :lines_past_blank, :idle_share, :fewest_lines_spare, :game, :runtime,
                           :gpu_share, :measured_frames) do
        def to_h = super.merge(game: game.map(&:to_h), runtime: runtime.map(&:to_h),
                               measured_frames: [measured_frames.begin, measured_frames.end],
                               slowest_pass_frames: [slowest_pass_frames.begin, slowest_pass_frames.end])
      end

      # +rom+ is a PS1EXE built with its record (PS1::Places). +keys+ are held from power-on, and
      # +settle+ passes run before the +frames+ passes measured.
      def self.run(rom, frames: FRAMES, settle: SETTLE, keys: [])
        built = rom.built or raise ArgumentError, "this program carries no record of its build to play it from"
        Emulator.load_ps1!
        headless = IR::Backends::PS1::HeadlessRun.new.hold(*keys).run(built.source_program, frames: settle + frames + 1)
        took = ((settle + 1)..(settle + frames)).to_h { |pass| [pass, headless.frames_took(pass)] }
        result_of(took, lines_past_blank(headless, took), *time_of(rom, frames: frames, settle: settle, keys: keys))
      end

      # The lines of the frame below the picture, the blank: the lines a frame has past those shown.
      BLANK_LINES = FRAME_LINES - Console::PLAYSTATION.screen_size.last

      # For each pass of +took+ that took more than a frame, by its number, how many lines sooner it
      # had to go to sleep to make the blank that began while it ran: the lines the screen had drawn
      # since that blank began, counting the one it was on.
      def self.lines_past_blank(headless, took)
        took.filter_map { |pass, frames| [pass, headless.lines_after_blank(pass) + 1] if frames > 1 }.to_h
      end

      # +tape+ played on +rom+ from power-on, and each of +frames+ read by itself (TapeProfile).
      # +routines+ is how many of a frame's routines each reading keeps.
      def self.run_tape(rom, tape:, frames:, routines: TapeProfile::ROUTINES_KEPT)
        places = rom.built or raise ArgumentError, "this program carries no record of its build to play it from"
        Emulator.load_ps1!
        meter = Meter.new(time: time_by_routine(places), file_name: FILE_NAME,
                          shown_at: places.runtime.fetch(IR::Backends::PS1::Runtime::Frame::SHOWN),
                          passes_at: places.waits_counted_at, routines: routines)
        TapeProfile.play(rom, tape: tape, frames: frames, meter: meter)
      end

      # A tape's frames measured on the PlayStation's core, which reads main RAM rather than a work
      # memory and takes the pad's own names for its buttons.
      class Meter < TapeProfile::ProcessorTimeMeter
        def hold(core, buttons)
          IR::Buttons.by_controller(buttons).each_with_index do |held, port|
            core.set_buttons(pad_buttons(held), port: port) if port.zero? || !held.empty?
          end
        end

        def words(core) = [core.ram_read32(@passes_at), core.ram_read32(@shown_at)]

        private

        def pad_buttons(buttons) = buttons.filter_map { |button| PAD_BUTTONS[button.to_sym] }
      end

      # The time of the +frames+ after +settle+ passes, the graphics chip's share of it, and which frames
      # those were.
      def self.time_of(rom, frames:, settle:, keys:)
        places = rom.built
        Emulator.with_cartridge(rom, file_name: FILE_NAME) do |core|
          core.set_buttons(keys.filter_map { |button| PAD_BUTTONS[button.to_sym] })
          core.run_frame while core.frames < MOST_FRAMES_TO_SETTLE && core.ram_read32(places.waits_counted_at) <= settle
          first = core.frames + 1
          core.take_processor_time # the first ask starts the count
          drawn_before = core.gpu_busy_cycles
          by_frame = Array.new(frames) do
            core.run_frame
            core.take_processor_time
          end
          total = by_frame.sum { |spent| spent.values.sum }
          gpu_share = total.zero? ? 0.0 : (core.gpu_busy_cycles - drawn_before).fdiv(total)
          [time_by_routine(places).report(by_frame), gpu_share, first..(first + frames - 1)]
        end
      end

      # Each address the emulator counts time at, to the routine it is in.
      def self.time_by_routine(places)
        routine_at = lambda do |address|
          places.routines.find { |each| each.addresses.cover?(address) }&.routine
        end
        TimeByRoutine.new(code: places.code, waits: WAITS, line: LINE_CYCLES, routine_at: routine_at)
      end

      # What the frames each pass took (+took+, by pass), the lines each pass of more than a frame ran past
      # the blank (+past+, by pass), the +time+ and the +gpu_share+ come to, over +measured_frames+.
      def self.result_of(took, past, time, gpu_share, measured_frames)
        frames = took.values.sum
        counted, slowest_frames = took.max_by { |pass, count| [count, -pass] }
        by_frames = past.group_by { |pass, _| took.fetch(pass) }.sort.to_h
        # The runtime counts the wait before the game's first pass as a pass of its own.
        Result.new(passes: took.size, frames: frames, fps: FRAME_RATE * took.size / frames,
                   slowest_frames: slowest_frames, slowest_pass: counted - 1,
                   slowest_pass_frames: TapeProfile.frames_of_pass(took, counted, measured_frames.begin),
                   passes_by_frames: took.values.tally.sort.to_h,
                   late_passes: past.values.select { |lines| lines <= BLANK_LINES },
                   lines_past_blank: by_frames.transform_values { |passes| passes.map(&:last) },
                   gpu_share: gpu_share, measured_frames: measured_frames, **time.to_h)
      end

      # The report, for a person.
      def self.render(result, out: $stdout)
        out.puts "PlayStation: #{result.passes} passes of the game loop in #{result.frames} frames " \
                 "(#{format('%.1f', result.fps)} a second), waiting #{format('%.1f%%', result.idle_share * 100)} of " \
                 "the time. The tightest frame had #{result.fewest_lines_spare} lines to spare."
        out.puts "The graphics chip was drawing for #{format('%.1f%%', result.gpu_share * 100)} of the time, beside " \
                 "the processor. Where the processor waited for it, the wait is in the runtime's lines below."
        out.puts "The time was measured over frames #{result.measured_frames.begin} to #{result.measured_frames.end} " \
                 "from power-on. A tape's frames are counted the same way: `rom.profile(tape:, frames:)` reads each one."
        out.puts TapeProfile.slowest_pass_line(result) if result.slowest_frames > 1
        result.passes_by_frames.each do |frames, passes|
          out.puts format("  %4d of them took %d %s", passes, frames, frames == 1 ? "frame" : "frames")
        end
        out.puts "  #{Profiler.late_pass_message(result.late_passes)}" unless result.late_passes.empty?
        result.lines_past_blank.each { |frames, lines| print_lines_past_blank(frames, lines, out) }
        TimeByRoutine.render(result, out: out)
      end

      # Said only of passes that took more than a frame: each waited for the NEXT break between pictures,
      # so the lines it ran past the one that began while it ran are what cost it a whole frame.
      def self.print_lines_past_blank(frames, lines, out)
        passes = lines.one? ? "1 pass" : "#{lines.size} passes"
        out.puts "  #{passes} of #{frames} frames ran #{Profiler.lines_phrase(lines)} past the last break between " \
                 "pictures. If a pass ends that many lines sooner, it takes one frame fewer."
      end
    end
  end
end
