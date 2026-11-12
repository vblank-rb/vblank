# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Live
    # THE CHECK A PORT RUNS ON ITS SHELL, the same for every port (Original::ShellCheckTasks is its
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
    # 5. plays the tape on both starts and on the all-in-one build, and compares every picture and
    #    every sample of sound.
    #
    # The shell is played as Ruby (Live::Shell), the way `vblank run --shell` plays it. A machine
    # that names no copy stops at step 2 with Original::NotSet, whose words say how to name one. Any
    # other step that goes wrong raises Failed, saying which step and where it went wrong.
    class ShellCheck
      class Failed < StandardError; end

      PASSES_WITHOUT_TAPE = 300         # Passes played with nothing pressed, when no tape is given
      MENU_PRESSES = { 2 => [:a] }.freeze # A on the menu's second pass: LOAD ROM, the line it starts on
      MOST_UNPACKING_PASSES = 1_000_000 # The menu and the unpacking together, before the check gives up

      # What one run of a game showed and sounded: each pass's picture's pixels, and each pass's
      # samples of sound.
      Played = Data.define(:pictures, :sounds)

      # One start of the shell: what the game showed and sounded (nil when it never played), the
      # words of each file or pack refused, and how many times it asked for a copy.
      Start = Data.define(:played, :refusals, :times_asked)

      # +game+ is the port (a Cartridge::Game), checked for each of +consoles+, every console it
      # names unless set. +tape+ is a Playthroughs::Tape of frames from power-on, or nil for
      # PASSES_WITHOUT_TAPE passes with nothing pressed. Each step is named to +say+ as it starts.
      def initialize(game, consoles: game.consoles, tape: nil, say: ->(line) { puts line })
        if tape && (tape.recorded_from_save? || tape.recorded_after_lead_in?)
          raise ArgumentError, "The shell check was given a tape that starts from #{tape.starts_from}. The check starts " \
                               "the game from power-on. Give a tape recorded from power-on."
        end

        @game = game
        @consoles = consoles
        @tape = tape
        @say = say
      end

      # Runs every step for each console. Raises Failed for a step that went wrong, or
      # Original::NotSet when this machine names no copy.
      def run
        @consoles.each { |console| run_for(console) }
        @say.call("The shell of #{@game.title} plays as its all-in-one build does")
      end

      private

      def run_for(console)
        @say.call("Building #{@game.title} for #{console} as a shell, with no copy in reach")
        shell = Original::Shell.build(@game, console: console, err: nil)
        copy = shell.original.copy
        live = Shell.from(shell)
        Dir.mktmpdir("vblank-shell-check") { |folder| compare_starts_with_all_in_one(live, console, copy, folder) }
      end

      # A copy that is one file is handed as that file. One that is a folder (a release of several
      # files) is handed as a folder holding the release's own files alone: a player's folder can
      # hold saves, settings and much else the game never reads.
      def hand_copy(copy, handed)
        return FileUtils.cp(copy.path, handed) unless copy.files

        FileUtils.mkdir_p(handed)
        copy.files.each { |file| FileUtils.cp(file.path, handed) }
      end

      def compare_starts_with_all_in_one(live, console, copy, folder)
        copy_path = copy.path
        handed = File.join(folder, File.basename(copy_path))
        hand_copy(copy, handed)
        kept_in = File.join(folder, "kept")

        @say.call("First start: unpacking #{copy_path}")
        first = refuse_start_problems!(play_start(live, kept_in, handed), "The first start", may_ask: true)
        @say.call("Comparing the kept pack with the all-in-one build's")
        refuse_different_packs!(File.binread(File.join(kept_in, Original::ShellFacts::PACK_FILE)), all_in_one_pack(console))

        FileUtils.rm_rf(handed)
        @say.call("Second start, with the copy out of reach")
        # Every copy is hidden as well, so a second start that reached for the machine's copy stops.
        second = Original.without_copies { play_start(live, kept_in, nil) }
        second = refuse_start_problems!(second, "The second start", may_ask: false)

        @say.call("Playing #{passes} passes on the all-in-one build")
        all_in_one = record_play(Session.new(@game.checked_program(err: nil, console: console)))
        refuse_different_play!(all_in_one, first, "The first start")
        refuse_different_play!(all_in_one, second, "The second start")
      end

      # The shell started with +kept_in+ as its folder, LOAD ROM picking +handed+ (nil: no file).
      def play_start(live, kept_in, handed)
        refusals = []
        asked = 0
        played = nil
        live.play(Headless.new(frames: MOST_UNPACKING_PASSES, buttons: MENU_PRESSES), folder_path: kept_in,
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

      def all_in_one_pack(console)
        @game.data_pack_file(console: console) or
          raise Failed, "#{@game.title} has no data_pack, so it has no shell to check."
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

      # What +session+ showed and sounded over the tape.
      def record_play(session)
        device = Headless.new(frames: passes, buttons: buttons_by_pass)
        session.play(device)
        Played.new(pictures: device.pictures.map(&:pixels), sounds: device.sounds)
      end

      def passes = @tape ? @tape.frames : PASSES_WITHOUT_TAPE

      # The tape's buttons by pass, from 1.
      def buttons_by_pass
        return {} unless @tape

        @tape.presses_within(1..@tape.frames).each_with_object({}) do |stretch, held|
          stretch.frames.each { |frame| held[frame] = stretch.buttons } unless stretch.buttons.empty?
        end
      end
    end
  end
end
