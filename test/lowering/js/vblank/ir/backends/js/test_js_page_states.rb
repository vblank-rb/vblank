# frozen_string_literal: true

require "test_helper"
require "json"
require "web_page"

# SAVE STATES ON A WEB PAGE (runtime/rg_page.js and rg_page_menu.js): F5 and F9, and the menu's Save
# and Load headings, keep the game's state in the page's storage and put it back between two
# frames, so the game plays on from where it was saved. The browser is the stand-in the page's other
# tests use (page_harness.js).
class TestJSPageStates < Minitest::Test
  include WebPage

  JS = VBlank::IR::Backends::JS

  private def page_with_menu(game = ticking_game, more: "", states: true)
    factory, = JS.new.factory_and_data_file(game.program, title: game.title, menu: game.menu?, code: game.identifying_code, states: states)
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

  private def played(steps, game = ticking_game, more: "")
    played_page(steps, game, html: page_with_menu(game, more: more))
  end

  private def key(code) = ["down #{code}", "up #{code}"]
  private def shown_menu = "js JSON.stringify(games[0].menu)"
  private def menu_after(lines) = JSON.parse(lines.grep(/\Ajs /).last.delete_prefix("js "))

  # The square moves a pixel every frame, so a picture says how far the game has got. Saved after
  # three frames (and done as the fourth ends), played on to ten, then loaded: the next picture is
  # the one the saved moment showed.
  def test_the_quick_state_puts_the_game_back_where_it_was_saved
    saved = pictures_in(played(["play 3", *key("F5"), "play 1", "picture one"])).first
    back = pictures_in(played(["play 3", *key("F5"), "play 1", "play 6", *key("F9"), "play 1", "picture one"])).first
    on = pictures_in(played(["play 3", *key("F5"), "play 1", "play 6", "picture one"])).first

    refute_equal saved, on
    assert_same_picture saved, back, "after loading the quick state"
  end

  # Kept in the page's storage under the game's title and code, not the title alone.
  def test_a_state_is_kept_under_the_games_title_and_code
    code = VBlank::Cartridge::GameCode.for("TICKING")
    name = "vblank-state:TICKING:#{code}:0"
    lines = played(["play 3", *key("F5"), "play 1", "js localStorage.getItem(#{name.to_json}).slice(0, 60)"])

    assert_match(/\{"at":\d+,"text":"vblank-state 1/, lines.grep(/\Ajs /).last)
  end

  # Down to the Save heading's Slot 2 and Enter; the menu closes so the game goes on, and the slot
  # now says when the state was taken where it said it was empty.
  def test_a_slot_chosen_in_the_menu_saves_there_and_then_says_when
    to_save = [*key("F1"), *([key("ArrowRight")] * 5).flatten, *([key("ArrowDown")] * 3).flatten]
    before = menu_after(played([*to_save, shown_menu]))
    after = menu_after(played([*to_save, *key("Enter"), "play 2", *key("F1"), *([key("ArrowRight")] * 5).flatten, shown_menu]))

    assert_equal "Save", before.fetch("heading")
    assert_equal ["Slot 2", "Empty"], before.fetch("lines")[2]
    assert_equal "Slot 2", after.fetch("lines")[2].first
    assert_match(/\A\d{4}-\d\d-\d\d \d\d:\d\d\z/, after.fetch("lines")[2].last)
    assert_equal ["Slot 1", "Empty"], after.fetch("lines")[1]
  end

  def test_a_slot_with_no_state_is_said_and_the_game_plays_on
    to_load = [*key("F1"), *([key("ArrowRight")] * 6).flatten, *([key("ArrowDown")] * 4).flatten, *key("Enter"), "play 1", *key("F1"),
               *([key("ArrowRight")] * 6).flatten]
    shown = menu_after(played([*to_load, shown_menu]))

    assert_match(/no state in slot 3/, shown.fetch("notice"))
  end

  # A state another build saved is refused in plain words, before anything changes.
  def test_a_state_from_another_build_is_refused
    code = VBlank::Cartridge::GameCode.for("TICKING")
    other = { at: 1_700_000_000_000, text: "vblank-state 1\nbuild gba 0123456789abcdef\n" }.to_json
    keep = "js localStorage.setItem(#{"vblank-state:TICKING:#{code}:3".to_json}, #{other.to_json})"
    to_load = [*key("F1"), *([key("ArrowRight")] * 6).flatten, *([key("ArrowDown")] * 4).flatten, *key("Enter"), "play 1", *key("F1"),
               *([key("ArrowRight")] * 6).flatten]
    shown = menu_after(played([keep, *to_load, shown_menu]))

    assert_match(/another build/, shown.fetch("notice"))
  end

  # A page with no storage has nowhere to keep a state, so its menu has no Save or Load.
  def test_a_page_with_no_storage_has_no_save_or_load_heading
    shown = menu_after(played([*key("F1"), shown_menu], more: ", storage: null"))

    refute_includes shown.fetch("headings"), "Save"
    refute_includes shown.fetch("headings"), "Load"
  end

  # A shell's parts run one after another and would write one set of slots, so none offers states.
  def test_a_shell_part_has_no_save_or_load_and_no_quick_keys
    lines = played_page(["play 3", *key("F5"), "play 1", kept_quick_state, *key("F1"), shown_menu], ticking_game,
                        html: page_with_menu(states: false))

    assert_includes lines, "js kept:null"
    refute_includes menu_after(lines).fetch("headings"), "Save"
  end

  # F5 while the game is paused with P is done at once: one frame plays, as a step does, to the boundary
  # where a state is taken, and the game stays paused.
  def test_a_state_asked_for_while_paused_is_done_at_once_and_the_game_stays_paused
    lines = played(["play 3", *key("KeyP"), *key("F5"), kept_quick_state])
    held = pictures_in(played(["play 3", *key("KeyP"), *key("F5"), "play 5", "picture one"])).first
    stepped = pictures_in(played(["play 3", *key("KeyP"), *key("KeyN"), "picture one"])).first

    assert(lines.any? { |line| line.start_with?("js kept:{") }, "a state is kept at once")
    assert_same_picture stepped, held, "paused, one frame after the state was asked for"
  end

  def test_a_game_with_no_menu_has_no_states
    html = page_with_menu.gsub("menu: true", "menu: false")
    lines = played_page(["play 3", *key("F5"), "play 1", kept_quick_state, shown_menu], ticking_game, html: html)

    assert_includes lines, "js kept:null"
    assert_includes lines, "js null"
  end

  # What the page's storage holds for the quick state, as a word: "kept:null" for nothing.
  private def kept_quick_state
    code = VBlank::Cartridge::GameCode.for("TICKING")
    "js 'kept:' + localStorage.getItem(#{"vblank-state:TICKING:#{code}:0".to_json})"
  end
end
