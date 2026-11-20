# frozen_string_literal: true

# THE WINDOW vblank run OPENS, IN A PROCESS OF ITS OWN. vblank run starts a helper process that
# builds the game (Live::BuildHelper), then becomes this: a fresh Ruby holding only what a game
# written out as one Ruby file carries (Ruby::SCRIPT_PARTS and rg_script_main.rb, loaded from the
# library ahead of this file) and Live::BuildWatch, and for a match over a network the network's
# parts (Live::WindowProcess::MATCH_PARTS). Nothing of the build is ever in this process, so the
# game plays with none of the build's memory to look after.
#
# The window opens at once at the console's size, shows what the helper is doing, reads the game it
# wrote (Ruby::WrittenGame.read), and plays it as a script plays its own (VBlankScript.play). A
# game written out by an earlier launch and still current (Live::WrittenGames) is played with no
# helper and no wait. A game that cannot play is said in the window and on the terminal, and ends
# the process with 1.
#
# A MATCH (--host, --join) is hosted or joined once the game is written, from what the helper
# wrote of it (WrittenGame#match, Live::MatchPlay), the window saying it waits for the others; a
# match with no window (--no-window) waits and plays with none, on Live::Headless.
require "json"

module VBlankWindow
  # +arguments+ is one JSON object, written by vblank run (CLI#play_built_in_helper): the window's
  # title, size, menu and buttons, where save states are kept, where the game is written, the
  # helper's pid and the descriptor it says what it is doing on (both nil when the game is written
  # already), whether to turn YJIT on, the match (CLI#match_launch, nil for none) and the options
  # VBlankScript.play takes.
  #
  # However this ends (the game played, a refusal, the window closed during the build, an error,
  # Ctrl-C), the helper is ended and reaped: a helper left running holds the whole build.
  def self.main(arguments)
    $stdout.sync = true # a line for the person (where to join a match) is read as it is said, by a person or a program
    launch = JSON.parse(arguments.fetch(0))
    options = launch.fetch("options").transform_keys(&:to_sym)
    match = launch["match"]&.transform_keys(&:to_sym)
    if launch["helper_pid"]
      watch = VBlank::Live::BuildWatch.new(IO.for_fd(launch.fetch("build_fd")), pid: launch.fetch("helper_pid"),
                                                                                title: launch.fetch("title"))
    end
    VBlankScript.turn_on_yjit if launch.fetch("yjit")
    window = open_window(launch, options) unless match && !match[:window]
    if watch
      outcome = watch.watch(window || VBlank::Live::BuildWatch::Unseen.new, refusal_frames: window ? options[:pictures] : 0,
                                                                            terminal: $stderr)
      exit 1 if outcome.refusal
      return if outcome.stopped?
    end

    written = VBlank::IR::Backends::Ruby::WrittenGame.read(launch.fetch("written_path"))
    network = begin_match(written, match, window) if match
    return play_without_window(written, options, match, network) unless window

    played = window
    window = nil # VBlankScript.play closes it
    VBlankScript.play(written, options.merge(state_folder: launch["state_folder"]), window: played, network: network)
  rescue VBlank::Live::SDL::Missing, VBlank::Live::SDL::Failed, ArgumentError => e
    warn e.message
    exit 1
  rescue Interrupt
    warn "You stopped the wait, so no match was played." if match && network.nil?
    exit 130
  rescue *match_failures => e
    warn VBlank::Live::MatchPlay.failure_message(e)
    exit 1
  ensure
    window&.close
    watch&.stop_helper
  end

  # What stops a match, when this process plays one; none otherwise, as Live::MatchPlay is not loaded.
  def self.match_failures = defined?(VBlank::Live::MatchPlay) ? [VBlank::Live::MatchPlay::Refused, *VBlank::Live::MatchPlay::FAILURES] : []

  # The window, at the console's size until the game is known.
  # A shell's window offers save states only once its game plays (VBlankScript.play), so it opens
  # with none.
  def self.open_window(launch, options)
    VBlank::Live::SDL.new(title: launch.fetch("title"), scale: options[:scale], width: launch.fetch("width"),
                          height: launch.fetch("height"), pixel_size: launch.fetch("pixel_size"), menu: launch.fetch("menu"),
                          settings_file: options[:"settings-file"] || :usual, config_dir: options[:"config-dir"],
                          state_folder_name: (launch["state_folder"] unless launch["shell"]),
                          buttons: launch.fetch("buttons").map(&:to_sym))
  end

  # The match +written+ plays in, hosted or joined as +match+ says, and begun: everybody is in. The
  # window, where there is one, says it waits while it does.
  def self.begin_match(written, match, window)
    facts = written.match or raise ArgumentError, "#{written.title} was written with nothing a match needs. Run it again."
    VBlank::Network::Refused.console_titles = match.fetch(:console_titles) # a refusal names the consoles
    play = VBlank::Live::MatchPlay.new(VBlank::Live::MatchPlay.facts_from_plain(facts), **match.except(:window, :keys, :console_titles))
    lockstep = play.open
    puts play.waiting_line if play.waiting_line
    begin_while_waiting(lockstep, window, play.waiting_line || "Joining the match")
    puts "The match has begun. You are player #{lockstep.player}."
    lockstep
  end

  # Lockstep#begin_match, which waits on the others; a window keeps showing +line+ meanwhile, and a
  # window closed while it waits stops the wait.
  def self.begin_while_waiting(lockstep, window, line)
    return lockstep.begin_match unless window

    began = Thread.new { lockstep.begin_match }
    until began.join(VBlank::Live::BuildWatch::FRAME_SECONDS)
      window.show_waiting([line])
      raise Interrupt if window.stop?
    end
    began.value
  end

  # A match played with no window: this computer's player holds the keys +match+ names, every
  # notice is said as it comes, and no save memory is kept, as a window keeps none in a match.
  def self.play_without_window(written, options, match, network)
    game = written.live_game
    device = VBlank::Live::Headless.new(frames: options[:pictures], buttons: match[:keys].map(&:to_sym),
                                        on_notice: ->(words) { puts words }, keeps_save: false)
    rate = VBlank::Live::Session.new(game: game, uncapped: options[:uncapped], stop_after_passes: options[:pictures],
                                     network: network).play(device)
    VBlankScript.say_rate(written.title, rate, game.frame_seconds, lateness: false)
    VBlank::Live::MatchPlay.summary_lines(network, events_said: true).each { |line| puts line }
  end
end

VBlankWindow.main(ARGV) if $PROGRAM_NAME == __FILE__
