# frozen_string_literal: true

require "test_helper"
require "differential"

# The games these tests play, shared with the Advance cartridge's own test of the same colours
# (test/lowering/gba/vblank/builder/test_recolor_cartridge.rb).
module RecolorGames
  include SharedConstants

  OWN = [:transparent, :red, :green].freeze
  SLOT = [:transparent, :blue, :white].freeze
  WARM = [:transparent, :yellow, :orange].freeze
  COLD = [:transparent, :gray, :black].freeze

  # An 8x8 ship, left half the first colour of its list and right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # The ship's picture and the lists, then whatever the block declares.
  private def built(&body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :slot, SLOT
      colors :warm, WARM
      colors :cold, COLD
      instance_eval(&body)
    end
    builder.finalize_program
    builder.program
  end

  # A ship drawn with the list :slot, and a loop that does what the block says. +before+
  # runs once, above the loop.
  private def program(before: nil, &game)
    built do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      instance_exec(&before) if before
      game_loop { instance_exec(ship, &game) }
    end
  end

  # FOUR LISTS, EACH DRAWN BY SEVERAL THINGS. Colours whose channels are multiples of four, so a
  # console that keeps three bits of each still tells them apart.
  def self.rgb4(red, green, blue) = VBlank::Graphics::Color.rgb(red * 4, green * 4, blue * 4)

  SCREEN = [:black, rgb4(0, 0, 3), rgb4(0, 0, 5)].freeze
  DUSK = [rgb4(2, 0, 2), rgb4(3, 0, 3), rgb4(5, 0, 5)].freeze
  MACHINE = [:black, rgb4(7, 0, 0), rgb4(0, 7, 0), rgb4(7, 7, 0)].freeze
  LIGHT = [:transparent, rgb4(7, 7, 7), rgb4(4, 4, 4)].freeze
  GLOW = [:transparent, rgb4(7, 4, 0), rgb4(4, 2, 0)].freeze
  SPARK = [:transparent, rgb4(0, 7, 7), rgb4(0, 4, 4)].freeze

  # Where each thing of #four_lists_game stands: a pixel of its left half, then its right.
  FOUR_LISTS_PIXELS = Ractor.make_shareable({ sky: [[1, 1], [5, 1]], machine: [[9, 1], [13, 1]], bean: [[41, 41], [45, 41]],
                                              moon: [[61, 41], [65, 41]], lamp: [[81, 41], [85, 41]],
                                              spark: [[101, 41], [105, 41]], backdrop: [[100, 100]] })

  # The pass that first tells :screen_colors and :light_colors to hold other colours.
  FOUR_LISTS_RECOLOR_PASS = 3

  # A game with four lists of colours:
  # - :screen_colors, which the backdrop follows, drawn by the moon sprite (and with +sky+ by the sky
  #   background too), and told to hold :dusk from pass FOUR_LISTS_RECOLOR_PASS;
  # - :machine_colors, drawn by the machine background (told `draw_with` it) and the bean sprite;
  # - :light_colors, drawn by the lamp sprite, and told to hold :glow from the same pass;
  # - :spark_colors, drawn by the spark sprite.
  # Each picture is 8x8, its left half the list's first colour after place 0 and its right half
  # the next (FOUR_LISTS_PIXELS). The sky makes two backgrounds at once, which the Color does not show.
  private def four_lists_game(sky: false)
    builder = Builder.new
    builder.instance_eval do
      colors :screen_colors, SCREEN
      colors :dusk, DUSK
      colors :machine_colors, MACHINE
      colors :light_colors, LIGHT
      colors :glow, GLOW
      colors :spark_colors, SPARK
      screen :tiled, backdrop: :screen_colors
      halves = ->(left, right) { Array.new(64) { |i| (i % 8) < 4 ? left : right } }
      if sky
        image :sky_tile, width: 8, height: 8, data: halves.(SCREEN[1], SCREEN[2]), colors: :screen_colors
        tiles :sky_set, "#" => :sky_tile
        background(:sky, tiles: :sky_set, map: ["# "]).draw_with :screen_colors
      end
      image :plate, width: 8, height: 8, data: halves.(MACHINE[1], MACHINE[2]), colors: :machine_colors
      tiles :machine_set, "#" => :plate
      machine = background :machine, tiles: :machine_set, map: [" #"]
      machine.draw_with :machine_colors
      { bean: [:machine_colors, MACHINE[2], MACHINE[3], 40], moon: [:screen_colors, SCREEN[1], SCREEN[2], 60],
        lamp: [:light_colors, LIGHT[1], LIGHT[2], 80], spark: [:spark_colors, SPARK[1], SPARK[2], 100] }
        .each do |name, (list, left, right, x)|
          image name, width: 8, height: 8, data: halves.(left, right), colors: list
          sprite(name, at: [x, 40]).draw_with list
        end
      pass = var :pass, 0
      game_loop do
        pass += 1
        recolor :screen_colors, :dusk if pass >= FOUR_LISTS_RECOLOR_PASS
        recolor :light_colors, :glow if pass >= FOUR_LISTS_RECOLOR_PASS
      end
    end
    builder.finalize_program
    builder.program
  end
end

# A LIST OF SPRITE COLOURS THAT HOLDS OTHER COLOURS while the game runs. A sprite told to
# draw with a list is drawn in whatever that list holds now, so one list can dress a
# goblin in one room and a bat in the next: the list is a slot, and `recolor` says what
# is in it. The Advance cartridge's own pixels are read in
# test/lowering/gba/vblank/builder/test_recolor_cartridge.rb.
class TestRecolor < Minitest::Test
  include Differential
  include RecolorGames

  # More sets of colours than the console has groups for sprites.
  SETS = 20

  # Set number +n+: two colours no other set has.
  def self.set(n) = [:transparent, VBlank::Graphics::Color.rgb(n, 31 - n, 5), VBlank::Graphics::Color.rgb(31 - n, n, 9)]

  # The ship's two halves, as the interpreter draws them after +frames+.
  private def halves(program, frames: 3)
    i = game_player.run(program, frames: frames)
    [i.screen.pixel(41, 41), i.screen.pixel(45, 41)]
  end

  private def colors_of(*names) = names.map { |name| shown(name) }

  def test_a_list_nothing_recolors_holds_the_colors_it_was_declared_with
    assert_equal colors_of(:blue, :white), halves(program { |_ship| nil })
  end

  def test_a_sprite_drawn_with_a_list_shows_the_colors_the_list_holds_now
    assert_equal colors_of(:yellow, :orange), halves(program { |_ship| recolor :slot, :warm })
  end

  # One of several, by a number the game works out: the ship's column counts up, so the
  # number is 2 by the third frame.
  private def counting_through_the_sets
    program do |ship|
      ship.x += 1
      recolor :slot, [:slot, :warm, :cold], showing: ship.x - 40
    end
  end

  def test_a_number_the_game_works_out_picks_which_colors_the_list_holds
    # The second pass's number, as far behind as the framework draws (Testing#framework_drawing_lag).
    i = game_player.run(counting_through_the_sets, frames: 2 + framework_drawing_lag)

    assert_equal colors_of(:gray, :black), [i.screen.pixel(43, 41), i.screen.pixel(47, 41)]
  end

  # A number that names none of them is the colors the list was declared with, so a counter
  # that has run off the end looks right.
  def test_a_number_outside_the_set_is_the_colors_it_was_declared_with
    assert_equal colors_of(:blue, :white), halves(program { |ship| recolor :slot, [:warm, :cold], showing: ship.x })
  end

  # A fade over the ship that ends on the pass the list changes: the list shows in full, unfaded,
  # and every other colour goes back too, whichever of the two the pass said first.
  private def fade_ending_as_a_list_changes(list_first:)
    built do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      image :bystander, width: 8, height: 8, data: SHIP, colors: OWN
      sprite :bystander, at: [60, 40]
      pass = var :pass, 0
      list_before = list_first ? 4 : 0
      list_after = list_first ? 0 : 4
      game_loop do
        pass += 1
        fade :black, 50 if pass < 4
        recolor :slot, :warm if pass == list_before
        fade :black, 0 if pass == 4
        recolor :slot, :warm if pass == list_after
      end
    end
  end

  # The ship's two halves, and the first half of the sprite the list does not dress.
  private def shown_after_the_fade(program)
    i = game_player.run(program, frames: 7)
    [i.screen.pixel(41, 41), i.screen.pixel(45, 41), i.screen.pixel(61, 41)]
  end

  def test_a_list_held_before_a_fade_ends_in_one_pass_shows_unfaded
    assert_equal colors_of(:yellow, :orange, :red), shown_after_the_fade(fade_ending_as_a_list_changes(list_first: true))
  end

  def test_a_list_held_after_a_fade_ends_in_one_pass_shows_unfaded
    assert_equal colors_of(:yellow, :orange, :red), shown_after_the_fade(fade_ending_as_a_list_changes(list_first: false))
  end

  def test_own_puts_back_the_colors_it_was_declared_with
    back = program do |ship|
      ship.x += 1
      recolor :slot, :warm
      recolor :slot, :own if ship.x > 41
    end
    i = game_player.run(back, frames: 4)

    assert_equal colors_of(:blue, :white), [i.screen.pixel(44, 41), i.screen.pixel(48, 41)]
  end

  # `draw_with` and `recolor` can come in either order: a list is one that changes because
  # something somewhere recolors it, however late that is written.
  def test_a_sprite_told_to_draw_with_the_list_after_it_is_recolored_shows_them_too
    late = built do
      recolor :slot, :warm
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :slot }
    end

    assert_equal colors_of(:yellow, :orange), halves(late)
  end

  # --- the console ---

  # The console's own pixels are read off the cartridge in the Advance's own test of this; here
  # the picture is held to the colours the list holds, and to the interpreter's.
  def test_the_console_shows_the_colors_the_list_holds_now
    recolored = program { |_ship| recolor :slot, :warm }

    assert_equal colors_of(:yellow, :orange), halves(recolored)
    assert_backends_agree(recolored, frames: 3)
  end

  def test_the_console_picks_by_a_number_too
    (2..5).each { |frames| assert_backends_agree(counting_through_the_sets, frames: frames) }
  end

  # --- the point of it: one group of sprite colors, however many sets ---

  # A ship that walks through twenty sets of colors, a new one each frame: by recoloring the
  # one list it is drawn with, or else by being told to draw with each of the twenty.
  private def many_sets(through_one_list:)
    klass = self.class
    built do
      names = (0...SETS).map { |n| colors :"set#{n}", klass.set(n) }
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot if through_one_list
      game_loop do
        ship.x += 1
        if through_one_list
          recolor :slot, names, showing: ship.x - 41
        else
          ship.draw_with names, showing: ship.x - 41
        end
      end
    end
  end

  # Told to draw with each of the twenty in turn, the ship fits too: a list borrows a group
  # while the ship wears it (see ScreenLayout::LentColors). Recoloring one list is the way
  # that costs one group and no lending.
  def test_twenty_lists_a_sprite_draws_with_borrow_their_groups
    [3, 13, 22].each { |frames| assert_backends_agree(many_sets(through_one_list: false), frames: frames) }
  end

  # --- with a tint or a fade in force ---

  # A list's colors go into the console's table, and a tint moves every color in that table.
  # So they go in through the tint in force, rather than at full brightness on a red screen.
  def test_colors_go_in_through_a_tint_in_force
    tinted = program(before: -> { tint :red, 50 }) { |_ship| recolor :slot, :warm }

    assert_backends_agree(tinted, frames: 4)
  end

  # ...and a tint that moves afterwards moves the colors the list holds, not the ones it was
  # declared with.
  def test_a_tint_that_moves_keeps_the_colors_the_list_holds
    moving = program do |ship|
      ship.x += 1
      recolor :slot, :warm
      tint :red, (ship.x - 40) * 10
    end

    (2..5).each { |frames| assert_backends_agree(moving, frames: frames) }
  end

  # A fade takes the tint's place, which puts the table back as it was drawn: the list still
  # holds what it was told.
  def test_a_fade_that_lifts_a_tint_keeps_the_colors_the_list_holds
    lifted = program do |ship|
      ship.x += 1
      recolor :slot, :warm
      if ship.x < 43
        tint :red, 50
      else
        fade :black, 50
      end
    end

    [2, 4, 6].each { |frames| assert_backends_agree(lifted, frames: frames) }
  end

  # --- pools ---

  private def guards_drawn_with_the_list
    built do
      guards = pool :guard, x: 0, y: 0, capacity: 4, image: :ship
      guards.spawn x: 40, y: 40
      guards.spawn x: 80, y: 40
      game_loop do
        guards.each { |g| g.draw_with :slot }
        recolor :slot, :warm
      end
    end
  end

  def test_every_instance_of_a_pool_drawn_with_the_list_shows_its_colors
    i = game_player.run(guards_drawn_with_the_list, frames: 4)

    assert_equal colors_of(:yellow, :yellow), [i.screen.pixel(41, 41), i.screen.pixel(81, 41)]
    assert_backends_agree(guards_drawn_with_the_list, frames: 4)
  end

  # --- friendly errors ---

  private def refused(&body) = assert_raises(ArgumentError) { built(&body) }.message

  def test_recoloring_a_name_that_is_not_a_list_says_so
    assert_match(/:ghost, which is not a list of colors/, refused { recolor :ghost, :warm })
  end

  def test_recoloring_with_a_name_that_is_not_a_list_says_so
    message = refused { recolor :slot, :ghost }

    assert_match(/list of colors :slot/, message)
    assert_match(/:ghost, which is not a list of colors/, message)
  end

  # A sprite drawn with the list was checked against the places the list has, so a set with
  # fewer would leave some of the sprite's pixels with no color to show.
  def test_a_set_with_fewer_colors_than_the_list_says_so
    message = refused do
      colors :thin, [:transparent, :red]
      recolor :slot, :thin
    end

    assert_match(/:thin, which has 2 colors/, message)
    assert_match(/3 colors or more/, message)
  end

  def test_several_sets_and_nothing_to_pick_between_them_says_so
    assert_match(/nothing to pick\s+between them/, refused { recolor :slot, [:warm, :cold] })
  end

  def test_one_set_and_showing_says_so
    assert_match(/names one list/, refused { recolor :slot, :warm, showing: 1 })
  end

  # A list nothing is drawn with shows nothing whatever it holds: a name spelled two ways.
  def test_recoloring_a_list_no_sprite_draws_with_says_so
    message = refused do
      sprite :ship, at: [40, 40]
      game_loop { recolor :slot, :warm }
    end

    assert_match(/list of colors :slot/, message)
    assert_match(/no sprite or pool draws with it/, message)
  end

  # A picture given as colors records no places. Where its own list has one color at two
  # places and a set gives those places different colors, half its pixels would be drawn
  # wrong — refused for a set a list holds as it is for a list the sprite names itself.
  def test_a_set_that_would_recolor_a_picture_wrongly_says_so
    message = refused do
      image :twin, width: 8, height: 8, data: Array.new(64, :red), colors: [:transparent, :red, :red]
      colors :pair, [:transparent, :blue, :blue]
      twin = sprite :twin, at: [40, 40]
      twin.draw_with :pair
      game_loop { recolor :pair, :warm }
    end

    assert_match(/draws with :pair, which was told to hold :warm/, message)
    assert_match(/place 1 and place 2/, message)
  end

  # A background drawn with a list that changes is drawn in what the list holds, so its tiles
  # are drawn in the colors the list was declared with: the colors it holds at power-on.
  def test_a_background_whose_tiles_are_not_drawn_from_the_list_says_so
    message = refused do
      tiles :hull, "#" => :ship
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      plates = background :plates, tiles: :hull, map: ["####"]
      plates.draw_with :slot
      game_loop { recolor :slot, :warm }
    end

    assert_match(/background :plates draws with :slot/, message)
    assert_match(/colors: :slot/, message)
  end

  # Drawn with a list that changes, a background is drawn with it for good: it has no other
  # lists to take turns with, and no colors of its own to go back to.
  def test_a_background_drawn_with_the_list_and_other_lists_says_so
    message = assert_raises(ArgumentError) do
      background_and_ship_drawn_with_the_list do |plates|
        plates.draw_with %i[slot warm], showing: 1
        game_loop { recolor :slot, :cold }
      end
    end.message

    assert_match(/background :plates draws with :slot/, message)
    assert_match(/for good/, message)
  end

  # --- backgrounds ---

  # Tiles drawn from :slot, the left half its first color and the right half its second.
  PLATE = Array.new(64) { |i| (i % 8) < 4 ? :blue : :white }.freeze

  # A row of plates and the ship, both drawn with :slot, a bystander in its own colors, and
  # whatever the block says.
  private def background_and_ship_drawn_with_the_list(&rest)
    built do
      image :plate, width: 8, height: 8, data: PLATE, colors: :slot
      tiles :hull, "#" => :plate
      plates = background :plates, tiles: :hull, map: ["#####"]
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      image :bystander, width: 8, height: 8, data: SHIP, colors: OWN
      sprite :bystander, at: [60, 40]
      instance_exec(plates, ship, &rest)
    end
  end

  # The plates' two halves, the ship's two halves and the bystander's first half.
  private def background_and_ship_halves(program, frames:)
    i = game_player.run(program, frames: frames)
    [[i.screen.pixel(1, 1), i.screen.pixel(5, 1)], [i.screen.pixel(41, 41), i.screen.pixel(45, 41)], i.screen.pixel(61, 41)]
  end

  # `recolor` reaches a background drawn with the list as it reaches a sprite: both show what
  # the list holds now, and a picture drawn in other colors keeps them.
  def test_a_background_drawn_with_the_list_shows_the_colors_the_list_holds_now
    recolored = background_and_ship_drawn_with_the_list do |plates|
      plates.draw_with :slot
      game_loop { recolor :slot, :warm }
    end
    warm = colors_of(:yellow, :orange)

    assert_equal [warm, warm, shown(:red)], background_and_ship_halves(recolored, frames: 3)
  end

  # A program with no game loop has no gap between frames to move the writes to, so the
  # background's colors are written where the list is told what to hold.
  def test_a_background_drawn_with_the_list_follows_it_without_a_game_loop
    unpaced = background_and_ship_drawn_with_the_list do |plates|
      plates.draw_with :slot
      recolor :slot, :warm
      halt
    end
    i = game_player.run(unpaced, frames: 3)

    assert_equal colors_of(:yellow, :orange), [i.screen.pixel(1, 1), i.screen.pixel(5, 1)]
  end

  # A sprite whose pictures are drawn in the list's colors, told to draw with the list and
  # nothing else, is drawn with it for good, from power-on: its own colors are the list's.
  # So it shows what the list holds before the line that says draw_with is reached.
  def test_a_sprite_drawn_in_the_list_and_with_it_alone_follows_it_from_power_on
    early = built do
      image :logo, width: 8, height: 8, data: PLATE, colors: :slot
      logo = sprite :logo, at: [40, 40]
      pass = var :pass, 0
      game_loop do
        pass += 1
        recolor :slot, :warm
        logo.draw_with :slot if pass > 8
      end
    end

    assert_equal colors_of(:yellow, :orange), halves(early, frames: 4)
  end

  # Before anything recolors it, the list holds the colors it was declared with.
  def test_a_background_drawn_with_the_list_shows_its_declared_colors_until_it_is_recolored
    waiting = background_and_ship_drawn_with_the_list do |plates|
      plates.draw_with :slot
      pass = var :pass, 0
      game_loop do
        pass += 1
        recolor :slot, :warm if pass > 5
      end
    end
    declared = colors_of(:blue, :white)

    assert_equal [declared, declared, shown(:red)], background_and_ship_halves(waiting, frames: 3)
  end

  # Five sets, then fifteen, a new one every pass, through one list the background and the
  # ship are both drawn with: on a console whose sprites and backgrounds share their lists
  # of colors, that is one list for both, whatever the sets. A number past the sets is the
  # list's own colors.
  private def stepping_through(count)
    klass = self.class
    background_and_ship_drawn_with_the_list do |plates|
      names = (0...count).map { |n| colors :"set#{n}", klass.set(n) }
      plates.draw_with :slot
      step = var :step, 0
      game_loop do
        step += 1
        recolor :slot, names, showing: step % (count + 2)
      end
    end
  end

  def test_a_background_and_a_sprite_step_through_five_sets_together
    [2, 4, 7, 9].each do |frames|
      plates, ship, bystander = background_and_ship_halves(stepping_through(5), frames: frames)

      assert_equal plates, ship
      assert_equal shown(:red), bystander
    end
  end

  def test_a_background_and_a_sprite_step_through_fifteen_sets_together
    [3, 10, 17, 19].each do |frames|
      plates, ship, bystander = background_and_ship_halves(stepping_through(15), frames: frames)

      assert_equal plates, ship
      assert_equal shown(:red), bystander
    end
  end

  # What each thing of #four_lists_game shows once pass +pass+ is drawn (Testing#framework_drawing_lag).
  private def four_lists_shown(pass)
    screen = game_player.run(four_lists_game, frames: pass + framework_drawing_lag).screen
    FOUR_LISTS_PIXELS.except(:sky).transform_values { |spots| spots.map { |x, y| screen.pixel(x, y) } }
  end

  private def shown_all(*colors) = colors.map { |color| shown(color) }

  # FOUR LISTS, ONE OF THEM DRAWN BY A BACKGROUND AND A SPRITE TOGETHER, and the backdrop following
  # another: each thing shows its own list's colours. On a console whose backgrounds and sprites read
  # one table of four lists (the Genesis), the background and the sprite drawn with one list take one
  # of the four between them, or the game does not fit.
  def test_a_background_and_a_sprite_drawn_with_one_list_beside_three_more_show_their_colors
    assert_equal({ machine: shown_all(MACHINE[1], MACHINE[2]),
                   bean: shown_all(MACHINE[2], MACHINE[3]), moon: shown_all(SCREEN[1], SCREEN[2]),
                   lamp: shown_all(LIGHT[1], LIGHT[2]), spark: shown_all(SPARK[1], SPARK[2]),
                   backdrop: shown_all(:black) }, four_lists_shown(FOUR_LISTS_RECOLOR_PASS - 1))
  end

  # The pass that recolours :screen_colors changes the moon and the backdrop together, and
  # :light_colors' lamp with them; the lists nothing recolours stay as they were.
  def test_recoloring_one_of_four_lists_changes_its_sprites_and_backdrop_on_one_frame
    assert_equal({ machine: shown_all(MACHINE[1], MACHINE[2]),
                   bean: shown_all(MACHINE[2], MACHINE[3]), moon: shown_all(DUSK[1], DUSK[2]),
                   lamp: shown_all(GLOW[1], GLOW[2]), spark: shown_all(SPARK[1], SPARK[2]),
                   backdrop: shown_all(DUSK[0]) }, four_lists_shown(FOUR_LISTS_RECOLOR_PASS))
  end
end
