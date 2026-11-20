# frozen_string_literal: true

# THE LAST PART OF A GAME WRITTEN OUT AS ONE RUBY FILE (Ruby#script): what runs when somebody
# plays it with `ruby game-ruby.rb`. Everything above it in that file — the game as Ruby in
# VBlankScript::SOURCE, its title and whether it has a menu, and the window, the menu and the
# session it plays in — was copied in when it was built, so it needs no vblank gem. The library
# itself never loads it, but the window vblank run opens does (rg_window_main.rb), and plays the
# game a helper process wrote through VBlankScript.play, as a script plays its own. What vblank
# run says as it plays is said here in the same words.
require "json"
require "optparse"

module VBlankScript
  # Plays the game in a window until the player stops it, and says how fast it went, as vblank run
  # does. The options are a few of vblank run's.
  def self.main(arguments)
    options = {}
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby #{File.basename($PROGRAM_NAME)} [options]"
      parser.on("--scale N", Integer, "The window is N times the size of the screen. Default: the size in the settings file.")
      parser.on("--pictures N", Integer, "Stop after the window has shown N pictures.")
      parser.on("--uncapped", "Do not wait for the end of each frame, to measure the speed.")
      parser.on("--[no-]collect-garbage", "Collect Ruby's garbage once the game has set itself up. Default: on.")
      parser.on("--settings-file FILE", "Read and write the window's settings in FILE only.")
      parser.on("--config-dir DIR", "Keep the window's settings files in DIR.")
      parser.on("--record-sound FILE", "Keep the sound the game makes, and write it to FILE (a .wav) when the play stops.")
      if SHELL_FACTS
        parser.on("--pack-folder DIR", "Keep the game's data pack in DIR.")
        parser.on("--unpack-workers N", Integer, "Make the data pack on N cores. Default: every core.")
      end
    end.parse!(arguments, into: options)
    %i[scale pictures unpack-workers].each do |name|
      raise OptionParser::InvalidArgument, "--#{name} must be a whole number above 0" if options[name]&.<(1)
    end
    turn_on_yjit
    play(VBlank::IR::Backends::Ruby::WrittenGame.of(self), options)
  rescue OptionParser::ParseError => e
    warn e.message
    exit 1
  end

  # YJIT turns the Ruby that runs most often into machine code as the game plays, which plays it
  # several times faster. A Ruby built without it plays the game slower, and one started with
  # ZJIT, the other of Ruby's compilers, keeps it.
  def self.turn_on_yjit
    RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled? && !zjit_on?
  end

  def self.zjit_on? = defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?

  # Which of Ruby's compilers turns the game's Ruby into machine code as it plays.
  def self.jit_in_use
    return "YJIT" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
    return "ZJIT" if zjit_on?

    "no JIT"
  end

  # Plays +written+ (an IR::Backends::Ruby::WrittenGame) until the player stops it, and says how fast
  # it went. +window+ is one opened already, before the game was known (rg_window_main.rb), which is
  # fitted to the game here; nil opens one for it. The window is closed however the play ends.
  # +options+ are #main's, by its names, and :state_folder, where save states and the game's save
  # memory are kept (Live::StateSlots.folder_name), the written game's own when left out.
  # +network+ is the match it plays in (a Network::Lockstep, begun), nil for none: only vblank run's
  # window plays one (Live::MatchPlay), a written-out script never does.
  #
  # A SHELL'S WINDOW offers save states only while its game plays, never its menu or its unpacking
  # (Original::Shell::Part#keeps_states?), so a window opened for one is opened with none.
  def self.play(written, options, window: nil, network: nil)
    game = written.live_game
    states = options.fetch(:state_folder, written.state_folder)
    if window
      problems = window.fit_game(width: game.width, height: game.height, pixel_size: game.pixel_size,
                                 game_controls: game.controls, buttons: game.buttons)
    else
      window = VBlank::Live::SDL.new(title: written.title, scale: options[:scale], width: game.width, height: game.height,
                                     pixel_size: game.pixel_size, menu: written.menu,
                                     settings_file: options[:"settings-file"] || :usual, config_dir: options[:"config-dir"],
                                     state_folder_name: (states unless written.shell), game_controls: game.controls,
                                     buttons: game.buttons)
      problems = window.settings_problems_message
    end
    warn problems if problems
    puts "Playing #{written.title} for the #{written.console_title} in Ruby #{RUBY_VERSION} with #{jit_in_use}. " \
         "#{'Press F1 or ` for the menu. ' if written.menu}Press P to pause. Hold Tab to play fast. Press Escape to stop."
    recording = VBlank::Live::Recording.new(window, frame_seconds: game.frame_seconds) if options[:"record-sound"]
    play_game = lambda do |playing|
      window.offer_states(states) if written.shell && states
      VBlank::Live::Session.new(game: playing, uncapped: options[:uncapped], stop_after_passes: options[:pictures],
                                collect_garbage: options.fetch(:"collect-garbage", true), network: network)
                           .play(recording || window)
    ensure
      window.withdraw_states if written.shell
    end
    rate = written.shell ? play_shell(written, window, options, play_game) : play_game.call(game)
    say_rate(written.title, rate, game.frame_seconds) if rate
    VBlank::Live::MatchPlay.summary_lines(network).each { |line| puts line } if network
  rescue VBlank::Live::SDL::Missing, VBlank::Live::SDL::Failed, VBlank::IR::ProgramError => e
    warn e.message
    exit 1
  ensure
    window&.close
    write_recorded_sound(recording, options[:"record-sound"]) if recording # a play that went wrong is the one most worth hearing
  end

  # What +recording+ kept, written to +path+, as vblank run says it.
  def self.write_recorded_sound(recording, path)
    sound = recording.sound
    return puts("The game made no sound, so VBlank wrote no #{path}.") unless sound

    sound.write_wav(path)
    puts "The sound the game made is in #{path}."
  end

  # How fast +rate+ went, once the play stops, as vblank run says it.
  # +lateness+ false leaves out which passes ran late, for a play on a clock that only moves as it
  # plays (a match with no window).
  def self.say_rate(title, rate, frame_seconds, lateness: true)
    if rate.passes_after_setup.positive?
      puts rate.words(console_frame_seconds: frame_seconds)
      puts rate.lateness.words if rate.lateness && lateness
    end
    return unless rate.stopped_itself?

    puts "#{title} stopped itself after #{rate.passes == 1 ? '1 frame' : "#{rate.passes} frames"}. " \
         "Its last picture stayed in the window."
  end

  # A game built as a shell (Live::Shell): the game from its kept pack, or its menu until the player
  # loads a copy. Gives back how fast the game went, or nil when the player stopped before it played.
  # An unpacking split in pieces plays on --unpack-workers cores, every core when not given.
  def self.play_shell(written, window, options, play_game)
    shell = VBlank::Live::Shell.new(facts: VBlank::Original::ShellFacts.from_plain(JSON.parse(written.shell.facts)),
                                    game: written.source, menu: written.shell.menu, unpackings: written.shell.unpackings,
                                    workers: unpack_workers(options[:"unpack-workers"]),
                                    worker_programs: written.shell.worker_programs)
    folder = options[:"pack-folder"] || window.folder_for(shell.folder) or
      raise VBlank::Live::SDL::Failed, "#{written.title} cannot make the folder to keep its data pack in. Give one with --pack-folder."
    puts "Playing #{written.title} as a shell. Its data pack is kept in #{folder}."
    shell.play(window, folder_path: folder, choose_copy: shell.copy_chooser(window), open_settings: -> { window.open_menu },
                       refused: lambda { |words|
                         warn words
                         window.notice(words)
                       }, kept_pack_refused: ->(words) { warn words }, play_game: play_game)
  end

  # How many cores an unpacking in pieces plays on: +asked+, or every core, and never more than
  # there are, as Original::PiecedUnpacking.worker_count says for a shell played by vblank run
  # in one process.
  def self.unpack_workers(asked)
    require "etc"
    [asked || Etc.nprocessors, Etc.nprocessors].min
  end
end

VBlankScript.main(ARGV) if $PROGRAM_NAME == __FILE__
