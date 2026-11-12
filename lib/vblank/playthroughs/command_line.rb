# frozen_string_literal: true

module VBlank
  module Playthroughs
    # WHAT `vblank run` WITH A SCRIPT OR A TAPE, AND `vblank compare`, DO once the command line has
    # been taken apart into options: find what to press, read the settings a command line can only
    # give as text, play or compare, and say what came of it.
    #
    # It is here and not in the command-line program so that it sits with what it drives, and
    # so that nothing in it knows which library read the command line. +options+ answers
    # `options[:tape]` for each flag by its name, +out+ is where it prints, and +build+ turns
    # the path of a game file into a cartridge the way `vblank build` would.
    #
    # What it cannot do it refuses in a sentence, with a Refused, before a game file is built
    # wherever that can be known: building takes a while, and the mistake is as often in the
    # second file's name as in the first.
    class CommandLine
      # What was written on the command line cannot be played or compared. The message says
      # what happened and what to write.
      class Refused < StandardError; end

      # THE WAYS `vblank run --on` RUNS A GAME, by the word the command line takes, and the way of
      # LoweredGame each is. None is the emulator: the command runs the game, and a console is
      # reached by writing a tape out for an emulator a person already has (--write-mgba-script,
      # --write-bk2). Ruby is first, the default, and the one a person plays in a window.
      WAYS = { "ruby" => "ruby", "js" => "web", "native" => "native", LoweredGame::LOGIC => LoweredGame::LOGIC,
               "interpreter" => "interpreter" }.freeze

      # THE WAYS A GAME CAN BE SHOWN, as a film shows it: the cartridge in its console's emulator, the
      # first and the one meant when none is given, then every word of WAYS but logic, which plays the
      # game's rules alone and has no picture.
      SHOWN_WAYS = [LoweredGame::EMULATOR, *(WAYS.keys - [LoweredGame::LOGIC])].freeze

      # The way of LoweredGame that +word+ (a word of SHOWN_WAYS, or nil) names, or nil for the
      # cartridge in its emulator. A word that is not one of them is refused, saying the ones there are.
      def self.shown_way_named(word)
        word = word&.to_s
        return nil if word.nil? || word == LoweredGame::EMULATOR
        return WAYS.fetch(word) if SHOWN_WAYS.include?(word)

        no_picture = word == LoweredGame::LOGIC ? " It plays the rules of the game alone, and it shows no picture." : ""
        raise ArgumentError, "A game cannot be shown on #{word.inspect}.#{no_picture} The ways to show a game are " \
                             "#{SHOWN_WAYS[0...-1].join(', ')} and #{SHOWN_WAYS.last}. To show the cartridge in its " \
                             "emulator, give #{LoweredGame::EMULATOR.inspect} or give no way."
      end

      def initialize(options, out:, build:)
        @options = options
        @out = out
        @build = build
      end

      # Play the script or the tape on the game the block gives (an UnbuiltGame) the way +on+ names
      # (a word of WAYS), in a window if +window+ asks for one, say the frames and the moments, and write
      # what was asked for. The block is called once what was written has been found good, since
      # it builds the game, and that takes a while. +export_cartridge+ makes the Advance's
      # cartridge, which only a tape written out for another emulator needs. +progress+ is told
      # how far the playing has got. Hands back what the playing came to.
      #
      # A run written out for another emulator is counted in passes (unless --in-passes names a
      # variable to count), since a pass is the one thing the run here and the cartridge share:
      # the export then plays those passes on the cartridge in the emulator to find the frame each
      # fell on (Tape#in_frames_on). A tape of frames is refused for an export, since its frames
      # are the run's here and not the cartridge's.
      def play(on:, window:, export_cartridge:, progress: Messages::Progress.silent)
        @settings_with_flags = RUN_SETTINGS_WITH_FLAGS
        saying_errors_plainly do
          refuse_flags_beside_logic!(on)
          refuse_in_passes_beside_tape!
          playing = tape_or_playthrough(lead_in_flag: :lead_in)
          refuse_export_of_frames!(playing)
          lead_in = lead_in_named(options[:lead_in])
          refuse_unwritable_file!(:write_tape)
          game = yield
          in_window_if_asked(game, window) do |device|
            settings = { lead_in: lead_in, pictures_in: options[:pictures_in], on: WAYS.fetch(on), window: device,
                         progress: progress }
            counted = in_passes_asked || (true if exporting? && !options[:tape])
            settings[:in_passes] = counted if counted
            playing.play(game, **settings).tap do |played|
              say_frames_and_moments(played, playing, game)
              write_tapes(played, export_cartridge)
            end
          end
        end
      end

      # Whether the presses are to be written out for another emulator.
      def exporting? = !!(options[:write_mgba_script] || options[:write_bk2])

      # Everything a playing with nobody at the controls is told on the command line, and so
      # nothing a person playing needs: each is refused without --tape or --script.
      PLAYING_FLAGS = %i[playthrough lead_in pictures_in write_tape write_mgba_script write_bk2 in_passes].freeze

      # Compare the cartridges at the two paths and say where they drift, or that they agree.
      # Hands back what the comparison found.
      def compare(first_file, second_file)
        saying_errors_plainly do
          refuse_missing_cartridges!(first_file, second_file)
          presses = tape_or_playthrough(lead_in_flag: :lead_ins)
          settings = comparison_settings
          cartridges = [first_file, second_file].map { |file| cartridge_at(file) }
          presses.compare(*cartridges, **settings).tap { |found| say_drifts_or_agreement(found) }
        end
      end

      private

      attr_reader :options

      # The block, handed a window on +game+'s screen where +wanted+ asks for one, which is closed
      # however the playing ends. A window takes SDL3, which only this needs, so it is loaded here.
      # Closing it is how a person stops watching, so that ends the command quietly. --scale,
      # --settings-file and --config-dir mean what they mean in a person's window.
      def in_window_if_asked(game, wanted)
        return yield(nil) unless wanted

        require "vblank/live"
        console = Console.described(game.console)
        title = Tape.title_and_checksum_of(game).first
        window = Live::SDL.new(title: title, caption: "#{title} (automated playthrough)", width: console.screen_width,
                               height: console.screen_height, scale: options[:scale],
                               settings_file: options[:settings_file] || :usual, config_dir: options[:config_dir])
        say window.settings_problems_message if window.settings_problems_message
        say "Press F1 or ` for the menu. Press P to pause. Hold Tab to play fast. Press Escape to stop."
        yield window
      rescue WindowStepper::WindowClosed
        say "The window was closed, so the playing stopped."
      ensure
        window&.close
      end

      # Each line goes out as it is said. What a command says and what stops it go to two
      # places, and a line held back would come out after the error that followed it.
      def say(text)
        @out.puts(text)
        @out.flush
      end

      # The settings the library names in its own messages, written the way Ruby writes them.
      # On the command line each is the flag of the same name.
      SETTINGS_WITH_FLAGS = (Comparison.settings + %i[lead_in pictures_in]).freeze

      # ...and the ones `vblank run` has a flag for, which are fewer: it starts no game from a save.
      RUN_SETTINGS_WITH_FLAGS = %i[lead_in pictures_in in_passes].freeze

      # What a playing or a comparison stops with that is the caller's to fix: a setting that
      # makes no sense, a game that would not build (the checks stopped it, or its console's
      # lowering refused it), a wait that never ended, a reading that could not be read, a
      # report that could not be written. Each already says what happened and what to do, so its
      # message is passed on as it is.
      def saying_errors_plainly
        yield
      rescue ArgumentError, VBlank::BuildError, GaveUp, Comparison::ReadingFailed, Comparison::ReportNotWritten,
             Comparison::PassCountFell, Comparison::PassNotReached, Comparison::PictureStoodStill => e
        raise Refused, message_with_flags(e.message)
      end

      # A message from the library names a setting the way Ruby writes it (`ignoring_frames:`).
      # The message is kept as it is, and a line under it says which flag that setting is.
      def message_with_flags(message)
        named = message.scan(/`(\w+):/).flatten.uniq.map(&:to_sym) & (@settings_with_flags || SETTINGS_WITH_FLAGS)
        return message if named.empty?

        "#{message}\nOn the command line, #{named.map { |setting| "`#{setting}:` is #{flag_of(setting)}" }.join(', and ')}."
      end

      def flag_of(setting) = "--#{setting.to_s.tr('_', '-')}"

      # `--in-passes passes` counts the game loop's passes, and any other word is a variable's name.
      def in_passes_asked
        said = options[:in_passes] or return nil
        said == Tape::COUNTS_PASSES ? true : said.to_sym
      end

      # A tape of frames made here is a pass a frame, which is not how the cartridge plays it.
      def refuse_export_of_frames!(playing)
        return unless exporting? && playing.is_a?(Tape) && playing.in_passes.nil?

        raise Refused, "The tape #{options[:tape]} counts frames. Here a game plays one pass each frame, and on the " \
                       "cartridge a pass can take more than one frame, so the frames of the tape are not the frames " \
                       "of the cartridge. To write a run for an emulator, play the script with --script and " \
                       "--write-mgba-script or --write-bk2. The run is then counted in passes."
      end

      # A tape records for itself what it counts.
      def refuse_in_passes_beside_tape!
        return unless options[:in_passes] && options[:tape]

        raise Refused, "--in-passes cannot go with --tape. A tape says what it counts. To fix this, remove --in-passes."
      end

      # `--on logic` has no picture and no sound, and its frames are not the console's, so a tape
      # of frames made there does not play on a cartridge, and a tape counted in passes does.
      def refuse_flags_beside_logic!(on)
        return unless on == LoweredGame::LOGIC

        refused = %i[window pictures_in write_mgba_script write_bk2]
        refused << :write_tape unless options[:in_passes]
        said = refused.find { |flag| options[flag] }
        return unless said

        raise Refused, "#{flag_of(said)} cannot go with --on logic. That way plays a game's rules with no picture and no " \
                       "sound, and its frames are not the console's. To fix this, use --on ruby or remove #{flag_of(said)}."
      end

      # Every file has to be there before anything is built: building the first game file
      # takes a while, and the second file's name can be the one spelled wrong.
      def refuse_missing_cartridges!(*files)
        missing = files.find { |file| !File.file?(file) } or return

        raise Refused, "I cannot find #{missing}. Give a game file (a .rb that declares a game) or a cartridge file (a .gba)."
      end

      # The cartridge a file is: a game file is built, the way `build` builds it, and
      # anything else is taken for a cartridge file and read.
      def cartridge_at(file)
        return Playthrough.cartridge_from(file) unless file.end_with?(".rb")

        @build.call(file)
      end

      # What decides which buttons to press: the tape, where one was given, or else the
      # playthrough picked from the script file. +lead_in_flag+ is the option this command
      # takes a lead-in by, which a tape recorded after one needs.
      def tape_or_playthrough(lead_in_flag:)
        return playthrough_to_play unless options[:tape]

        refuse_tape_with_same_script!
        Tape.read(options[:tape]).tap { |tape| refuse_tape_missing_start!(tape, lead_in_flag) }
      end

      def refuse_tape_with_same_script!
        return unless same_script?

        raise Refused, "--same script plays a script on each cartridge by itself, and a tape holds no script. " \
                       "Give the script with --script in place of --tape, or leave --same out."
      end

      # A tape records what it was recorded from, and the same presses from anywhere else are a
      # different game. What it needs is asked for by its flag, before anything is built.
      def refuse_tape_missing_start!(tape, lead_in_flag)
        if tape.recorded_from_save? && lead_in_flag == :lead_in
          raise Refused, "The tape #{options[:tape]} was recorded on a cartridge that started from a save. vblank run " \
                         "starts every game from power-on, so it does not play this tape. To play it, start the " \
                         "cartridge from that save in Ruby: `tape.play(cartridge, save: \"game.sav\")`."
        end
        if tape.recorded_from_save? && !options[:save] && !Array(options[:saves]).then { it.size == 2 && it.none?("-") }
          raise Refused, "The tape #{options[:tape]} was recorded from a save. Give that save with --save, or a save " \
                         "for each cartridge with --saves."
        end
        return unless tape.recorded_after_lead_in? && !options[lead_in_flag]

        raise Refused, "The tape #{options[:tape]} was recorded after a lead-in. Name the lead-in with " \
                       "#{flag_of(lead_in_flag)}, and give the script file that declares it with --script."
      end

      # Every playthrough the script file declares. The file only declares them, so the
      # list is cleared, the file loaded, and what it added taken — once, however many
      # times it is asked.
      def declared_playthroughs
        @declared_playthroughs ||= begin
          file = options[:script] or
            raise Refused, "I need to know what to press. Give a script file with --script, or a tape with --tape."
          raise Refused, "I cannot find the script file #{file}." unless File.file?(file)

          VBlank.forget_registered_playthroughs!
          load File.expand_path(file)
          VBlank.registered_playthroughs.tap do |declared|
            next unless declared.empty?

            raise Refused, <<~MSG.chomp
              #{file} does not declare a playthrough. Add:
                VBlank.playthrough "NAME" do
                  # ...the steps...
                end
            MSG
          end
        end
      end

      def playthrough_to_play
        return playthrough_named(options[:playthrough]) if options[:playthrough]
        return declared_playthroughs.first if declared_playthroughs.one?

        raise Refused, "#{options[:script]} declares #{declared_playthroughs.size} playthroughs, and I do not know which " \
                       "to play. Say which with --playthrough. They are: #{playthrough_names}."
      end

      # A playthrough by its name, which a command line can only give as text: one declared
      # with a symbol for a name is found by the same letters.
      def playthrough_named(name)
        declared_playthroughs.find { |declared| declared.name.to_s == name } or
          raise Refused, "#{options[:script]} declares no playthrough named #{name.inspect}. " \
                         "Its playthroughs are: #{playthrough_names}."
      end

      def playthrough_names = declared_playthroughs.map { |declared| declared.name.to_s.inspect }.join(", ")

      # A lead-in is a playthrough from the script file, by its name, and `-` or nothing
      # given is none. A tape holds what to press and declares no playthrough, so a lead-in
      # needs the script file whatever the presses come from.
      def lead_in_named(name)
        return nil if name.nil? || name == "-"
        return playthrough_named(name) if options[:script]

        raise Refused, "A lead-in is a playthrough in a script file, and no script file was given. " \
                       "Give the file that declares #{name.inspect} with --script."
      end

      # The lead-in of each cartridge, the first one's and then the second's.
      def lead_ins_named(names)
        return names.map { |name| lead_in_named(name) } if names.size == 2

        raise Refused, "--lead-ins needs two names, the first cartridge's lead-in and then the second's. " \
                       "It was given #{names.size}. Write - for a cartridge with no lead-in, for example --lead-ins intro -."
      end

      # The save file of each cartridge, the first one's and then the second's; - is none.
      def save_files_named(paths)
        return paths.map { |path| path == "-" ? nil : path } if paths.size == 2

        raise Refused, "--saves needs two save files, the first cartridge's and then the second's. " \
                       "It was given #{paths.size}. Write - for a cartridge with no save, for example --saves ours.sav -."
      end

      # A tape and a save are written after the whole playing, so a place that cannot be
      # written to is refused before a frame is played.
      def refuse_unwritable_file!(flag)
        path = options[flag] or return
        raise Refused, "#{flag_of(flag)} #{path} is a folder. Give the name of a file to write." if File.directory?(path)

        folder = File.dirname(File.expand_path(path))
        return if File.directory?(folder) && File.writable?(folder)

        raise Refused, "#{flag_of(flag)} #{path} cannot be written. The folder #{File.dirname(path)} is not there, " \
                       "or cannot be written to. Make the folder, then run this again."
      end

      def say_frames_and_moments(played, playing, cartridge)
        title = Tape.title_and_checksum_of(cartridge).first
        what = options[:tape] ? "the tape #{options[:tape]}" : playing.name.to_s.inspect
        say "Played #{played.frames} frames of #{what} on #{title}."
        say_moments(played.moments) { |frame| "frame #{frame}" }
        say "Wrote #{played.picture_files.size} pictures in #{options[:pictures_in]}." if options[:pictures_in]
      end

      # One line a moment, the names in a column, and after each whatever the block makes of
      # the frame or frames it was reached on.
      def say_moments(moments)
        width = moments.keys.map { |name| name.to_s.size }.max
        moments.each { |name, reached| say "  #{name.to_s.ljust(width)}  #{yield reached}" }
      end

      # The tape, and the tape written out for another emulator, which is the Advance's cartridge's
      # list of frames: that cartridge is built for it, and only then.
      def write_tapes(played, export_cartridge)
        say "Wrote the tape to #{played.tape.write(options[:write_tape])}." if options[:write_tape]
        return unless options[:write_mgba_script] || options[:write_bk2]

        cartridge = export_cartridge.call
        say "Wrote the mGBA script to #{played.tape.write_mgba_script(cartridge, options[:write_mgba_script])}." if options[:write_mgba_script]
        say "Wrote the BizHawk movie to #{played.tape.write_bizhawk_movie(cartridge, options[:write_bk2])}." if options[:write_bk2]
      end

      # Every setting that was given, as `compare` takes them from Ruby: each is the option of
      # the same name, and the ones a command line can only give as text are read here. One
      # that was not given is left out, so that what it is with nothing given stays the
      # library's to decide.
      def comparison_settings
        if options[:sprite_sizes] && !options[:ignoring_sprites]
          raise Refused, "--sprite-sizes was given without --ignoring-sprites. Add --ignoring-sprites, or remove --sprite-sizes."
        end

        said =Comparison.settings.to_h { |setting| [setting, options[setting]] }.compact
        said.to_h do |setting, written|
          [setting, case setting
                    when :ignoring_rectangles, :looking_at then written.map { |one| parse_rectangle(one, setting) }
                    when :layers, :forgiving_torn_frames_of, :skipping_still_frames_of then written.to_sym
                    when :ignoring_frames then written.map { |one| parse_frame_stretch(one) }
                    when :ignoring_sprites then written && options[:sprite_sizes] ? parse_sprite_sizes(options[:sprite_sizes]) : written
                    when :readings then written.to_h { |one| parse_reading(one) }
                    when :by_passes then parse_pass_count(written)
                    when :comparing then written.map(&:to_sym)
                    when :same then written.to_sym
                    when :lead_ins then lead_ins_named(written)
                    when :saves then save_files_named(written)
                    else written
                    end]
        end
      end

      def parse_rectangle(written, setting)
        numbers = written.split(",")
        return numbers.map(&:to_i) if numbers.size == 4 && numbers.all? { |number| number.match?(/\A\d+\z/) }

        flag = "--#{setting.to_s.tr('_', '-')}"
        raise Refused, "#{flag} #{written} is not a rectangle. Write it as X,Y,WIDTH,HEIGHT, for example #{flag} 0,128,240,32."
      end

      # --sprite-sizes as it is written on a command line: the two sizes of a Super Nintendo
      # cartridge's sprites, small then large, as WIDTHxHEIGHT with a comma between them.
      def parse_sprite_sizes(written)
        sizes = written.split(",").map { |size| size.match(/\A(\d+)x(\d+)\z/)&.captures&.map(&:to_i) }
        return sizes if sizes.size == 2 && sizes.all?

        raise Refused, "--sprite-sizes #{written} is not two sprite sizes. Write the two sizes, small then large, " \
                       "for example --sprite-sizes 8x8,16x16."
      end

      # A stretch as it is written on a command line: two ends with two dots between them,
      # or three to leave the last one out. An end is a frame number or a moment's name, and
      # either can be left off.
      def parse_frame_stretch(written)
        match = written.match(/\A(\w*)(\.{2,3})(\w*)\z/) or raise ArgumentError
        first, last = [match[1], match[3]].map { |text| parse_stretch_end(text) }
        Range.new(first, last, match[2].size == 3)
      rescue ArgumentError
        raise Refused, "--ignoring-frames #{written} is not a range. Write a range of frame numbers or of moments, " \
                       "for example --ignoring-frames 1..120 title..in_the_world."
      end

      def parse_stretch_end(text)
        return nil if text.empty?

        text.match?(/\A\d+\z/) ? text.to_i : text.to_sym
      end

      # A reading as it is written on a command line, which can only be variables: a name
      # alone is the variable of that name on both, and after `=` it is one variable for
      # both, or two with a comma between them, the first cartridge's and the second's.
      def parse_reading(written)
        name, variables = written.split("=", 2)
        variables = (variables || name).split(",").map(&:to_sym)
        if name.to_s.empty? || variables.empty? || variables.size > 2
          raise Refused, "--readings #{written} is not a reading. Write NAME, or NAME=VARIABLE, or NAME=FIRST,SECOND, " \
                         "for example --readings steps hero_x=px,hx."
        end
        [name.to_sym, variables.one? ? variables.first : variables]
      end

      # A count of passes as it is written on a command line: `passes` is the game loop's own
      # count, as for `--in-passes`, and any other word a variable's name; two with a comma
      # between them are the first cartridge's and the second's.
      def parse_pass_count(written)
        counts = written.split(",").map { |one| one == "passes" ? true : one.to_sym }
        return counts.one? ? counts.first : counts if counts.size.between?(1, 2) && !written.end_with?(",")

        raise Refused, "--by-passes #{written} is not a count of passes. Write passes, or VARIABLE, or FIRST,SECOND, " \
                       "for example --by-passes passes or --by-passes ticks,passes."
      end

      def same_script? = options[:same] == "script"

      def say_drifts_or_agreement(result)
        if result.drift?
          result.drifts.each { |drift| say_drift(drift, result) }
        elsif same_script?
          say "The two cartridges agree at every named moment."
        else
          say "The two cartridges agree. #{result.frames} frames were played, and no frame drifted."
        end
        return unless same_script?

        say "The frame each cartridge reached each moment on:"
        say_moments(result.moments) { |ours, theirs| "first #{ours}, second #{theirs}" }
      end

      def say_drift(drift, result)
        if same_script?
          ours, theirs = result.moments.fetch(drift.moment)
          say "The two cartridges drifted at the moment #{drift.moment}: frame #{ours} on the first, frame #{theirs} on the second."
        else
          before = drift.moment ? " The moment named before it was #{drift.moment}." : ""
          say "The two cartridges drifted on frame #{drift.frame}.#{before}"
        end
        if drift.second_frame
          say "  #{"on pass #{drift.pass}: " if drift.pass}frame #{drift.frame} on the first, frame #{drift.second_frame} " \
              "on the second"
        end
        say "  what differed: #{drift.differed.join(', ')}"
        say "  it lasted to frame #{drift.last_frame} (#{HOW_A_DRIFT_ENDED.fetch(drift.ended)})" if drift.last_frame
        say "  report: #{drift.report}" if drift.report
      end

      HOW_A_DRIFT_ENDED = { back_in_step: "then the two were back in step", not_looked_at: "the next frame was not looked at",
                            tape_ran_out: "the last frame that was played" }.freeze
    end
  end
end
