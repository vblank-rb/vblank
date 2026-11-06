# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "cli_playing"
require "png_reading"

# `vblank run` with a script or a tape: a game played from the command line with nobody at the
# controls, as Ruby with YJIT on unless --on says another way. It says what it is doing from its
# first line, how many frames went by and where each moment fell, and writes what it is told:
# pictures, the tape, a tape written out for another emulator. These tests run the command with
# no terminal, so there is no window unless --window asks for one.
#
# A person at the controls (no script, no tape) is tested beside the rest of `vblank run`, in
# test/all/vblank/test_cli.rb.
class TestCommandLineRun < Minitest::Test
  include CLIPlaying
  include PNGReading

  BLUE = [0, 0, 255].freeze
  WHITE = [255, 255, 255].freeze

  # A script that asks the Ruby the game runs in whether YJIT is on there. The game runs in a Ruby
  # of its own, which says so itself (`running_jit`), so a wait that gives up says YJIT was off in
  # the process that plays the game, whatever the command's own Ruby has.
  ASK_THE_JIT = <<~RUBY
    VBlank.playthrough "ask the jit" do
      wait_until("YJIT is on", within: 1) { |game| game.running_jit == :yjit }
    end
  RUBY

  # A walker that is heavy every fourth pass: on the cartridge that pass takes more than a frame,
  # so the frames the cartridge plays are more than the passes. Built for a computer it walks four
  # pixels a pass, and on a cartridge two.
  HEAVY_WALKER = <<~RUBY
    require "vblank"

    VBlank.game "HEAVY", consoles: %i[gba gbc] do
      screen :bitmap
      step = built_for_computer? ? 4 : 2
      pass = var :pass, 0
      spent = var :spent, 0
      x = var :x, 20
      game_loop do
        pass += 1
        x += step if held(:right)
        repeat(3000) { spent += 1 } if (pass & 3) == 0
        clear_screen :blue
        draw_rect_at x, 60, 8, 8, :white
      end
    end
  RUBY

  # A tape that says it started from a save.
  FROM_A_SAVE = <<~TAPE
    vblank tape 1
    recorded on: WALKER 0x00000000
    starts from: a save 0x1A2B3C4D

    10 -
  TAPE

  # THE RUN COMMAND ON A GAME FILE AND A SCRIPT says, in its first line, that there is no window,
  # what runs the game and how to get one; then that it builds the game; then what was played. It
  # writes the pictures and the tape where it is told. The picture at :walked shows the box twenty
  # frames of two pixels on from where it began.
  def test_run_with_a_script_plays_with_nobody_at_the_controls_and_says_so
    with_game_and_scripts do |dir|
      out, status = cli("run", "walker.rb", "--script", "walk.rb", "--pictures-in", "pictures",
                        "--write-tape", "walk.tape", dir: dir)
      walked = png_pixels(File.binread(File.join(dir, "pictures", "walked.png")))

      assert status.success?, out
      assert_match(/\ANo window\b.*Ruby #{Regexp.escape(RUBY_VERSION)}, with YJIT.*--window/o, out.lines.first)
      assert_operator out.index("Building WALKER"), :<, out.index("Played"), "it says it builds before it plays"
      assert_match(/^  playing from power-on +[\d.]+s +frame 10$/, out)
      assert_match(/^  Playing on from standing +[\d.]+s +frame 30$/, out)
      assert_match(/Played 60 frames of "walk" on WALKER\./, out)
      assert_match(/standing +frame 10$/, out)
      assert_match(/walked +frame 30$/, out)
      refute_match(/Press P to pause/, out, "nobody is at the controls")
      assert_equal %w[standing.png walked.png], Dir.children(File.join(dir, "pictures")).sort
      assert_equal [BLUE, WHITE], [walked[(60 * 240) + 59], walked[(60 * 240) + 60]], "the box's left edge is at 60"
      assert_equal ["10 -", "moment standing", "20 right", "moment walked", "30 -"],
                   File.readlines(File.join(dir, "walk.tape"), chomp: true).drop(4)
    end
  end

  # YJIT IS ON IN THE PROCESS THAT PLAYS, with a script as with a person, unless --no-yjit says not.
  def test_a_script_is_played_with_yjit_on_unless_told_not
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "jit.rb"), ASK_THE_JIT)

      with_jit, on = cli("run", "walker.rb", "--script", "jit.rb", dir: dir)
      without, off = cli("run", "walker.rb", "--script", "jit.rb", "--no-yjit", dir: dir)

      assert on.success?, with_jit
      refute off.success?, without
      assert_match(/waited until YJIT is on/, without)
      assert_match(/\ANo window\b.*Ruby #{Regexp.escape(RUBY_VERSION)}, with no JIT/o, without.lines.first)
    end
  end

  # A TAPE IN PLACE OF A SCRIPT: the tape the script made plays the same sixty frames and the same
  # two moments, again as Ruby.
  def test_run_plays_a_tape
    with_game_and_scripts do |dir|
      cli("run", "walker.rb", "--script", "walk.rb", "--write-tape", "walk.tape", dir: dir)

      out, status = cli("run", "walker.rb", "--tape", "walk.tape", dir: dir)

      assert status.success?, out
      assert_match(/\ANo window\b.*Ruby/, out.lines.first)
      assert_match(/Played 60 frames of the tape walk\.tape on WALKER\./, out)
      assert_match(/standing +frame 10$/, out)
      assert_match(/walked +frame 30$/, out)
    end
  end

  # --on PICKS ANOTHER WAY OF RUNNING THE GAME, and the first line names it: JavaScript played by
  # node, and C built by zig. The script plays the same on each.
  def test_on_js_and_on_native_run_the_game_another_way
    with_game_and_scripts do |dir|
      { "js" => /JavaScript/, "native" => /\bC\b/ }.each do |way, named|
        out, status = cli("run", "walker.rb", "--script", "walk.rb", "--on", way, dir: dir)

        assert status.success?, out
        assert_match(/\ANo window\b/, out.lines.first)
        assert_match(named, out.lines.first)
        refute_match(/YJIT/, out.lines.first, "#{way} does not run the game in this Ruby")
        assert_match(/walked +frame 30$/, out)
      end
    end
  end

  # --window shows the playing in the window a person plays in, here on SDL's dummy drivers, and
  # then nothing says there is no window.
  def test_window_shows_a_script_playing
    with_game_and_scripts do |dir|
      drivers = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy" }
      out, status = Open3.capture2e(drivers, RUBY, BIN, "run", "walker.rb", "--script", "walk.rb", "--window",
                                    "--settings-file", File.join(dir, "settings.txt"), chdir: dir)
      flunk out.lines.first.chomp if out.include?("cannot find SDL3")

      assert status.success?, out
      refute_match(/No window/, out)
      assert_match(/Played 60 frames of "walk" on WALKER\./, out)
    end
  end

  # A TAPE COUNTED IN PASSES can be made on the rules alone, and played as Ruby. It says what it
  # counts, so playing it asks nothing more.
  def test_a_tape_of_passes_made_on_the_rules_plays_as_ruby
    with_game_and_scripts do |dir|
      out, status = cli("run", "walker.rb", "--script", "walk.rb", "--on", "logic", "--in-passes", "passes",
                        "--write-tape", "walk.tape", dir: dir)

      assert status.success?, out
      assert_includes File.read(File.join(dir, "walk.tape")), "counts: passes\n"

      out, status = cli("run", "walker.rb", "--tape", "walk.tape", dir: dir)

      assert status.success?, out
      assert_match(/walked +frame 30$/, out)
    end
  end

  # A TAPE WRITTEN OUT FOR ANOTHER EMULATOR is how a console is reached from here: the game is
  # built as the Advance's cartridge for it, and the script mGBA loads is written.
  def test_write_mgba_script_writes_the_tape_for_mgba
    with_game_and_scripts do |dir|
      out, status = cli("run", "walker.rb", "--script", "walk.rb", "--write-mgba-script", "walk.lua", dir: dir)

      assert status.success?, out
      assert_match(/Wrote the mGBA script to .*walk\.lua\./, out)
      assert File.file?(File.join(dir, "walk.lua"))
    end
  end

  # THE EXPORT IS IN THE CARTRIDGE'S FRAMES. The run is counted in passes, and the passes are
  # played on the cartridge in the emulator to find the frame each fell on: the heavy walker takes
  # more frames there than passes, so the movie has more frames than the tape has passes.
  def test_an_export_is_the_cartridges_frames_for_the_passes_played
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "heavy.rb"), HEAVY_WALKER)
      out, status = cli("run", "heavy.rb", "--console", "gba", "--script", "walk.rb", "--write-tape", "walk.tape",
                        "--write-bk2", "walk.bk2", dir: dir)

      assert status.success?, out
      assert_includes File.read(File.join(dir, "walk.tape")), "counts: passes\n"
      movie, unzipped = Open3.capture2("unzip", "-p", File.join(dir, "walk.bk2"), "Input Log.txt")
      skip_on_this_machine "unzip is not installed" unless unzipped.success?
      assert_operator movie.lines.grep(/\A\|/).length, :>, 60, "sixty passes take more frames on the cartridge"
    end
  end

  # AN EXPORTED RUN IS THE CARTRIDGE'S GAME. A cartridge answers `built_for_computer?` with false,
  # so a run written out for an emulator is played as the cartridge is built: the walker takes two
  # pixels a pass, and reaches sixty after twenty passes of RIGHT, where with no export it takes ten.
  def test_an_exported_run_plays_the_game_the_cartridge_holds
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "heavy.rb"), HEAVY_WALKER)
      to_sixty = ["run", "heavy.rb", "--console", "gba", "--script", "several.rb", "--playthrough", "walk to sixty"]

      alone, = cli(*to_sixty, dir: dir)
      exported, status = cli(*to_sixty, "--write-bk2", "walk.bk2", dir: dir)

      assert status.success?, exported
      assert_match(/arrived +frame 20$/, alone)
      assert_match(/arrived +frame 30$/, exported)
    end
  end

  # AN EXPORT IS FOR THE ADVANCE'S CARTRIDGE, so another console is refused before anything is built.
  def test_an_export_for_another_console_is_refused_before_the_build
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "heavy.rb"), HEAVY_WALKER)
      File.write(File.join(dir, "color.rb"), HEAVY_WALKER.sub("%i[gba gbc]", "%i[gbc]"))
      File.write(File.join(dir, "color_first.rb"), HEAVY_WALKER.sub("%i[gba gbc]", "%i[gbc gba]"))
      {
        ["heavy.rb", "--console", "gbc"] => /--console gba/,
        ["color_first.rb"] => /--console gba/,
        ["color.rb"] => /COLOR|Game Boy Advance/,
      }.each do |args, says|
        out, status = cli("run", *args, "--script", "walk.rb", "--write-mgba-script", "walk.lua", dir: dir)

        refute status.success?, args.inspect
        assert_match(says, out, args.inspect)
        assert_match(/Game Boy Advance/, out, args.inspect)
        refute_match(/Building/, out, "refused before the build: #{args.inspect}")
      end
    end
  end

  # A TAPE THAT STARTS FROM A SAVE is not played by this command, which starts every game from
  # power-on, and the words say how it is played, with no flag the command does not have.
  def test_a_tape_from_a_save_says_how_it_is_played
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "saved.tape"), FROM_A_SAVE)

      out, status = cli("run", "walker.rb", "--tape", "saved.tape", dir: dir)

      refute status.success?, out
      assert_match(/from a save/, out)
      assert_match(/power-on/, out)
      assert_match(/save:/, out)
      refute_match(/with --save/, out)
    end
  end

  def test_a_tape_says_what_it_counts_so_in_passes_beside_one_is_refused
    with_game_and_scripts do |dir|
      out, status = cli("run", "walker.rb", "--tape", "walk.tape", "--in-passes", "passes", dir: dir)

      refute status.success?, out
      assert_match(/--in-passes cannot go with --tape/, out)
    end
  end

  # A GAME FILE PLAYED AS THE COLOR, with --console gbc: its variables have their names, so a
  # script can wait on one. The box walks from 20 to 60 at two pixels a frame, which is twenty
  # frames of RIGHT after the ten of standing.
  COLOR_WALKER = <<~RUBY
    require "vblank"

    VBlank.game "COLOR WALKER", consoles: %i[gba gbc] do
      screen :tiled
      image(:box, "#" => :white) { "########\\n" * 8 }
      x = 20
      box = sprite :box, at: [x, 60]
      game_loop do
        x += 2 if held(:right)
        box.move_to x, 60
      end
    end
  RUBY

  def test_run_with_console_gbc_plays_the_game_as_the_color
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "color_walker.rb"), COLOR_WALKER)

      out, status = cli("run", "color_walker.rb", "--console", "gbc", "--script", "several.rb",
                        "--playthrough", "walk to sixty", dir: dir)

      assert status.success?, out
      assert_match(/on COLOR WALKER\./, out)
      assert_match(/arrived +frame 30$/, out)
    end
  end

  # --set REACHES THE GAME FILE. The walk to sixty is forty pixels: twenty frames of holding RIGHT
  # at the game's two a frame, and ten at four.
  def test_set_builds_the_game_file_with_a_setting
    with_game_and_scripts do |dir|
      to_sixty = ["run", "walker.rb", "--script", "several.rb", "--playthrough", "walk to sixty"]

      as_written, = cli(*to_sixty, dir: dir)
      quick, status = cli(*to_sixty, "--set", "speed=4", dir: dir)

      assert status.success?, quick
      assert_match(/arrived +frame 30$/, as_written)
      assert_match(/arrived +frame 20$/, quick)
    end
  end

  # A LEAD-IN, named from the script file, is played first and not counted: five frames of one
  # before twelve of standing is still twelve frames played, and the tape says it starts after a
  # lead-in.
  def test_run_plays_a_lead_in_first_and_does_not_count_it
    with_game_and_scripts do |dir|
      out, status = cli("run", "walker.rb", "--script", "several.rb", "--playthrough", "stand",
                        "--lead-in", "five frames", "--write-tape", "stand.tape", dir: dir)

      assert status.success?, out
      assert_match(/Played 12 frames of "stand" on WALKER\./, out)
      assert_equal "starts from: power-on after a lead-in", File.readlines(File.join(dir, "stand.tape"), chomp: true)[2]
    end
  end

  # A TAPE RECORDED AFTER A LEAD-IN needs the lead-in again, and the lead-in is declared in a
  # script file: each thing missing is asked for by its flag, and with both the tape plays its
  # twelve frames.
  def test_a_tape_recorded_after_a_lead_in_asks_for_it_by_its_flag
    with_game_and_scripts do |dir|
      cli("run", "walker.rb", "--script", "several.rb", "--playthrough", "stand", "--lead-in", "five frames",
          "--write-tape", "led-in.tape", dir: dir)
      on_the_tape = ["run", "walker.rb", "--tape", "led-in.tape"]

      no_lead_in, without = cli(*on_the_tape, dir: dir)
      no_script, without_a_script = cli(*on_the_tape, "--lead-in", "five frames", dir: dir)
      out, with = cli(*on_the_tape, "--lead-in", "five frames", "--script", "several.rb", dir: dir)

      refute without.success?
      assert_match(/recorded after a lead-in.*--lead-in.*--script/, no_lead_in)
      refute without_a_script.success?
      assert_match(/no script file was given.*--script/, no_script)
      assert with.success?, out
      assert_match(/Played 12 frames of the tape led-in\.tape on WALKER\./, out)
    end
  end

  # --- what it needs to be told ---

  # A SCRIPT FILE WITH SEVERAL PLAYTHROUGHS AND NONE PICKED is refused, listing them. So is a name
  # it does not declare.
  def test_several_playthroughs_and_none_picked_lists_them
    with_game_and_scripts do |dir|
      [[], ["--playthrough", "run"]].each do |picked|
        out, status = cli("run", "walker.rb", "--script", "several.rb", *picked, dir: dir)

        refute status.success?
        assert_match(/"stand", "walk to sixty", "five frames"/, out)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # A PLAYTHROUGH NAMED WITH A SYMBOL is picked by the same letters, since a command line can only
  # give text.
  def test_a_playthrough_named_with_a_symbol_is_picked_by_its_letters
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "symbols.rb"), <<~RUBY)
        VBlank.playthrough(:stroll) { wait frames: 3 }
        VBlank.playthrough(:amble) { wait frames: 7 }
      RUBY

      out, status = cli("run", "walker.rb", "--script", "symbols.rb", "--playthrough", "amble", dir: dir)

      assert status.success?, out
      assert_match(/Played 7 frames of "amble" on WALKER\./, out)
    end
  end

  # What is wrong is said in plain words and with no backtrace, before the game file is built
  # wherever that can be known.
  def test_what_cannot_be_played_is_said_plainly
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "empty.rb"), "# no playthrough here\n")
      {
        ["walker.rb", "--script", "nope.rb"] => /cannot find the script file nope\.rb/,
        ["walker.rb", "--script", "empty.rb"] => /does not declare a playthrough/,
        ["nope.rb", "--script", "walk.rb"] => /cannot find the game file nope\.rb/,
        ["walker.rb", "--script", "walk.rb", "--lead-in", "nobody"] => /no playthrough named "nobody"/,
        ["walker.rb", "--script", "walk.rb", "--write-tape", "nowhere/walk.tape"] => /--write-tape nowhere\/walk\.tape cannot be written/,
        ["walker.rb", "--script", "walk.rb", "--on", "logic", "--write-tape", "walk.tape"] => /--write-tape cannot go with --on logic/,
        ["walker.rb", "--script", "walk.rb", "--on", "logic", "--pictures-in", "shots"] => /--pictures-in cannot go with --on logic/,
        ["walker.rb", "--script", "walk.rb", "--on", "logic", "--window"] => /--window cannot go with --on logic/,
        ["walker.rb", "--script", "walk.rb", "--on", "basic"] => /--on basic.*ruby, js, native/,
        ["walker.rb", "--script", "walk.rb", "--pictures", "3"] => /--pictures.*person/,
        ["walker.rb", "--write-tape", "walk.tape"] => /--write-tape.*--tape or --script/,
      }.each do |args, says|
        out, status = cli("run", *args, dir: dir)

        refute status.success?, args.inspect
        assert_match(says, out, args.inspect)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # THE COMMAND DOES NOT PLAY A CARTRIDGE: not a cartridge file, not the emulator, not a save.
  # Each is refused with the way a console is reached from here, a tape written out for an
  # emulator somebody already uses.
  def test_a_cartridge_the_emulator_and_a_save_are_refused_naming_the_export
    with_game_and_scripts do |dir|
      File.binwrite(File.join(dir, "walker.gba"), "")
      [
        ["walker.gba", "--tape", "walk.tape"],
        ["walker.rb", "--script", "walk.rb", "--on", "emulator"],
        ["walker.rb", "--script", "walk.rb", "--save", "walked.sav"],
        ["walker.rb", "--script", "walk.rb", "--write-save", "walked.sav"],
      ].each do |args|
        out, status = cli("run", *args, dir: dir)

        refute status.success?, args.inspect
        assert_match(/--write-mgba-script/, out, args.inspect)
        assert_match(/--write-bk2/, out, args.inspect)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # `vblank play` IS GONE: the command that plays a game is `vblank run`, and the refusal says the
  # line to write. A cartridge file is pointed at the export.
  def test_play_is_refused_naming_run
    with_game_and_scripts do |dir|
      out, status = cli("play", "walker.rb", "--tape", "walk.tape", dir: dir)
      cartridge, refused = cli("play", "walker.gba", "--tape", "walk.tape", dir: dir)

      refute status.success?, out
      assert_includes out, "vblank run walker.rb --tape walk.tape"
      refute refused.success?, cartridge
      assert_match(/--write-mgba-script/, cartridge)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # A wait that never ends stops the command with the playthrough's own words for it.
  def test_a_script_that_gives_up_says_so_and_fails
    with_game_and_scripts do |dir|
      File.write(File.join(dir, "never.rb"), <<~RUBY)
        VBlank.playthrough "never" do
          wait_until("the box is at ninety", within: 5) { |game| game.var(:x) >= 90 }
        end
      RUBY

      out, status = cli("run", "walker.rb", "--script", "never.rb", dir: dir)

      refute status.success?
      assert_match(/waited until the box is at ninety/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # THE BUILT-IN HELP describes the one command, and the list no longer names play.
  def test_help_describes_run_with_a_script_or_a_tape
    with_game_and_scripts do |dir|
      list, = cli("help", dir: dir)
      help, = cli("help", "run", dir: dir)

      refute_match(/vblank play\b/, list)
      %w[--script --playthrough --tape --on --no-window --lead-in --pictures-in --write-tape --write-mgba-script
         --write-bk2 --in-passes --set].each { |option| assert_includes help, option }
      assert_match(/YJIT/, help)
    end
  end
end
