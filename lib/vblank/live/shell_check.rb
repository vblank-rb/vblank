# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Live
    # The check a port runs on its shell, the same for every port (Original::ShellCheckTasks is its
    # rake task). It does what a player does, with nobody at the controls, and holds each step to
    # the all-in-one build of the same game:
    #
    # 1. builds the shell with every copy hidden (Original::Shell.build), so a port whose code needs
    #    the copy stops here;
    # 2. starts it for the first time and picks LOAD ROM, handing it a copy of the copy this machine
    #    names (Original::Game#copy), which the shell unpacks and keeps as its pack;
    # 3. compares that pack, byte for byte, with the one the all-in-one build makes from the same copy
    #    (Cartridge::Game#data_pack_file);
    # 4. takes the copy it handed the shell out of reach and starts the shell again, which must play
    #    from the kept pack without asking for a copy;
    # 5. plays a short stretch of the game on both starts and on the all-in-one build, and compares
    #    every picture and every sample of sound.
    #
    # The stretch stays short, whatever the tape. What the check holds is the shell's own workings,
    # and step 3 already holds every byte of the pack, whatever a tape reaches; the play only shows
    # that the game reads its pack. A port's tape grows with the game, so playing all of it three
    # times as Ruby would grow towards playing the whole game on every commit. The check plays the
    # tape's first +passes+ passes (STRETCH_PASSES unless the port names more, to reach past its
    # title into the game proper), and Original::WholeGameCheck plays the whole tape, as C.
    #
    # The all-in-one side plays alongside the shell. Its build, its pack and its play need nothing
    # from the shell's starts, so where this process can start another (on the main Ractor) they are
    # made in a child process of their own while the shell is built and started here, and the check
    # takes as long as the longer of the two. Inside any other Ractor a process cannot be started,
    # so the all-in-one side is made after the starts, in this one.
    #
    # The shell is played as Ruby (Live::Shell) with YJIT (Live.turn_on_yjit), the way `vblank run
    # --shell` plays it, on a Headless device asked what the window is asked and opened at the
    # window's size. A machine
    # that names no copy stops at step 2 with Original::NotSet, whose words say how to name one. Any
    # other step that goes wrong raises Failed, saying which step and where it went wrong.
    class ShellCheck
      class Failed < StandardError; end

      # The passes of the game played on each start and on the all-in-one build, when the port names
      # none: five seconds of the console, long enough for a game to set itself up from its pack and
      # draw from it, and short enough that the check costs little on every commit.
      STRETCH_PASSES = 300

      MENU_PRESSES = Ractor.make_shareable({ 2 => [:a] }) # A on the menu's second pass: LOAD ROM, the line it starts on
      MOST_UNPACKING_PASSES = 1_000_000 # The menu and the unpacking together, before the check gives up

      # What one run of a game showed and sounded: each pass's picture's pixels, and each pass's
      # samples of sound.
      Played = Data.define(:pictures, :sounds)

      # One start of the shell: what the game showed and sounded (nil when it never played), the
      # words of each file or pack refused, and how many times it asked for a copy.
      Start = Data.define(:played, :refusals, :times_asked)

      # What the all-in-one build made: its +pack+ file's bytes, and what it +played+.
      AllInOne = Data.define(:pack, :played)

      # +game+ is the port (a Cartridge::Game), checked for each of +consoles+, every console it
      # names unless set. +tape+ is a Playthroughs::Tape of frames from power-on, whose first
      # +passes+ are played; with no tape, +passes+ are played with nothing pressed. Each step is
      # named to +say+ as it starts.
      def initialize(game, consoles: game.consoles, tape: nil, passes: STRETCH_PASSES, say: ->(line) { puts line })
        if tape && (tape.recorded_from_save? || tape.recorded_after_lead_in?)
          raise ArgumentError, "The shell check was given a tape that starts from #{tape.starts_from}. The check starts " \
                               "the game from power-on. Give a tape recorded from power-on."
        end
        raise ArgumentError, "The shell check was given passes: #{passes.inspect}. Give a whole number above 0." unless passes.is_a?(Integer) && passes.positive?

        @game = game
        @consoles = consoles
        @tape = tape
        @passes = tape ? [tape.frames, passes].min : passes
        @say = say
      end

      # Runs every step for each console. Raises Failed for a step that went wrong, or
      # Original::NotSet when this machine names no copy.
      def run
        Live.turn_on_yjit
        @consoles.each { |console| run_for(console) }
        @say.call("The shell of #{@game.title} plays as its all-in-one build does")
      end

      private

      def run_for(console)
        when_built = Alongside.forkable? ? "alongside the shell" : "after the first start, with the pack comparison"
        @say.call("Building #{@game.title} for #{console} all-in-one, #{when_built}")
        all_in_one = Alongside.start { all_in_one_made(console) }
        begin
          @say.call("Building #{@game.title} for #{console} as a shell, with no copy in reach")
          shell = Original::Shell.build(@game, console: console, err: nil)
          copy = shell.original.copy
          live = Shell.from(shell)
          # The size `vblank run --shell` opens its window at, which refuses a picture of any other.
          @screen = shell.game.described_console.framed_screen_size
          Dir.mktmpdir("vblank-shell-check") { |folder| compare_starts_with_all_in_one(live, copy, folder, all_in_one) }
        ensure
          all_in_one.stop
        end
      end

      # The all-in-one build's pack, and its play over the stretch. The game is read once for both.
      #
      # Most of this side's time is reading and checking the game, which is the same however often
      # the check runs. The build plays the port's unpacking routine itself only where the pack
      # cache the game names (`data_pack cache:`) has no entry, which its key makes happen once
      # after each change to the routine, the copy or the part of VBlank that unpacks
      # (Original::PackCache). That miss is the bulk of the side's time for a big port, and the
      # next check reads the entry.
      def all_in_one_made(console)
        parts = @game.all_in_one_parts(err: nil, console: console)
        pack = parts.data_pack_file or raise Failed, "#{@game.title} has no data_pack, so it has no shell to check."
        program = parts.program
        AllInOne.new(pack: pack, played: record_play(Session.new(program), program.described_console.framed_screen_size))
      end

      # A copy that is one file is handed as that file. One that is a folder (a release of several
      # files) is handed as a folder holding the release's own files alone: a player's folder can
      # hold saves, settings and much else the game never reads.
      def hand_copy(copy, handed)
        return FileUtils.cp(copy.path, handed) unless copy.files

        FileUtils.mkdir_p(handed)
        copy.files.each { |file| FileUtils.cp(file.path, handed) }
      end

      # +all_in_one+ is the Alongside making the all-in-one build's AllInOne.
      def compare_starts_with_all_in_one(live, copy, folder, all_in_one)
        copy_path = copy.path
        handed = File.join(folder, File.basename(copy_path))
        hand_copy(copy, handed)
        kept_in = File.join(folder, "kept")

        @say.call("First start: unpacking #{copy_path}, then playing #{@passes} passes")
        first = refuse_start_problems!(play_start(live, kept_in, handed), "The first start", may_ask: true)
        # Before the second start, which would refuse a wrong pack as a start problem and not name
        # it as the wrong pack.
        @say.call("Comparing the kept pack with the all-in-one build's")
        made = all_in_one.value
        refuse_different_packs!(File.binread(File.join(kept_in, Original::ShellFacts::PACK_FILE)), made.pack)

        FileUtils.rm_rf(handed)
        @say.call("Second start, with the copy out of reach")
        # Every copy is hidden as well, so a second start that reached for the machine's copy stops.
        second = Original.without_copies { play_start(live, kept_in, nil) }
        second = refuse_start_problems!(second, "The second start", may_ask: false)

        @say.call("Comparing #{@passes} passes of each start with the all-in-one build's")
        refuse_different_play!(made.played, first, "The first start")
        refuse_different_play!(made.played, second, "The second start")
      end

      # The shell started with +kept_in+ as its folder, LOAD ROM picking +handed+ (nil: no file).
      def play_start(live, kept_in, handed)
        refusals = []
        asked = 0
        played = nil
        live.play(Headless.new(frames: MOST_UNPACKING_PASSES, buttons: MENU_PRESSES, screen: @screen), folder_path: kept_in,
                  choose_copy: lambda {
                    asked += 1
                    handed
                  },
                  refused: ->(words) { refusals << words },
                  # A player is never told of a kept pack that is not read; the check is, since
                  # the pack its first start kept must be the one its second start reads.
                  kept_pack_refused: ->(words) { refusals << words },
                  play_game: ->(game) { played = record_play(Session.new(game: game)) })
        Start.new(played: played, refusals: refusals, times_asked: asked)
      end

      # What +start+ (the one called +which+) played; Failed when it refused anything, asked for a
      # copy when it +may_ask+ not, or never played the game.
      def refuse_start_problems!(start, which, may_ask:)
        raise Failed, "#{which} refused this: #{start.refusals.first}" unless start.refusals.empty?
        if !may_ask && start.times_asked.positive?
          raise Failed, "#{which} asked for a copy again. It must play from the pack the first start kept."
        end
        return start.played if start.played

        raise Failed, "#{which} never played the game. The unpacking did not finish in #{MOST_UNPACKING_PASSES} passes."
      end

      def refuse_different_packs!(kept, made)
        return if kept == made

        at = (0...[kept.bytesize, made.bytesize].min).find { |byte| kept.getbyte(byte) != made.getbyte(byte) }
        where = at ? "first at byte #{at}" : "in length"
        raise Failed, "The pack the shell kept is not the all-in-one build's pack. They differ #{where}. The shell's " \
                      "pack is #{kept.bytesize} bytes, and the all-in-one build's is #{made.bytesize}. The unpacking " \
                      "must write each slot as the all-in-one build fills it."
      end

      def refuse_different_play!(expected, actual, which)
        refuse_different_pictures!(expected.pictures, actual.pictures, which)
        return if expected.sounds == actual.sounds

        pass = expected.sounds.each_index.find { |at| expected.sounds[at] != actual.sounds[at] } || expected.sounds.size
        raise Failed, "#{which} sounds different from the all-in-one build, first on pass #{pass + 1}."
      end

      def refuse_different_pictures!(expected, actual, which)
        unless expected.size == actual.size
          raise Failed, "#{which} showed #{actual.size} pictures, and the all-in-one build #{expected.size}."
        end

        expected.each_index do |pass|
          next if expected[pass] == actual[pass]

          pixel = expected[pass].each_index.find { |at| expected[pass][at] != actual[pass][at] }
          raise Failed, "#{which} shows a different picture from the all-in-one build on pass #{pass + 1}, first at " \
                        "pixel #{pixel}."
        end
      end

      # What +session+ showed and sounded over the stretch, on a device opened at +screen+ (the
      # window's size, [width, height]).
      def record_play(session, screen = @screen)
        device = Headless.new(frames: @passes, buttons: buttons_by_pass, screen: screen)
        session.play(device)
        Played.new(pictures: device.pictures.map(&:pixels), sounds: device.sounds)
      end

      # The tape's buttons by pass, from 1, over the stretch.
      def buttons_by_pass
        return {} unless @tape

        @tape.presses_within(1..@passes).each_with_object({}) do |stretch, held|
          stretch.frames.each { |frame| held[frame] = stretch.buttons } unless stretch.buttons.empty?
        end
      end

      # Work done in a child process while this one goes on (#value gives its answer, or raises the
      # error it raised), or, where this process cannot start one, done here when its answer is
      # asked for. Ruby runs one thread at a time within a Ractor, so a thread would not go any
      # faster; a process has a core of its own.
      #
      # The child is a fork, so it starts with everything this process has made, the game among
      # it, and hands its answer back through a pipe in Ruby's own format (Marshal). It ends with
      # exit! whatever happens, so nothing set to run as this process ends (a test runner's report)
      # runs in it too. An error in the child is sent as its class's name and its words, never as
      # the error itself (one may hold a Proc, which cannot be sent), and raised here as Failed.
      class Alongside
        def self.start(&work)
          forkable? ? Forked.new(work) : InThisProcess.new(work)
        end

        # A process is started only from the main Ractor: Ruby refuses a fork from any other.
        def self.forkable? = Process.respond_to?(:fork) && Ractor.current == Ractor.main

        # The work, done when its answer is first asked for.
        class InThisProcess
          def initialize(work) = @work = work
          def value = (@value ||= @work.call)
          def stop = nil
        end

        # The work, done in a child process.
        class Forked
          def initialize(work)
            @reader, writer = IO.pipe
            @reader.binmode
            @pid = Process.fork do
              @reader.close
              writer.binmode
              writer.write(Forked.answer_bytes(work))
              writer.close
            ensure
              exit!(0)
            end
            writer.close
          end

          # The work's answer, as [:value, answer], or [:error, class name, words] for an error the
          # work or the sending of its answer raised, in Marshal's bytes.
          def self.answer_bytes(work)
            Marshal.dump([:value, work.call])
          rescue Exception => e # rubocop:disable Lint/RescueException -- every error is the parent's to raise
            Marshal.dump([:error, e.class.name.to_s, e.message.to_s])
          end

          def value
            return @value if defined?(@value)

            bytes = @reader.read
            status = wait
            if bytes.empty?
              raise Failed, "The process making the all-in-one build ended with no answer (#{status&.inspect || 'its end not seen'})."
            end

            kind, answer, words = Marshal.load(bytes) # rubocop:disable Security/MarshalLoad -- written by this process's own child
            raise Failed, "Making the all-in-one build stopped with #{answer}: #{words}" if kind == :error

            @value = answer
          end

          # The child ended, whether or not its answer was asked for: a check that stopped early
          # leaves no process behind.
          def stop
            return unless @pid

            Process.kill(:KILL, @pid)
            wait
          rescue Errno::ESRCH
            wait
          end

          private

          # The child waited for, and how it ended (a Process::Status), or nil where it was waited
          # for already.
          def wait
            return unless @pid

            _, status = Process.wait2(@pid)
            status
          rescue Errno::ECHILD
            nil
          ensure
            @pid = nil
            @reader.close unless @reader.closed?
          end
        end
      end
      private_constant :Alongside
    end
  end
end
