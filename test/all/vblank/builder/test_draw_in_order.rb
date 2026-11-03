# frozen_string_literal: true

require "test_helper"
require "differential"

# SPRITES DRAWN IN AN ORDER THE GAME WORKS OUT. A top-down game draws whichever character
# stands lower on the screen in front: walk round below something and you are drawn over it,
# walk round above it and it is drawn over you. The order changes every time two things pass
# each other, so no order fixed when the cartridge is built is right.
#
# Two blocks overlap at OVERLAP. The enemy is declared first, so without an order the hero
# (declared after it) is always in front. Which colour shows there is the whole answer.
#
# Where the Advance's cartridge keeps each sprite in its table is read in the emulator in
# test/lowering/gba/vblank/builder/test_draw_in_order_cartridge.rb, which plays the game kept
# here in DrawInOrderGames.
module DrawInOrderGames
  include SharedConstants # Builder, which the games below name from inside the module

  BLOCK = Ractor.make_shareable(Array.new(16) { "#" * 16 }.join("\n"))
  ENEMY_AT = [60, 60].freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The enemy stands at ENEMY_AT; the hero is eight pixels right of it and +hero_y+ down.
  private def two_program(hero_y, ordered: true, step: 0, hero_named_first: false)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      enemy = sprite :enemy, at: enemy_at
      hero = sprite :hero, at: [enemy_at[0] + 8, hero_y]
      draw_in_order(*(hero_named_first ? [hero, enemy] : [enemy, hero])) if ordered
      game_loop { hero.y += step unless step.zero? }
    end
  end

  # The same two, in one order with a crowd of +crowd+ things that never come out, so the enemy
  # and the hero are past the 128th thing the order holds.
  private def crowded_program(hero_y, crowd: 130)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      image(:speck, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      crowd = pool :crowd, x: 0, y: 0, capacity: crowd, image: :speck
      enemy = sprite :enemy, at: enemy_at
      hero = sprite :hero, at: [enemy_at[0] + 8, hero_y]
      draw_in_order(crowd, enemy, hero)
      game_loop { hero.y += 0 }
    end
  end

  # TAKING TURNS. Three blocks in a row on one line, each four pixels right of the one before,
  # so neighbours overlap and all three overlap in the middle: red, then green, then blue,
  # named in that order. +turns+ is what `take_turns:` is given; with +count+ 2 only the first
  # two are made.
  TURNS_AT = [60, 60].freeze
  TURN_COLORS = %i[red green blue].freeze

  private def turns_program(turns, count: 3)
    block = BLOCK
    at = TURNS_AT
    colors = TURN_COLORS
    program do
      screen :tiled
      blocks = colors.first(count).each_with_index.map do |color, i|
        image(:"block_#{color}", "#" => color) { block }
        sprite :"block_#{color}", at: [at[0] + (i * 4), at[1]]
      end
      draw_in_order(*blocks, take_turns: turns)
      game_loop {}
    end
  end
end

class TestDrawInOrder < Minitest::Test
  include Differential
  include DrawInOrderGames

  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  OVERLAP = [70, 66].freeze

  private def shown(prog, frames: 2) = game_player.run(prog, frames: frames).screen.pixel(*OVERLAP)

  def test_without_an_order_the_later_sprite_is_always_in_front
    assert_equal GREEN, shown(two_program(54, ordered: false))
    assert_equal GREEN, shown(two_program(66, ordered: false))
  end

  def test_whoever_stands_lower_is_in_front
    assert_equal RED, shown(two_program(54)), "the hero stands higher, so the enemy covers him"
    assert_equal GREEN, shown(two_program(66)), "the hero stands lower, so he covers the enemy"
  end

  # The things can be named in any order; which is in front follows the numbers, not the list.
  def test_the_things_can_be_named_in_any_order
    assert_equal RED, shown(two_program(54, hero_named_first: true))
    assert_equal GREEN, shown(two_program(66, hero_named_first: true))
    assert_backends_agree(two_program(66, hero_named_first: true), frames: 2)
  end

  def test_the_console_draws_the_same_order
    assert_backends_agree(two_program(54), frames: 2)
    assert_backends_agree(two_program(66), frames: 2)
  end

  # The hero walks down a pixel a frame from above the enemy to below it, and the two swap
  # which is in front on the frame his feet pass the enemy's.
  def test_two_sprites_swap_as_one_walks_past_the_other
    walking = two_program(50, step: 1)
    seen = [4, 14].map { |frames| shown(walking, frames: frames) }

    assert_equal [RED, GREEN], seen
    [4, 14].each { |frames| assert_backends_agree(walking, frames: frames) }
  end

  # THE NUMBER IS THE GAME'S TO WORK OUT. A puff of smoke starts a step nearer the front and
  # drops back; here a variable the game owns decides, and `front: :lowest` reverses it.
  private def keyed_program(boost, front:)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      lift = var :lift, boost
      enemy = sprite :enemy, at: enemy_at
      hero = sprite :hero, at: [enemy_at[0] + 8, enemy_at[1] + 4]
      draw_in_order(enemy, hero, front: front) { |thing| thing == hero ? thing.y + lift : thing.y }
      game_loop {}
    end
  end

  def test_the_order_can_be_a_number_the_game_works_out
    assert_equal GREEN, shown(keyed_program(0, front: :highest))
    assert_equal RED, shown(keyed_program(-10, front: :highest))
    assert_equal GREEN, shown(keyed_program(-10, front: :lowest))
    assert_backends_agree(keyed_program(-10, front: :highest), frames: 2)
  end

  # A POOL'S THINGS TAKE PART ONE BY ONE. Two of them are spawned so that the older — which
  # a pool draws in front — stands higher; in order, the lower one covers it instead.
  private def pool_program(ordered: true)
    block = BLOCK
    program do
      screen :tiled
      image(:walker, "#" => :red) { block }
      image(:hero, "#" => :blue) { block }
      walkers = pool :walker, x: 0, y: 0, capacity: 4, image: :walker
      hero = sprite :hero, at: [62, 58]
      draw_in_order walkers, hero if ordered
      walkers.spawn(x: 60, y: 54)
      walkers.spawn(x: 64, y: 62)
      game_loop {}
    end
  end

  def test_a_pools_things_are_ordered_one_by_one
    assert_equal BLUE, shown(pool_program(ordered: false)), "a sprite declared after the pool is in front"
    assert_equal RED, shown(pool_program), "the lower of the pool's things covers the hero"
    assert_backends_agree(pool_program, frames: 2)
  end

  # A POOL ALONE, SORTED AMONG ITSELF, beside an order of other things, the way one kind of thing in
  # a world of many stands higher in front, whatever the rest do. The younger of two puffs stands
  # lower, and a pool draws its older thing in front: here the higher, older one would be in front
  # with no order at all, so the younger is made the higher.
  private def puffs_program(ordered:)
    block = BLOCK
    program do
      screen :tiled
      colors :puff_colors, %i[transparent red]
      colors :young_colors, %i[transparent green]
      image(:puff, "#" => :red, colors: :puff_colors) { block }
      image(:hero, "#" => :blue) { block }
      image(:enemy, "#" => :white) { block }
      puffs = pool :puffs, x: 0, y: 0, capacity: 4, image: :puff
      hero = sprite :hero, at: [0, 100]
      enemy = sprite :enemy, at: [20, 100]
      draw_in_order hero, enemy
      draw_in_order(puffs, front: :lowest) { |puff| puff.y } if ordered
      puffs.spawn(x: 60, y: 62)
      puffs.spawn(x: 64, y: 54)
      game_loop { puffs.each { |puff| puff.draw_with :young_colors if puff.y == 54 } }
    end
  end

  def test_a_pool_alone_is_ordered_among_itself_beside_another_order
    assert_equal RED, shown(puffs_program(ordered: false), frames: 3), "the older thing of a pool is in front"
    assert_equal GREEN, shown(puffs_program(ordered: true), frames: 3), "the higher thing is in front"
    assert_backends_agree(puffs_program(ordered: true), frames: 3)
  end

  # --- taking turns in front, a frame each ---

  # Where red and green overlap, where all three do, and where green and blue do.
  RED_GREEN = [65, 66].freeze
  ALL_THREE = [70, 66].freeze
  GREEN_BLUE = [77, 66].freeze

  private def colors_at(prog, frames)
    screen = game_player.run(prog, frames: frames).screen
    [RED_GREEN, ALL_THREE, GREEN_BLUE].map { |at| screen.pixel(*at) }
  end

  # The first one named in front of the rest, and the run turned round: what each of the three
  # places shows.
  FIRST_IN_FRONT = [RED, RED, GREEN].freeze
  LAST_IN_FRONT = [GREEN, BLUE, BLUE].freeze

  # Two blocks overlapping, level with each other: the one in front changes every frame, so
  # each shows half the time where they overlap, and neither hides the other for good. The
  # first frame the game shows has the first one named in front.
  def test_two_overlapping_sprites_take_turns_in_front
    prog = turns_program(true, count: 2)
    seen = (1..4).map { |frames| game_player.run(prog, frames: frames).screen.pixel(*RED_GREEN) }

    assert_equal [RED, GREEN, RED, GREEN], seen
    (1..2).each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  # The whole run turns round, not just a pair of it: the first named is in front of all of
  # them one frame and the last named the next, and the middle one goes from in front of the
  # last to behind it.
  def test_the_whole_run_turns_round_every_frame
    prog = turns_program(true)

    assert_equal FIRST_IN_FRONT, colors_at(prog, 1), "red in front, then green, then blue"
    assert_equal LAST_IN_FRONT, colors_at(prog, 2), "blue in front, then green, then red"
    assert_equal FIRST_IN_FRONT, colors_at(prog, 3)
    (1..2).each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  # The game says which way round the first frame shows: the first one named in front, or the
  # last.
  def test_the_game_chooses_which_one_starts_in_front
    assert_equal FIRST_IN_FRONT, colors_at(turns_program(:first), 1)
    assert_equal LAST_IN_FRONT, colors_at(turns_program(:last), 1)
    assert_equal FIRST_IN_FRONT, colors_at(turns_program(:last), 2)
    assert_backends_agree(turns_program(:last), frames: 1)
  end

  # A pool's things take turns one by one, beside a sprite: a red thing of the pool and the blue
  # hero overlap, and which shows changes every frame.
  def test_a_pools_things_take_turns_with_a_sprite
    block = BLOCK
    prog = program do
      screen :tiled
      image(:walker, "#" => :red) { block }
      image(:hero, "#" => :blue) { block }
      walkers = pool :walker, x: 0, y: 0, capacity: 2, image: :walker
      hero = sprite :hero, at: [64, 60]
      draw_in_order walkers, hero, take_turns: true
      walkers.spawn(x: 60, y: 60)
      game_loop {}
    end
    seen = (1..4).map { |frames| game_player.run(prog, frames: frames).screen.pixel(*RED_GREEN) }

    assert_equal 2, seen.uniq.length, "each shows on alternate frames"
    assert_equal [BLUE, RED].sort, seen.uniq.sort
    assert_equal seen.first(2), seen.last(2)
    (1..2).each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  def test_taking_turns_with_a_number_of_its_own_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order(one, two, take_turns: true) { |thing| thing.y }
    end

    assert_match(/take_turns/, message)
  end

  def test_taking_turns_with_a_front_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, two, take_turns: true, front: :lowest
    end

    assert_match(/front:/, message)
  end

  def test_an_unknown_take_turns_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, two, take_turns: :middle
    end

    assert_match(/:first/, message)
  end

  # --- what the build refuses ---

  private def refusal(&block)
    assert_raises(ArgumentError) { program(&block) }.message
  end

  def test_a_bitmap_screen_is_refused
    block = BLOCK
    message = refusal do
      screen :bitmap
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, two
    end

    assert_match(/screen :tiled/, message)
  end

  def test_a_thing_named_twice_in_one_order_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, one, two, take_turns: true
    end

    assert_match(/named twice/, message)
  end

  def test_one_sprite_alone_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      draw_in_order one
    end

    assert_match(/two/, message)
  end

  def test_something_that_is_not_a_sprite_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      draw_in_order one, :b
    end

    assert_match(/sprite or a pool/, message)
  end

  def test_a_sprite_in_two_orders_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      three = sprite :c, at: [8, 8], facing: { down: :a }
      draw_in_order one, two
      draw_in_order two, three
    end

    assert_match(/:b/, message)
    assert_match(/one order/, message)
  end

  def test_sprites_in_different_layers_are_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      layers :ground, :sky
      one = layer(:ground) { sprite :a, at: [0, 0] }
      two = layer(:sky) { sprite :b, at: [4, 4], facing: { down: :a } }
      draw_in_order one, two
    end

    assert_match(/layer/, message)
  end

  def test_sprites_in_different_scenes_are_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      scene(:playing) do
        two = sprite :b, at: [4, 4], facing: { down: :a }
        draw_in_order one, two
      end
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :playing } }
    end

    assert_match(/scene/, message)
  end

  def test_a_pool_that_draws_nothing_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      dust = pool :dust, x: 0, y: 0, capacity: 4
      draw_in_order one, dust
    end

    assert_match(/pool :dust draws nothing/, message)
  end

  # THE ORDER HOLDS INSIDE EACH LAYER. A hero and a guard standing in one layer, the lower one in
  # front, and the hero then sent behind the background: the guard stays in front of it, and the
  # hero shows only where nothing covers him.
  private def layer_changing_game(pool:)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:field, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:red, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:green, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :field
      layers :behind, :ground, :front
      layer(:ground) { background :world, tiles: :set, map: "###\n###\n###" }
      hero = layer(:front) { sprite :red, at: [4, 4] }
      if pool
        guards = layer(:front) { self.pool(:guards, x: 4, y: 8, capacity: 2, image: :green) }
        guards.spawn
        draw_in_order hero, guards
      else
        guard = layer(:front) { sprite :green, at: [4, 8] }
        draw_in_order hero, guard
      end
      step = 0
      behind = var :behind, 0
      game_loop do
        step += 1
        hero.move_to 4, 12 if step == 10
        behind = 1 if step == 20
        hero.put_in_layer %i[front behind], showing: behind
      end
    end
    b.finalize_program
    b.program
  end

  private def assert_order_holds_in_each_layer(program)
    screen_at = ->(frames) { game_player.run(program, frames: frames).screen }

    assert_equal 0x03E0, screen_at.call(6).pixel(6, 10), "the guard stands lower, so it is in front"
    in_front = screen_at.call(16)
    assert_equal 0x001F, in_front.pixel(6, 13), "the hero stands lower now, so he is in front"
    assert_equal 0x001F, in_front.pixel(6, 17), "...and nothing covers him"
    behind = screen_at.call(28)
    assert_equal 0x03E0, behind.pixel(6, 13), "the hero has gone behind the background, and the guard has not"
    assert_equal 0x7C00, behind.pixel(6, 17), "the background covers him"
  end

  def test_a_sprite_in_an_order_can_change_layer
    assert_order_holds_in_each_layer(layer_changing_game(pool: false))
  end

  def test_a_sprite_ordered_with_a_pool_can_change_layer
    assert_order_holds_in_each_layer(layer_changing_game(pool: true))
  end

  # The pool told, all of it at once, with a thing of it ordered against the sprite that stays.
  def test_a_pool_in_an_order_can_change_layer
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:field, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:red, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:green, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :field
      layers :behind, :ground, :front
      layer(:ground) { background :world, tiles: :set, map: "###\n###\n###" }
      hero = layer(:front) { sprite :red, at: [4, 4] }
      guards = layer(:front) { self.pool(:guards, x: 4, y: 8, capacity: 2, image: :green) }
      guards.spawn
      draw_in_order hero, guards
      step = 0
      behind = var :behind, 0
      game_loop do
        step += 1
        behind = 1 if step == 10
        guards.put_in_layer %i[front behind], showing: behind
      end
    end
    b.finalize_program

    assert_equal 0x03E0, game_player.run(b.program, frames: 6).screen.pixel(6, 13), "in front of the background"
    later = game_player.run(b.program, frames: 16).screen
    assert_equal 0x7C00, later.pixel(6, 13), "gone behind it"
    assert_equal 0x001F, later.pixel(6, 6), "and the sprite that stayed is where it was"
  end

  def test_an_unknown_front_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, two, front: :top
    end

    assert_match(/:highest/, message)
  end
end
