# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# WHICH ROUTINES GO IN THE CONSOLE'S QUICK MEMORY, decided by measuring the game.
#
# It is the one choice a build cannot measure its way to on its own: the choice is an input to
# the lowering, so it has to be made before the cartridge it would run exists. So the game is
# built once, run, and built again knowing — and these tests are about that loop closing.
#
# The fixture is built so the answer is unmistakable: the routine doing the work is only
# reachable through a scene the game does not boot into, so a build that measures it and a
# build that guesses cannot land in the same place.
class TestMeasuredPlacement < Minitest::Test
  include EmulatorSupport

  Placement = VBlank::IR::Backends::GBA::Placement

  def setup
    require_emulator!
  end

  # The work lives in the second scene. Nothing reaches it by holding a button — a scene is
  # switched by a press, and a held button is one press however long it is held.
  private def game_with_work_in_a_later_scene
    VBlank.game("MPLC", consoles: %i[gba], code: "MPLC", maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      x = 0

      scene(:title) { x += 1 }
      scene(:playing) { call :the_hot_one }
      func(:the_hot_one) { repeat(3000) { x += 1 } }

      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
  end

  private def placement_for(profile)
    game_with_work_in_a_later_scene
      .build_rom(out: StringIO.new, err: StringIO.new, profile: profile).built.placement
  end

  def test_a_measured_build_keeps_the_routine_the_game_really_spends_its_frames_in
    placement = placement_for(true)

    assert_equal :measurement, placement.chosen_from
    assert_includes placement.funcs, :the_hot_one,
                    "the work is in a scene the game never boots into, and measuring finds it anyway"
  end

  def test_without_measuring_the_choice_is_made_from_the_shape_and_says_so
    placement = placement_for(false)

    assert_equal :shape, placement.chosen_from
  end

  # The report has to say which of the two happened, because an author cannot tell by reading
  # the list and the difference is a factor of about two and a third on whatever is on it.
  def test_the_report_says_which_answer_it_gave
    %i[measurement shape].each do |expected|
      out = StringIO.new
      rom = game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: StringIO.new,
                                                      profile: expected == :measurement)
      VBlank::Diagnostics::BuildReport.render(rom, out: out)

      if expected == :measurement
        assert_match(/chosen from a measurement/, out.string)
      else
        assert_match(/chosen from the shape of the program/, out.string)
        assert_match(/measures/, out.string, "...and says how to get the measured one")
      end
    end
  end

  # A ROUTINE ON EVERY SCREEN OUTRANKS ONE ON A SINGLE SCREEN THAT DOES LESS IN ALL. The game
  # loop runs on every frame the player ever sees; a menu's routine runs on one screen they see
  # for a moment. Ranking each by its busiest screen weighed the two as though both ran on one,
  # and a file-select screen seen once took the quick memory from the game loop.
  #
  # Here :everywhere does 300 steps on each of four screens and :one_screen 800 on one: less
  # than it on the one screen, and far more than it across the game.
  private def game_with_a_routine_on_every_screen
    VBlank.game("MPL3", consoles: %i[gba], maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      x = 0
      func(:everywhere) { repeat(300) { x += 1 } }
      func(:one_screen) { repeat(800) { x += 1 } }
      scene(:logos) { x += 1 }
      scene(:title) { x += 1 }
      scene(:files) { call :one_screen }
      scene(:playing) { x += 1 }
      game_loop do
        call :everywhere
        case_var(:state) do
          when_val 0, :logos
          when_val 1, :title
          when_val 2, :files
          when_val 3, :playing
        end
      end
    end
  end

  def test_a_routine_on_every_screen_outranks_one_on_a_single_screen
    rom = game_with_a_routine_on_every_screen.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    work = VBlank::Diagnostics::Profiler.survey_scenes(rom, frames: 10).work
    ranked = VBlank::Diagnostics::RoutineProfile.from_work(work).order_by_work(%i[one_screen everywhere])

    assert_equal %i[everywhere one_screen], ranked, "measured: #{work.slice(:everywhere, :one_screen)}"
  end

  # --- a measurement saved and read back ---

  def test_a_saved_measurement_decides_the_next_build
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.profile.json")
      first = game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: StringIO.new,
                                                        profile: false)
      VBlank::Diagnostics::RoutineProfile.from_work(VBlank::Diagnostics::Profiler.survey_scenes(first, frames: 10).work).write(path)

      placement = placement_for(path)

      assert_equal :measurement, placement.chosen_from
      assert_includes placement.funcs, :the_hot_one
    end
  end

  # A profile that has drifted from its game keeps deciding the placement, so the drift is
  # said out loud rather than left to work quietly.
  def test_a_measurement_naming_a_routine_the_game_no_longer_has_says_so
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stale.profile.json")
      VBlank::Diagnostics::RoutineProfile.from_work({ a_routine_since_renamed: 5000 }).write(path)

      err = StringIO.new
      game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: err, profile: path)

      assert_match(/a_routine_since_renamed/, err.string)
      assert_match(/measure the game again/, err.string)
    end
  end

  # ...and the routines the BUILD invents are not drift. One glyph walker per font appears and
  # disappears as a game changes, and saying so every time would train an author to ignore it.
  def test_a_routine_the_build_made_is_not_reported_as_drift
    Dir.mktmpdir do |dir|
      path = File.join(dir, "built.profile.json")
      VBlank::Diagnostics::RoutineProfile.from_work({ VBlank::Messages::MadeNames.make(:digit_routine, font: :default) => 5000 }).write(path)

      err = StringIO.new
      game_with_work_in_a_later_scene.build_rom(out: StringIO.new, err: err, profile: path)

      refute_match(/out of date/, err.string)
    end
  end

  # --- what an author says wins ---

  # The measurement decides what the framework picks; it never overrules the author. A routine
  # insisted on is placed before anything the chooser wanted, measured or not.
  def test_an_author_still_overrules_the_measurement
    game = VBlank.game("MPL2", consoles: %i[gba], code: "MPL2", maker: "01") do
      screen :bitmap
      clear_screen :black
      x = 0
      func(:never_run, fast: true) { repeat(3000) { x += 1 } }
      game_loop { x += 1 }
    end
    placement = game.build_rom(out: StringIO.new, err: StringIO.new).built.placement

    assert_includes placement.funcs, :never_run,
                    "measured at nothing, and kept anyway because the author asked"
  end

  # A SAVE NOBODY MAKES WHILE THE GAME IS MEASURED, measured all the same: the two screens that
  # save are each measured with a save running, so the routine that writes it a piece a pass is
  # weighed by what it costs there, and kept without the game insisting on it.
  def test_a_save_is_measured_and_kept_without_fast_true
    game = VBlank.game("MSAV", consoles: %i[gba]) do
      screen :bitmap
      score = 0
      saved = Array.new(40) { |n| var :"saved#{n}", 0 } # enough to write that its writing is worth the room
      files = save_data :file, copies: 2 do
        keep score
        saved.each { |value| keep value }
      end
      var :state, 0
      scene(:files) { files[0].save if pressed(:a) }
      scene(:playing) do
        score += 1
        files[1].save if pressed(:start)
      end
      game_loop do
        case_var(:state) do
          when_val 0, :files
          when_val 1, :playing
        end
      end
    end
    placement = game.build_rom(out: StringIO.new, err: StringIO.new, profile: true).built.placement
    step = VBlank::Messages::MadeNames.make(:save_record, record: :file, piece: :step)

    assert_includes placement.funcs, step, "the save's writing is kept, measured, with nothing insisted on"
  end

  # --- what a scene is measured doing ---

  # A ROUTINE THAT RUNS ONLY WHILE A BUTTON IS DOWN. The build measures each scene with nobody
  # at the controls, so without a word from the game it measures :fighting at nothing.
  private def game_that_fights_while_b_is_held(measuring)
    VBlank.game("MHLD", consoles: %i[gba], maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      x = 0
      scene(:title) { x += 1 }
      scene(:playing, **measuring) { call :fighting if held(:b) }
      func(:fighting) { repeat(3000) { x += 1 } }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
  end

  def test_a_routine_run_only_while_a_button_is_held_is_measured_at_nothing_without_measure_holding
    placement = game_that_fights_while_b_is_held({}).build_rom(out: StringIO.new, err: StringIO.new).built.placement

    assert_equal :measurement, placement.chosen_from
    refute_includes placement.funcs, :fighting, "nobody holds B while the scene is measured"
  end

  def test_measure_holding_puts_the_routine_the_held_button_runs_in_quick_memory
    placement = game_that_fights_while_b_is_held({ measure_holding: %i[b] })
                .build_rom(out: StringIO.new, err: StringIO.new).built.placement

    assert_includes placement.funcs, :fighting, "the scene was measured holding B"
  end

  def test_the_report_says_what_a_scene_was_measured_holding
    rom = game_that_fights_while_b_is_held({ measure_holding: %i[b up] }).build_rom(out: StringIO.new, err: StringIO.new)
    out = StringIO.new
    VBlank::Diagnostics::BuildReport.render(rom, out: out)

    assert_match(/:playing.*measured holding B \+ UP/, out.string)
    refute_match(/:title.*measured holding/, out.string, "a scene that says nothing is measured standing still")
  end

  # A BUTTON READ AS IT GOES DOWN fires once however long it is held, so a scene where a
  # pistol fires on each press is measured with a tape: here B down for a frame and up for one,
  # over and over.
  def test_a_tape_given_to_measure_holding_is_played_round_while_the_scene_is_measured
    tape = VBlank::Playthroughs::Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: MTAP 0x00000000
      starts from: power-on

      1 b
      1 -
    TAPE
    game = VBlank.game("MTAP", consoles: %i[gba], maker: "01") do
      screen :bitmap
      clear_screen :black
      var :state, 0
      x = 0
      scene(:title) { x += 1 }
      scene(:playing, measure_holding: tape) { call :fighting if pressed(:b) }
      func(:fighting) { repeat(3000) { x += 1 } }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
    rom = game.build_rom(out: StringIO.new, err: StringIO.new)
    out = StringIO.new
    VBlank::Diagnostics::BuildReport.render(rom, out: out)

    assert_includes rom.built.placement.funcs, :fighting, "B went down thirty times in the measured frames"
    assert_match(/:playing.*measured playing a tape of 2 frames/, out.string)
  end

  # A routine measured at almost nothing is not worth the room: moving it costs a longer call
  # at every site, every frame, and gives back only a share of what little it runs.
  def test_a_routine_that_hardly_runs_is_not_worth_the_room
    profile = VBlank::Diagnostics::RoutineProfile.from_work({ busy: 5000, idle: 3 })

    assert profile.worth_quick_memory?(:busy)
    refute profile.worth_quick_memory?(:idle)
    assert_equal %i[busy idle], profile.order_by_work(%i[idle busy]), "dearest first"
  end
end
