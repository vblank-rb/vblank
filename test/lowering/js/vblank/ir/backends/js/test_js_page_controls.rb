# frozen_string_literal: true

require "test_helper"
require "web_page"
require "json"

# THE SCREEN AND THE KEYS AS DATA. A page template can write them out (`<%= controls.to_json %>`)
# so a site shows the controls in its own design and sizes the frame before the game loads. The
# same facts come from JS.controls without building a page. The words the default page shows are
# made from the same data, and the data is held to the keys rg_page.js reads.
class TestJSPageControls < Minitest::Test
  include WebPage

  JS = VBlank::IR::Backends::JS

  private def controls_of(console, players: 1, pixel_size: 1)
    kit = VBlank::Console.described(console)
    JSON.parse(JS::Page.controls(screen: kit.framed_screen_size, pixel_size: pixel_size, buttons: kit.buttons, players: players).to_json)
  end

  def test_the_screen_is_the_canvas_size_and_the_pixel_size
    controls = controls_of(:gba, pixel_size: 2)

    assert_equal({ "width" => 240, "height" => 160, "pixel_size" => 2 }, controls.fetch("screen"))
  end

  def test_one_player_has_every_console_button_and_the_pages_own_keys
    controls = controls_of(:gba)

    assert_equal ["KeyX"], controls.dig("first_player", "a")
    assert_equal %w[Backspace ShiftRight], controls.dig("first_player", "select")
    assert_equal ["ArrowRight"], controls.dig("first_player", "right")
    assert_equal VBlank::Console.described(:gba).buttons.map(&:to_s).sort, controls.fetch("first_player").keys.sort
    assert_nil controls.fetch("second_player")
    assert_equal({ "fullscreen" => "KeyF", "menu" => "F1" }, controls.fetch("page_keys"))
  end

  def test_two_players_have_the_second_players_keys_for_the_consoles_buttons
    snes = controls_of(:snes, players: 2)

    assert_equal ["KeyO"], snes.dig("second_player", "a")
    assert_equal ["KeyH"], snes.dig("second_player", "x")
    assert_equal ["KeyL"], snes.dig("second_player", "right")
    assert_equal snes.fetch("first_player").keys.sort, snes.fetch("second_player").keys.sort
    assert_equal ["KeyW"], snes.dig("first_player", "x")
  end

  def test_a_template_writes_the_controls_as_json
    page = built_page(template: "<%= game %><script>const controls = <%= controls.to_json %>;</script>")
    written = JSON.parse(page[/const controls = (.*);<\/script>/m, 1])

    assert_equal [240, 160], written.fetch("screen").values_at("width", "height")
    assert_equal ["KeyX"], written.dig("first_player", "a")
  end

  def test_the_words_on_the_default_page_come_from_the_same_keys
    page = JS::Page.html(title: "WORDS", script: "", screen: [240, 160], players: 2)
    keys = page[%r{<p class="keys">.*?</p>}m]

    assert_includes keys, "<kbd>X</kbd> is A"
    assert_includes keys, "<kbd>Backspace</kbd> is Select"
    assert_includes keys, "<kbd>A</kbd> and <kbd>S</kbd> are L and R"
    assert_includes keys, "<kbd>O</kbd> is A"
    assert_includes keys, "<kbd>7</kbd> and <kbd>9</kbd> are L and R"
  end

  # The data names the keys rg_page.js reads: its two tables are held to it, button for button.
  def test_the_data_is_the_keys_rg_page_js_reads
    source = File.read(VBlank.root.join("lib/vblank/ir/backends/js/runtime/rg_page.js"))
    read = lambda do |name|
      table = source[/^const #{name} = \{(.*?)\};/m, 1]
      table.scan(/(\w+): "(\w+)"/).group_by(&:last).transform_values { |pairs| pairs.map(&:first).sort }
    end
    controls = JSON.parse(JS::Page.controls(screen: [240, 160], buttons: VBlank::IR::Buttons::NAMES, players: 2).to_json)
    written = lambda { |player| controls.fetch(player).transform_values(&:sort) }

    assert_equal read.call("PAGE_KEYS"), written.call("first_player")
    assert_equal read.call("PAGE_SECOND_PLAYER_KEYS"), written.call("second_player")
  end

  def test_controls_come_from_a_game_without_building_a_page
    game = VBlank.game "CONTROLS", consoles: %i[gba], players: { computer: 1..2, else: 1 } do
      screen :bitmap
      game_loop { clear_screen :black }
    end
    controls = JSON.parse(JS.new.controls(game, console: :gba).to_json)

    assert_equal [240, 160], controls.fetch("screen").values_at("width", "height")
    assert_equal ["KeyO"], controls.dig("second_player", "a")
  end
end
