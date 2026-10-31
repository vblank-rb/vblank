# frozen_string_literal: true

require "test_helper"

# The games these tests play, shared with the Advance's own twin of them
# (test/console/gba/vblank/builder/test_still_frames_on_the_advance.rb).
#
# A SCREEN THAT IS REBUILT WHOLE draws its picture again from everything it is made of: the
# backdrop, each background where it is scrolled to, the sprites over them. A game that scrolls
# a background even once is one, and so is one that bends, turns or fades a layer. Each such
# game asks for that rebuild itself every frame, when it says where its backgrounds are and when
# its sprites are drawn, so nothing that changes the picture has ever had to ask on its own
# account. A run that skips the rebuild on a frame where the scroll and the sprites stand still
# gains a great deal, and finds out whether anything else changes the picture but never asked.
#
# Every game here holds its scroll and its sprite exactly still, and on one frame changes ONE
# other thing, so nothing else in the picture covers for it. Nine frames follow it, all still,
# and each is compared with the interpreter on the runs that check every frame, so a picture
# that should have changed and did not is seen on the frame it was due and on every one after.
module StillFrameGames
  include SharedConstants

  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  YELLOW = VBlank::Graphics::Color.resolve(:yellow)
  BLACK = VBlank::Graphics::Color.resolve(:black)

  # The frame (counting passes of the game loop from 1) that the game changes its one thing on,
  # and how many frames are played in all.
  CHANGE_AT = 3
  FRAMES = 12

  # Where every game holds its background, and a pixel well inside the cell (7, 5) of its map,
  # which is where the games that change one tile change it.
  SCROLL = [3, 5].freeze
  CELL_PIXEL = [56, 38].freeze

  # A map of red tiles, and one of blue, 32 cells across and down, which no console shows more than.
  RED_FIELD = Ractor.make_shareable(Array.new(32) { "#" * 32 })
  BLUE_FIELD = Ractor.make_shareable(Array.new(32) { "o" * 32 })

  # A map of columns, alternately red and blue, and a pixel that is in a red one with the map at
  # its corner and in a blue one scrolled by SCROLL.
  COLUMNS = Ractor.make_shareable(Array.new(32) { "#o" * 16 })
  COLUMN_PIXEL = [6, 3].freeze

  # The left half of each tile red and the right half green, for the games that swap colours.
  BARS = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # A program built for this run's console, so a game laid out from its `screen_height` is laid
  # out for the console it is played on.
  private def program(&block)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console))
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def screen_height = VBlank::Console.described(game_console).screen_height

  # A tiled game with the pictures every case here draws from — a red, a blue and a green tile
  # and a white ball — and one sprite standing still. +game+ says the rest, in the game's own
  # verbs, and ends with its game loop.
  private def still_game(&game)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      image(:green_art, "#" => :green) { tile }
      image(:ball, "#" => :white) { tile }
      tiles :set, "#" => :red_art, "o" => :blue_art, "g" => :green_art
      ball = sprite :ball, at: [120, 90]
      instance_exec(ball, &game)
    end
  end

  # The colour at +where+ once the whole game has been played.
  private def shown_at_the_end(prog, where = CELL_PIXEL)
    game_player.run(prog, frames: FRAMES).screen.pixel(*where)
  end

  # The ball's pixel at its first place, which is white while it stands there, and the same
  # distance inside it eight pixels along.
  BALL_PIXEL = [122, 92].freeze
  BALL_PIXEL_EIGHT_ALONG = [130, 92].freeze
end

class TestStillFrames < Minitest::Test
  include StillFrameGames

  # --- what is drawn over the scenery: the sprites are what moves on a screen whose scroll stands
  # still, and a rebuild skipped for a sprite that did move is a ball left where it was ---

  def test_a_sprite_that_moves_on_a_screen_whose_scroll_stands_still_is_drawn_where_it_is
    prog = still_game do |ball|
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        ball.x += 8 if tick == CHANGE_AT
      end
    end
    screen = game_player.run(prog, frames: FRAMES).screen

    assert_equal [RED, VBlank::Graphics::Color.resolve(:white)],
                 [screen.pixel(*BALL_PIXEL), screen.pixel(*BALL_PIXEL_EIGHT_ALONG)]
  end

  def test_a_sprite_hidden_on_a_screen_whose_scroll_stands_still_is_gone
    prog = still_game do |ball|
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        ball.hide if tick == CHANGE_AT
      end
    end

    assert_equal RED, shown_at_the_end(prog, BALL_PIXEL)
  end

  # --- what the scenery is made of ---

  def test_a_tile_set_on_a_still_screen_shows
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        field.set_tile 7, 5, "o" if tick == CHANGE_AT
      end
    end

    assert_equal BLUE, shown_at_the_end(prog)
  end

  def test_another_map_on_a_still_screen_shows
    prog = still_game do
      field = background :field, tiles: :set, map: { first: RED_FIELD, second: BLUE_FIELD }
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        field.show_map :second if tick == CHANGE_AT
      end
    end

    assert_equal BLUE, shown_at_the_end(prog)
  end

  # A room of another area is drawn from that area's own set of tiles, which land where the
  # first area's did, so the colour is the only thing that says the second set came in.
  def test_the_tiles_of_another_area_on_a_still_screen_show
    prog = still_game do
      image(:shrine_floor, "#" => :red) { SOLID_TILE }
      image(:clearing_grass, "#" => :green) { SOLID_TILE }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: RED_FIELD }, clearing: { glade: RED_FIELD } }
      tick = var :tick, 0
      where = var :room, 0
      game_loop do
        ground.scroll_to(*SCROLL)
        tick += 1
        where = 1 if tick == CHANGE_AT
        ground.show_map where
      end
    end

    assert_equal GREEN, shown_at_the_end(prog)
  end

  # The whole layer drawn from another list of colours: not one cell of the map moves.
  def test_a_layer_drawn_in_other_colours_on_a_still_screen_shows
    prog = program do
      screen :tiled
      image :bar, width: 8, height: 8, data: BARS, colors: %i[transparent red green]
      colors :shimmer, %i[transparent yellow white]
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        rays.scroll_to(*SCROLL)
        tick += 1
        rays.draw_with :shimmer if tick == CHANGE_AT
      end
    end

    assert_equal YELLOW, shown_at_the_end(prog)
  end

  # Tiles the game paints while it runs: a pixel drawn into a canvas shows on the frame after.
  def test_a_pixel_drawn_into_a_canvas_on_a_still_screen_shows
    prog = still_game do
      colors :ink, %i[transparent white red blue]
      board = canvas :board, width: 64, height: 16, colors: :ink
      front = background :front, tiles: :board, map: board.cells
      tick = var :tick, 0
      game_loop do
        front.scroll_to(*SCROLL)
        tick += 1
        board.pixel 20, 8, :white if tick == CHANGE_AT
      end
    end

    assert_equal VBlank::Graphics::Color.resolve(:white), shown_at_the_end(prog, [17, 3])
  end

  # --- which scenery is up ---

  # A scene with a background of its own takes over from one with none, and the other way round.
  # The scene's own background is put up as the scene arrives, and its scroll said every frame.
  private def scenes_with_and_without_a_cover(cover_first:)
    still_game do
      state = var :state, cover_first ? 1 : 0
      tick = var :tick, 0
      scene(:bare) {}
      scene(:covered) do
        cover = background :cover, tiles: :set, map: BLUE_FIELD
        cover.scroll_to(*SCROLL)
      end
      game_loop do
        tick += 1
        state = cover_first ? 0 : 1 if tick == CHANGE_AT
        case_var(:state) do
          when_val 0, :bare
          when_val 1, :covered
        end
      end
    end
  end

  def test_a_background_put_up_by_a_scene_on_a_still_screen_shows
    assert_equal BLUE, shown_at_the_end(scenes_with_and_without_a_cover(cover_first: false))
  end

  def test_a_background_taken_down_by_a_scene_on_a_still_screen_is_gone
    assert_equal BLACK, shown_at_the_end(scenes_with_and_without_a_cover(cover_first: true))
  end

  # A scene that comes back puts its background up again, and for the pass it arrives in the
  # picture shows that background from its corner. The scroll it was last given is still there,
  # and the game says it again, so the number written is the one already stored: what the
  # picture shows is what changes. Columns of two colours, so the corner and the scroll differ.
  def test_a_scene_coming_back_on_a_still_screen_shows_its_background_where_it_is_scrolled
    prog = still_game do
      state = var :state, 0
      tick = var :tick, 0
      scene(:bare) {}
      scene(:covered) { background(:cover, tiles: :set, map: COLUMNS).scroll_to(*SCROLL) }
      game_loop do
        tick += 1
        state = 1 if tick == 2
        state = 0 if tick == 5
        state = 1 if tick == CHANGE_AT + 4
        case_var(:state) do
          when_val 0, :bare
          when_val 1, :covered
        end
      end
    end

    assert_equal BLUE, shown_at_the_end(prog, COLUMN_PIXEL)
  end

  def test_one_scenes_background_replaced_by_anothers_on_a_still_screen_shows
    prog = still_game do
      state = var :state, 0
      tick = var :tick, 0
      scene(:first) { background(:red_field, tiles: :set, map: RED_FIELD).scroll_to(*SCROLL) }
      scene(:second) { background(:blue_field, tiles: :set, map: BLUE_FIELD).scroll_to(*SCROLL) }
      game_loop do
        tick += 1
        state = 1 if tick == CHANGE_AT
        case_var(:state) do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end

    assert_equal BLUE, shown_at_the_end(prog)
  end

  # --- what sits over the scenery ---

  # A status bar slid down off the field it covered: the field shows where the bar was.
  def test_a_status_bar_moved_on_a_still_screen_shows_the_field_where_it_was
    bar_row = screen_height - 40
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      bar = status_bar :score, tiles: :set, map: ["g" * 32] * 5, top: bar_row
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        bar.move_to screen_height if tick == CHANGE_AT
      end
    end

    assert_equal RED, shown_at_the_end(prog, [8, bar_row + 4])
  end

  # A fade over the whole screen is laid over the picture as it is shown, and so is the
  # picture it lifts from.
  def test_a_fade_begun_on_a_still_screen_shows
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        fade :black, 100 if tick == CHANGE_AT
      end
    end

    assert_equal BLACK, shown_at_the_end(prog)
  end

  def test_a_fade_that_lifts_on_a_still_screen_shows_the_picture_again
    prog = still_game do
      field = background :field, tiles: :set, map: RED_FIELD
      tick = var :tick, 0
      game_loop do
        field.scroll_to(*SCROLL)
        tick += 1
        fade :black, 100 if tick < CHANGE_AT
        fade :black, 0 if tick == CHANGE_AT
      end
    end

    assert_equal RED, shown_at_the_end(prog)
  end
end
