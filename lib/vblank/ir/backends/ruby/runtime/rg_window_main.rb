# frozen_string_literal: true

# THE WINDOW vblank run OPENS, IN A PROCESS OF ITS OWN. vblank run starts a helper process that
# builds the game (Live::BuildHelper), then becomes this: a fresh Ruby holding only what a game
# written out as one Ruby file carries (Ruby::SCRIPT_PARTS and rg_script_main.rb, loaded from the
# library ahead of this file) and Live::BuildWatch. Nothing of the build is ever in this process,
# so the game plays with none of the build's memory to look after.
#
# The window opens at once at the console's size, shows what the helper is doing, reads the game it
# wrote (Ruby::WrittenGame.read), and plays it as a script plays its own (VBlankScript.play). A
# game that cannot play is said in the window and on the terminal, and ends the process with 1.
require "fileutils"
require "json"

module VBlankWindow
  # +arguments+ is one JSON object, written by vblank run (CLI#play_built_in_helper): the window's
  # title, size, menu and buttons, where save states are kept, where the helper writes the game
  # and the folder to remove once it is read, the helper's pid and the descriptor it says what it
  # is doing on, whether to turn YJIT on, and the options VBlankScript.play takes.
  #
  # However this ends (the game played, a refusal, the window closed during the build, an error,
  # Ctrl-C), the helper is ended and reaped and the folder it wrote in is removed: the folder may
  # hold an original's data, and a helper left running holds the whole build.
  def self.main(arguments)
    launch = JSON.parse(arguments.fetch(0))
    options = launch.fetch("options").transform_keys(&:to_sym)
    watch = VBlank::Live::BuildWatch.new(IO.for_fd(launch.fetch("build_fd")), pid: launch.fetch("helper_pid"),
                                                                              title: launch.fetch("title"))
    VBlankScript.turn_on_yjit if launch.fetch("yjit")
    window = open_window(launch, options)
    outcome = watch.watch(window, refusal_frames: options[:pictures], terminal: $stderr)
    exit 1 if outcome.refusal
    return if outcome.stopped?

    written = VBlank::IR::Backends::Ruby::WrittenGame.read(outcome.written)
    FileUtils.rm_rf(launch.fetch("written_folder"))
    played = window
    window = nil # VBlankScript.play closes it
    VBlankScript.play(written, options.merge(state_folder: launch["state_folder"]), window: played)
  rescue VBlank::Live::SDL::Missing, VBlank::Live::SDL::Failed => e
    warn e.message
    exit 1
  rescue Interrupt
    exit 130
  ensure
    window&.close
    watch&.stop_helper
    FileUtils.rm_rf(launch.fetch("written_folder")) if launch
  end

  # The window, at the console's size until the game is known.
  def self.open_window(launch, options)
    VBlank::Live::SDL.new(title: launch.fetch("title"), scale: options[:scale], width: launch.fetch("width"),
                          height: launch.fetch("height"), pixel_size: launch.fetch("pixel_size"), menu: launch.fetch("menu"),
                          settings_file: options[:"settings-file"] || :usual, config_dir: options[:"config-dir"],
                          state_folder_name: launch["state_folder"], buttons: launch.fetch("buttons").map(&:to_sym))
  end
end

VBlankWindow.main(ARGV) if $PROGRAM_NAME == __FILE__
