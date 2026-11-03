# frozen_string_literal: true

require "thor"
require_relative "../vblank"

module VBlank
  # Thor is required here and in bin/vblank only — never by the library — so
  # building a ROM in code or in a test does not depend on it.
  #
  # THE HELP IS WRITTEN OUT BY HAND, one page a command, beside the options it explains. Thor can
  # make a help page from each option's own line, and what it makes is one line an option, as
  # wide as the longest, with every option of every format in one list and the explaining in a
  # paragraph after. Nobody reads that. A page here is what a person wants first, the commands
  # they came to type, and then the options in groups, short, in 80 columns. The class refuses to
  # load if a page leaves out an option its command takes (#refuse_undocumented_options!), so a
  # new option cannot go unexplained.
  class CLI < Thor
    # Without this, Thor reports a failed command but still exits 0.
    def self.exit_on_failure?
      true
    end

    # How `compare` ends. It ends with 1 when the two cartridges drift, the way `diff` does
    # when two files differ. Thor ends every command it stops with 1 as well, which would
    # leave another program unable to tell a drift from a file name spelled wrong. So a
    # `compare` that could not be made ends with 2, and every other command keeps Thor's 1.
    DRIFTED = 1
    NOT_COMPARED = 2

    # What --console takes: every console a game can name.
    CONSOLES = VBlank::Console::DESCRIPTIONS.keys.map(&:to_s).freeze

    # The words that ask for help, wherever on the line they are.
    HELP_FLAGS = %w[--help -h].freeze

    # Each command's help page, by the command's name: filled as each command is declared
    # below, and frozen after the last.
    HELP_PAGES = {}

    def self.help_page(command, text)
      HELP_PAGES[command] = text.freeze
    end

    # A command whose name Thor keeps for itself, and the method that does it: Thor will not let
    # a command be a method called `run`, so `vblank run` is mapped onto one of another name.
    COMMAND_METHODS = { "run" => "run_game" }.freeze
    map COMMAND_METHODS.transform_values(&:to_sym)

    # The name of the method that does the command a person types as +name+.
    def self.method_for(name) = COMMAND_METHODS.fetch(name, name)

    # Thor's command for the command a person types as +name+.
    def self.command_named(name) = all_commands.fetch(method_for(name))

    def self.start(given_args = ARGV, config = {})
      refuse_play!(given_args)
      args = route_help_flags(given_args)
      args = checked_args(args) unless args.first == "help"
      super(args, config.merge(debug: true))
    rescue Thor::Error => e
      raise if ENV["THOR_DEBUG"] == "1"

      # Thor raises exactly this class, and none of its kinds, when a command is given too few
      # words or too many; its kinds (a value an option does not take) say something worth keeping.
      warn(e.instance_of?(Thor::InvocationError) ? wrong_words_message(args) : e.message)
      exit(given_args.first == "compare" ? NOT_COMPARED : 1)
    end

    # THERE IS NO `vblank play`. It played a script or a tape on the cartridge, in the emulator, while
    # `vblank run` played the game as Ruby with a person at the controls. Nothing in the two names
    # said which ran the game how, and a bot was run on the emulator by somebody sure it was Ruby.
    # Now `vblank run` plays a game either way, so the old name is refused with the line to write
    # instead, as is `vblank help play`.
    def self.refuse_play!(args)
      words = args.first == "help" ? args.drop(1) : args
      return unless words.first == "play"

      given = words.drop(1).reject { |word| HELP_FLAGS.include?(word) }
      said = "There is no vblank play now. One command plays a game: vblank run. With --tape or --script, " \
             "nobody is at the controls."
      if given.any? { |word| cartridge_word?(word) }
        raise Thor::Error, "#{said}\n\n#{NO_CARTRIDGE}"
      end

      raise Thor::Error, "#{said} Write:\n  #{['vblank', 'run', *given].join(' ')}" unless given.empty?

      raise Thor::Error, "#{said} Run vblank run --help to see how."
    end

    # A word of a `vblank play` line that is about a cartridge: a cartridge file, a save, or the emulator.
    def self.cartridge_word?(word)
      return true if %w[--save --write-save emulator --on=emulator].include?(word) || word.start_with?("--save=", "--write-save=")

      VBlank::Console.kits.any? { |kit| word.end_with?(kit.description.extension) }
    end

    # Why `vblank run` takes no cartridge, and how a console is reached instead.
    NO_CARTRIDGE = <<~TEXT.chomp
      vblank run runs the game file itself, as Ruby unless --on says another way.
      It does not play a cartridge. So it takes no cartridge file, no save, and
      no --on emulator. To play a tape on a console, write the tape for an
      emulator, then open that file in the emulator:
        vblank run game.rb --tape t.tape --write-mgba-script t.lua   for mGBA
        vblank run game.rb --tape t.tape --write-bk2 t.bk2           for BizHawk
    TEXT

    # `vblank`, `vblank --help` and `vblank build --help` become `vblank help` and
    # `vblank help build`. Thor would take the --help after a command for an argument, and
    # build would go looking for a game file of that name. A word after `--` is never a flag.
    def self.route_help_flags(args)
      asked = args.take_while { |word| word != "--" }
      return ["help"] if asked.empty? || HELP_FLAGS.include?(asked.first)
      return ["help", asked.first] if asked.intersect?(HELP_FLAGS)

      args
    end

    # The list of commands: `vblank help`, and `vblank help help`.
    def self.help(_shell, _subcommand = false)
      $stdout.print COMMAND_LIST
    end

    # One command's page: `vblank help build`.
    def self.command_help(_shell, name)
      return help(nil) if name == "help"
      raise Thor::Error, no_command_message(name) unless HELP_PAGES.key?(name)

      $stdout.print HELP_PAGES.fetch(name)
    end

    def self.no_command_message(name)
      meant = DidYouMean::SpellChecker.new(dictionary: HELP_PAGES.keys).correct(name).first
      "There is no command \"#{name}\".#{" Did you mean #{meant}?" if meant} The commands are: " \
        "#{HELP_PAGES.keys.join(', ')}. Run vblank --help to see what each one does."
    end

    # What a command and its options say, checked before Thor sees them, and given back with each
    # option's value joined to it (-o out.gba becomes --output=out.gba). Thor hands an option it
    # does not know to the command as a word, so a misspelled --format became a file name, or was
    # dropped without a word and a cartridge built where a web page was asked for; it takes an
    # option given no value for its own name, so -o alone wrote a file called "output"; and it
    # takes a value that starts with a dash for an option.
    def self.checked_args(args)
      name = args.first
      raise Thor::Error, no_command_message(name) unless HELP_PAGES.key?(name)

      options = options_by_switch(command_named(name))
      words = args.drop(1)
      checked = [name]
      until words.empty?
        word = words.shift
        if word == "--"
          checked.push(word, *words)
          break
        end
        unless switch?(word)
          checked << word
          next
        end

        switch, value = word.split("=", 2)
        switch = switch.tr("_", "-")
        option = options[switch] or refuse_unknown_option!(args, word, switch, options.keys)
        if value || option.boolean? || option.type == :array
          checked << word
          next
        end

        given = words.first
        if given.nil? || options.key?(given.split("=", 2).first)
          raise Thor::Error, "#{switch} needs a value. Write it as: #{switch} #{option.banner}. " \
                             "Run vblank #{name} --help to see the options."
        end
        checked << "#{option.switch_name}=#{words.shift}"
      end
      checked
    end

    # A word written the way an option is: one or two dashes, then a letter.
    def self.switch?(word) = word.match?(/\A--?[a-zA-Z]/)

    # Every way a command's options can be written, and the option each one is: --format, -o,
    # and --no-stats and --skip-stats for an option that is on or off.
    def self.options_by_switch(command)
      command.options.values.each_with_object({}) do |option, found|
        plain = option.switch_name
        found[plain] = option
        option.aliases.each { |short| found[short] = option }
        next unless option.boolean?

        found["--no-#{plain.delete_prefix('--')}"] = option
        found["--skip-#{plain.delete_prefix('--')}"] = option
      end
    end

    # Other names people reach for, for what a build makes, and the option that says it.
    NATIVE = ["--format=native", "a program for this computer"].freeze
    WEB = ["--format=web", "a web page"].freeze
    CARTRIDGE = [nil, "a cartridge for each console the game names"].freeze
    FORMAT_FLAGS = {
      "--native" => NATIVE, "--desktop" => NATIVE, "--web" => WEB, "--html" => WEB,
      "--cartridge" => CARTRIDGE, "--rom" => CARTRIDGE,
      # --gba, --gbc and one for every other console: its cartridge alone.
      **VBlank::Console.kits.to_h { |kit| ["--#{kit.name}", ["--console=#{kit.name}", "the #{kit.title}'s cartridge alone"]] }
    }.freeze

    def self.refuse_unknown_option!(args, word, switch, known)
      name = args.first
      said = "vblank #{name} has no option #{switch}."
      raise Thor::Error, "#{said} #{switch} is for a cartridge.\n\n#{NO_CARTRIDGE}" if name == "run" && cartridge_word?(switch)
      if name == "build" && FORMAT_FLAGS.key?(switch)
        option, what = FORMAT_FLAGS.fetch(switch)
        line = ["vblank", *args].filter_map { |part| part == word ? option : part }.join(" ")
        raise Thor::Error, "#{said} To build #{what}, write:\n  #{line}"
      end

      meant = DidYouMean::SpellChecker.new(dictionary: known).correct(switch).first
      said += " Did you mean #{meant}?" if meant
      said += " To choose what is built, use --format game, native or web." if name == "build"
      raise Thor::Error, "#{said} Run vblank #{name} --help to see the options."
    end

    # A command given too few words, or too many: how it is written, in place of Thor's
    # "was called with arguments". The usual way to get there is an option that takes several
    # words (--set, --keys) written before the game file, which it then takes as one of them, so
    # that is said, with the line put right.
    def self.wrong_words_message(args)
      name = args.first
      command = command_named(name)
      wanted = command.usage.split.drop(1)
      plain = wanted.size == 1 ? "one #{wanted.first}" : wanted.join(" and ")
      said = "vblank #{name} takes #{plain}. Write it as: vblank #{command.usage} [options]."
      taken = words_taken_by_lists(args, command, wanted.size)
      if taken
        list, words = taken
        line = ["vblank", name, *words, *(args.drop(1) - words)].join(" ")
        said = "#{list} took #{words.join(' ')}, since it takes every word after it. Put #{plain} first:\n  #{line}"
      end
      "#{said}\nRun vblank #{name} --help to see more."
    end

    # The option that takes several words and the words it took that were meant for the command,
    # when that is what happened; nil otherwise.
    def self.words_taken_by_lists(args, command, wanted)
      lists = command.options.values.select { |option| option.type == :array }.map(&:switch_name)
      at = args.index { |word| lists.include?(word) } or return nil
      before = args[1...at].reject { |word| switch?(word) }
      missing = wanted - before.size
      run = args.drop(at + 1).take_while { |word| !switch?(word) }
      return nil unless missing.positive? && run.size > missing

      [args[at], run.last(missing)]
    end

    # A page that leaves out an option its command takes stops the program loading, so the
    # tests catch it the first time anything runs the command. An option counts as explained
    # where its whole name is on the page: --save is not explained by --save-file.
    def self.refuse_undocumented_options!
      HELP_PAGES.each do |name, page|
        missing = command_named(name).options.values.map(&:switch_name).reject do |switch|
          page.match?(/(?<![\w-])#{Regexp.escape(switch)}(?![\w-])/)
        end
        raise "The help page for vblank #{name} does not explain #{missing.join(', ')}." unless missing.empty?
      end
      # help and tree are Thor's own: help prints these pages, and tree is refused as a command
      # that is not there.
      undescribed = all_commands.keys - HELP_PAGES.keys.map { |name| method_for(name) } - %w[help tree]
      raise "These commands have no help page: #{undescribed.join(', ')}." unless undescribed.empty?
    end

    COMMAND_LIST = <<~TEXT
      Usage: vblank COMMAND [options]

      Make a game:
        vblank new NAME              Write a starter game to NAME.rb.
        vblank build GAME_FILE       Build a cartridge for each console, a
                                       program for this computer, or a web page.
        vblank preview GAME_FILE     Play the game in a browser. Reload the page
                                       to build it again.
        vblank run GAME_FILE         Play the game in a window, as Ruby with
                                       YJIT. With --tape or --script, nobody is
                                       at the controls.

      Check a game:
        vblank profile GAME_FILE     Run the game and report what it costs.
        vblank compare FIRST SECOND  Play two games on the same presses and say
                                       where their screens differ.
        vblank inspect ROM_FILE      Print a .gba's header and first instructions.

      Run vblank COMMAND --help to see a command's options.
    TEXT

    # THE CONSOLES, as the help pages name them, from the kits (Console::KITS): every console a game
    # can be for is offered wherever a command takes --console, with nothing to add here for one.
    CONSOLE_NAMES = VBlank::Console.kits.map { |kit| kit.name.to_s }.freeze
    # "gba, gbc or snes"
    CONSOLE_CHOICES = "#{CONSOLE_NAMES[0...-1].join(', ')} or #{CONSOLE_NAMES.last}".freeze
    # A line for each console: its name, the console, and the ending of its cartridge's file.
    CONSOLE_LINES = VBlank::Console.kits.map do |kit|
      "  #{kit.name.to_s.ljust(6)}the #{kit.title}, a #{kit.description.extension}"
    end.join("\n").freeze
    # The consoles whose cartridges `compare` can line up side by side
    # (Console::Kit#compared_side_by_side?), and how a sentence says them.
    COMPARED = VBlank::Console.kits.select(&:compared_side_by_side?).freeze
    COMPARED_TITLES = COMPARED.map(&:title).join(" and ").freeze
    COMPARED_NAMES = COMPARED.map(&:name).freeze

    # The words for --set, the same on every command that takes it.
    SET = "--set NAME=VALUE ...     Values for the game's `setting` lines."

    # The words for the buttons --keys holds.
    BUTTONS = VBlank::IR::Buttons::NAMES.join(" ")

    # The words for what to press, the same on `run` and `compare`.
    PRESSES = <<~TEXT.chomp
      --script PATH            The script file.
      --playthrough NAME       Which playthrough, when the script has several.
      --tape PATH              Play this tape, in place of a script.
    TEXT

    desc "build GAME_FILE", "Build a cartridge for each console, a program for this computer, or a web page"
    help_page "build", <<~TEXT
      Usage: vblank build GAME_FILE [--format game|native|web] [options]

      Build the game in GAME_FILE, a Ruby file with this in it:

        VBlank.game "NAME", consoles: %i[gba gbc] do
          # ...the game...
        end

      consoles: names the consoles the game is for. The build makes a cartridge
      for each, beside GAME_FILE and named from the game's title:

      #{CONSOLE_LINES}

      If one console's cartridge cannot be built, the build still writes the
      others, says why, and ends as a failure.

      A game for more than one console must lay itself out from `screen_width`
      and `screen_height`, since the screens are not the same size. The build
      says what each console shows differently and what it cannot do.

      Examples:
        vblank build game.rb                    a .gba cartridge, and a .gbc if
                                                  the game is for the Color too
        vblank build game.rb --console gbc      the Game Boy Color cartridge alone
        vblank build game.rb --format=native    a program for this computer
        vblank build game.rb --format=web       a web page that plays the game
        vblank build game.rb --format=ruby      one Ruby file that plays the game
        vblank build game.rb -o roms/pong.gba   a cartridge, written to roms/
        vblank build game.rb --set floors=3     with `setting :floors` as 3

      Put GAME_FILE before --set and --keys: they take every word after them.

      Options:
        -o, --output PATH        Where to write what is built. PATH is one file,
                                 so a game for two consoles needs --console too.
        --format FORMAT          game, ir, native, ruby or web. Default: game.
        --console NAME           #{CONSOLE_CHOICES}: build that console's
                                 cartridge alone. Default: one for each console
                                 the game names. With --format native, web or
                                 ruby: the console to make the game as.
                                 Default: the first one the game names.
        --variant NAME           The chip on the cartridge, such as superfx
                                 for a Super Nintendo cartridge with a Super
                                 FX 2, or none. Default: what the game names
                                 in variants:. A game for more than one
                                 console needs --console too.
        #{SET}

      Measuring (see vblank profile --help):
        --stats                  Say how far packing shrank the pictures and
                                 sounds, and what is kept in quick memory. The
                                 Advance's cartridge only.
        --profile                Run the cartridge and report what it costs.
        --scene NAME             Profile this scene. Turns on --profile.
        --keys BUTTON ...        Profile with these buttons held. Turns on
                                 --profile. The buttons are:
                                 #{BUTTONS}

      --format native, a program for this computer:
        --target COMPUTER        windows, linux or linux-arm. Default: this
                                 computer. Not tested on those systems.
        --strip                  Leave the debugging data out. The file is
                                 smaller, and a crash report says much less.
        Needs zig 0.17. Run the program with --help to see its keys and options.

      --format web, a web page:
        --js KIND                page, module or script. Default: page.
                                 page: one HTML file that plays the game.
                                 module: an ES module that exports createGame.
                                 script: a script that puts createGame on
                                 window.VBlank.
        --global NAME            With --js script: its name on window.VBlank.
                                 Default: the file's name.
        --template FILE          An .html.erb file with <%= game %> in it, to
                                 make the page from.
        --data WHERE             inline or separate. Default: inline.
                                 separate: the game's big tables go in a .data
                                 file beside the page, which must be served.

      --format ruby, one Ruby file: the game as Ruby, with the window that vblank
        run plays it in. To play it, run `ruby` with the file's name. It needs
        Ruby, the gem `fiddle` and SDL3. It does not need VBlank, the game's
        files or its pictures, so you can copy it to another computer.

      --format ir prints the game's IR as Ruby, for work on VBlank itself. It is
        the IR that the Advance's cartridge is made from, so the game must name
        gba in consoles:.

      A program, a web page and a Ruby file are made from the game as one
      console plays it, with that console's screen.
    TEXT
    option :output, aliases: "-o", banner: "PATH"
    option :format, banner: "NAME", default: "game"
    option :console, banner: "NAME", enum: CONSOLES
    option :variant, banner: "NAME"
    option :profile, type: :boolean, default: false
    option :stats, type: :boolean, default: false
    option :scene, banner: "NAME"
    option :keys, type: :array, banner: "BUTTON", default: []
    option :set, type: :array, banner: "NAME=VALUE", default: []
    option :target, banner: "COMPUTER"
    option :strip, type: :boolean, default: false
    option :template, banner: "FILE"
    option :js, default: "page", enum: %w[page module script]
    option :global, banner: "NAME"
    option :data, default: "inline", enum: %w[inline separate]
    def build(game_file)
      refuse_web_options_out_of_place!
      case options[:format]
      when "game" then build_cartridges(game_file)
      when "ir" then build_ir(game_file)
      when "native" then build_native(game_file)
      when "web" then build_web(game_file)
      when "ruby" then build_ruby(game_file)
      when "gbc"
        raise Thor::Error, "There is no --format=gbc now. To build a Game Boy Color cartridge, use --console gbc."
      else
        raise Thor::Error, "#{options[:format].inspect} is not a build format. The formats are: game, ir, native, " \
                           "ruby, web."
      end
    rescue ArgumentError, VBlank::BuildError => e
      # A setting the game does not ask for, or one it cannot read, or a build that stopped (the
      # guardrails' reasons are printed already; a lowering's are the message): say why, not a
      # backtrace.
      raise Thor::Error, e.message
    end

    desc "profile GAME_FILE", "Run the game and report what it costs"
    help_page "profile", <<~TEXT
      Usage: vblank profile GAME_FILE [options]

      Build the game in GAME_FILE, run the cartridge in an emulator, and report
      two things: what the build made (how big each routine is, and which ones
      fit in the console's quick memory), and where the frames went while it ran
      (the frame rate, and how much of each frame was left over).

      A game for one console is profiled on that console. A game for both needs
      --console. The Game Boy Color's report says where its frames went, by
      routine, the frame rate it played at, and how much of the time it slept.

      Examples:
        vblank profile game.rb
        vblank profile game.rb --keys right a     with right and A held
        vblank profile game.rb --scene level      in the scene named :level
        vblank profile game.rb --from boss.ss1    from an emulator save state
        vblank profile game.rb --console gbc      its Game Boy Color cartridge

      Options:
        --console NAME           #{CONSOLE_CHOICES}: which console's cartridge
                                 to run. A game for several consoles needs it.
        --keys BUTTON ...        Hold these buttons for the whole run. The
                                 buttons are:
                                 #{BUTTONS}
        --press BUTTON ...       Press these buttons as the measuring starts, for
                                 a button the game reads as it goes down.
        --scene NAME             Hold the game in this scene, and measure that.
        --from PATH              Start from an emulator save state, made by
                                 playing to that moment once. The state must come
                                 from this same build of the game.
        --frames N               Measure this many frames. Default: #{VBlank::Diagnostics::Profiler::FRAMES}.
        --settle N               Run this many frames first, so the game is past
                                 its start. With --scene, the frames the scene
                                 runs first. 0 from power-on measures the start.
                                 Default: #{VBlank::Diagnostics::Profiler::SETTLE}.
        --format FORMAT          human or json. Default: human. json is the
                                 same numbers, to compare two builds.
        #{SET}
    TEXT
    option :format, banner: "NAME", default: "human"
    option :console, banner: "NAME", enum: CONSOLES
    option :frames, type: :numeric, banner: "N", default: VBlank::Diagnostics::Profiler::FRAMES
    option :settle, type: :numeric, banner: "N", default: VBlank::Diagnostics::Profiler::SETTLE
    option :keys, type: :array, banner: "BUTTON", default: []
    option :press, type: :array, banner: "BUTTON", default: []
    option :scene, banner: "NAME"
    option :from, banner: "PATH"
    option :set, type: :array, banner: "NAME=VALUE", default: []
    def profile(game_file)
      format = { "human" => :human, "json" => :json }[options[:format]] or
        raise Thor::Error, "#{options[:format].inspect} is not a profile format. The formats are: human, json."
      game = load_game(game_file)
      # Built the same way `build` builds it — measured placement included — so this reports on
      # the cartridge somebody would actually ship, not a differently-placed one.
      game.build_rom(settings: given_settings, console: console_to_run(game, "profile"))
          .profile(format: format, frames: options[:frames], settle: options[:settle], scene: options[:scene],
                   from: options[:from], keys: held_buttons || [], press: buttons_named(options[:press]))
    rescue ArgumentError, VBlank::BuildError => e
      raise Thor::Error, e.message
    end

    # The options `run` and `compare` both take: what says which buttons to press, and the
    # settings and the console a game file is built with.
    def self.options_for_playing
      option :console, banner: "NAME", enum: CONSOLES
      option :script, banner: "PATH"
      option :playthrough, banner: "NAME"
      option :tape, banner: "PATH"
      option :set, type: :array, banner: "NAME=VALUE", default: []
    end

    desc "compare FIRST SECOND", "Play two games on the same presses and say where they differ"
    help_page "compare", <<~TEXT
      Usage: vblank compare FIRST SECOND [options]

      Play two cartridges on the same presses, and say the first frame on which
      their screens differ. Each is a game file (a .rb, built first) or a .gba.
      A comparison compares #{COMPARED_TITLES} cartridges only, so a game file
      for several consoles needs --console #{COMPARED_NAMES.join(" or ")}.

      Exit status: 0 the same, 1 different, 2 not compared (a file that is not
      there, a script that gave up).

      Examples:
        vblank compare old.gba new.gba --tape walk.tape
        vblank compare game.rb theirs.gba --script walk.rb --carrying-on
        vblank compare a.gba b.gba --tape walk.tape --ignoring-frames 1..120

      What to press, as for vblank run:
        #{PRESSES.gsub("\n", "\n  ")}
        --console NAME           #{COMPARED_NAMES.join(" or ")}: which console's cartridge to
                                 build a game file for several consoles as.
        --same WHICH             tape or script. Default: tape.
                                 tape: both get the same presses on the same
                                 frames.
                                 script: the script plays each one by itself,
                                 and the two are compared at each moment.
        --frames-apart N         With --same script: how many frames apart the
                                 two can reach a moment.

      Where the two start:
        --save PATH              Start both from this save file.
        --lead-ins FIRST SECOND  A playthrough for each to play first and not
                                 count, or - for none. Needs --script.

      What counts as different (with none of these, one pixel is a difference):
        --share-may-differ SHARE
                                 The share of the pixels that can differ, 0 to 1.
        --frames-in-a-row N      How many frames in a row must differ.
        --ignoring-rectangles X,Y,WIDTH,HEIGHT ...
                                 Parts of the screen to leave out.
        --ignoring-frames RANGE ...
                                 Frames to leave out: 1..120, 900.., or moments
                                 by name, title..in_the_world.

      What is compared:
        --readings NAME ...      Variables to compare as well as the screen. NAME
                                 reads NAME from both. NAME=VARIABLE reads
                                 VARIABLE from both. NAME=FIRST,SECOND reads a
                                 different one from each. Only a game file has
                                 variable names; a .gba has none.
        --comparing WHAT         picture or readings: compare only that one.
                                 Default: the picture, and any --readings.
        --carrying-on            Go on past the first difference and list them all.
        --reports-in DIR         Write a folder to DIR for each difference: both
                                 screens, where they differ, and a tape that plays
                                 a cartridge to that frame.
        #{SET}
    TEXT
    options_for_playing
    option :share_may_differ, type: :numeric, banner: "SHARE"
    option :frames_in_a_row, type: :numeric, banner: "N"
    option :ignoring_rectangles, type: :array, banner: "X,Y,WIDTH,HEIGHT"
    option :ignoring_frames, type: :array, banner: "RANGE"
    option :readings, type: :array, banner: "NAME[=VARIABLE[,VARIABLE]]"
    option :comparing, type: :array, banner: "WHAT", enum: %w[picture readings]
    option :carrying_on, type: :boolean
    option :same, banner: "WHICH", enum: %w[tape script]
    option :frames_apart, type: :numeric, banner: "N"
    option :save, banner: "PATH"
    option :lead_ins, type: :array, banner: "NAME"
    option :reports_in, banner: "DIR"
    def compare(first_file, second_file)
      # A comparison lines screens up at one size, so only the consoles whose kits say it can are offered.
      result = with_playthroughs_command_line("compare", offered: COMPARED_NAMES) do |command|
        command.compare(first_file, second_file)
      end
      exit DRIFTED if result.drift?
    end

    desc "preview GAME_FILE", "Play the game in a browser, built again on every reload"
    help_page "preview", <<~TEXT
      Usage: vblank preview GAME_FILE [options]

      The same as `vblank run GAME_FILE --browser`. Serve the game in GAME_FILE as
      a web page on this computer, and print its address. Open it in a browser to
      play. Change the game file and reload the page: the page is built again from
      the file. If the build stops, the page says why. Press Ctrl-C to stop the
      server.

      The browser does not run the cartridge. Test the .gba as well before you
      give it to anybody.

      Options:
        --console NAME           #{CONSOLE_CHOICES}: which console to play the
                                 game as. Default: the first console in
                                 consoles:.
        --port N                 The port to serve the page on. Default: 8000.
        --template FILE          Make the page from FILE, an .html.erb file with
                                 <%= game %> in it.
        #{SET}
    TEXT
    option :console, banner: "NAME", enum: CONSOLES
    option :port, type: :numeric, default: 8000
    option :template, banner: "FILE"
    option :set, type: :array, banner: "NAME=VALUE", default: []
    def preview(game_file) = serve_in_browser(game_file)

    desc "run GAME_FILE", "Play the game on this computer, with a person or a script at the controls"
    help_page "run", <<~TEXT
      Usage: vblank run GAME_FILE [options]
             vblank run GAME_FILE --tape PATH | --script PATH [options]

      Build the game in GAME_FILE as Ruby, and play it on this computer. Ruby
      runs the game, with YJIT, the part of Ruby that makes it run faster.

      With no --tape and no --script, you play the game in a window, at the
      speed of the console. When the play stops, the command prints how fast the
      game ran.

      With --tape or --script, nobody is at the controls: the tape or the script
      holds the buttons. The command prints how many frames went by and the
      frame of each moment. If the output is a terminal, a window shows the
      play at the speed of the console. If not, or with --no-window, there is
      no window and the game runs as fast as this computer can. The first line
      then says so, and says what runs the game.

      The command does not play a cartridge. To play a tape on a console, write
      it for an emulator with --write-mgba-script or --write-bk2.

      With --browser, serve the game as a web page instead, and print its address.
      Open it in a browser to play. Change the game file and reload the page: the
      page is built again from the file, and if the build stops, the page says
      why. Press Ctrl-C to stop the server. The window does not build again: stop
      the play and run the command again.

      The keys:
        arrows                   the direction pad
        X, Z                     A, B
        Enter, Backspace         Start, Select
        A key, S key             L, R
        F1 or `                  open the menu. On a Mac keyboard, ` (the key
                                 above Tab) needs no fn key. The game pauses
                                 while the menu is open. In the menu, you can
                                 change the speed of fast forward, the size of
                                 the window, fullscreen, the volume, mute and
                                 the frame rate, and you can stop the play. Use
                                 the arrows to move along the bar and down into
                                 a heading, and Enter to choose. A game that
                                 says menu: false has no menu.
        P                        pause the game. Press P again to continue.
        N                        while the game is paused, play one frame.
        Tab                      while you hold Tab, the game plays fast, at up
                                 to four times the speed of the console. You can
                                 change this speed in the menu. The game makes
                                 no sound until you release Tab.
        Escape                   stop the play. Closing the window stops it too.

      A gamepad plays the game too, alongside the keyboard: the D-pad or the left
      stick, the right face button for A and the bottom one for B, Start, Back
      for Select, and the shoulder buttons for L and R. You can plug it in or
      pull it out while the game plays. To open the menu with a gamepad, press
      Back and Start together, or the guide button in the middle (macOS can keep
      that button for itself). In the menu, the D-pad moves, A chooses and B
      closes the menu. Pause, fast forward and Escape need the keyboard.

      The window needs SDL3 and the gem `fiddle`. To install SDL3 on macOS, run
      `brew install sdl3`. On Debian or Ubuntu, run `apt install libsdl3-dev`. If
      the game has a Gemfile, add `gem "fiddle"` to it.

      The window shows the screen of the console that the game is for. If the
      game names more than one console in consoles:, the window shows the first
      one. To play the game as a different console, add --console. The sound
      plays on this computer's speaker. When this computer is too slow for the
      game, the sound has gaps.

      Examples:
        vblank run game.rb
        vblank run game.rb --console gbc         the game as the Game Boy Color
        vblank run game.rb --scale 4             a bigger window
        vblank run game.rb --browser             in a browser; a reload rebuilds it
        vblank run game.rb --uncapped --pictures 600
                                                 how fast this computer can play
                                                 600 pictures of the game
        vblank run game.rb --script walk.rb      a script holds the buttons
        vblank run game.rb --tape walk.tape --no-window --pictures-in shots
                                                 a tape, as fast as it can go
        vblank run game.rb --script walk.rb --on native
                                                 the game built as C

      A script is a Ruby file that says what to press:

        VBlank.playthrough "walk to the door" do
          wait frames: 10
          hold :right, frames: 40
          moment :at_the_door
        end

      A tape is the presses of an earlier play, written by --write-tape. It
      plays the same presses on the same frames.

      Ways to run the game (--on):
        ruby         The game as Ruby, in this Ruby, with YJIT. The default.
        js           The game as JavaScript, played by node. Needs node.
        native       The game as C. Needs zig.
        logic        The rules of the game as C, with no picture and no sound,
                     for a bot: far faster. Needs zig. It writes a tape only
                     with --in-passes, and it has no window.
        interpreter  The interpreter that VBlank checks the other ways against.
                     It is slow, and it makes no sound.
      A person plays as Ruby only. Two ways are two runs: if the game takes
      longer than a frame over a pass, a counted frame falls at a different
      moment on each. A script that steers, or waits for the game, plays the
      same on each way.

      The window shows a picture each time the game finishes a frame. The
      speaker sets the speed of the game: the game makes each frame's sound,
      and waits while the speaker has enough to play. When this computer is
      too slow for the game, the game runs slower than the console. With no
      speaker, the window keeps the speed of the console by the clock, and
      shows fewer pictures than the game has frames.

      Options:
        --console NAME           #{CONSOLE_CHOICES}: which console to play the
                                 game as. Default: the first console in
                                 consoles:.
        --scale N                The window is N times the size of the screen.
                                 Default: the size in the settings file, which
                                 is 3 until you change it. You can change the
                                 size of the window in the menu.
        --settings-file FILE     Read and write the window's settings in FILE
                                 only. Default: the settings.txt files that the
                                 desktop build of a game uses too, so a change
                                 in one is there in the other.
        --config-dir DIR         Keep the settings.txt files in DIR. Default:
                                 $XDG_CONFIG_HOME/vblank if that is set, else
                                 ~/.config/vblank on Linux, else the folder
                                 your computer keeps for programs.
        --pictures N             Stop after the window has shown N pictures.
        --uncapped               Do not wait for the end of each frame. The game
                                 then runs as fast as this computer can play it.
                                 Use this to measure the speed. Tab does nothing
                                 then.
        --no-yjit                Do not use YJIT, the part of Ruby that makes
                                 the game run faster. Use this to measure the
                                 speed without it. Default: --yjit.
        --record-sound FILE      When the play stops, write the sound that the
                                 game gave the speaker to FILE, a .wav file.
                                 Use this to listen to a sound problem again.
        --on WAY                 #{VBlank::Playthroughs::CommandLine::WAYS.keys.join(', ')}: how to
                                 run the game. Default: ruby.
        #{SET}

      With nobody at the controls:
        #{PRESSES.gsub("\n", "\n  ")}
        --window, --no-window    Show the play in a window, or not. Default: a
                                 window if the output is a terminal. In the
                                 window, the menu, pause and fast forward work.
                                 The keyboard and gamepads do not reach the
                                 game. Close the window to stop.
        --lead-in NAME           Play this playthrough first, and do not count
                                 it: a way past logos and a title screen. Needs
                                 --script, even with --tape.
        --in-passes COUNT        Count the script in passes of the game loop,
                                 not frames, so that its tape plays the same
                                 game at any speed on every way. COUNT is
                                 passes, or the name of a variable that the
                                 game adds to.
        --pictures-in DIR        Write the screen at each moment to DIR, as a
                                 PNG named for the moment.
        --write-tape PATH        Write the presses that were made, as a tape.
        --write-mgba-script PATH Write them as a script that mGBA loads in
                                 Tools > Scripting.
        --write-bk2 PATH         Write them as a BizHawk movie. Both are for
                                 the Game Boy Advance cartridge, which is built
                                 for them, from power-on with no BIOS screen.

      In a browser:
        --browser                Play in a browser, not in a window. Only
                                 --console, --port, --template and --set go with
                                 this.
        --port N                 With --browser, the port to serve the page on.
                                 Default: 8000.
        --template FILE          With --browser, make the page from FILE, an
                                 .html.erb file with <%= game %> in it.
    TEXT
    option :browser, type: :boolean, default: false
    option :port, type: :numeric
    option :template, banner: "FILE"
    option :console, banner: "NAME", enum: CONSOLES
    option :scale, type: :numeric, banner: "N"
    option :pictures, type: :numeric, banner: "N"
    option :uncapped, type: :boolean, default: false
    option :yjit, type: :boolean, default: true
    option :record_sound, banner: "FILE"
    option :settings_file, banner: "FILE"
    option :config_dir, banner: "DIR"
    option :on, banner: "WAY"
    option :window, type: :boolean
    option :script, banner: "PATH"
    option :playthrough, banner: "NAME"
    option :tape, banner: "PATH"
    option :lead_in, banner: "NAME"
    option :in_passes, banner: "COUNT"
    option :pictures_in, banner: "DIR"
    option :write_tape, banner: "PATH"
    option :write_mgba_script, banner: "PATH"
    option :write_bk2, banner: "PATH"
    option :set, type: :array, banner: "NAME=VALUE", default: []
    def run_game(game_file)
      refuse_mismatched_play_options!
      return serve_in_browser(game_file) if options[:browser]

      refuse_cartridge_file!(game_file)
      refuse_unless_whole_and_positive!("--scale", options[:scale]) if options[:scale]
      refuse_unless_whole_and_positive!("--pictures", options[:pictures]) if options[:pictures]
      way = way_to_run
      # YJIT compiles the Ruby that runs most often to machine code as the game plays, which plays
      # a game several times faster. A Ruby built without it plays the game slower, and so does
      # --no-yjit, for measuring both ways. A Ruby started with ZJIT keeps it. It is turned on
      # here, before anything is built, so a script's own blocks have it too.
      RubyVM::YJIT.enable if options[:yjit] && defined?(RubyVM::YJIT) && !yjit_on? && !zjit_on?
      return play_unattended(game_file, way) if unattended?

      game = load_game(game_file)
      program = program_to_run(game)
      require_relative "live"
      rate = play_in_window(game, program, live_session(game, program))
      # The game moves on one frame for each picture, so the pictures a second are its speed. A
      # game that stopped itself before its first picture has no speed to say.
      if rate.passes.positive?
        say format("Showed %<pictures>d pictures in %<seconds>.1f seconds, %<per_second>.1f a second. " \
                   "The console shows %<console>.1f a second.",
                   pictures: rate.passes, seconds: rate.seconds, per_second: rate.passes_per_second,
                   console: 1 / program.described_console.frame_seconds)
      end
      say_stopped_itself(game, rate) if rate.stopped_itself?
    end

    desc "inspect ROM_FILE", "Print a .gba's header and first instructions"
    help_page "inspect", <<~TEXT
      Usage: vblank inspect ROM_FILE

      Print the header of a .gba (its title, game code, maker and checksum, and
      whether the checksum is right), then its first instructions, disassembled.
    TEXT
    def inspect(rom_file)
      raise Thor::Error, "I cannot find the ROM file #{rom_file}." unless File.file?(rom_file)

      # The cartridge's own header says which console it is for. A console with no inspector yet
      # is refused by name: the Advance's reads its header and disassembles ARM, so another
      # console's cartridge would come out as numbers that look like an answer and mean nothing.
      bytes = File.binread(rom_file)
      kit = VBlank::Console.kits.find { |each| each.cartridge.header?(bytes) }
      return kit.inspector.new(rom_file).report if kit&.inspector

      inspected = VBlank::Console.kits.select(&:inspector)
      what = kit ? "is a #{kit.title} cartridge" : "is not a cartridge of a console that VBlank builds for"
      raise Thor::Error, "#{rom_file} #{what}. `vblank inspect` reads only the header and the code of a " \
                         "#{inspected.map(&:title).join(' or ')} cartridge. To fix this, give it a " \
                         "#{inspected.map { |each| each.description.extension }.join(' or ')} file."
    end

    desc "new NAME", "Write a starter game to NAME.rb"
    help_page "new", <<~TEXT
      Usage: vblank new NAME [options]

      Write NAME.rb: a game that builds and runs, to start from. It is for the
      Game Boy Advance and the Game Boy Color, so vblank build NAME.rb makes
      NAME.gba and NAME.gbc.

      Example:
        vblank new pong        writes pong.rb. Then: vblank build pong.rb

      Options:
        --force                  Write over NAME.rb if it is there already.
    TEXT
    option :force, type: :boolean, default: false
    def new(name)
      file = "#{name}.rb"
      if File.exist?(file) && !options[:force]
        raise Thor::Error, "#{file} already exists. Use --force to overwrite it."
      end

      File.write(file, starter_source(name))
      say "Wrote #{file}. Run it with `ruby #{file}` or `vblank build #{file}`."
    end

    refuse_undocumented_options!
    HELP_PAGES.freeze

    private

    # --- compare ---

    # `compare` is done by the library (see Playthroughs::CommandLine), which is handed the
    # options, somewhere to print, and how a game file is built here. What it refuses, it refuses
    # in a sentence, and that sentence is what the command ends with.
    #
    # +doing+ is what the command does with a game file ("compare"), for the question a game for
    # two consoles is asked when --console does not say which.
    def with_playthroughs_command_line(doing, offered: nil)
      build = lambda do |file|
        game = load_game(file)
        game.build_rom(settings: given_settings, console: console_to_run(game, doing, offered: offered || game.consoles))
      end
      yield VBlank::Playthroughs::CommandLine.new(options, out: $stdout, build: build)
    rescue VBlank::Playthroughs::CommandLine::Refused => e
      raise Thor::Error, e.message
    end

    # --- run ---

    # The checked program of +game+, as the console --console names plays it, or the first the game
    # names, saying so when there was a choice. The Ruby runtime draws whichever console's screen
    # the program is for. The game plays as Ruby, so no cartridge is made for it.
    #
    # +for_computer+ is what the game's `built_for_computer?` answers. A run written out for an
    # emulator is built as the cartridge is, with false, so the run is the game the cartridge holds.
    def program_to_run(game, console: console_to_play(game), for_computer: true)
      # A big game takes a while to read and check, and somebody is waiting for the window, so a
      # status line goes out before the first phase starts. It says what is happening and no more.
      say "Building #{game.title} - Please wait."
      game.checked_program(progress: VBlank::Messages::Progress.to($stderr), settings: given_settings, console: console,
                           for_computer: for_computer)
    rescue ArgumentError, VBlank::BuildError => e
      raise Thor::Error, e.message
    end

    # "DEMO is for the Game Boy Advance and the Game Boy Color. This plays it as the Game Boy
    # Advance. To play it as the Game Boy Color, add --console gbc." Said only for a game that
    # names more than one console, since a person who did not choose should know they can.
    #
    # `profile` and `compare` ask instead (#console_to_run), since they make a cartridge somebody
    # will measure or compare. `run` is somebody wanting to see the game, or a script wanting to
    # play it, so it plays the console the game names first, and says so.
    def console_to_play(game)
      console = options[:console]&.to_sym || game.consoles.first
      say_console_chosen(game, console) unless options[:console]
      console
    end

    def say_console_chosen(game, console)
      others = game.consoles - [console]
      return if others.empty?

      ways = others.map { |name| "as the #{VBlank::Console.described(name).title}, add --console #{name}" }
      say "#{game.title} is for the #{consoles_named(game)}. This plays it as the " \
          "#{VBlank::Console.described(console).title}. To play it #{ways.join('. To play it ')}."
    end

    # The game built as Ruby, ready to play: a game that needs something the Ruby runtime cannot do
    # yet is refused here, before a window opens.
    def live_session(game, program)
      VBlank::Live::Session.new(program, uncapped: options[:uncapped], stop_after_passes: options[:pictures])
    rescue VBlank::IR::Backends::Ruby::RuntimeGap => e
      raise Thor::Error, "VBlank cannot play #{game.title} in a window yet. The game needs a part of VBlank " \
                         "that does not work in Ruby yet: #{e.part}. Build a cartridge, or use vblank preview."
    end

    # The options only a window has, by the words a person typed.
    WINDOW_OPTIONS = { scale: "--scale", pictures: "--pictures", settings_file: "--settings-file", config_dir: "--config-dir",
                       record_sound: "--record-sound", uncapped: "--uncapped" }.freeze

    def refuse_mismatched_play_options!
      if options[:browser]
        word = WINDOW_OPTIONS.find { |name, _word| options[name] }&.last
        raise Thor::Error, "#{word} is for the window, so it does nothing with --browser. Take one of them out." if word

        word = %i[tape script on].find { |name| options[name] } || nobody_flags_given.first
        raise Thor::Error, "--#{word.to_s.tr('_', '-')} does nothing with --browser. Take one of them out." if word
      else
        word = { port: "--port", template: "--template" }.find { |name, _word| options[name] }&.last
        raise Thor::Error, "#{word} is for a page in a browser. Add --browser, or take it out." if word
      end
      unattended? ? refuse_person_options! : refuse_nobody_options!
    end

    # What only a person at the controls has: a count of pictures to stop at, a game not held to
    # the console's speed, the sound written to a file.
    PERSON_OPTIONS = { pictures: "--pictures", uncapped: "--uncapped", record_sound: "--record-sound" }.freeze

    def refuse_person_options!
      word = PERSON_OPTIONS.find { |name, _word| options[name] }&.last or return

      raise Thor::Error, "#{word} is for a person at the controls. With --tape or --script, nobody is at the " \
                         "controls. Remove #{word}, or remove --tape and --script."
    end

    # A person plays in a window, as Ruby: what a tape or a script is told means nothing then.
    def refuse_nobody_options!
      if nobody_flags_given.any?
        word = "--#{nobody_flags_given.first.to_s.tr('_', '-')}"
        raise Thor::Error, "#{word} goes with --tape or --script, which hold the buttons. With neither, a person " \
                           "plays. Add --tape or --script, or remove #{word}."
      end
      if options[:window] == false
        raise Thor::Error, "With no --tape and no --script, a person plays the game, and a person needs a window. " \
                           "Remove --no-window, or give --tape or --script."
      end
      refuse_person_way!
    end

    def refuse_person_way!
      case options[:on]
      when nil, "ruby" then nil
      when "js"
        raise Thor::Error, "A person plays the game in a window as Ruby. To play the game as JavaScript, use " \
                           "--browser in place of --on js."
      when "native"
        raise Thor::Error, "A person plays the game in a window as Ruby. To play the game as C, build it with " \
                           "vblank build GAME_FILE --format=native, and run the program that it makes."
      else
        raise Thor::Error, "--on #{options[:on]} is for a play with nobody at the controls. Give --tape or --script, " \
                           "or remove --on."
      end
    end

    # Whether a tape or a script holds the buttons, so that nobody is at the controls.
    def unattended? = !!(options[:tape] || options[:script])
    def nobody_flags_given = VBlank::Playthroughs::CommandLine::PLAYING_FLAGS.select { |name| options[name] }

    # The game file is run, so a cartridge given in its place is refused with how a console is reached.
    def refuse_cartridge_file!(game_file)
      return unless self.class.cartridge_word?(game_file)

      raise Thor::Error, "#{game_file} is a cartridge.\n\n#{NO_CARTRIDGE}"
    end

    # The way --on names (a word of Playthroughs::CommandLine::WAYS), ruby unless it says.
    def way_to_run
      way = options[:on] || "ruby"
      return way if VBlank::Playthroughs::CommandLine::WAYS.key?(way)
      raise Thor::Error, "--on emulator is for a cartridge.\n\n#{NO_CARTRIDGE}" if way == "emulator"

      ways = VBlank::Playthroughs::CommandLine::WAYS.keys
      raise Thor::Error, "--on #{way} is not a way to run a game. The ways are #{ways[0...-1].join(', ')} and #{ways.last}."
    end

    # --- run, with nobody at the controls ---

    # What runs the game each way, as the first line says it.
    WAY_WORDS = { "js" => "JavaScript, played by node,", "native" => "C, built by zig,",
                  "logic" => "C, with the rules of the game alone,", "interpreter" => "The interpreter" }.freeze

    def runner_words(way)
      WAY_WORDS.fetch(way) { "Ruby #{RUBY_VERSION}, with #{jit_in_use}," }
    end

    # Play the script or the tape on the game in +game_file+, the way +way+ says. Whether there is a
    # window is said first, before the game is built, since a big build takes a minute.
    def play_unattended(game_file, way)
      window = options[:window].nil? ? way != VBlank::Playthroughs::LoweredGame::LOGIC && $stdout.tty? : options[:window]
      say window ? "A window shows the play. #{runner_words(way).delete_suffix(',')} runs the game." : no_window_line(way)
      refuse_export_for_other_console!
      command = VBlank::Playthroughs::CommandLine.new(options, out: $stdout, build: nil)
      game = nil
      export = -> { game.build_rom(settings: given_settings, console: EXPORTED_CONSOLE) }
      command.play(on: way, window: window, export_cartridge: export, progress: VBlank::Messages::Progress.to($stderr)) do
        game = load_game(game_file)
        refuse_export_for_other_console!(game)
        program = exporting? ? program_to_run(game, console: EXPORTED_CONSOLE, for_computer: false) : program_to_run(game)
        VBlank::Playthroughs::UnbuiltGame.new(program, title: game.title,
                                                       source: [File.binread(game_file), given_settings, program.console])
      end
    rescue VBlank::Playthroughs::CommandLine::Refused => e
      raise Thor::Error, e.message
    rescue VBlank::IR::Backends::Ruby::RuntimeGap => e
      raise Thor::Error, "VBlank cannot play #{game&.title || game_file} as Ruby yet. The game needs a part of VBlank " \
                         "that does not work in Ruby yet: #{e.part}. Give another way with --on, such as --on native."
    end

    # The console whose cartridge a tape is written out for: mGBA's script and BizHawk's movie are
    # lists of frames for one Game Boy Advance cartridge.
    EXPORTED_CONSOLE = :gba

    def exporting? = !!(options[:write_mgba_script] || options[:write_bk2])

    # A tape is written out for the Advance's cartridge, and the run has to be that console's game, so
    # anything else is refused before the build and the play: from the options alone, and then,
    # with +game+ loaded, a game that is not for the Advance or names another console first.
    def refuse_export_for_other_console!(game = nil)
      return unless exporting?

      said = "--write-mgba-script and --write-bk2 write the tape for a Game Boy Advance cartridge, so the game " \
             "must play as the Game Boy Advance."
      asked = options[:console]
      raise Thor::Error, "#{said} To fix this, use --console gba in place of --console #{asked}." if asked && asked != "gba"
      return if game.nil?
      unless game.consoles.include?(EXPORTED_CONSOLE)
        raise Thor::Error, "#{said} #{game.title} is not for the Game Boy Advance. To fix this, add :gba to its consoles:."
      end
      return if asked || game.consoles.first == EXPORTED_CONSOLE

      raise Thor::Error, "#{said} #{game.title} plays first as another console. To fix this, add --console gba."
    end

    # "No window: the output is not a terminal. Ruby 3.4.1, with YJIT, runs the game as fast as this
    # computer can. To show it in a window, add --window."
    def no_window_line(way)
      why = if way == VBlank::Playthroughs::LoweredGame::LOGIC then "--on logic has no picture"
            elsif options[:window] == false then "--no-window asks for none"
            else "the output is not a terminal"
            end
      how = way == VBlank::Playthroughs::LoweredGame::LOGIC ? "To watch it, use --on ruby and --window." : "To show it in a window, add --window."
      "No window: #{why}. #{runner_words(way)} runs the game as fast as this computer can. #{how}"
    end

    # The game as a page on this computer, built again on every reload, until Ctrl-C.
    def serve_in_browser(game_file)
      raise Thor::Error, "I cannot find the game file #{game_file}." unless File.file?(game_file)

      port = options[:port] || 8000
      server =VBlank::IR::Backends::JS::Preview.new(game_file, settings: options[:set], template: options[:template],
                                                                 console: options[:console], port: port)
      server.serve
    rescue Errno::EADDRINUSE
      raise Thor::Error, "Port #{port} is in use already. Give another with --port."
    end

    # +session+ played in a window until the player stops it, or --pictures are shown; the window
    # is closed however the play ends. Something the game does that its rules refuse (a push onto a
    # full list) is said in words.
    def play_in_window(game, program, session)
      console = program.described_console
      window = VBlank::Live::SDL.new(title: game.title, scale: options[:scale], width: console.screen_width,
                                     height: console.screen_height, menu: game.menu?,
                                     settings_file: options[:settings_file] || :usual,
                                     config_dir: options[:config_dir])
      warn window.settings_problems_message if window.settings_problems_message
      say "Playing #{game.title} for the #{console.title} in Ruby #{RUBY_VERSION} with #{jit_in_use}. " \
          "#{'Press F1 or ` for the menu. ' if game.menu?}Press P to pause. Hold Tab to play fast. Press Escape to stop."
      recording = VBlank::Live::Recording.new(window, frame_seconds: console.frame_seconds) if options[:record_sound]
      session.play(recording || window)
    rescue VBlank::Live::SDL::Missing, VBlank::Live::SDL::Failed, VBlank::IR::ProgramError => e
      raise Thor::Error, e.message
    ensure
      window&.close
      write_recorded_sound(recording) if recording # a play that went wrong is the one most worth hearing
    end

    def write_recorded_sound(recording)
      sound = recording.sound
      return say("The game made no sound, so VBlank wrote no #{options[:record_sound]}.") unless sound

      sound.write_wav(options[:record_sound])
      say "The sound the game made is in #{options[:record_sound]}."
    end

    # A game that halted, or came to its end, kept its last picture up until the window was closed.
    def say_stopped_itself(game, rate)
      frames = rate.passes == 1 ? "1 frame" : "#{rate.passes} frames"
      say "#{game.title} stopped itself after #{frames}. Its last picture stayed in the window."
    end

    def yjit_on? = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
    def zjit_on? = defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?

    # Which of Ruby's two compilers is turning the game's Ruby into machine code as it plays: YJIT,
    # which vblank run turns on, or ZJIT, the newer one, which a Ruby built with it turns on when
    # it is started with --zjit (tools/ruby_speed.rb compares the three).
    def jit_in_use
      return "YJIT" if yjit_on?
      return "ZJIT" if zjit_on?

      "no JIT"
    end

    def refuse_unless_whole_and_positive!(switch, value)
      return if value.is_a?(Integer) && value.positive?

      raise Thor::Error, "#{switch} must be a whole number of 1 or more. For example: #{switch} 3."
    end

    # --- build and profile ---

    # The "game" format (--format=game, the default): a cartridge for each console the game names,
    # or for the one --console says.
    #
    # EACH IS BUILT WHATEVER HAPPENS TO THE OTHER. A game for both consoles that the Color cannot
    # play still gets its Advance cartridge, and the command then ends saying why the Color's was
    # not made and how to stop asking for it — which may be all the game needs, since not every
    # game is for the Color. It still ends as a failure: a console the game names was not built.
    # A profile asked for comes after every cartridge is written, so refusing one costs no cartridge.
    def build_cartridges(game_file)
      game = load_game(game_file)
      consoles = options[:console] ? [options[:console].to_sym] : game.consoles
      refuse_one_output_for_two_consoles!(game) if options[:output] && consoles.size > 1
      if options[:variant] && consoles.size > 1
        raise Thor::Error, "--variant names the chip for one console. " \
                           "#{consoles_choice_message(game, 'build', game.consoles)}"
      end
      built = {}
      failed = {}
      consoles.each do |console|
        built[console] = write_cartridge_for(game, game_file, console)
      rescue VBlank::BuildError => e
        # A build the guardrails stopped (their reasons are printed already), or something the
        # checks let through that the console's lowering cannot make.
        failed[console] = e.message
      end
      built.each_value { |rom| profile_rom(rom) } if options[:profile] || options[:scene] || options[:keys].any?
      raise Thor::Error, not_built_message(game, failed, built.keys) unless failed.empty?
    end

    # One console's cartridge, written beside the game file or to --output, and handed back.
    def write_cartridge_for(game, game_file, console)
      # Somebody is sitting there waiting for this, so it says what it is doing.
      variant = options[:variant] || game.variant_for(console)
      rom = game.build_rom(progress: VBlank::Messages::Progress.to($stderr), settings: given_settings, console: console,
                           variant: variant)
      path = options[:output] || File.join(File.dirname(File.expand_path(game_file)), game.default_filename(console: console))
      rom.write(path)
      say "Built #{File.basename(path)} (#{rom.size} bytes)"
      # What asset packing and the quick memory did is said for a console whose build does them:
      # the Color's packs nothing and has no quick memory to choose for.
      if options[:stats] && VBlank::Console.for(console).measured_builds?
        say rom.compression.summary_line if rom.compression&.any?
        say placement_line(rom) if rom.placement&.funcs&.any?
      end
      rom
    end

    # Why the consoles in +failed+ (console => reason) were not built, and the ways to stop
    # asking for each. A reason every console gave alike is the game's own fault, so it is said
    # once and with no advice about leaving a console out. +built+ are the consoles that were.
    def not_built_message(game, failed, built)
      reasons = failed.values.uniq
      return reasons.first if reasons.size == 1 && (failed.size > 1 || game.consoles.size == 1)

      failed.map do |console, reason|
        title = VBlank::Console.described(console).title
        advice = "#{game.title} was not built for the #{title}. If the game is not for the #{title}, " \
                 "take :#{console} out of consoles: where the game is named."
        if built.size == 1
          advice += " To build the #{VBlank::Console.described(built.first).title} cartridge alone, " \
                    "use --console #{built.first}."
        end
        "#{reason}\n\n#{advice}"
      end.join("\n\n")
    end

    def refuse_one_output_for_two_consoles!(game)
      raise Thor::Error, "--output names one file, and #{consoles_choice_message(game, 'write', game.consoles)}"
    end

    # The console a command that runs one cartridge runs +game+ on: the one --console names, or the
    # game's only one. A game for two with neither said is asked which, since nothing is taken to
    # be for the Advance. +doing+ is what the command does with it ("profile", "play"), and
    # +offered+ the consoles it can do that on, which `compare` holds to the Advance.
    def console_to_run(game, doing, offered: game.consoles)
      return options[:console].to_sym if options[:console]
      return game.consoles.first if game.consoles.size == 1

      raise Thor::Error, consoles_choice_message(game, doing, offered)
    end

    # "PONG is for the Game Boy Advance and the Game Boy Color. Say which cartridge to play: add
    # --console gba or --console gbc."
    def consoles_choice_message(game, doing, offered)
      "#{game.title} is for the #{consoles_named(game)}. Say which cartridge to #{doing}: add --console " \
        "#{offered.join(' or --console ')}."
    end

    # The consoles +game+ is for, as a person names them: "Game Boy Advance and the Game Boy Color".
    def consoles_named(game) = game.consoles.map { |name| VBlank::Console.described(name).title }.join(" and the ")

    # The file a build that is not a cartridge writes, beside the game file: the cartridge's name
    # for +console+ with +ending+ in place of the cartridge's.
    def file_beside(game, game_file, console, ending)
      cartridge = game.default_filename(console: console)
      File.join(File.dirname(File.expand_path(game_file)),
                cartridge.delete_suffix(VBlank::Console.described(console).extension) + ending)
    end

    # The "ir" format (--format=ir): the game's IR as a standalone Ruby class, instead
    # of a cartridge. Built through the same full pipeline as --format=game (so a
    # guardrail error stops this exactly the way it stops a real build), then the
    # finished ROM's own source tree (rom.source_program) is what gets dumped — the
    # ROM bytes themselves are simply not written anywhere. The class it writes lowers the
    # program as the Advance's cartridge (IR::Dump.class_source), so it is the Advance's build.
    def build_ir(game_file)
      game = load_game(game_file)
      refuse_ir_for_other_console!(game)
      rom = game.build_rom(settings: given_settings, console: :gba)
      source = VBlank::IR::Dump.class_source(rom.source_program, class_name: "#{constantize(game.title)}IR",
                                            **rom.build_options)
      if options[:output]
        File.write(options[:output], source)
        say "Wrote #{options[:output]}"
      else
        Pager.new.page(source)
      end
    end

    # The IR a dump writes is a class that builds the Advance's cartridge (IR::Dump), so it is made
    # for the Advance alone: another console asked for, or a game that is not for the Advance, is
    # refused rather than quietly dumped as the Advance's.
    def refuse_ir_for_other_console!(game)
      asked = options[:console]&.to_sym
      if asked && !VBlank::Console.for(asked).dumps_ir?
        raise Thor::Error, "--format ir writes the game for the Game Boy Advance only. To write the IR, " \
                           "remove --console #{asked}."
      end
      return if game.consoles.any? { |console| VBlank::Console.for(console).dumps_ir? }

      raise Thor::Error, "#{game.title} is not for the Game Boy Advance, and --format ir writes the game for " \
                         "the Game Boy Advance only. To write the IR, add :gba to the game's consoles:."
    end

    # The "native" format: the game as a program for this computer, with a window. Written
    # beside the game file, named like the cartridge with no extension — or with "-desktop" on
    # the end where that name is already a folder, as a game split across files often has.
    def build_native(game_file)
      game = load_game(game_file)
      console = console_to_play(game)
      target = options[:target]&.tr("-", "_")&.to_sym
      if target && !VBlank::IR::Backends::Native::TARGETS.key?(target)
        names = VBlank::IR::Backends::Native::TARGETS.keys.map { |name| name.to_s.tr("_", "-") }
        raise Thor::Error, "There is no build for #{options[:target]}. A game can be built for " \
                           "#{names.join(', ')}. To build for this computer, leave out --target."
      end
      path = options[:output] || begin
        plain = file_beside(game, game_file, console, "")
        plain = "#{plain}-#{options[:target]}" if target
        plain = "#{plain}-desktop" if File.directory?(plain)
        target == :windows ? "#{plain}.exe" : plain
      end
      say "Building #{File.basename(path)} for #{target ? options[:target] : 'this computer'} - Please wait."
      VBlank::IR::Backends::Native.new.build_desktop(game, path, console: console, settings: given_settings, target: target,
                                                                 strip: options[:strip])
      say "Built #{path}"
    rescue VBlank::BuildError, VBlank::IR::Backends::Native::Zig::Error => e
      raise Thor::Error, e.message
    end

    # The "ruby" format: the game as one Ruby file that plays in a window with Ruby, fiddle and SDL3
    # alone (IR::Backends::Ruby#script), written beside the game file and named like its cartridge
    # with "-ruby.rb" in place of the cartridge's ending. It is played as the console --console
    # names, or the first the game names, as vblank run plays it.
    def build_ruby(game_file)
      game = load_game(game_file)
      console = console_to_play(game)
      path = options[:output] || file_beside(game, game_file, console, "-ruby.rb")
      VBlank::IR::Backends::Ruby.new.build_script(game, path, console: console, settings: given_settings)
      say "Built #{path}. To play it, run: ruby #{File.basename(path)}"
    rescue VBlank::IR::Backends::Ruby::RuntimeGap => e
      raise Thor::Error, "VBlank cannot write #{game.title} as Ruby yet. The game needs a part of VBlank " \
                         "that does not work in Ruby yet: #{e.part}."
    end

    # An option given where it does nothing — --strip on anything but a program for a computer, an
    # option for the web build on another format or beside an output it is not for — is refused,
    # so nobody thinks it did something.
    def refuse_web_options_out_of_place!
      if options[:strip] && options[:format] != "native"
        raise Thor::Error, "--strip works only with --format=native. Add --format=native, or remove --strip."
      end

      given = { js: options[:js] != "page", data: options[:data] != "inline", template: options[:template],
                global: options[:global] }.select { |_, said| said }.keys
      if options[:format] != "web" && !given.empty?
        raise Thor::Error, "--#{given.first} works only with --format=web. Add --format=web, or remove --#{given.first}."
      end
      if options[:global] && options[:js] != "script"
        raise Thor::Error, "--global works only with --js=script. Add --js=script, or remove --global."
      end
      return unless options[:template] && options[:js] != "page"

      raise Thor::Error, "--template works only with the page (--js=page). Remove --js, or remove --template."
    end

    # What --js names, and the ending of the file each is written to.
    WEB_OUTPUTS = { "page" => ".html", "module" => ".mjs", "script" => ".js" }.freeze

    # The "web" format: the game as one web page that plays it in a browser, or with --js the game
    # alone as JavaScript for a page of the author's own. Written beside the game file, named like
    # the cartridge with the output's ending in place of .gba.
    def build_web(game_file)
      game = load_game(game_file)
      console = console_to_play(game)
      js = options[:js]
      path = options[:output] || file_beside(game, game_file, console, WEB_OUTPUTS.fetch(js))
      web = VBlank::IR::Backends::JS.new
      data = options[:data].to_sym
      progress = VBlank::Messages::Progress.to($stderr)
      case js
      when "module" then web.build_module(game, path, console: console, settings: given_settings, data: data, progress: progress)
      when "script" then web.build_script(game, path, name: options[:global] || File.basename(path, ".*"),
                                                      console: console, settings: given_settings, data: data, progress: progress)
      else
        template = options[:template] ? File.expand_path(options[:template]) : VBlank::IR::Backends::JS::Page::DEFAULT
        web.build_page(game, path, console: console, settings: given_settings, template: template, data: data, progress: progress)
      end
      say "Built #{path}"
    rescue VBlank::BuildError => e
      raise Thor::Error, e.message
    end

    # One line on what the build kept in the console's quick memory, for --stats. The
    # full list is in the cost report; this is the size of it.
    def placement_line(rom)
      placement = rom.placement
      routines = placement.funcs.length
      format("Quick memory: %d routine%s (%.1fK), %.1fK of 32K free",
             routines, routines == 1 ? "" : "s",
             placement.code_bytes / 1024.0, placement.free_bytes / 1024.0)
    end

    # What the build made, and what it cost when it ran. An unknown scene name is a friendly
    # error, not a backtrace.
    def profile_rom(rom, format: :human)
      rom.profile(format: format, scene: options[:scene], keys: held_buttons || [])
    rescue ArgumentError => e
      raise Thor::Error, e.message
    end

    # The buttons --keys named, checked before the emulator runs. nil when none were
    # named, which leaves the profiler to hold each button the game reads, in turn.
    def held_buttons
      return nil if options[:keys].empty?

      buttons_named(options[:keys])
    end

    # The buttons +names+ say, each checked.
    def buttons_named(names)
      buttons = names.map { |name| name.to_s.downcase.to_sym }
      unknown = buttons.reject { |button| VBlank::IR::Buttons.known?(button) }
      unless unknown.empty?
        raise Thor::Error, "#{unknown.first} is not a button. The buttons are: " \
                           "#{VBlank::IR::Buttons::NAMES.join(', ')}."
      end
      buttons
    end

    # The settings --set named, as text: the game's own `setting` line reads each as the kind
    # of thing its default is.
    def given_settings
      options[:set].to_h do |pair|
        name, value = pair.split("=", 2)
        if value.nil? || name.empty?
          raise Thor::Error, "--set #{pair} does not say a value. Write it as NAME=VALUE, for example --set floors=1."
        end

        [name.to_sym, value]
      end
    end

    # The file only declares its game (VBlank.game records without building), so clear
    # the registry, load the file, and take what it added.
    def load_game(game_file)
      path = File.expand_path(game_file)
      raise Thor::Error, "I cannot find the game file #{game_file}." unless File.file?(path)

      VBlank.forget_registered_games!
      load path
      VBlank.registered_games.last || raise(Thor::Error, <<~MSG.chomp)
        #{game_file} does not declare a game. Add:
          VBlank.game "NAME", consoles: %i[gba gbc] do
            # ...the game...
          end
      MSG
    rescue VBlank::BuildError => e
      # A build that stopped while the file loaded: show the plain-language reason, not a backtrace.
      raise Thor::Error, e.message
    end

    def starter_source(name)
      title = name.upcase.gsub(/[^A-Z0-9 ]/, "").strip[0, 12]
      title = "GAME" if title.empty?
      const = constantize(name)

      <<~RUBY
        # frozen_string_literal: true
        #
        # #{title} — a starter game. Run it with `ruby #{name}.rb`, or build it with
        # `vblank build #{name}.rb`, which makes a cartridge for each console it names:
        # #{name}.gba for the Game Boy Advance and #{name}.gbc for the Game Boy Color.

        require "vblank"

        #{const} = VBlank.game "#{title}", consoles: %i[gba gbc] do
          screen :bitmap

          game_loop do
            clear_screen :black
            # The middle of whichever screen it is built for: the two are not the same size.
            draw_text "#{title}", :center, (screen_height - text_height) / 2, :white
          end
        end

        #{const}.write_if_main
      RUBY
    end

    # A CamelCase Ruby constant name from an arbitrary string (a file name, a game
    # title) — "PONG" -> "Pong", "grid-cursor" -> "GridCursor". Falls back to "Game"
    # for a string with nothing constant-safe in it (all punctuation, a leading digit).
    def constantize(str)
      const = str.to_s.split(/[^a-zA-Z0-9]+/).map(&:capitalize).join
      const.match?(/\A[A-Z]/) ? const : "Game"
    end
  end
end
