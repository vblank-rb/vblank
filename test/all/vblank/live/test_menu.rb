# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# The menu over the window a game is played in (WindowMenu says what it holds): a bar
# of headings, the open heading's lines under it, worked with the arrows and Enter. These play it
# with no window at all, and read what it would have a window draw.
class TestMenu < Minitest::Test
  Menu = VBlank::Live::Menu
  WindowMenu = VBlank::Live::WindowMenu

  def test_a_menu_starts_closed_with_the_desktop_builds_settings
    menu = Menu.new

    refute menu.open?
    assert_equal({ fast_forward_speed: 4, scale: 3, fullscreen: false, volume: 100, muted: false, frame_rate: true,
                   frame_time: false },
                 menu.settings.to_h)
  end

  # Opened, it shows the first heading's lines with none of them chosen, so the next key a player
  # presses moves somewhere rather than changing something.
  def test_a_menu_opens_on_the_bar_with_no_line_chosen
    menu = opened

    assert_equal "Game", menu.open_heading
    assert_nil menu.chosen_line
  end

  # Left and right on the bar go from heading to heading, round at either end, and choose no line
  # under any of them: passing the window's size on the way to the sound leaves it as it was.
  def test_left_and_right_on_the_bar_move_between_headings_and_change_nothing
    menu = opened
    menu.press(:right)
    menu.press(:right)
    assert_equal "Sound", menu.open_heading
    assert_nil menu.chosen_line

    4.times { menu.press(:right) }
    assert_equal "Game", menu.open_heading
    menu.press(:left)
    assert_equal "Developer", menu.open_heading
    assert_equal WindowMenu::STARTING, menu.settings
  end

  def test_down_or_enter_goes_into_the_lines_and_up_from_the_first_comes_back
    menu = opened
    menu.press(:down)
    assert_equal "Resume", menu.chosen_line

    menu.press(:up)
    assert_nil menu.chosen_line
    menu.press(:enter)
    assert_equal "Resume", menu.chosen_line
  end

  # Down past the last line goes round to the first.
  def test_down_goes_round_the_lines
    menu = opened
    4.times { menu.press(:down) }

    assert_equal "Resume", menu.chosen_line
  end

  # On a slider, left and right change its number a step at a time, never past what it can be.
  def test_left_and_right_on_a_slider_change_it
    menu = opened
    2.times { menu.press(:down) }
    6.times { menu.press(:right) }
    assert_equal 8, menu.settings.fast_forward_speed

    menu.press(:right)
    menu.press(:right)
    menu.press(:right)
    menu.press(:right)
    menu.press(:left)
    menu.press(:left)
    assert_equal 6, menu.settings.fast_forward_speed
  end

  def test_volume_goes_in_tens
    menu = opened
    2.times { menu.press(:right) }
    menu.press(:down)
    3.times { menu.press(:left) }

    assert_equal 70, menu.settings.volume
  end

  # On a line that is not a slider, left and right go on to the next heading, back on the bar.
  def test_left_and_right_on_another_line_move_to_the_next_heading
    menu = opened
    menu.press(:down)
    menu.press(:right)

    assert_equal "Window", menu.open_heading
    assert_nil menu.chosen_line
  end

  def test_enter_switches_a_check_on_and_off
    menu = opened
    menu.press(:right)
    2.times { menu.press(:down) }
    menu.press(:enter)
    assert menu.settings.fullscreen

    menu.press(:enter)
    refute menu.settings.fullscreen
  end

  def test_enter_on_resume_closes_the_menu_and_on_quit_asks_to_stop
    menu = opened
    menu.press(:down)
    menu.press(:enter)
    refute menu.open?

    menu.toggle
    3.times { menu.press(:down) }
    menu.press(:enter)
    assert menu.quit?
  end

  # The gamepad's B closes the menu from anywhere in it.
  def test_close_closes_the_menu
    menu = opened
    menu.press(:down)
    menu.press(:close)

    refute menu.open?
  end

  # A menu opened again starts on the bar, on the first heading.
  def test_a_menu_opens_again_on_the_first_heading
    menu = opened
    menu.press(:right)
    menu.press(:down)
    menu.toggle
    menu.toggle

    assert_equal "Game", menu.open_heading
    assert_nil menu.chosen_line
  end

  # The window is made no bigger than the frontend says fits on the screen.
  def test_the_window_size_goes_no_higher_than_the_frontend_allows
    menu = Menu.new(scales: 1..4)
    menu.toggle
    menu.press(:right)
    menu.press(:down)
    5.times { menu.press(:right) }

    assert_equal 4, menu.settings.scale
  end

  # --- what it has a window draw ---

  # The Keys heading, on the line of the console button at +place+.
  private def on_key_line(menu, place)
    menu.toggle
    3.times { menu.press(:right) }
    (place + 1).times { menu.press(:down) }
  end

  # Every line of the Keys heading, from the first down to Reset.
  private def key_lines(menu)
    on_key_line(menu, 0)
    lines = [menu.chosen_line]
    lines << menu.tap { menu.press(:down) }.chosen_line until lines.last == "Reset"
    lines
  end

  def test_a_key_chosen_from_the_menu_is_that_button_and_is_kept
    menu = Menu.new
    on_key_line(menu, 0)
    menu.press(:enter)

    assert_includes menu.controls.capture_prompt, "for A"
    assert menu.controls.capture_key(20)
    refute_predicate menu.controls, :capturing?
    assert_equal :a, menu.controls.button_of_key(20)
    assert_nil menu.controls.button_of_key(27)
    assert_predicate menu.controls, :unwritten?
    assert_includes menu.controls.text, "key.a = key 20\n"
  end

  def test_a_key_another_button_has_is_refused_in_words_and_the_wait_goes_on
    menu = Menu.new
    on_key_line(menu, 0)
    menu.press(:enter)
    menu.controls.capture_key(29)

    assert_match(/already the B button/, menu.controls.notice)
    assert_predicate menu.controls, :capturing?
    assert_equal :b, menu.controls.button_of_key(29)
  end

  def test_a_hotkeys_key_is_refused_and_escape_gives_up
    menu = Menu.new
    on_key_line(menu, 0)
    menu.press(:enter)
    menu.controls.capture_key(19)

    assert_match(/hotkey for "Pause"/, menu.controls.notice)
    menu.controls.capture_key(VBlank::Live::Settings::ESCAPE)
    refute_predicate menu.controls, :capturing?
    assert_equal :a, menu.controls.button_of_key(27), "A keeps its key"
  end

  def test_a_gamepad_button_chosen_from_the_menu_swaps_with_the_one_that_had_it
    menu = Menu.new
    on_key_line(menu, 0)
    menu.press(:enter)
    menu.controls.capture_pad(:south)

    assert_equal :south, menu.controls.pad_of(:a)
    assert_equal :east, menu.controls.pad_of(:b)
  end

  def test_reset_puts_keys_and_gamepad_buttons_back
    menu = Menu.new
    on_key_line(menu, 0)
    menu.press(:enter)
    menu.controls.capture_key(20)
    menu.press(:enter)
    menu.controls.capture_pad(:south)
    10.times { menu.press(:down) }
    assert_equal "Reset", menu.chosen_line
    menu.press(:enter)

    assert_equal :a, menu.controls.button_of_key(27)
    assert_equal :east, menu.controls.pad_of(:a)
  end

  # The Keys heading lists the console's buttons: a Genesis pad's C, and no Select, L or R.
  def test_the_keys_heading_lists_the_buttons_the_console_has
    controls = VBlank::Live::Settings.new(key_names: Menu::NumberedKeys.new, buttons: VBlank::Console::GENESIS.buttons)

    assert_equal %w[A B Start Right Left Up Down C Reset], key_lines(Menu.new(controls: controls))
    assert_equal %w[A B Select Start Right Left Up Down R L Reset], key_lines(Menu.new)
  end

  # A window told no console has the Advance's buttons, written down without the consoles, since a
  # game written out as Ruby carries the menu and not them.
  def test_a_window_told_no_console_has_the_advances_buttons
    assert_equal VBlank::Console::ADVANCE.buttons, WindowMenu::ADVANCE_BUTTONS
  end

  # Choosing a key for C, the eighth line of a Genesis menu, gives the key to C.
  def test_a_key_chosen_for_c_presses_c
    controls = VBlank::Live::Settings.new(key_names: Menu::NumberedKeys.new, buttons: VBlank::Console::GENESIS.buttons)
    menu = Menu.new(controls: controls)
    on_key_line(menu, 7)
    menu.press(:enter)

    assert_includes menu.controls.capture_prompt, "for C"
    menu.controls.capture_key(7)
    assert_equal :c, menu.controls.button_of_key(7)
  end

  def test_closing_the_menu_ends_a_choice
    menu = Menu.new
    on_key_line(menu, 0)
    menu.press(:enter)
    menu.toggle

    refute_predicate menu.controls, :capturing?
  end

  def test_the_bar_shows_every_heading_and_the_open_headings_lines
    words = drawn_words(opened)

    assert_equal %w[Game Window Sound Keys Hotkeys Developer Resume F1 Fast\ forward 4x Quit Esc], words.map(&:text)
  end

  def test_a_closed_menu_draws_nothing_but_what_the_window_is_doing
    assert_empty Menu.new.drawing(width: 720, height: 480, density: 1)

    status = Menu.new.drawing(width: 720, height: 480, density: 1, held: true, fast_forward: nil, frame_rate: 60)
    assert_equal ["60 fps", "PAUSED"], status.grep(WindowMenu::Words).map(&:text)
  end

  # A line about the match (a player left) is said in the corner too, under what the window is doing,
  # so a player in fullscreen, who sees no title bar, reads it.
  def test_a_notice_is_said_in_the_corner_under_the_status
    status = Menu.new.drawing(width: 720, height: 480, density: 1, frame_rate: 60, notice: "Player 2 left the match.")

    assert_equal ["60 fps", "Player 2 left the match."], status.grep(WindowMenu::Words).map(&:text)
  end

  def test_fast_forward_is_said_in_the_corner_with_its_speed
    status = Menu.new.drawing(width: 720, height: 480, density: 1, fast_forward: 4)

    assert_equal ["FAST FORWARD 4x"], status.grep(WindowMenu::Words).map(&:text)
  end

  # The size line says what the window would be, and a check mark is drawn only for a check that
  # is on.
  def test_the_window_heading_says_the_size_and_marks_what_is_on
    menu = opened(settings: WindowMenu::STARTING.with(frame_rate: true))
    menu.press(:right)

    assert_equal ["Size", "3x  (720 × 480)", "Fullscreen", "Show frame rate", "✓"],
                 drawn_words(menu).map(&:text).drop(6)
  end

  # The chosen line has the chosen colour behind it, across the box.
  def test_the_chosen_line_has_a_bar_behind_it
    menu = opened
    menu.press(:down)
    resume = drawn_words(menu).find { |words| words.text == "Resume" }
    behind = menu.drawing(width: 720, height: 480, density: 1).grep(WindowMenu::Box)
                 .select { |box| box.color == WindowMenu::COLORS[:chosen] }

    assert_equal 1, behind.size
    assert_operator behind.first.y, :<=, resume.letters.first.to.fetch(1)
    assert_operator behind.first.y + behind.first.height, :>, resume.letters.first.to.fetch(1)
  end

  # On a screen with twice the pixels each way, the menu is drawn at twice the pixels, so it is
  # the same size to the eye and sharper: here the bar, and the corner of the box under Game.
  def test_a_retina_screen_draws_the_menu_at_twice_the_pixels
    one = opened.drawing(width: 720, height: 480, density: 1).grep(WindowMenu::Box)
    two = opened.drawing(width: 1440, height: 960, density: 2).grep(WindowMenu::Box)

    assert_equal [0, 0, 1440, 44], [two[0].x, two[0].y, two[0].width, two[0].height]
    assert_equal [one[0].width * 2, one[0].height * 2], [two[0].width, two[0].height]
    lines_box = ->(boxes) { boxes.find { |box| box.color == WindowMenu::COLORS[:border] } }
    assert_equal [lines_box.call(one).x * 2, lines_box.call(one).y * 2], [lines_box.call(two).x, lines_box.call(two).y]
  end

  # --- saving and loading states ---

  # What a menu is told of the places a state is kept: when each was taken, or that it is empty.
  class Slots
    def initialize(taken = {}) = @taken = taken
    def text_for(slot) = @taken.fetch(slot, "Empty")
  end

  # A menu with no places to keep states in (a match with other players) offers none.
  def test_a_menu_with_no_places_for_states_has_no_save_or_load_heading
    menu = opened
    2.times { menu.press(:left) }

    assert_equal "Hotkeys", menu.open_heading
    2.times { menu.press(:right) }
    assert_equal "Game", menu.open_heading
  end

  def test_save_and_load_headings_follow_hotkeys_where_states_can_be_kept
    menu = opened(states: Slots.new)
    4.times { menu.press(:right) }
    assert_equal "Hotkeys", menu.open_heading
    menu.press(:right)
    assert_equal "Save", menu.open_heading
    menu.press(:right)
    assert_equal "Load", menu.open_heading
  end

  # A slot says whether it holds a state, and when it was taken, at the right of its line.
  def test_each_slot_says_whether_it_holds_a_state_and_when
    menu = opened(states: Slots.new(3 => "2026-11-10 14:03"))
    5.times { menu.press(:right) }
    words = drawn_words(menu).map(&:text)

    assert_equal ["Quick Save", "F5", "Slot 1", "Empty", "Slot 2", "Empty", "Slot 3", "2026-11-10 14:03"], words.drop(8).first(8)
  end

  def test_quick_save_asks_for_the_quick_state_and_closes_the_menu
    menu = opened(states: Slots.new)
    5.times { menu.press(:right) }
    menu.press(:down)
    menu.press(:enter)

    refute menu.open?
    assert_equal WindowMenu::StateRequest.new(action: :save, slot: 0), menu.take_state_request
    assert_nil menu.take_state_request
  end

  def test_a_slot_chosen_to_load_asks_to_load_that_slot
    menu = opened(states: Slots.new)
    6.times { menu.press(:right) }
    4.times { menu.press(:down) }
    menu.press(:enter)

    assert_equal WindowMenu::StateRequest.new(action: :load, slot: 3), menu.take_state_request
  end

  # A shell's window has no places for states while its menu and unpacking play, and has them once its
  # game does.
  def test_states_offered_later_add_the_save_and_load_headings
    menu = opened
    menu.states = Slots.new
    5.times { menu.press(:right) }

    assert_equal "Save", menu.open_heading
    menu.states = nil
    assert_equal "Game", menu.open_heading
    2.times { menu.press(:left) }
    assert_equal "Hotkeys", menu.open_heading
  end

  # --- the developer's heading: the game's variables, and the frame time ---

  # Some of a game's variables, as a frontend reads them from the game while it plays.
  VARIABLES = [["score", 120], ["lives", 3], ["ball_x", -4], ["ball_y", 77], ["paddle_x", 100], ["frames", 9000],
               ["speed", 2], ["level", 5], ["best_score", 4000], ["timer", 30], ["state", 1], ["hits", 12],
               ["misses", 0], ["bonus", 50]].freeze

  def test_game_variables_under_developer_opens_the_window_and_closes_the_menu
    menu = on_developer_line(0)
    assert_equal "Game variables", menu.chosen_line
    menu.press(:enter)

    refute menu.open?
    assert menu.variables_open?
  end

  # The window has a line for each variable and its value, under a heading that stays put, as many
  # lines as fit; the rest are reached with down.
  def test_the_variables_window_lists_each_variable_and_scrolls
    menu = with_variables_open
    words = variable_words(menu)
    assert_equal ["Game variables", "Type letters to find a name", "Name", "Value", "score", "120", "lives", "3"], words.first(8)
    assert_includes words, "1 to 12 of 14"
    refute_includes words, "misses"

    3.times { menu.press_on_variables(:down) }
    words = variable_words(menu)
    assert_equal %w[Name Value ball_x -4], words[2, 4], "down past the end goes no further than the last line"
    assert_includes words, "bonus"
    assert_includes words, "3 to 14 of 14"

    menu.press_on_variables(:up)
    assert_includes variable_words(menu), "2 to 13 of 14"
  end

  # Letters typed find the variables whose names have them, in any case; Backspace takes the last off.
  def test_typed_letters_filter_the_variables_by_name
    menu = with_variables_open
    [22, 6, 18].each { |letter| assert menu.type_key(letter) } # S, C and O, by where they sit on the keyboard
    words = variable_words(menu)

    assert_equal ["sco", "Name", "Value", "score", "120", "best_score", "4000", "1 to 2 of 2"], words.drop(1)
    assert menu.type_key(WindowMenu::BACKSPACE_KEY)
    assert menu.type_key(WindowMenu::BACKSPACE_KEY)
    assert_includes variable_words(menu), "1 to 9 of 9", "s alone is in nine names"
    [27, 27].each { |letter| menu.type_key(letter) } # X, X
    assert_includes variable_words(menu), "No name has these letters"
  end

  # Only the keys that type a name are the window's, and none of them while the menu is open over it.
  def test_only_letters_digits_and_the_underscore_are_typed
    menu = with_variables_open
    refute menu.type_key(40), "Return types nothing"
    refute menu.type_key(WindowMenu::BACKSPACE_KEY + 1000)
    menu.toggle
    refute menu.type_key(22), "the menu open over the window has the keys"
  end

  # The gamepad's B closes the window; so does Game variables chosen again.
  def test_close_or_game_variables_again_shuts_the_window
    menu = with_variables_open
    menu.press_on_variables(:close)
    refute menu.variables_open?

    menu = with_variables_open
    on_developer_line(0, menu)
    menu.press(:enter)
    refute menu.variables_open?
  end

  # Show frame time is a check under Developer, and the frame time is the menu's setting.
  def test_show_frame_time_is_switched_under_developer
    menu = on_developer_line(1)
    assert_equal "Show frame time", menu.chosen_line
    menu.press(:enter)

    assert menu.settings.frame_time
    assert_includes drawn_words(menu).map(&:text), "✓"
  end

  # --- what the window says over the picture until a button is pressed ---

  # What could not be used in the settings file is said over the picture, in the middle, with an OK
  # that the next button pressed answers.
  def test_settings_file_problems_are_said_until_a_button_answers
    menu = Menu.new
    menu.problems = "settings.txt:\nLine 2: volume is a whole number from 0 to 100."
    words = drawn_words(menu).map(&:text)

    assert_equal ["The settings file", "The window cannot use some of the settings file. It uses the rest, and",
                  "the game plays as usual.", "settings.txt:", "Line 2: volume is a whole number from 0 to 100.", "OK",
                  "Press a button to close this."], words
    assert menu.messages_shown?
    menu.answer_messages
    assert_empty drawn_words(menu)
  end

  # What a shell tells the player is said at the foot of the window, until a button answers it.
  def test_what_a_shell_tells_is_said_at_the_foot_until_a_button_answers
    menu = Menu.new
    menu.tell("That file is not a copy of the game.")
    words = menu.drawing(width: 720, height: 480, density: 1)

    assert_equal ["Load ROM", "That file is not a copy of the game.", "OK", "Press a button to close this."],
                 words.grep(WindowMenu::Words).map(&:text)
    assert_operator words.grep(WindowMenu::Box).first.y, :>, 300, "at the foot of the window"
    menu.answer_messages
    refute menu.messages_shown?
  end

  # A menu over a game for several players offers a match, under a heading after Game: how many
  # players a host waits for, and the four ways to start one. A menu told nothing of a match (a game
  # for one player, a match already begun, the desktop build and the web page) has none.
  def test_a_menu_offers_a_match_only_when_told_how_many_players_it_can_take
    refute_includes headings_of(opened), WindowMenu::MATCH

    menu = opened(match_players: 4)
    assert_equal ["Game", WindowMenu::MATCH], headings_of(menu).first(2)
    menu.press(:right)
    assert_equal ["Players", "Host by address", "Host with a room code", "Join by address", "Join by room code"],
                 lines_under(menu)

    menu.match_players = nil
    refute_includes headings_of(menu), WindowMenu::MATCH
  end

  # Players is a slider from two to the most the game takes, and the host waits for that many.
  def test_host_asks_for_a_match_of_the_players_chosen_and_closes_the_menu
    menu = on_match_line(5, "Players")
    5.times { menu.press(:right) }
    assert_includes drawn_words(menu).map(&:text), "5"
    menu.press(:down)
    menu.press(:enter)

    assert_equal WindowMenu::MatchRequest.new(does: :host, text: nil, players: 5), menu.take_match_request
    refute menu.open?
    assert_nil menu.take_match_request, "asked once"
  end

  def test_a_room_code_host_asks_for_the_relay
    menu = on_match_line(4, "Host with a room code")
    menu.press(:enter)

    assert_equal WindowMenu::MatchRequest.new(does: :host_code, text: nil, players: 2), menu.take_match_request
  end

  # Join by address waits for the address to be typed, shown on its line as it is typed, and Enter
  # asks to join it. The key with the semicolon on it types the colon an address has before its port.
  def test_join_by_address_takes_the_address_typed_then_enter
    menu = on_match_line(4, "Join by address")
    menu.press(:enter)
    assert menu.typing?

    "127.0.0.1;7777".each_char { |char| menu.type_key(scancode_of(char)) }
    menu.type_key(scancode_of("8"))
    menu.type_key(WindowMenu::BACKSPACE_KEY)
    assert_includes drawn_words(menu).map(&:text), "127.0.0.1:7777_"
    assert_nil menu.take_match_request, "nothing is asked before Enter"
    menu.press(:enter)

    assert_equal WindowMenu::MatchRequest.new(does: :join_address, text: "127.0.0.1:7777", players: nil), menu.take_match_request
    refute menu.typing?
    refute menu.open?
  end

  # A room code is written in capitals, as the relay makes it, whatever is typed.
  def test_join_by_room_code_writes_the_code_in_capitals
    menu = on_match_line(4, "Join by room code")
    menu.press(:enter)
    "ab12".each_char { |char| menu.type_key(scancode_of(char)) }
    menu.type_key(scancode_of(".")) # a code has no dot
    menu.press(:enter)

    assert_equal WindowMenu::MatchRequest.new(does: :join_code, text: "AB12", players: nil), menu.take_match_request
  end

  # An address that is not one is said under the lines when Enter is pressed, and nothing is asked: the
  # game plays on, and the player mends it.
  def test_an_address_that_is_not_one_is_said_on_enter_and_asks_nothing
    menu = on_match_line(4, "Join by address")
    menu.press(:enter)
    "host;".each_char { |char| menu.type_key(scancode_of(char)) }
    menu.press(:enter)

    assert_nil menu.take_match_request
    assert menu.typing?
    assert_match(/HOST:PORT/, menu.typing_problem)
    assert_includes drawn_words(menu).map(&:text), menu.typing_problem
    menu.type_key(scancode_of("1"))
    assert_nil menu.typing_problem, "said until the next key"
    menu.press(:enter)
    assert_equal "host:1", menu.take_match_request.text
  end

  # Enter with nothing typed asks for nothing, and closing gives up the typing and keeps the menu open.
  def test_typing_is_given_up_by_closing_and_asks_nothing_when_empty
    menu = on_match_line(4, "Join by address")
    menu.press(:enter)
    menu.press(:enter)
    assert_nil menu.take_match_request

    assert menu.cancel_typing
    refute menu.typing?
    assert menu.open?
    refute menu.cancel_typing, "nothing left to give up"
  end

  private

  def headings_of(menu)
    names = []
    menu.toggle unless menu.open?
    first = menu.open_heading
    loop do
      names << menu.open_heading
      menu.press(:right)
      break if menu.open_heading == first
    end
    names
  end

  def lines_under(menu)
    menu.press(:down)
    lines = [menu.chosen_line]
    lines << menu.tap { menu.press(:down) }.chosen_line until menu.chosen_line == lines.first && lines.size > 1
    lines[0...-1]
  end

  # An open menu offering a match for up to +most+ players, on the line called +label+ under Match.
  def on_match_line(most, label)
    menu = opened(match_players: most)
    menu.press(:right)
    menu.press(:down)
    menu.press(:down) until menu.chosen_line == label
    menu
  end

  # SDL's scancode for the key that types +char+ (the semicolon's key for a colon).
  def scancode_of(char)
    case char
    when "a".."z" then WindowMenu::LETTER_KEYS.min + char.ord - "a".ord
    when "1".."9" then WindowMenu::DIGIT_KEYS.min + char.to_i - 1
    when "0" then WindowMenu::DIGIT_KEYS.max
    when "." then WindowMenu::PERIOD_KEY
    when ";" then WindowMenu::SEMICOLON_KEY
    end
  end

  def opened(**options)
    menu = Menu.new(**options)
    menu.toggle
    menu
  end

  # The Developer heading, the last, on its line at +index+.
  def on_developer_line(index, menu = Menu.new)
    menu.toggle
    menu.press(:left)
    (index + 1).times { menu.press(:down) }
    menu
  end

  def with_variables_open
    menu = on_developer_line(0)
    menu.press(:enter)
    menu
  end

  def variable_words(menu)
    menu.drawing(width: 720, height: 480, density: 1, variables: VARIABLES).grep(WindowMenu::Words).map(&:text)
  end

  def drawn_words(menu) = menu.drawing(width: 720, height: 480, density: 1).grep(WindowMenu::Words)
end
