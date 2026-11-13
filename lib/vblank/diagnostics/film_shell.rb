# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Diagnostics
    # A PORT'S SHELL FILMED AS A PLAYER FIRST MEETS IT: one side of a film (Film), the shell started
    # for the first time with no pack kept. The menu comes up, LOAD ROM is chosen, the shell is handed
    # this machine's copy of the original, the progress bar fills while the copy is unpacked, and the
    # game plays on with the film's buttons. Beside it, #all_in_one is the same game built all-in-one,
    # its first frame put on the film frame the shell's game began on.
    #
    #   shell = VBlank::Diagnostics::FilmShell.new(GAME)
    #   VBlank::Diagnostics::Film.make("shell.mp4", sides: { "shell" => -> { shell.open },
    #                                                        "all-in-one" => -> { shell.all_in_one } },
    #                                               parts: [1..2000])
    #
    # The shell is built with every copy hidden (Original::Shell.build) and played as Ruby
    # (Live::Shell), as `vblank run --shell` and the shell check play it. The copy handed over is the
    # one this machine names (Original::Game#copy), so a machine that names none stops with
    # Original::NotSet, whose words say how to name one. The copy and the pack the shell keeps are in
    # a folder of the side's own, taken away when the side closes: nothing of the copy reaches the
    # film's folder but its pictures.
    #
    # THE SHELL PLAYS ITSELF, so a film side here plays it in a Fiber on a device that hands each
    # picture back as it is shown, one film frame at a time. The menu's buttons are the shell check's
    # (Live::ShellCheck::MENU_PRESSES: A on LOAD ROM); the film's own buttons reach the game alone.
    #
    # THE UNPACKING KEEPS REAL TIME. It plays in a Ractor of its own (Live::BackgroundUnpacking), and
    # the window shows its newest picture each frame, a frame's time apart at most: the film shows
    # the bar as a player's window would, so how many frames it fills over is this machine's speed.
    class FilmShell
      # A shell played as a film side refused the copy it was handed: the words a player is told.
      class Refused < StandardError; end

      # +game+ is the port (a Cartridge::Game); +console+ the console its shell is built for, the
      # first it names unless set.
      def initialize(game, console: nil)
        require_relative "../live"
        @game = game
        @console = console ? Console.named(console) : game.consoles.first
        @built = Original::Shell.build(game, console: @console, err: nil)
        @copy = @built.original.copy
        @game_began_on = nil
      end

      # The film frame the shell's game showed its first picture on, once a side opened by #open has
      # played that far; nil before.
      attr_reader :game_began_on

      # The shell from its first start, as a side Film plays (step, screenshot, close).
      def open = ShellSide.new(Live::Shell.from(@built), @copy, ->(frame) { @game_began_on = frame })

      # The all-in-one build of the game, shown as a display switched off until the frame the shell's
      # game began on, then played from its first pass with the same buttons. Opened after the shell's
      # side has played past that frame (Film plays its sides in order, so list the shell first).
      def all_in_one
        unless @game_began_on
          raise ArgumentError, "The all-in-one side starts on the frame the shell's game began on, and the shell's side " \
                               "has not shown the game yet. To fix this, put the shell's side first in `sides:`, " \
                               "and give parts that reach past the end of the unpacking."
        end

        session = Live::Session.new(@game.checked_program(err: nil, console: @console))
        AllInOneSide.new(session, held_back: @game_began_on - 1, width: @built.game.described_console.screen_width,
                                  height: @built.game.described_console.screen_height)
      end

      # A copy that is one file is handed as that file. One that is a folder (a release of several
      # files) is handed as a folder holding the release's own files alone, as the shell check hands it.
      def self.hand_copy(copy, handed)
        return FileUtils.cp(copy.path, handed) unless copy.files

        FileUtils.mkdir_p(handed)
        copy.files.each { |file| FileUtils.cp(file.path, handed) }
      end

      # WHERE A FILMED PLAY SHOWS ITS PICTURES: a device for Live::Session (its comment lists what a
      # device answers) whose clock moves only when the play waits, as Live::Headless's does, and
      # which hands each picture back out of the Fiber the play runs in. It seats players as a window
      # does. +buttons+ answers the buttons held for a pass, by the pass's number.
      class FilmedDevice
        attr_reader :now
        attr_writer :buttons

        def initialize
          @now = 0r
          @buttons = ->(_pass) { [] }
          @stopping = false
        end

        def show(pixels, width, height) = Fiber.yield(Live::Headless::Picture.new(pixels: pixels.dup, width: width, height: height))
        def play_sound(_left, _rate, _right = nil) = nil
        def sound_waiting = nil
        def held_buttons(pass) = @buttons.call(pass)
        def fast_forward_speed(_pass) = 1
        def hold_while_paused = false
        def seat_players(_most_players) = nil
        def notice(_words) = nil
        def wait_until(seconds) = (@now = [@now, seconds.to_r].max)

        # Asked once a pass: true once the side is closing, which ends every play the shell is in.
        def stop? = @stopping

        def stop! = (@stopping = true)
      end

      # A PLAY THE FILM STEPS A PICTURE AT A TIME: +play+, called with the device, runs in a Fiber,
      # and each step resumes it until it shows its next picture. A play that has ended keeps its
      # last picture, as a console does.
      class SteppedPlay
        # The pixels of the picture shown last, a row at a time, as the console's screen shows them.
        def pixels = @picture&.pixels

        # +play+ is a lambda, not a block: it is called in the Fiber after this method has returned.
        def initialize(play)
          @device = FilmedDevice.new
          @fiber = Fiber.new do
            play.call(@device)
            nil
          end
          @picture = nil
        end

        # One picture further, with +keys+ (IR::Buttons.mask) the film's buttons for it.
        def step_picture(keys)
          @keys = keys
          return unless @fiber.alive?

          shown = @fiber.resume
          @picture = shown if shown
        end

        # The film's buttons for the picture being played, by name: the first player's, a bit each
        # in IR::Buttons::NAMES's order (IR::Buttons.mask).
        def film_buttons = IR::Buttons::NAMES.select.with_index { |_name, bit| @keys.to_i.anybits?(1 << bit) }

        def screenshot(path)
          Graphics::PNG.write(path, width: @picture.width, height: @picture.height, pixels: @picture.pixels)
        end

        # Every play ended: each one asked to stop sees it on its next pass, so the Fiber is run
        # until it ends.
        def stop
          @device.stop!
          @fiber.resume while @fiber.alive?
        end
      end
      private_constant :SteppedPlay

      # THE SHELL'S SIDE. +copy+ is the copy handed to LOAD ROM, and +game_began+ is told the film
      # frame the game's first picture is on.
      class ShellSide
        def initialize(shell, copy, game_began)
          @folder = Dir.mktmpdir("film-shell")
          handed = File.join(@folder, File.basename(copy.path))
          FilmShell.hand_copy(copy, handed)
          @frame = 0
          @play = SteppedPlay.new(lambda { |device|
            device.buttons = ->(pass) { Live::ShellCheck::MENU_PRESSES.fetch(pass, []) }
            shell.play(device, folder_path: File.join(@folder, "kept"), choose_copy: -> { handed },
                               refused: ->(words) { raise Refused, words },
                               play_game: lambda { |game|
                                 game_began.call(@frame + 1)
                                 device.buttons = ->(_pass) { @play.film_buttons }
                                 Live::Session.new(game: game).play(device)
                               })
          })
        rescue StandardError
          close
          raise
        end

        def step(count = 1, keys: 0)
          count.times do
            @play.step_picture(keys)
            @frame += 1
          end
          self
        end

        # The pixels of the picture on the film's frame just played.
        def pixels = @play.pixels

        def screenshot(path) = @play.screenshot(path)

        # The shell stopped where it stands and its folder, the copy and the pack in it, taken away.
        def close
          @play&.stop
          FileUtils.remove_entry(@folder, true) if @folder
          nil
        end
      end

      # THE ALL-IN-ONE BUILD'S SIDE: +held_back+ frames of a display switched off, then +session+
      # played from its first pass with the film's buttons.
      class AllInOneSide
        def initialize(session, held_back:, width:, height:)
          @held_back = held_back
          @off = Live::Headless::Picture.new(pixels: Array.new(width * height, IR::Backends::Reference::Framebuffer::HELD_OFF),
                                             width: width, height: height)
          @play = SteppedPlay.new(lambda { |device|
            device.buttons = ->(_pass) { @play.film_buttons }
            session.play(device)
          })
        end

        def step(count = 1, keys: 0)
          count.times do
            next @held_back -= 1 if @held_back.positive?

            @play.step_picture(keys)
          end
          self
        end

        def pixels = @play.pixels || @off.pixels

        def screenshot(path)
          return @play.screenshot(path) if @play.pixels

          Graphics::PNG.write(path, width: @off.width, height: @off.height, pixels: @off.pixels)
        end

        def close = @play.stop
      end
    end
  end
end
