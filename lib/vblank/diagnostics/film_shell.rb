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
    # (Live::Shell), with YJIT (Live.turn_on_yjit), as `vblank run --shell` and the shell check play
    # it. The game waits for no clock (FilmedDevice): each side plays it as fast as this machine can,
    # and the MP4 shows sixty frames a second whatever that took. The copy handed over is the
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
    # A side opened with `from: :game` plays the menu and the unpacking before the film's first frame,
    # filming neither, so its frame 1 is the game's first pass on any machine:
    #
    #   Film.make("game.mp4", sides: { "shell" => -> { shell.open(from: :game) },
    #                                  "all-in-one" => -> { shell.all_in_one } }, parts: [1..600])
    class FilmShell
      # A shell played as a film side refused the copy it was handed: the words a player is told.
      class Refused < StandardError; end

      # A side counted from the game opened on a shell whose play ended before its game began.
      class GameNeverBegan < StandardError; end

      # +game+ is the port (a Cartridge::Game); +console+ the console its shell is built for, the
      # first it names unless set.
      def initialize(game, console: nil)
        require_relative "../live"
        Live.turn_on_yjit
        @game = game
        @console = console ? Console.named(console) : game.consoles.first
        @built = Original::Shell.build(game, console: @console, err: nil)
        @copy = @built.original.copy
        @game_began_on = nil
      end

      # Where a side opened by #open puts the film's first frame: on the shell's menu, or on the first
      # frame of the shell's game.
      COUNTED_FROM = %i[menu game].freeze

      # The film frame the shell's game showed its first picture on, once a side opened by #open has
      # played that far; nil before. 1 for a side counted from the game, once it has played a frame.
      attr_reader :game_began_on

      # The shell from its first start, as a side Film plays (step, screenshot, close). +from+ :menu
      # films the menu and the unpacking before the game, so the frame the game begins on is this
      # machine's speed. +from+ :game plays the menu and the unpacking as the side opens, filming
      # neither, so the film's first frame is the game's first on any machine.
      #
      # +sound:+ true keeps the sound each picture is shown with, for a film that hears this side
      # (#last_frame_samples on the side); without it the side keeps none.
      def open(from: :menu, sound: false)
        unless COUNTED_FROM.include?(from)
          raise ArgumentError, "`from: #{from.inspect}` is not a place to start the shell's film. Give `from: :menu` " \
                               "to film the menu and the unpacking, or `from: :game` to start on the game's first frame."
        end

        ShellSide.new(Live::Shell.from(@built), @copy, ->(frame) { @game_began_on = frame }, from_game: from == :game,
                                                                                            sound: sound)
      end

      # The all-in-one build of the game, shown as a display switched off until the frame the shell's
      # game began on, then played from its first pass with the same buttons. Opened after the shell's
      # side has played past that frame (Film plays its sides in order, so list the shell first).
      # +sound:+ as #open's; the frames held back are silent.
      def all_in_one(sound: false)
        unless @game_began_on
          raise ArgumentError, "The all-in-one side starts on the frame the shell's game began on, and the shell's side " \
                               "has not shown the game yet. To fix this, put the shell's side first in `sides:`, " \
                               "and give parts that reach past the end of the unpacking."
        end

        session = Live::Session.new(@game.checked_program(err: nil, console: @console))
        AllInOneSide.new(session, held_back: @game_began_on - 1, width: @built.game.described_console.screen_width,
                                  height: @built.game.described_console.screen_height, sound: sound)
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
      #
      # KEEPING SOUND (+keeps_sound+). A session shows a pass's picture and then hands over the pass's
      # sound (Session#play_at_console_speed), so a picture handed out as it is shown would leave its
      # sound for the next step. A device that keeps sound holds each picture back until the session's
      # next call to it, the sound being the one that comes first, and hands the picture out then with
      # the sound it was shown with (#sound_shown). The pictures come out in the same order, each on the
      # same step; one still held when the play ends or the game begins is handed out by
      # #hand_out_picture.
      class FilmedDevice
        attr_reader :now
        attr_writer :buttons

        # The samples handed over with the picture handed out last, left and right by turns.
        attr_reader :sound_shown

        def initialize(keeps_sound: false)
          @now = 0r
          @buttons = ->(_pass) { [] }
          @stopping = false
          @keeps_sound = keeps_sound
          @held_picture = nil
          @sound = []
          @sound_shown = []
        end

        def show(pixels, width, height)
          picture = Live::Headless::Picture.new(pixels: pixels.dup, width: width, height: height)
          return Fiber.yield(picture) unless @keeps_sound

          hand_out_picture
          @held_picture = picture
        end

        # A pass's sound, the left speaker's and the right's (the left's again for a game with one).
        def play_sound(left, _rate, right = nil)
          return unless @keeps_sound

          left ||= []
          @sound.concat(left.zip(right || left).flatten.compact)
          hand_out_picture
        end

        # The picture held back, with the sound that came since the one before, out of the Fiber.
        def hand_out_picture
          return unless @held_picture

          picture = @held_picture
          @held_picture = nil
          @sound_shown = @sound
          @sound = []
          Fiber.yield(picture)
        end

        def sound_waiting = nil
        def held_buttons(pass) = hand_out_picture.then { @buttons.call(pass) }
        def fast_forward_speed(_pass) = 1
        def hold_while_paused = hand_out_picture.then { false }
        def seat_players(_most_players) = nil
        def notice(_words) = nil

        def wait_until(seconds)
          hand_out_picture
          @now = [@now, seconds.to_r].max
        end

        # Asked once a pass: true once the side is closing, which ends every play the shell is in.
        def stop?
          hand_out_picture
          @stopping
        end

        def stop! = (@stopping = true)
      end

      # A PLAY THE FILM STEPS A PICTURE AT A TIME: +play+, called with the device, runs in a Fiber,
      # and each step resumes it until it shows its next picture. A play that has ended keeps its
      # last picture, as a console does.
      class SteppedPlay
        # The pixels of the picture shown last, a row at a time, as the console's screen shows them.
        def pixels = @picture&.pixels

        # +play+ is a lambda, not a block: it is called in the Fiber after this method has returned.
        # +keeps_sound+ keeps the sound each picture is shown with (FilmedDevice).
        def initialize(play, keeps_sound: false)
          @device = FilmedDevice.new(keeps_sound: keeps_sound)
          @fiber = Fiber.new do
            play.call(@device)
            @device.hand_out_picture
            nil
          end
          @picture = nil
          @samples = []
          @keeps_sound = keeps_sound
        end

        # The samples the picture stepped to last was shown with, left and right by turns: none for a
        # step that showed no new picture. A play that keeps no sound is refused, not heard as silence.
        def last_frame_samples
          return @samples if @keeps_sound

          raise ArgumentError, "This side of the shell keeps no sound, so a film cannot hear it. To fix this, open it " \
                               "with `sound: true`: `shell.open(sound: true)` or `shell.all_in_one(sound: true)`."
        end

        # One picture further, with +keys+ (IR::Buttons.mask) the film's buttons for it. Answers what
        # the play handed out of its Fiber: the picture, GAME_BEGINS, or nil once the play has ended.
        def step_picture(keys)
          @keys = keys
          @samples = []
          return unless @fiber.alive?

          shown = @fiber.resume
          if shown.is_a?(Live::Headless::Picture)
            @picture = shown
            @samples = @device.sound_shown
          end
          shown
        end

        # True while the play can be stepped further.
        def playing? = @fiber.alive?

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

      # What the shell's play hands out of its Fiber, in place of a picture, when the game is about to
      # play its first pass: a side counted from the game stops its lead-in there.
      GAME_BEGINS = :game_begins

      # THE SHELL'S SIDE. +copy+ is the copy handed to LOAD ROM, and +game_began+ is told the film
      # frame the game's first picture is on. +from_game+ plays the menu and the unpacking before the
      # film's first frame (#play_lead_in), so that frame is the game's first pass, played with the
      # film's buttons for it.
      class ShellSide
        def initialize(shell, copy, game_began, from_game:, sound: false)
          @folder = Dir.mktmpdir("film-shell")
          handed = File.join(@folder, File.basename(copy.path))
          FilmShell.hand_copy(copy, handed)
          @frame = 0
          @play = SteppedPlay.new(lambda { |device|
            device.buttons = ->(pass) { Live::ShellCheck::MENU_PRESSES.fetch(pass, []) }
            shell.play(device, folder_path: File.join(@folder, "kept"), choose_copy: -> { handed },
                               refused: ->(words) { raise Refused, words },
                               play_game: lambda { |game|
                                 device.hand_out_picture # the shell's last, on its own step
                                 Fiber.yield(GAME_BEGINS) if from_game
                                 game_began.call(@frame + 1)
                                 device.buttons = ->(_pass) { @play.film_buttons }
                                 Live::Session.new(game: game).play(device)
                               })
          }, keeps_sound: sound)
          play_lead_in if from_game
        rescue StandardError
          close
          raise
        end

        # The samples the frame just played was shown with, left and right by turns.
        def last_frame_samples = @play.last_frame_samples

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

        private

        # The menu and the unpacking played with no film frame counted, as many pictures as this
        # machine takes, until the game is about to play its first pass.
        def play_lead_in
          until @play.step_picture(0) == GAME_BEGINS
            next if @play.playing?

            raise GameNeverBegan, "The shell stopped before its game began. A film cannot start on the game's first " \
                                  "frame. To see why, film the shell with `from: :menu`."
          end
        end
      end

      # THE ALL-IN-ONE BUILD'S SIDE: +held_back+ frames of a display switched off, then +session+
      # played from its first pass with the film's buttons.
      class AllInOneSide
        def initialize(session, held_back:, width:, height:, sound: false)
          @held_back = held_back
          @off = Live::Headless::Picture.new(pixels: Array.new(width * height, IR::Backends::Reference::Framebuffer::HELD_OFF),
                                             width: width, height: height)
          @play = SteppedPlay.new(lambda { |device|
            device.buttons = ->(_pass) { @play.film_buttons }
            session.play(device)
          }, keeps_sound: sound)
          @silent_step = false
        end

        def step(count = 1, keys: 0)
          count.times do
            @silent_step = @held_back.positive?
            next @held_back -= 1 if @silent_step

            @play.step_picture(keys)
          end
          self
        end

        # The samples the frame just played was shown with, left and right by turns: none while the
        # display is switched off.
        def last_frame_samples = @silent_step ? [] : @play.last_frame_samples

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
