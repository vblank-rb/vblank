# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# THE WINDOW MENU, AS THE DESKTOP BUILD HAS IT (runtime/rg_window_menu.c), held to the Ruby copy
# vblank run draws (Live::Menu): the same keys are played through both, and what each draws after
# every key is compared, box by box and letter by letter, at the densities of an ordinary screen,
# a Retina one and two in between. The C is driven through a small program (menu_harness.c), at
# both of the settings the backend is built at, which have to agree.
class TestNativeWindowMenu < Minitest::Test
  Native = VBlank::IR::Backends::Native
  Computer = VBlank::IR::Backends::Computer
  Zig = Native::Zig
  Menu = VBlank::Live::Menu
  WindowMenu = VBlank::Live::WindowMenu
  # What the Ruby menu is told of the places states are kept in; the C one is told with "slot N WORDS".
  class Slots
    def initialize = @taken = {}
    def set(slot, words) = @taken[slot] = words
    def text_for(slot) = @taken.fetch(slot, "Empty")
  end

  HARNESS = Ractor.make_shareable(File.expand_path("menu_harness.c", __dir__))

  # How the window is drawn after each key, taken in turn: its width and height in pixels, its
  # density, whether the game is held, fast forward's speed, and the frame rate and the frame time,
  # as words.
  DRAWS = [[720, 480, 1.0, false, nil, "60.0", nil], [1440, 960, 2.0, true, nil, "59.9", "4.25"],
           [1080, 720, 1.5, false, 4, nil, nil], [900, 600, 1.25, true, nil, nil, "0.50"]].freeze

  # The game's variables as the window reads them, by "watch NAME VALUE" after "watch_begin".
  WATCHED = [["score", 120], ["lives", 3], ["ball_x", -4], ["ball_y", 77], ["paddle_x", 100], ["frames", 9000],
             ["speed", 2], ["level", 5], ["best_score", 4000], ["timer", 30], ["state", 1], ["hits", 12],
             ["misses", 0], ["a_rather_long_name_for_a_variable", -2_147_483_648]].freeze

  # Every heading, every line, both ends of every slider, each check on and off, and the ways out.
  WALK = [
    "toggle", "press right", "press right", "press right", "press left", "press left", "press down",
    *["press right"] * 7, *["press left"] * 8, "press down", "press down", "press up", "press down", "press down",
    "press right", "press enter", *["press right"] * 12, *["press left"] * 12, "press down", "press enter",
    "press down", "press enter", "press enter", "press down", "press up", "press up", "press up", "press up",
    "press right", "press down", *["press left"] * 11, *["press right"] * 3, "press down", "press enter",
    "press down", "press left", "press enter", "press enter", "toggle", "toggle", "press close", "toggle",
    "press enter", "press up", "press enter"
  ].freeze

  def test_the_c_menu_draws_what_the_ruby_menu_draws_after_every_key
    assert_same_drawing(WALK, most_scale: 6)
  end

  # A screen too small for the size the window was left at: the slider goes no further than fits.
  def test_the_size_goes_no_further_than_the_screen_has_room_for
    assert_same_drawing(["toggle", "press right", "press down", "press right", "press left", "press left", "press left"],
                        most_scale: 2)
  end

  # A hotkey changes a setting while the menu is open, and the line shows it.
  def test_a_hotkey_shows_in_the_menu
    assert_same_drawing(["toggle", "press right", "hotkey frame_rate", "hotkey fullscreen", "press right", "hotkey mute"],
                        most_scale: 10)
  end

  def test_a_picture_of_another_size_is_written_in_the_size_line
    assert_same_drawing(["toggle", "press right", "press down"], most_scale: 10, picture: [160, 144])
  end

  # Keys and gamepad buttons chosen from the menu: a key taken, a key another button has refused in
  # words and waited on, Escape giving up, a gamepad button swapped, a hotkey, and both Resets.
  def test_choosing_keys_draws_the_same
    to_keys = ["toggle", "press right", "press right", "press right"]
    assert_same_drawing([*to_keys, "press down", "press enter", "capture_key 20", "press down", "press enter",
                         "capture_key 20", "capture_key 26", "press down", "press enter", "capture_key 41",
                         "press up", "press enter", "capture_pad 2", "press up", "press enter", "capture_pad 2",
                         "press right", "press down", "press enter", "capture_key 26", "press enter", "capture_key 30",
                         "press up", "press enter", "press left", "press up", "press enter", "toggle"], most_scale: 6)
  end

  def test_quit_is_chosen_from_the_menu_and_resume_closes_it
    assert_equal ["open 0 quit 0", "open 1 quit 1"],
                 ask("toggle", "press down", "press enter", "state", "toggle", "press down", "press down", "press down",
                     "press enter", "state")
  end

  # The Save and Load headings: the slots as they say "Empty" and as they say when a state was
  # taken (set with "slot N WORDS"), the quick lines, and the line chosen on each.
  def test_the_save_and_load_headings_draw_the_same
    to_save = ["toggle", *["press right"] * 5]
    assert_same_drawing([*to_save, "slot 3 2026-11-10 14:03", "slot 0 2026-11-09 09:30", "press down", "press down", "press down",
                         "press down", "press right", *["press down"] * 12, "press up", "press left", "press left", "toggle"],
                        most_scale: 6)
  end

  # Enter on a quick line or a slot asks for a save or a load, closes the menu, and is asked once.
  def test_a_save_or_load_chosen_is_asked_for_once_and_the_menu_closes
    to_save = ["toggle", *["press right"] * 5]
    got = ask(*to_save, "press down", "press enter", "request", "request", "state", "toggle", *["press right"] * 6, "press down",
              "press down", "press down", "press enter", "request", "toggle", *["press right"] * 5, "press down", *["press down"] * 10,
              "press enter", "request")
    assert_equal ["request save 0", "request none", "open 0 quit 0", "request load 2", "request save 10"], got
  end


  # Developer: the window of the game's variables opened, filled, scrolled past its end and back,
  # found by typed letters (S, C, O, an underscore, a digit, Backspace and a key that types nothing),
  # read again with fewer variables, the menu opened over it, and shut by B and by its line; then
  # Show frame time switched on and off.
  def test_the_variables_window_and_the_frame_time_draw_the_same
    to_developer = ["toggle", "press left", "press down"]
    watch = ["watch_begin", *WATCHED.map { |name, value| "watch #{name} #{value}" }]
    assert_same_drawing([*to_developer, "press enter", *watch, *["variables down"] * 4, "variables up", "type_key 22",
                         "type_key 6", "type_key 18", "type_key 42", "type_key 42", "type_key 45", "type_key 30",
                         "type_key 40", "type_key 42", "type_key 42", "watch_begin", "watch lives 2", "toggle", "type_key 22",
                         "toggle", "variables close", *to_developer, "press enter", *to_developer, "press enter",
                         "toggle", "press left", "press down", "press down", "press enter", "press enter"], most_scale: 6)
  end

  # What the window says until a button answers it: the settings file's problems in the middle, a
  # word too wide for the box on a line of its own, an empty line and line breaks at the end; what a
  # shell tells at the foot; both at once, with the menu and the window of variables under them; and
  # a narrow window, where the box is as wide as the window has room for.
  def test_what_the_window_says_until_a_button_answers_draws_the_same
    problems = "problems /home/player/.config/vblank/(all games)/settings.txt:|Line 2: volume is a whole number from 0 " \
               "to 100.||Line 3: \"Nonesuch\" is not a key's name. #{'Averyveryverylongwordwithnospaces' * 3} ends it.||"
    told = "tell That file is not a copy of the game. It is 4 bytes, and a copy is 16777216 bytes. Choose another file."
    assert_same_drawing([problems, "answer", told, "toggle", problems, "press left", "press down", "press enter", "answer",
                         problems, "answer"], most_scale: 6)
    assert_same_drawing([problems, told], most_scale: 2, draws: [[300, 200, 1.0, false, nil, nil, nil], [500, 300, 2.0, false, nil, nil, nil]])
  end

  # A shell's parts keep no states, so their window has no Save or Load, and no F5 or F9.
  def test_a_window_with_no_states_has_no_save_or_load_heading
    with, without = [true, false].map { |states| Native::MenuData.source(states: states) }

    assert_includes with, '"Save"'
    refute_includes without, '"Save"'
    refute_includes without, '"Load"'
    assert_includes without, "rg_game_has_states = 0"
    assert_includes with, "rg_game_has_states = 1"
  end

  # The Keys heading has a line for each of the console's buttons: a Genesis game's has C and no
  # Select, and the Advance's no X, Y or C.
  def test_the_keys_heading_lists_the_buttons_the_console_has
    genesis = Native::MenuData.source(buttons: VBlank::Console::GENESIS.buttons)
    advance = Native::MenuData.source

    assert_includes genesis, '{"C", RG_MENU_BUTTON'
    refute_includes genesis, '{"Select", RG_MENU_BUTTON'
    assert_includes advance, '{"Select", RG_MENU_BUTTON'
    %w[X Y C].each { |name| refute_includes advance, "{\"#{name}\", RG_MENU_BUTTON" }
  end


  private

  # Plays +walk+ through both copies, drawing after each step, and fails at the first line that
  # differs, saying which key it came after.
  def assert_same_drawing(walk, most_scale:, picture: [240, 160], draws: DRAWS)
    menu = Menu.new(picture: picture, scales: 1..most_scale, states: slots = Slots.new)
    commands = ["picture #{picture.join(' ')}", "most_scale #{most_scale}"]
    expected = []
    watched = []
    (["start"] + walk).each_with_index do |step, index|
      play_in_ruby(menu, step, slots, watched) unless step == "start"
      commands << step unless step == "start"
      width, height, density, held, fast, rate, work = draws[index % draws.size]
      commands << "draw #{width} #{height} #{density} #{held ? 1 : 0} #{fast || 0} #{rate || '-'} #{work || '-'}"
      expected << [step, drawing_lines(menu.drawing(width: width, height: height, density: density, held: held,
                                                    fast_forward: fast, frame_rate: rate, frame_work: work,
                                                    variables: watched))]
    end
    said = ask(*commands).slice_after("end").to_a
    expected.each_with_index do |(step, lines), index|
      got = said.fetch(index, [])
      differ = lines.each_index.find { |at| lines[at] != got[at] } || (lines.size if got.size != lines.size)
      next unless differ

      flunk "after \"#{step}\" (step #{index}) the C menu drew\n  #{got[differ].inspect}\nwhere the Ruby one drew\n  " \
            "#{lines[differ].inspect}\n(line #{differ} of what was drawn)"
    end
  end

  def play_in_ruby(menu, step, slots, watched)
    command, name, value = step.split
    case command
    when "slot" then slots.set(name.to_i, step.split(" ", 3).last)
    when "watch_begin" then watched.clear
    when "watch" then watched << [name, value.to_i]
    when "type_key" then menu.type_key(name.to_i)
    when "problems" then menu.problems = step.split(" ", 2).last.tr("|", "\n")
    when "tell" then menu.tell(step.split(" ", 2).last.tr("|", "\n"))
    when "answer" then menu.answer_messages
    when "variables" then menu.press_on_variables(name.to_sym)
    when "toggle" then menu.toggle
    when "press" then menu.press(name.to_sym)
    when "capture_key" then menu.controls.capture_key(name.to_i)
    when "capture_pad" then menu.controls.capture_pad(VBlank::Live::Settings::PAD_BUTTONS.fetch(name.to_i))
    when "hotkey"
      now = menu.settings
      menu.settings = case name
                      when "frame_rate" then now.with(frame_rate: !now.frame_rate)
                      when "fullscreen" then now.with(fullscreen: !now.fullscreen)
                      when "mute" then now.with(muted: !now.muted)
                      end
    end
  end

  # What Live::Menu#drawing gives, as the harness prints the C's.
  def drawing_lines(parts)
    lines = parts.flat_map do |part|
      if part.is_a?(WindowMenu::Box)
        ["box #{[part.x, part.y, part.width, part.height, part.radius, *part.color].join(' ')}"]
      else
        ["words #{part.color.join(' ')} #{part.text}",
         *part.letters.map { |letter| "letter #{[*letter.from, *letter.to].join(' ')}" }]
      end
    end
    lines << "end"
  end

  # What the harness answers to +commands+, a line each, as lines — run at both settings of the
  # backend, which have to agree.
  def ask(*commands)
    input = commands.map { |command| "#{command}\n" }.join
    sources = [HARNESS, menu_data, *%w[rg_window_menu.c rg_menu_font.c rg_window.c].map { |file| File.join(Zig::RUNTIME_DIR, file) }]
    checked, fast = %i[checked fast].map do |mode|
      Computer::ProgramRun.run(Zig.compile_without_sdl(sources, mode: mode), input: input).lines.map(&:chomp)
    end
    assert_equal checked, fast, "the checked and the optimised build should answer alike"
    checked
  end

  # The menu's description and letters as C, where the compiler can read it: in a folder named for
  # what it holds, so a build is kept and found again by what is in it.
  def menu_data
    text = Native::MenuData.source
    path = File.join(Dir.tmpdir, "vblank-native", "menu-#{Digest::SHA256.hexdigest(text)[0, 24]}", Native::MenuData::FILE)
    return path if File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path))
    writing = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
    File.write(writing, text)
    File.rename(writing, path)
    path
  end
end
