# frozen_string_literal: true

require "test_helper"
require "stringio"

%w[animate font_styles fonts grid_cursor level maze pixels scroll sheet sparks sprite_mover tiles].each do |name|
  ShareableConstants.require_file(VBlank.root.join("examples", name).to_s)
end
require VBlank.root.join("tools/make_example_assets").to_s # the art's colors, so expectations track the source

# The small examples that name the Game Boy Color beside the other consoles, each played as the
# Color: its cartridge in the emulator, checked against the interpreter on every frame, under one
# tape of buttons. Each test asserts one thing the example's own header says a player sees. The
# Color's screen is 160 by 144, so every place read here is the one the example lays out from
# screen_width and screen_height.
class TestSmallExamplesOnTheColor < Minitest::Test
  Color = VBlank::Graphics::Color
  FRAMES = 150

  # Right, down, A, left, up and nothing, twenty frames each.
  TAPE = lambda do |frame|
    case (frame - 1) / 20
    when 0 then [:right]
    when 1 then [:down]
    when 2 then [:a]
    when 3 then [:left]
    when 4 then [:up]
    else []
    end
  end

  # Plays +game+ as the Color for FRAMES frames under TAPE. The block is handed the player and the
  # frame on each frame, to read the picture then; the player is returned, to read the end.
  private def play(game, &each_frame)
    player = game_player.input_each_frame(&TAPE)
    player.each_vblank { |frame| each_frame.call(player, frame) } if each_frame
    player.run(game.program(console: :gbc), frames: FRAMES)
  end

  # The left, top, right and bottom pixels of the +color+ on +screen+, or nil where it is not there.
  private def box_of(screen, color)
    lit = (0...screen.height).flat_map { |y| (0...screen.width).filter_map { |x| [x, y] if screen.pixel(x, y) == color } }
    lit.empty? ? nil : [lit.map(&:first).min, lit.map(&:last).min, lit.map(&:first).max, lit.map(&:last).max]
  end

  private def count_of(screen, color) = (0...screen.height).sum { |y| (0...screen.width).count { |x| screen.pixel(x, y) == color } }

  # The hero's body is drawn, and inside the room: the walls, the first eight pixels round it,
  # kept it in.
  private def assert_hero_in_the_room(screen, hero)
    box = box_of(screen, hero)

    refute_nil box, "the hero is drawn"
    assert_operator box.first(2).min, :>=, 8, "the hero was kept inside the wall border"
  end

  def test_animate_coin_spins_where_it_started_after_the_walk_round
    start = Color.resolve(:yellow)
    coin = nil
    moved = nil
    run = play(Animate::GAME) do |player, frame|
      coin = box_of(player.screen, start) if frame == 2
      moved = box_of(player.screen, start) if frame == 8
    end

    assert_operator moved[0], :>, coin[0], "the coin walks right while right is held"
    assert_equal start, run.screen.pixel((run.screen.width / 2) - 1, (run.screen.height / 2) - 1),
                 "walked right, down, left and up, the coin is back in the middle"
  end

  def test_font_styles_draws_the_word_in_three_fonts
    screen = play(FontStyles::GAME).screen
    word = lambda do |y, height, color|
      want = Color.resolve(color)
      (0...60).flat_map { |dx| (0...height).filter_map { |dy| [dx, dy] if screen.pixel(8 + dx, y + dy) == want } }
    end

    refute_empty word.call(12, 7, :white), "the built-in HELLO"
    refute_empty word.call(40, 5, :green), "the lowercase hello"
    refute_empty word.call(64, 5, :cyan), "the script hello"
    refute_equal word.call(40, 5, :green).to_set, word.call(64, 5, :cyan).to_set, "the two fonts draw different glyphs"
  end

  def test_fonts_draws_the_tiny_number_smaller_than_the_default_one
    screen = play(FontsDemo::GAME).screen
    green = Color.resolve(:green)
    in_band = ->(y, height) { (y...(y + height)).sum { |row| (0...screen.width).count { |x| screen.pixel(x, row) == green } } }

    assert_operator in_band.call(18, 7), :>, in_band.call(54, 5), "the tiny number plots fewer pixels"
    assert_operator in_band.call(54, 5), :>, 0, "the tiny number is drawn"
    assert_equal 0, in_band.call(59, 3), "the tiny number is only five rows tall"
  end

  def test_grid_cursor_is_back_in_its_cell_and_leaves_no_trail
    screen = play(GridCursor::GAME).screen
    cell = GridCursor::CELL
    col = screen.width / cell / 2
    row = screen.height / cell / 2
    cyan = Color.resolve(:cyan)
    lit = ->(c, r) { (0...cell).all? { |d| screen.pixel((c * cell) + d, (r * cell) + d) == cyan } }

    assert lit.call(col, row), "after a step each way the cursor is lit in the middle cell"
    refute lit.call(col + 1, row), "the cell it stepped to and left is not left lit"
    assert_equal cell * cell, count_of(screen, cyan), "one cell is lit and no more"
  end

  def test_level_draws_the_csv_map_with_the_hero_over_it
    assets = MakeExampleAssets
    screen = play(Level::GAME).screen

    assert_equal assets::BRICK, screen.pixel(100, 3), "tile 1 of the CSV is the brick in the wall border"
    assert_equal assets::FLOOR, screen.pixel(100, 100), "tile 2 is the floor"
    assert_hero_in_the_room screen, assets::HERO
  end

  def test_maze_hero_stops_flush_against_the_wall
    hero = VBlank::Graphics::Color.rgb(31, 20, 0)
    brick = VBlank::Graphics::Color.rgb(20, 10, 8)
    flush = nil
    run = play(Maze::GAME) { |player, frame| flush = box_of(player.screen, hero) if frame == 20 }

    assert_equal 30, flush[2], "walking right, the hero's body stops at x30, against the pillar at x32"
    assert_equal brick, run.screen.pixel(100, 4), "the room's wall border is drawn"
    assert_equal hero, run.screen.pixel(12, 20), "the hero is back by the left wall"
  end

  def test_pixels_draws_the_flag_and_the_corner_markers
    screen = play(Pixels::GAME).screen
    flag_x = (screen.width - 99) / 2
    flag_y = (screen.height - 60) / 2

    assert_equal [Color.rgb8(0, 255, 0), Color.resolve(:white), Color.resolve(:red)],
                 [0, 33, 66].map { |across| screen.pixel(flag_x + across + 5, flag_y + 5) }, "the green, white and red stripes"
    assert_equal [Color.resolve(:yellow), Color.resolve(:cyan), Color.resolve(:magenta), Color.resolve("#FF8800")],
                 [[0, 0], [screen.width - 1, 0], [0, screen.height - 1], [screen.width - 1, screen.height - 1]]
                   .map { |x, y| screen.pixel(x, y) }, "a marker in each corner"
  end

  def test_scroll_pans_the_world_under_the_screen
    water = Color.resolve(:blue)
    panned = nil
    run = play(Scroll::GAME) { |player, frame| panned = box_of(player.screen, water) if frame == 21 }
    start = box_of(run.screen, water)

    assert_equal [96, 80], start.first(2), "the lake is where it began once the camera is back"
    assert_equal 56, panned[0], "held right, the world slid forty pixels left"
  end

  def test_sheet_draws_the_room_and_the_hero_in_it
    assets = MakeExampleAssets
    screen = play(Sheet::GAME).screen

    assert_equal assets::BRICK, screen.pixel(100, 3), "the brick wall border"
    assert_equal assets::FLOOR, screen.pixel(100, 100), "the floor"
    assert_hero_in_the_room screen, assets::HERO
  end

  def test_sparks_fill_the_screen_with_falling_sparks
    run = play(Sparks::GAME)

    assert_equal Sparks::SLOTS * 4, count_of(run.screen, Color.resolve(:yellow)), "every slot's two by two spark is drawn"
  end

  def test_sprite_mover_heart_moves_right_two_pixels_a_frame
    red = Color.resolve(:red)
    left = {}
    run = play(SpriteMover::GAME) { |player, frame| left[frame] = box_of(player.screen, red)&.first if [4, 8].include?(frame) }

    start_x, start_y = SpriteMover.layout(run.screen.width, run.screen.height).fetch(:heart)
    back_x, back_y = box_of(run.screen, red).first(2)

    assert_equal 8, left[8] - left[4], "held right, the heart moves two pixels a frame"
    # The cartridge plays its first pass a frame after a computer's build does, so it sees one
    # frame less of right than of left and ends a step short; a computer's build ends on the spot.
    assert_equal start_y, back_y, "after the walk round the heart is back at the height it started"
    assert_in_delta start_x, back_x, SpriteMover::SPEED, "and back where it started, give or take a step"
  end

  def test_tiles_shows_the_next_room_and_opens_the_door
    floor = VBlank::Graphics::Color.rgb(5, 5, 8)
    seen = {}
    play(Tiles::GAME) { |player, frame| seen[frame] = [player.screen.pixel(40, 40), player.screen.pixel(80, 72)] if [30, 50].include?(frame) }

    assert_equal Color.resolve(:blue), seen[30][0], "pressing right shows the cavern, whose pool is where the hall has floor"
    refute_equal floor, seen[30][1], "the doorway is a wall until A is pressed"
    assert_equal floor, seen[50][1], "A opens the door into floor"
  end
end
