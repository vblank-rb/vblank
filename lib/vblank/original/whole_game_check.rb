# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Original
    # The whole game, played by a port's shell and by its all-in-one build, as C. Live::ShellCheck
    # holds the shell's own workings on a short stretch of play, played as Ruby, on every commit.
    # This plays a tape the port keeps from power-on to its end, however long, and holds every
    # picture and every sample of sound of the shell's game to the all-in-one build's: a check run
    # on demand (ShellCheckTasks' `rake shell:whole_game`), never on every commit.
    #
    # 1. builds the shell with every copy hidden (Shell.build), and the all-in-one build;
    # 2. plays the shell's unpacking as C (IR::Backends::Native::FinalStateRun), handed the copy this
    #    machine names (Game#copy), and holds the pack it writes to the all-in-one build's byte
    #    for byte;
    # 3. builds the shell's game and the all-in-one build as C, optimised, and plays both on the tape
    #    at once, the shell's game handed that pack, each as fast as the computer goes;
    # 4. compares them pass by pass as they play, and stops at the first pass they differ on.
    #
    # What it does not play is the shell's menu, which is the same small program in every port and
    # the shell check's to hold: the C side of it is the desktop program's, which needs a window.
    # The shell's game is what a player plays once the menu hands over, and the pack it is handed
    # is the one the shell's own unpacking wrote.
    #
    # Both sides play at once, each a program of its own (Native::HeadlessRun) talked to from a
    # thread of its own. Each hands its passes over through a queue that holds PASSES_AHEAD at most,
    # so neither runs far ahead of the comparison and nothing of a long tape is kept once compared.
    #
    # A machine that names no copy stops at step 2 with NotSet, whose words say how to name one. A
    # step that goes wrong raises Failed, saying which and where.
    class WholeGameCheck
      class Failed < StandardError; end

      # How many passes a side may play ahead of the comparison: enough that neither waits on the
      # other's every pass, few enough that the pictures held stay small.
      PASSES_AHEAD = 60

      # One pass as a side played it: its +number+ (0 for the game setting itself up, then 1 for the
      # first pass of its loop), its +picture+ as shown, every pixel row by row, and the +sound+ it
      # made, the left and right speakers' samples by turns.
      Pass = Data.define(:number, :picture, :sound)

      # A side whose play came to its end, after +passes+ passes.
      Ended = Data.define(:passes)

      # One of the two programs played: +exe+, the program built as C, +program+, what it was built
      # from, and +start_file+, the bytes it is handed as it starts (nil for none).
      Side = Data.define(:exe, :program, :start_file)

      # A game built as C already, played as Native::HeadlessRun plays one it builds itself.
      class CompiledRun < IR::Backends::Native::HeadlessRun
        def initialize(exe)
          super()
          @exe = exe
        end

        private

        def headless_program(_program) = @exe
      end
      private_constant :CompiledRun

      # +game+ is the port (a Cartridge::Game), checked for each of +consoles+, every console it
      # names unless set. +tape+ is a Playthroughs::Tape of frames from power-on, played whole. Each
      # step is named to +say+ as it starts.
      def initialize(game, tape:, consoles: game.consoles, say: ->(line) { puts line })
        if tape.recorded_from_save? || tape.recorded_after_lead_in?
          raise ArgumentError, "The whole-game check was given a tape that starts from #{tape.starts_from}. The check " \
                               "starts the game from power-on. Give a tape recorded from power-on."
        end

        @game = game
        @consoles = consoles
        @tape = tape
        @say = say
      end

      # Runs every step for each console. Raises Failed for a step that went wrong, or NotSet when
      # this machine names no copy.
      def run
        @consoles.each { |console| run_for(console) }
        @say.call("The shell of #{@game.title} plays the whole tape as its all-in-one build does")
      end

      private

      def run_for(console)
        @say.call("Building #{@game.title} for #{console} as a shell, with no copy in reach")
        shell = Shell.build(@game, console: console, err: nil)
        copy = shell.original.copy
        @say.call("Building #{@game.title} for #{console} all-in-one")
        whole = @game.checked_program(err: nil, console: console)
        made = @game.data_pack_file(console: console) or raise Failed, "#{@game.title} has no data_pack, so it has no shell to check."

        @say.call("Compiling both as C, and unpacking #{copy.path} with the shell's unpacking as C")
        compiling = [shell.game, whole].map { |program| compile(program) }
        begin
          pack = unpacked_as_c(shell, copy)
          refuse_different_packs!(pack, made)
          shell_exe, whole_exe = compiling.map(&:value)
        ensure
          # A check stopped early still waits for its compiles, so no zig is left building behind
          # it. Killing the threads would not stop zig: Open3 waits for its process however the
          # thread ends. A compile is the length of one build, short beside the play.
          compiling.each { |thread| wait_for_compile(thread) }
        end

        @say.call("Playing the tape's #{@tape.frames} passes on both, as C")
        compare_plays(Side.new(exe: whole_exe, program: whole, start_file: nil),
                      Side.new(exe: shell_exe, program: shell.game, start_file: pack), shell.game.described_console.screen_width)
      end

      # A thread compiling +program+ as C, optimised, whose value is the program's path. zig runs as
      # a process of its own, so the two compiles go on at once.
      def compile(program)
        Thread.new { IR::Backends::Native.new.build_headless(program, mode: :fast) }.tap { |thread| thread.report_on_exception = false }
      end

      # +thread+ (a #compile) ended. Its error, if any, is the caller's to raise through #value, or
      # comes after one already being raised, so it is not raised here.
      def wait_for_compile(thread)
        thread.join
      rescue StandardError
        nil
      end

      # The pack file the shell's unpacking writes from +copy+, played as C: the header the shell
      # writes for the copy's release, then the pack's bytes, which the program adds to the file.
      def unpacked_as_c(shell, copy)
        bytes = copy.read_bytes
        release = shell.facts.release_with_sha1(copy.sha1) or
          raise Failed, "#{copy.path} is no release the shell reads, so it cannot be unpacked."
        unpacking = shell.unpackings.fetch(release.unpacking)
        Dir.mktmpdir("vblank-whole-game") do |folder|
          path = File.join(folder, ShellFacts::PACK_FILE)
          File.binwrite(path, shell.facts.pack_for(copy.sha1, ""))
          ended = IR::Backends::Native::FinalStateRun.new(stuck_after: Unpacking::SECONDS_WITHOUT_FRAME)
                                                     .run(unpacking.program, frames: unpacking.most_frames, file: bytes,
                                                                             list_file: IR::Backends::Native::FinalStateRun::ListFile.new(
                                                                               name: Unpacking::BYTES, path: path
                                                                             ))
          refuse_unfinished_unpacking!(ended, copy)
          File.binread(path)
        end
      end

      def refuse_unfinished_unpacking!(ended, copy)
        finished = ended.vars.fetch(Unpacking::FINISHED, 0)
        fault = ended.vars.fetch(Unpacking::FAULT_KIND, 0)
        return if finished == 1 && fault.zero?

        raise Failed, "The shell's unpacking, played as C, did not finish: #{ShellFacts.unpacking_stopped_message(copy.path, fault)}"
      end

      def refuse_different_packs!(unpacked, made)
        return if unpacked == made

        at = (0...[unpacked.bytesize, made.bytesize].min).find { |byte| unpacked.getbyte(byte) != made.getbyte(byte) }
        where = at ? "first at byte #{at}" : "in length"
        raise Failed, "The pack the shell's unpacking wrote as C is not the all-in-one build's pack. They differ #{where}. " \
                      "The shell's pack is #{unpacked.bytesize} bytes, and the all-in-one build's is #{made.bytesize}."
      end

      # Both sides played on the tape at once and compared pass by pass as they come, the screen
      # +width+ pixels across; Failed at the first pass they differ on.
      def compare_plays(whole, shell, width)
        queues = [whole, shell].map { SizedQueue.new(PASSES_AHEAD) }
        players = [whole, shell].zip(queues).map { |side, queue| play(side, queue) }
        begin
          loop do
            expected, actual = queues.map { |queue| next_from(queue) }
            refuse_different_pass!(expected, actual, width)
            break if expected.is_a?(Ended)
          end
        ensure
          queues.each(&:close)
          players.each(&:join)
        end
      end

      # What a side handed over next: a Pass, or Ended. An error the side's play raised is raised here.
      def next_from(queue)
        item = queue.pop
        raise item if item.is_a?(Exception)

        item
      end

      # A thread playing +side+ on the tape, handing each pass to +queue+ as it is played and then
      # Ended (or the error the play raised). Once the queue is closed, the play stops at its next pass.
      def play(side, queue)
        Thread.new do
          run = CompiledRun.new(side.exe).forgetting_moments.sounding_as_played
          run.hand_file(side.start_file) if side.start_file
          buttons = buttons_by_pass
          passes = 0
          run.input_each_frame { |frame| buttons.fetch(frame, []) }
          # Each frame's boundary shows the picture and hands over the sound of the pass before it:
          # the first, the game as it set itself up.
          run.each_vblank do
            queue.push(Pass.new(number: passes, picture: run.screen.shown, sound: run.last_frame_samples))
            passes += 1
          end
          run.run(side.program, frames: @tape.frames)
          # The last pass, which no boundary follows: the picture the run ended on.
          queue.push(Pass.new(number: passes, picture: run.screen.shown, sound: run.last_frame_samples))
          queue.push(Ended.new(passes: passes))
        rescue ClosedQueueError
          nil
        rescue Exception => e # rubocop:disable Lint/RescueException -- any end of the play must reach the comparison, which waits on it
          begin
            queue.push(e)
          rescue ClosedQueueError
            nil
          end
        end
      end

      def refuse_different_pass!(expected, actual, width)
        if expected.is_a?(Ended) || actual.is_a?(Ended)
          return if expected == actual

          shell_passes = actual.is_a?(Ended) ? actual.passes : "more than #{expected.passes}"
          whole_passes = expected.is_a?(Ended) ? expected.passes : "more than #{actual.passes}"
          raise Failed, "The shell's game played #{shell_passes} passes of the tape, and the all-in-one build #{whole_passes}."
        end

        unless expected.picture == actual.picture
          pixel = expected.picture.each_index.find { |at| expected.picture[at] != actual.picture[at] }
          raise Failed, "The shell's game shows a different picture from the all-in-one build #{pass_words(expected)}, " \
                        "first at (#{pixel % width}, #{pixel / width})."
        end
        return if expected.sound == actual.sound

        raise Failed, "The shell's game sounds different from the all-in-one build #{pass_words(expected)}."
      end

      def pass_words(pass) = pass.number.zero? ? "as it sets itself up, before its first pass" : "after pass #{pass.number}"

      # The tape's buttons by pass, from 1.
      def buttons_by_pass
        @tape.presses_within(1..@tape.frames).each_with_object({}) do |stretch, held|
          stretch.frames.each { |frame| held[frame] = stretch.buttons } unless stretch.buttons.empty?
        end
      end
    end
  end
end
