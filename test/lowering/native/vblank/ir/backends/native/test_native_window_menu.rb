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

  # How the window is drawn after each key, taken in turn: its width in pixels, its density, whether
  # the game is held, fast forward's speed, and the frame rate and the frame time, as words.
  DRAWS = [[720, 1.0, false, nil, "60.0", nil], [1440, 2.0, true, nil, "59.9", "4.25"], [1080, 1.5, false, 4, nil, nil],
           [900, 1.25, true, nil, nil, "0.50"]].freeze

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


  private

  # Plays +walk+ through both copies, drawing after each step, and fails at the first line that
  # differs, saying which key it came after.
  def assert_same_drawing(walk, most_scale:, picture: [240, 160])
    menu = Menu.new(picture: picture, scales: 1..most_scale, states: slots = Slots.new)
    commands = ["picture #{picture.join(' ')}", "most_scale #{most_scale}"]
    expected = []
    (["start"] + walk).each_with_index do |step, index|
      play_in_ruby(menu, step, slots) unless step == "start"
      commands << step unless step == "start"
      width, density, held, fast, rate, work = DRAWS[index % DRAWS.size]
      commands << "draw #{width} #{density} #{held ? 1 : 0} #{fast || 0} #{rate || '-'} #{work || '-'}"
      expected << [step, drawing_lines(menu.drawing(width: width, density: density, held: held, fast_forward: fast,
                                                    frame_rate: rate, frame_work: work))]
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

  def play_in_ruby(menu, step, slots)
    command, name = step.split
    case command
    when "slot" then slots.set(name.to_i, step.split(" ", 3).last)
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
