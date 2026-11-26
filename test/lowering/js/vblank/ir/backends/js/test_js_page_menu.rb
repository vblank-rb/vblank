# frozen_string_literal: true

require "test_helper"
require "json"
require "vblank/live"
require "web_page"

# The menu over a web page's game (runtime/rg_page_menu.js), held to the Ruby copy vblank run plays
# (Live::Menu and Live::Settings): the same keys go through both, and what each holds is compared
# after every key. A page lays out its own text, so what is compared is what the menu says: the
# headings, the line chosen, each line's words, and the words of a refusal.
class TestJSPageMenu < Minitest::Test
  include WebPage

  JS = VBlank::IR::Backends::JS
  Live = VBlank::Live

  # SDL's numbers for the keys these tests press, with SDL's names, which the page says the same.
  class KeyNames
    NAMES = { 27 => "X", 29 => "Z", 42 => "Backspace", 229 => "Right Shift", 40 => "Return", 79 => "Right", 80 => "Left", 81 => "Down",
              82 => "Up", 22 => "S", 4 => "A", 19 => "P", 17 => "N", 60 => "F3", 68 => "F", 16 => "M", 58 => "F1", 43 => "Tab",
              20 => "Q", 26 => "W", 7 => "D", 6 => "C" }.freeze
    def name(key) = NAMES[key]
    def key(name) = NAMES.key(name)
  end

  # The places states are kept in, as the Ruby copy is told of them: all empty, as a new page's are.
  class EmptySlots
    def text_for(_slot) = "Empty"
  end

  # A key on the page, and what it is in the Ruby copy: a key for the menu, or a key being chosen.
  MOVES = { right: "ArrowRight", left: "ArrowLeft", up: "ArrowUp", down: "ArrowDown", enter: "Enter" }.freeze
  CHOSEN = { 20 => "KeyQ", 26 => "KeyW", 29 => "KeyZ", 19 => "KeyP", Live::Settings::ESCAPE => "Escape" }.freeze
  # Keys typed into the window of the game's variables, by the browser's names, and SDL's numbers for them.
  TYPED = { "KeyS" => 22, "KeyC" => 6, "KeyO" => 18, "Minus" => 45, "Digit1" => 30, "Backspace" => 42 }.freeze
  # The window of variables scrolled and shut with the menu closed, and the key that does it on the page.
  ON_VARIABLES = { scroll_up: [:up, "ArrowUp"], scroll_down: [:down, "ArrowDown"], shut: [:close, "Escape"] }.freeze

  # +before+ is script run before the game is made: what a browser kept from an earlier visit.
  private def page_with_menu(game = walking_game, more: "", before: "")
    factory, = JS.new.factory_and_data_file(game.program, title: game.title, menu: game.menu?)
    <<~HTML
      <!doctype html>
      <canvas id="one" width="240" height="160"></canvas>
      <script>
      (function () {
      "use strict";
      #{before}
      #{factory}
      window.games = [createGame({ canvas: document.getElementById("one"), menu: true #{more} })];
      })();
      </script>
    HTML
  end

  private def asked_of_page = "js JSON.stringify(games[0].menu)"
  private def asked_with_variables = "js JSON.stringify([games[0].menu, games[0].readState({ lists: false }).vars])"

  # What the page's menu holds after each of +steps+, with the game's variables then as "read_vars". A
  # step "play N" plays N frames rather than pressing a key.
  private def page_says(steps, game = walking_game, before: "")
    played = steps.flat_map { |code| code.start_with?("play ") ? [code, asked_with_variables] : ["down #{code}", "up #{code}", asked_with_variables] }
    lines = played_page([asked_with_variables, *played], html: page_with_menu(game, before: before)).grep(/\Ajs /)
    lines.map do |line|
      shown, vars = JSON.parse(line.delete_prefix("js "))
      shown.merge("read_vars" => vars)
    end
  end

  # The Ruby copy's the same, as the page says it. A page has no window size, and its controllers
  # are numbered as a browser numbers them, so those two are left out. What is over the game is
  # compared too: the words Live::Menu#drawing writes, in the order it writes them, given the
  # variables the page read and its frame time, the game held while the menu is open. A page lays
  # out its own text, so where a line breaks is left out: the words are compared one by one. While
  # the menu is open, Ruby's words go on with the menu's own, which the open heading's lines stand
  # for here.
  private def ruby_says(menu, headings, shown)
    lines = headings.find { |each| each.name == menu.open_heading }&.lines&.reject { |line| line.setting == :scale }
    [menu.open_heading, menu.chosen_line, lines&.map { |line| [line.label, words_of(menu, line)] }, menu.controls.notice,
     words_over(menu, shown)]
  end

  private def words_over(menu, shown)
    drawn = menu.drawing(width: 720, height: 480, density: 1.0, held: menu.open?, variables: shown.fetch("read_vars").to_a,
                         frame_work: (shown.fetch("frame_work") if menu.settings.frame_time))
    words = drawn.grep(Live::WindowMenu::Words).map(&:text).join(" ").split
    menu.open? ? words.first(page_words_over(shown).size) : words
  end

  private def page_words_over(shown) = shown.fetch("over").join(" ").split

  private def words_of(menu, line)
    menu.controls.text_for(line).to_s.split(" / ").first if %i[button hotkey].include?(line.kind)
  end

  private def page_as_ruby_says(shown, headings)
    open = shown.fetch("open")
    words = shown.fetch("lines").zip(page_kinds(shown, headings)).map { |(label, right), bound| [label, (right.split(" / ").first if bound)] } if open
    [shown.fetch("heading"), shown.fetch("chosen"), words, shown.fetch("notice"), page_words_over(shown)]
  end

  private def page_kinds(shown, headings)
    headings.find { |each| each.name == shown.fetch("heading") }.lines.reject { |line| line.setting == :scale }.map { |line| %i[button hotkey].include?(line.kind) }
  end

  # Plays +walk+ through both and fails at the first step they differ. A step is a key for the menu,
  # :toggle, a key chosen for a button (a number), a key typed into the window of variables (its
  # browser name), a key for that window (ON_VARIABLES), "play N" for frames of the game, or
  # :console_button, a console button pressed, which answers what is shown over the picture.
  # +before+ is script run before the page's game is made, and +problems+ what the page is to show
  # it could not use of what it had stored.
  private def assert_same_menu(walk, game = walking_game, before: "", problems: nil)
    buttons = VBlank::Console.described(game.consoles.first).buttons
    headings = Live::WindowMenu.headings(buttons: buttons)
    said = page_says(walk.map { |step| page_code(step) }, game, before: before)
    menu = new_ruby_menu(game, problems)
    [nil, *walk].each_with_index do |step, at|
      play_in_ruby(menu, step) if step
      assert_equal ruby_says(menu, headings, said.fetch(at)), page_as_ruby_says(said.fetch(at), headings), "after step #{at}, #{step}"
    end
    said
  end

  # The Ruby copy as a page of +game+ starts, saying +problems+ over the picture if there are any.
  private def new_ruby_menu(game, problems)
    controls = VBlank::IR::ComputerControls.runtime_numbers(game.program.computer_controls)
    buttons = VBlank::Console.described(game.consoles.first).buttons
    settings = Live::Settings.new(key_names: KeyNames.new, game_controls: controls, buttons: buttons)
    menu = Live::Menu.new(controls: settings, states: EmptySlots.new)
    menu.show_problems(problems, title: JS::MenuData::PROBLEMS_TITLE, intro: JS::MenuData::PROBLEMS_INTRO) if problems
    menu
  end

  # +step+ played through the Ruby menu.
  private def play_in_ruby(menu, step)
    case step
    when :toggle then menu.toggle
    when Integer then menu.controls.capture_key(step)
    when :console_button then menu.answer_messages
    when *ON_VARIABLES.keys then menu.press_on_variables(ON_VARIABLES.fetch(step).first)
    when /\Aplay / then nil
    when String then menu.type_key(TYPED.fetch(step))
    else menu.press(step)
    end
  end

  # What the page is handed for +step+: a key's name, or frames to play.
  private def page_code(step)
    case step
    when :toggle then "F1"
    when Integer then CHOSEN.fetch(step)
    when :console_button then "ArrowRight"
    when *ON_VARIABLES.keys then ON_VARIABLES.fetch(step).last
    when String then step
    else MOVES.fetch(step)
    end
  end

  def test_the_page_menu_walks_as_the_ruby_menu_does
    assert_same_menu([:toggle, :right, :right, :down, :down, :up, :up, :left, :left, :left, :left, :right, :toggle])
  end

  # --- Developer: the window of the game's variables, the frame time, and the stored settings' box ---

  # More variables than the window shows at once, one of them counting frames, so the window is
  # scrolled and read as the game plays.
  private def many_variables_game
    VBlank.game "MANY VARS", consoles: %i[gba] do
      screen :bitmap
      frames = var :frames, 0
      %w[score lives ball_x ball_y paddle_x speed level best_score timer state hits misses].each_with_index do |name, at|
        var name.to_sym, (at * 37) - 100
      end
      game_loop do
        frames += 1
        clear_screen :black
      end
    end
  end

  # Developer is the last heading, so left from Game reaches it.
  TO_DEVELOPER = %i[toggle left down].freeze

  # The window opened from its line, read after frames, scrolled past its end and back, found by
  # typed letters (S, C, O, an underscore, a digit, Backspace), the menu opened over it, and shut by
  # Escape and by its line; then Show frame time switched on, read after a second of frames, and off.
  def test_the_variables_window_and_the_frame_time_go_as_they_do_in_ruby
    steps_shown = assert_same_menu([*TO_DEVELOPER, :enter, "play 3", *[:scroll_down] * 4, :scroll_up, "KeyS", "KeyC", "KeyO", "Backspace",
                      "Backspace", "Minus", "Digit1", "Backspace", "Backspace", "Backspace", "play 2", :toggle, :toggle,
                      :shut, *TO_DEVELOPER, :enter, *TO_DEVELOPER, :enter,
                      *TO_DEVELOPER, :down, :enter, :toggle, "play 70", *TO_DEVELOPER, :down, :enter, :toggle], many_variables_game)
    over = steps_shown.map { |shown| shown.fetch("over").join(" ") }

    assert over.any? { |words| words.include?("lives -63") }, "a variable read as the game plays"
    assert over.any? { |words| words.include?("1 to 12 of 16") }
    assert_includes over, "Game variables sc Name Value score -100 best_score 159 1 to 2 of 2", "found by the letters typed"
    assert over.any? { |words| words.match?(/\A\d+\.\d\d ms of work a frame\z/) }, "the frame time, after a second of frames"
  end

  # What the page kept that it cannot use is shown over the picture, named, until a console button
  # answers it; the rest of what it kept is used.
  def test_stored_settings_the_page_cannot_use_are_shown_until_a_button_answers
    kept = { volume: 300, muted: "yes", fast_forward_speed: 6, frame_time: 1, keys: { right: "KeyQ" }, pads: "x" }
    problems = "vblank-settings, in this site's storage:\n" \
               "volume is a whole number from 0 to 100, not 300.\n" \
               "muted is on or off, not \"yes\".\n" \
               "frame_time is on or off, not 1.\n" \
               "pads is the controller buttons of each button by name, not \"x\", so all of them stay as they were.\n" \
               "keys.right is a list of keys, not \"KeyQ\", so Right keeps the keys it had."
    before = "localStorage.setItem(\"vblank-settings\", #{JSON.generate(JSON.generate(kept))});"
    assert_same_menu(["play 2", :toggle, :toggle, :console_button, "play 1"], before: before, problems: problems)
    shown = page_says(["F1"], before: before).last
    assert_includes shown.fetch("lines"), ["Fast forward", "6x"], "what the page could use is used"
  end

  def test_choosing_keys_on_the_page_goes_as_it_does_in_ruby
    to_keys = [:toggle, :right, :right, :right]
    assert_same_menu([*to_keys, :down, :enter, 20, :down, :enter, 20, 26, :down, :enter, Live::Settings::ESCAPE, :down, :enter, 19,
                      Live::Settings::ESCAPE, :toggle])
  end

  def test_the_hotkeys_heading_goes_as_it_does_in_ruby
    assert_same_menu([:toggle, :right, :right, :right, :right, :down, :enter, 20, :enter, 29, Live::Settings::ESCAPE,
                      *[:down] * 7, :enter, :toggle])
  end

  # The key is the button at once, and is kept for the next visit.
  def test_a_key_chosen_on_the_page_plays_the_game_and_is_remembered
    choose_q_for_right = ["down F1", "up F1", *(["down ArrowRight", "up ArrowRight"] * 3), *(["down ArrowDown", "up ArrowDown"] * 5),
                          "down Enter", "up Enter", "down KeyQ", "up KeyQ", "down F1", "up F1"]
    chosen = pictures_in(played_page([*choose_q_for_right, "down KeyQ", "play 10", "picture one"], html: page_with_menu)).first
    arrows = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first

    assert_same_picture arrows, chosen, "after ten frames holding the key chosen for Right"
    kept = played_page([*choose_q_for_right, 'js localStorage.getItem("vblank-settings")'], html: page_with_menu).grep(/\Ajs /).first
    assert_equal ["KeyQ", nil], JSON.parse(kept.delete_prefix("js ")).dig("keys", "right")
  end

  def test_a_controller_button_chosen_on_the_page_swaps_with_the_one_that_had_it
    steps = ["pad connect", "down F1", "up F1", *(["down ArrowRight", "up ArrowRight"] * 3), "down ArrowDown", "up ArrowDown",
             "down Enter", "up Enter", "pad press 1", "play 1", "pad release 1", asked_of_page]
    shown = JSON.parse(played_page(steps, html: page_with_menu).grep(/\Ajs /).last.delete_prefix("js "))

    assert_equal "X / east", shown.fetch("lines")[0].last
    assert_equal "Z / south", shown.fetch("lines")[1].last
  end

  # --- the game's own keys (computer_keys, computer_gamepad) ---

  # The walking game, with D for Right besides the right arrow, and the north button too.
  private def game_with_keys
    VBlank.game "PAGE KEYS", consoles: %i[gba] do
      computer_keys right: :d
      computer_gamepad right: :north
      screen :bitmap
      x = var :x, 0
      game_loop do
        x += 1 if held(:right)
        clear_screen :black
        draw_rect_at x, 20, 4, 4, :green
      end
    end
  end

  def test_the_controls_show_the_games_keys_and_reset_puts_them_back_as_in_ruby
    to_keys = [:toggle, :right, :right, :right]
    assert_same_menu([*to_keys, *[:down] * 5, :enter, 20, *[:down] * 6, :enter, :toggle], game_with_keys)
  end

  def test_a_games_key_plays_the_button_with_the_menu_and_without
    arrows = pictures_in(played_page(["down ArrowRight", "play 10", "picture"], game_with_keys)).first
    with_d = pictures_in(played_page(["down KeyD", "play 10", "picture"], game_with_keys)).first
    in_menu_page = pictures_in(played_page(["down KeyD", "play 10", "picture one"], game_with_keys, html: page_with_menu(game_with_keys))).first

    assert_same_picture arrows, with_d, "after ten frames holding D"
    assert_same_picture arrows, in_menu_page, "after ten frames holding D on a page with the menu"
  end

  def test_the_games_keys_are_not_kept_for_every_game_on_the_site
    steps = ["down KeyM", "up KeyM", 'js localStorage.getItem("vblank-settings")']
    kept_line = played_page(steps, game_with_keys, html: page_with_menu(game_with_keys)).grep(/\Ajs /).first
    kept = JSON.parse(kept_line.delete_prefix("js "))

    assert_equal ["ArrowRight", nil], kept.dig("keys", "right")
    assert_equal [15, nil], kept.dig("pads", "right")
  end

  # --- the buttons only some consoles have: X, Y and C ---

  # A square lit along the top for each of +console+'s buttons held, in IR::Buttons::NAMES order.
  private def buttons_game_for(console)
    buttons = VBlank::Console.described(console).buttons
    VBlank.game "BUTTONS", consoles: [console] do
      screen :bitmap
      game_loop do
        clear_screen :black
        buttons.each_with_index { |button, i| fill_rect i * 10, 0, 8, 8, :white if held(button) }
      end
    end
  end

  def test_the_c_key_and_the_left_controller_button_press_c_on_a_genesis_page
    pressed_c = played_page(["down KeyC", "play 3", "picture one"], buttons_game_for(:genesis), html: page_with_menu(buttons_game_for(:genesis)))
    pad_c = played_page(["pad connect", "pad press 2", "play 3", "picture one"], buttons_game_for(:genesis),
                        html: page_with_menu(buttons_game_for(:genesis)))
    nothing = played_page(["play 3", "picture one"], buttons_game_for(:genesis), html: page_with_menu(buttons_game_for(:genesis)))

    refute_equal pictures_in(nothing).first, pictures_in(pressed_c).first, "the C key lights C's square"
    assert_same_picture pictures_in(pressed_c).first, pictures_in(pad_c).first, "with the left controller button held"
  end

  def test_w_and_q_press_x_and_y_on_a_super_nintendo_page
    game = buttons_game_for(:snes)
    keys = played_page(["down KeyW", "down KeyQ", "play 3", "picture one"], game, html: page_with_menu(game))
    pad = played_page(["pad connect", "pad press 3", "pad press 2", "play 3", "picture one"], game, html: page_with_menu(game))
    nothing = played_page(["play 3", "picture one"], game, html: page_with_menu(game))

    refute_equal pictures_in(nothing).first, pictures_in(keys).first
    assert_same_picture pictures_in(keys).first, pictures_in(pad).first, "with the top and left controller buttons held"
  end

  # The Advance has no X, Y or C, so W, Q and C hold nothing and :any stays false.
  def test_w_q_and_c_press_nothing_on_an_advance_page
    game = VBlank.game "ANY", consoles: %i[gba] do
      screen :bitmap
      x = var :x, 0
      game_loop do
        x += 1 if held(:any)
        clear_screen :black
        draw_rect_at x, 20, 4, 4, :green
      end
    end
    pressed = played_page(["down KeyW", "down KeyQ", "down KeyC", "play 5", "picture one"], game, html: page_with_menu(game))
    nothing = played_page(["play 5", "picture one"], game, html: page_with_menu(game))

    assert_same_picture pictures_in(nothing).first, pictures_in(pressed).first, "after five frames holding W, Q and C"
  end

  # A Genesis page's Keys heading lists C and no Select, as vblank run's does.
  def test_a_genesis_pages_keys_heading_goes_as_it_does_in_ruby
    assert_same_menu([:toggle, :right, :right, :right, *[:down] * 8, :enter, 26, :toggle], buttons_game_for(:genesis))
  end

  def test_p_pauses_the_page_and_the_menu_holds_the_game
    paused = pictures_in(played_page(["play 3", "down KeyP", "up KeyP", "play 5", "picture one"], ticking_game, html: page_with_menu(ticking_game))).first
    in_menu = pictures_in(played_page(["play 3", "down F1", "up F1", "play 5", "picture one"], ticking_game, html: page_with_menu(ticking_game))).first
    three = pictures_in(played_page(["play 3", "picture"], ticking_game)).first

    assert_same_picture three, paused, "paused after three frames"
    assert_same_picture three, in_menu, "the menu opened after three frames"
  end

  def test_tab_held_plays_at_the_fast_forward_speed
    fast = pictures_in(played_page(["down Tab", "play 3", "picture one"], ticking_game, html: page_with_menu(ticking_game))).first
    nine = pictures_in(played_page(["play 9", "picture"], ticking_game)).first

    assert_same_picture nine, fast, "one frame as the game starts, then two of the browser's at four times the speed"
  end

  def test_a_host_that_does_not_ask_has_no_menu_and_its_p_is_its_own
    html = page_with_menu(ticking_game).gsub("menu: true", "menu: false")
    lines = played_page(["play 3", "down KeyP", "up KeyP", "play 5", "picture one", asked_of_page], ticking_game, html: html)

    assert_same_picture pictures_in(played_page(["play 8", "picture"], ticking_game)).first, pictures_in(lines).first, "P does nothing"
    assert_includes lines, "js null"
  end

  # A page cannot close its tab, so Quit leaves the game's last picture up, each colour a quarter as
  # bright, with the words to reload lit white in the middle. Quit is the third line of Game.
  def test_quit_dims_the_last_picture_and_says_to_reload
    quit = ["play 3", *%w[F1 ArrowDown ArrowDown ArrowDown Enter].flat_map { |code| ["down #{code}", "up #{code}"] }, "play 5", "picture one"]
    quitted = pictures_in(played_page(quit, ticking_game, html: page_with_menu(ticking_game))).first
    three = pictures_in(played_page(["play 3", "picture"], ticking_game)).first

    assert_same_picture stopped_over(three, VBlank::Graphics::Fonts.default), quitted, "after Quit"
  end

  # On a page Escape closes the menu and leaves fullscreen, so Quit names no key there.
  def test_quit_names_no_key_on_a_page
    shown = page_says(["F1"]).last

    assert_includes shown.fetch("lines"), ["Quit", ""]
  end

  # +picture+ dimmed and the stopped words in +font+ lit over it, as the page draws them.
  private def stopped_over(picture, font)
    words = JS::MenuData.stopped_words(font)
    want = picture.map { |color| (color >> 2) & 0x1CE7 }
    left = (240 - words.width) / 2
    top = (160 - words.height) / 2
    words.points.each_slice(2) { |x, y| want[((top + y) * 240) + left + x] = 0x7FFF }
    want
  end

  def test_the_stopped_words_are_in_the_font_the_game_writes_in
    # A block six pixels wide for every letter the words need.
    blocks = "STOPEDRLAYGIN.H".chars.to_h { |char| [char, Array.new(7) { [1] * 6 }] }
    game = VBlank.game "WRITES", consoles: %i[gba] do
      screen :bitmap
      font :wide, glyphs: blocks, fold: :upper
      game_loop do
        draw_number 7, 0, 0, :white, font: :tiny
        draw_text "HI", 0, 10, :white, font: :wide
      end
    end

    font = JS::MenuData.game_font(game.program, 240)
    assert_equal 6, font.width, "the first font with letters, after a font of digits alone"
    assert_equal VBlank::Graphics::Fonts.default, JS::MenuData.game_font(ticking_game.program, 240), "a game that writes nothing"
  end

  def test_a_game_that_says_it_has_no_menu_has_none_on_the_page
    game = VBlank.game("NOMENU", consoles: %i[gba], menu: false) { game_loop {} }

    assert_includes played_page([asked_of_page], html: page_with_menu(game)), "js null"
  end
end
