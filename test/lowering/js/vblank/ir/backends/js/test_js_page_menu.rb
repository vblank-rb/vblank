# frozen_string_literal: true

require "test_helper"
require "json"
require "vblank/live"
require "web_page"

# THE MENU OVER A WEB PAGE'S GAME (runtime/rg_page_menu.js), held to the Ruby copy vblank run plays
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
              20 => "Q", 26 => "W" }.freeze
    def name(key) = NAMES[key]
    def key(name) = NAMES.key(name)
  end

  # A key on the page, and what it is in the Ruby copy: a key for the menu, or a key being chosen.
  MOVES = { right: "ArrowRight", left: "ArrowLeft", up: "ArrowUp", down: "ArrowDown", enter: "Enter" }.freeze
  CHOSEN = { 20 => "KeyQ", 26 => "KeyW", 29 => "KeyZ", 19 => "KeyP", Live::Settings::ESCAPE => "Escape" }.freeze

  private def page_with_menu(game = walking_game, more: "")
    factory, = JS.new.factory_and_data_file(game.program, title: game.title, menu: game.menu?)
    <<~HTML
      <!doctype html>
      <canvas id="one" width="240" height="160"></canvas>
      <script>
      (function () {
      "use strict";
      #{factory}
      window.games = [createGame({ canvas: document.getElementById("one"), menu: true #{more} })];
      })();
      </script>
    HTML
  end

  private def asked_of_page = "js JSON.stringify(games[0].menu)"

  # What the page's menu holds after each of +steps+.
  private def page_says(steps, game = walking_game)
    played = steps.flat_map { |code| ["down #{code}", "up #{code}", asked_of_page] }
    played_page([asked_of_page, *played], html: page_with_menu(game)).grep(/\Ajs /).map { |line| JSON.parse(line.delete_prefix("js ")) }
  end

  # The Ruby copy's the same, as the page says it. A page has no window size, and its controllers
  # are numbered as a browser numbers them, so those two are left out.
  private def ruby_says(menu)
    lines = Live::WindowMenu::HEADINGS.find { |each| each.name == (menu.open_heading || "Game") }.lines.reject { |line| line.setting == :scale }
    [menu.open_heading, menu.chosen_line, lines.map { |line| [line.label, words_of(menu, line)] }, menu.controls.notice]
  end

  private def words_of(menu, line)
    menu.control_text(line).to_s.split(" / ").first if %i[button hotkey].include?(line.kind)
  end

  private def page_as_ruby_says(shown)
    words = shown.fetch("lines").zip(page_kinds(shown)).map { |(label, right), bound| [label, (right.split(" / ").first if bound)] }
    [shown.fetch("heading"), shown.fetch("chosen"), words, shown.fetch("notice")]
  end

  private def page_kinds(shown)
    name = shown.fetch("heading") || "Game"
    Live::WindowMenu::HEADINGS.find { |each| each.name == name }.lines.reject { |line| line.setting == :scale }.map { |line| %i[button hotkey].include?(line.kind) }
  end

  # Plays +walk+ through both and fails at the first step they differ.
  private def assert_same_menu(walk)
    menu = Live::Menu.new(controls: Live::Settings.new(key_names: KeyNames.new))
    expected = [ruby_says(menu)]
    codes = walk.map do |step|
      case step
      when :toggle then menu.toggle
      when Integer then menu.controls.capture_key(step)
      else menu.press(step)
      end
      expected << ruby_says(menu)
      step == :toggle ? "F1" : step.is_a?(Integer) ? CHOSEN.fetch(step) : MOVES.fetch(step)
    end
    said = page_says(codes)
    expected.each_with_index { |want, at| assert_equal want, page_as_ruby_says(said.fetch(at)), "after step #{at}, #{walk[at - 1]}" }
  end

  def test_the_page_menu_walks_as_the_ruby_menu_does
    assert_same_menu([:toggle, :right, :right, :down, :down, :up, :up, :left, :left, :left, :left, :right, :toggle])
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

  def test_a_game_that_says_it_has_no_menu_has_none_on_the_page
    game = VBlank.game("NOMENU", consoles: %i[gba], menu: false) { game_loop {} }

    assert_includes played_page([asked_of_page], html: page_with_menu(game)), "js null"
  end
end
