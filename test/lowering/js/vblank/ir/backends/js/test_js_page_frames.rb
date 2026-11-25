# frozen_string_literal: true

require "test_helper"
require "web_page"

# The page's frames, as a browser hands them over: a frame of the browser's that comes late finds
# several of the game's passes owed, and plays them all before it draws the last; one that comes
# early finds none. Whatever the browser does, every picture put on the canvas is the picture of
# one whole pass, and a pass costs the browser's collector little.
class TestJSPageFrames < Minitest::Test
  include WebPage

  TILE = Array.new(8) { "#" * 8 }.join("\n").freeze
  BLUE_ROW = 12 # the map's one row of blue tiles
  DOOR_AT = 96  # where the white square stands on the field, in pixels down from its top

  # A field that scrolls up a pixel a pass under a white square kept at one place on it, the square
  # placed from where the view was before the pass moves it, as a game places what stands in a room
  # before it moves its camera. A picture of one pass shows the square at one distance from the blue
  # row; a picture mixing two passes shows it a pixel off.
  private def panning_game
    tile = TILE
    blue_row = BLUE_ROW
    door_at = DOOR_AT
    VBlank.game "PANNING", consoles: %i[gba] do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      image(:door, "#" => :white) { tile }
      tiles :set, "#" => :red_art, "b" => :blue_art
      field = background :field, tiles: :set, map: Array.new(32) { |row| (row == blue_row ? "b" : "#") * 32 }
      doors = pool :door, x: 0, y: 0, capacity: 2, image: :door
      doors.spawn(x: 40, y: door_at)
      view = var :view, 0
      game_loop do
        doors.each { |door| door.y = door_at - view }
        view += 1
        field.scroll_to 0, view
      end
    end
  end

  # How far below the blue row's top the square's top is, down the column x = 44.
  private def door_below_blue(picture)
    column = (0...160).map { |y| picture[(y * 240) + 44] }
    column.index(VBlank::Graphics::Color.resolve(:white)) - column.index(VBlank::Graphics::Color.resolve(:blue))
  end

  def test_every_picture_shows_a_square_pinned_to_the_field_where_one_pass_shows_it
    interpreter = Reference.new.run(panning_game.program, frames: 10).screen.shown
    # Frames as a busy browser hands them out: one a pass, two passes owed, a frame that comes
    # early with none owed, then three passes owed.
    steps = ["play 3", "picture", "play 1", "picture", "skip 1", "play 1", "picture", "play 1", "picture",
             "skip 2", "play 1", "picture", "play 1", "picture"]
    pictures = pictures_in(played_page(steps, panning_game))

    assert_equal 6, pictures.size
    pictures.each_with_index do |picture, i|
      assert_equal door_below_blue(interpreter), door_below_blue(picture), "picture #{i + 1}: the square against the field"
    end
  end

  # A still room: a background and a sprite that never move, and a game that does nothing a pass.
  private def still_room
    tile = TILE
    VBlank.game "STILLROOM", consoles: %i[gba] do
      screen :tiled
      enable_sound
      image(:red_art, "#" => :red) { tile }
      image(:door, "#" => :white) { tile }
      tiles :set, "#" => :red_art
      background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      sprite :door, at: [40, 40]
      game_loop {}
    end
  end

  # What a pass allocates in a room where nothing moves, counted by V8's allocation sampler (the
  # harness's "allocated" step). Each byte is garbage the browser's collector takes back, and a page
  # that leaves it tens of kilobytes a pass, sixty times a second, pauses for it. The budget is the
  # page's own reading of buttons and the runtime's list of sprites, a few kilobytes, with room to
  # spare; the sound mixed a sample at a time once made a little object for every sample, many times
  # the budget.
  ALLOCATED_A_PASS_MOST = 8_000

  def test_a_pass_of_a_still_room_allocates_little
    allocated = played_page(["play 60", "allocated 120"], still_room).grep(/\Aallocated /).first.split.last.to_i

    assert_operator allocated, :<=, ALLOCATED_A_PASS_MOST, "bytes the page allocated a pass"
  end
end
