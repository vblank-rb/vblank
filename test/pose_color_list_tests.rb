# frozen_string_literal: true

# ONE SPRITE WHOSE POSES ARE DRAWN FROM DIFFERENT LISTS OF COLOURS, played by each console whose
# build makes it (Console::Description#pose_lists): a pose is shown in its own list's colours as the
# pose changes (PoseColorListTests), and, where the build goes that far, a pose drawn from a list
# the game changes (`recolor`) shows what that list holds once the sprite is told to follow it
# (PoseColorListFollowTests). A console whose build does not follow yet refuses that in words
# (PoseColorListFollowRefusedTests). No test here is in `test/all/`, since the Advance's build keeps
# one list for a whole sprite.
#
# Each picture is 8x8, its left half the first colour of its list after the see-through one and
# its right half the next, so a pose in another pose's colours, or in a list's old colours, shows
# at a known place.
module PoseColorListGames
  include SharedConstants

  WARM = %i[transparent red orange].freeze
  COLD = %i[transparent blue white].freeze
  DUSK = %i[transparent magenta yellow].freeze
  GLOW = %i[transparent green cyan].freeze

  # The pass on which the sprite turns from its first pose to its second.
  TURN_PASS = 4

  # Where the sprite stands, and a pixel of each half of it.
  AT = [40, 40].freeze
  LEFT_HALF = [41, 41].freeze
  RIGHT_HALF = [46, 41].freeze

  # A tiled game with the lists and the two poses, :left of :warm and :right of :cold (or of the
  # lists given: a name, the colours themselves, or nil for a picture given none), then whatever
  # the block declares.
  private def pose_colors_game(left: :warm, right: :cold, &body)
    halves = ->(first, second) { Array.new(64) { |at| (at % 8) < 4 ? first : second } }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :warm, WARM
      colors :cold, COLD
      colors :dusk, DUSK
      colors :glow, GLOW
      image :left, width: 8, height: 8, data: halves.(WARM[1], WARM[2]), **{ colors: left }.compact
      image :right, width: 8, height: 8, data: halves.(COLD[1], COLD[2]), **{ colors: right }.compact
      instance_eval(&body)
    end
    builder.finalize_program
    builder.program
  end

  # One sprite facing :left, which turns to :right on pass TURN_PASS. The block, handed the sprite
  # and the count of passes, is the rest of each pass; +before+ runs once above the loop.
  private def turning_sprite_game(before: nil, **lists, &each_pass)
    pose_colors_game(**lists) do
      ship = sprite :ship, at: AT, facing: { left: :left, right: :right }
      instance_exec(ship, &before) if before
      pass = var :pass, 0
      game_loop do
        pass += 1
        ship.face :right if pass >= TURN_PASS
        instance_exec(ship, pass, &each_pass) if each_pass
      end
    end
  end

  # A BACKGROUND AND A SPRITE EACH TOLD TO FOLLOW :warm AND :cold, the game changing :cold to hold
  # :dusk from pass 2 and never changing :warm. The background's tiles are a tile of each list at
  # the top left. The sprite faces :orange_first, of :warm, and turns to :right, of :cold, on pass
  # TURN_PASS; :orange_first is drawn with :warm's second colour on its left half, so the colours it
  # uses, in the order its pixels use them, are not in the list's order.
  private def followed_beside_background_game
    halves = ->(first, second) { Array.new(64) { |at| (at % 8) < 4 ? first : second } }
    pose_colors_game do
      image :orange_first, width: 8, height: 8, data: halves.(WARM[2], WARM[1]), colors: :warm
      image :warm_tile, width: 8, height: 8, data: halves.(WARM[1], WARM[2]), colors: :warm
      image :cold_tile, width: 8, height: 8, data: halves.(COLD[1], COLD[2]), colors: :cold
      tiles :title_set, "w" => :warm_tile, "c" => :cold_tile
      background(:title, tiles: :title_set, map: ["wc"]).draw_with({ warm: :warm, cold: :cold })
      ship = sprite :ship, at: AT, facing: { orange_first: :orange_first, right: :right }
      ship.draw_with({ warm: :warm, cold: :cold })
      pass = var :pass, 0
      game_loop do
        pass += 1
        ship.face :right if pass >= TURN_PASS
        recolor :cold, :dusk if pass >= 2
      end
    end
  end

  # The colours of the sprite's two halves after +frames+ of +program+.
  private def halves_shown(program, frames:)
    screen = game_player.run(program, frames: frames + framework_drawing_lag).screen
    [screen.pixel(*LEFT_HALF), screen.pixel(*RIGHT_HALF)]
  end

  private def shown_all(colors) = colors.map { |color| shown(color) }
end

module PoseColorListTests
  include PoseColorListGames

  def test_each_pose_is_shown_in_the_colors_of_its_own_list_as_the_pose_changes
    program = turning_sprite_game

    assert_equal shown_all(WARM.drop(1)), halves_shown(program, frames: TURN_PASS - 1), "the first pose, drawn from :warm"
    assert_equal shown_all(COLD.drop(1)), halves_shown(program, frames: TURN_PASS + 2), "the second pose, drawn from :cold"
  end

  def test_a_pose_given_its_colors_themselves_beside_one_given_a_list_by_name_keeps_its_own
    program = turning_sprite_game(right: COLD)

    assert_equal shown_all(WARM.drop(1)), halves_shown(program, frames: TURN_PASS - 1)
    assert_equal shown_all(COLD.drop(1)), halves_shown(program, frames: TURN_PASS + 2)
  end

  def test_a_pose_given_no_list_beside_one_given_a_list_keeps_its_own_colors
    program = turning_sprite_game(right: nil)

    assert_equal shown_all(WARM.drop(1)), halves_shown(program, frames: TURN_PASS - 1)
    assert_equal shown_all(COLD.drop(1)), halves_shown(program, frames: TURN_PASS + 2)
  end

  # Two sprites facing the same poses, one turned and one not: each shows its own pose's colours.
  def test_two_sprites_of_the_same_poses_each_show_the_colors_of_the_pose_they_face
    program = pose_colors_game do
      sprite :still, at: [80, 40], facing: { left: :left, right: :right }
      turned = sprite :turned, at: AT, facing: { left: :left, right: :right }
      turned.face :right
      game_loop {}
    end
    screen = game_player.run(program, frames: 3).screen

    assert_equal shown_all(COLD.drop(1)), [screen.pixel(*LEFT_HALF), screen.pixel(*RIGHT_HALF)], "the sprite turned to :right"
    assert_equal shown_all(WARM.drop(1)), [screen.pixel(81, 41), screen.pixel(86, 41)], "the sprite still facing :left"
  end

  # A pool's things are sprites that can each show any of its pictures.
  def test_each_thing_of_a_pool_shows_the_colors_of_the_pose_it_faces
    program = pose_colors_game do
      guards = pool :guard, x: 0, y: 0, way: 0, capacity: 2, facing: { left: :left, right: :right }
      guards.spawn x: 40, y: 40, way: 0
      guards.spawn x: 80, y: 40, way: 1
      game_loop { guards.each { |guard| guard.face %i[left right], showing: guard.way } }
    end
    screen = game_player.run(program, frames: 3).screen

    assert_equal shown_all(WARM.drop(1)), [screen.pixel(*LEFT_HALF), screen.pixel(*RIGHT_HALF)], "the thing facing :left"
    assert_equal shown_all(COLD.drop(1)), [screen.pixel(81, 41), screen.pixel(86, 41)], "the thing facing :right"
  end

  def test_following_a_list_no_pose_of_the_sprite_is_drawn_from_is_refused
    error = assert_raises(ArgumentError) do
      turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm, dusk: :dusk }) })
    end

    assert_includes error.message, ":dusk"
    assert_includes error.message, ":warm and :cold"
  end

  def test_drawing_one_list_of_several_with_another_list_is_refused
    error = assert_raises(ArgumentError) do
      turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :glow, cold: :cold }) })
    end

    assert_includes error.message, "warm: :warm"
  end

  def test_one_other_list_for_a_sprite_of_several_lists_is_refused_naming_the_way_to_follow_them
    error = assert_raises(ArgumentError) do
      turning_sprite_game(before: ->(ship) { ship.draw_with :glow })
    end

    assert_includes error.message, "different `colors:` lists"
    assert_includes error.message, "draw_with({"
  end

  # A sprite whose poses are all of one list has nothing to tell apart: following that list is
  # drawing with it, as `draw_with :warm` is.
  def test_a_sprite_of_one_list_told_to_follow_it_draws_with_it
    program = pose_colors_game do
      ship = sprite :left, at: AT
      ship.draw_with({ warm: :warm })
      game_loop { recolor :warm, :glow }
    end

    assert_equal shown_all(GLOW.drop(1)), halves_shown(program, frames: 3)
  end
end

# FOLLOWING THE LISTS: told to draw each of its lists with that list, the sprite shows what the list
# of the pose showing holds now.
module PoseColorListFollowTests
  include PoseColorListGames

  def test_a_sprite_told_to_follow_its_lists_shows_what_the_list_of_its_pose_holds
    program = turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm, cold: :cold }) }) do |_ship, pass|
      recolor :warm, :glow if pass >= 2
      recolor :cold, :dusk if pass >= TURN_PASS + 3
    end

    assert_equal shown_all(WARM.drop(1)), halves_shown(program, frames: 1), "the first pose, :warm as declared"
    assert_equal shown_all(GLOW.drop(1)), halves_shown(program, frames: 3), "the first pose, :warm told to hold :glow"
    assert_equal shown_all(COLD.drop(1)), halves_shown(program, frames: TURN_PASS + 1), "the second pose, :cold as declared"
    assert_equal shown_all(DUSK.drop(1)), halves_shown(program, frames: TURN_PASS + 5), "the second pose, :cold told to hold :dusk"
  end

  # A list the sprite was not told to follow stays as drawn, whatever the game sets it to hold for
  # another sprite that draws with it.
  def test_a_list_the_sprite_does_not_follow_stays_as_its_pose_was_drawn
    program = turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm }) }) do |_ship, pass|
      recolor :warm, :glow if pass >= 2
    end

    assert_equal shown_all(GLOW.drop(1)), halves_shown(program, frames: 3), "the pose of :warm, which the sprite follows"
    assert_equal shown_all(COLD.drop(1)), halves_shown(program, frames: TURN_PASS + 2), "the pose of :cold, as drawn"
  end

  # Told to follow a list the game never changes, the sprite shows its poses as drawn.
  def test_following_lists_the_game_never_changes_shows_each_pose_as_drawn
    program = turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm, cold: :cold }) })

    assert_equal shown_all(WARM.drop(1)), halves_shown(program, frames: TURN_PASS - 1)
    assert_equal shown_all(COLD.drop(1)), halves_shown(program, frames: TURN_PASS + 2)
  end
end

# A CONSOLE WHOSE BUILD SHOWS EACH POSE IN ITS OWN LIST'S COLOURS AND DOES NOT FOLLOW THE LISTS YET
# refuses a sprite told to follow them, naming itself, before it plays.
module PoseColorListFollowRefusedTests
  include PoseColorListGames

  def test_a_sprite_told_to_follow_its_lists_is_refused_naming_the_console
    program = turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm, cold: :cold }) }) do |_ship, pass|
      recolor :warm, :glow if pass >= 2
      recolor :cold, :dusk if pass >= 3
    end
    error = assert_raises(Reference::ProgramError, VBlank::IR::Guardrails::ValidationError) { game_player.run(program, frames: 2) }

    assert_includes error.message, "sprite :ship"
    assert_includes error.message, "#{VBlank::Console.described(game_console).title} build does not make that yet"
  end
end

# A CONSOLE WHOSE BUILD KEEPS ONE LIST FOR A WHOLE SPRITE refuses a sprite whose poses are drawn from
# different lists, naming itself and the way round it.
module PoseColorListRefusedTests
  include PoseColorListGames

  def test_a_sprite_whose_poses_are_drawn_from_different_lists_is_refused_naming_the_console
    error = assert_raises(Reference::ProgramError, VBlank::IR::Guardrails::ValidationError) { game_player.run(turning_sprite_game, frames: 2) }

    assert_includes error.message, "sprite :ship"
    assert_includes error.message, "#{VBlank::Console.described(game_console).title} build draws all the pictures of one sprite from one list"
    assert_includes error.message, "for the pictures of each list"
  end
end
