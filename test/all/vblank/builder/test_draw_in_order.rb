# frozen_string_literal: true

require "test_helper"
require "differential"

# Sprites drawn in an order the game works out. A top-down game draws whichever character
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
  # and the hero are past the 128th thing the order holds (or, given a smaller +crowd+, last of a
  # run of that many and two).
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

  # Seven things in one order, each a small block of a colour of its own, all of them over one
  # pixel, SEVEN_AT. Each stands a pixel right of the one before and +heights+ down, so which
  # colour shows there says which of the seven is in front.
  SEVEN_COLORS = %i[red green blue yellow cyan magenta white].freeze
  SEVEN_AT = [66, 36].freeze

  private def seven_program(heights, front: nil)
    colors = SEVEN_COLORS
    program do
      screen :tiled
      things = colors.each_with_index.map do |color, i|
        image(:"small_#{color}", "#" => color) { (["#" * 8] * 8).join("\n") }
        sprite :"small_#{color}", at: [60 + i, 30 + heights[i]]
      end
      front ? draw_in_order(*things, front: front) : draw_in_order(*things)
      game_loop {}
    end
  end

  # Taking turns. Three blocks in a row on one line, each four pixels right of the one before,
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

  # A run drawn in the order a list of the game's own holds, read as the interpreter reads it
  # (Reference#names_in_draw_order): every entry the list holds, a place below nought counting back
  # from the run's last sprite, and a place naming none of its sprites stopping the game. The builder
  # keeps its own list full of the run's places, so only a run written onto the frame's drawing by hand
  # reaches the rest. Two blocks overlap at OVERLAP: the red one first in the run, the green one second.
  # The block is handed the list and writes the game.
  private def hand_ordered_program(&game)
    block = BLOCK
    enemy_at = ENEMY_AT
    prog = program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      sprite :enemy, at: enemy_at
      sprite :hero, at: [enemy_at[0] + 8, enemy_at[1] + 6]
      instance_exec(list(:order, capacity: 4, width: :byte), &game)
    end
    prog.walk.select { |node| node.kind == :present_objects }.each do |drawn|
      run = VBlank::IR::Build::DrawOrder.new(objects: drawn.names, order: :order)
      ordered = VBlank::IR::Build.present_objects(drawn.names, orders: [run])
      beside = drawn.parent.children
      beside[beside.index(drawn)] = ordered
      ordered.parent = drawn.parent
    end
    prog
  end
end

class TestDrawInOrder < Minitest::Test
  include Differential
  include DrawInOrderGames

  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  OVERLAP = [70, 66].freeze

  # Where the red block of DrawInOrderGames#hand_ordered_program shows and the green one does not reach.
  RED_ALONE = [62, 62].freeze

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

  # An order as long as the Game Boy Color keeps places for (forty), the fewest of any console, so a
  # crowd every console keeps: a pool of all but two, and the enemy and the hero.
  def test_an_order_as_long_as_the_smallest_console_keeps_is_drawn
    crowd = VBlank::Console.described(:gbc).sprite_places - 2
    assert_equal RED, shown(crowded_program(54, crowd: crowd)), "the hero stands higher, so the enemy covers him"
    assert_equal GREEN, shown(crowded_program(66, crowd: crowd)), "the hero stands lower, so he covers the enemy"
  end

  # The hero walks down a pixel a frame from above the enemy to below it, and the two swap
  # which is in front on the frame his feet pass the enemy's.
  def test_two_sprites_swap_as_one_walks_past_the_other
    walking = two_program(50, step: 1)
    seen = [4, 14].map { |frames| shown(walking, frames: frames) }

    assert_equal [RED, GREEN], seen
    [4, 14].each { |frames| assert_backends_agree(walking, frames: frames) }
  end

  # Level things keep the order they had last frame, not the order they were declared in. The hero
  # is declared before the enemy, so standing level from the start the enemy covers him. Starting
  # lower, in front, and walking up until he is level, he stays in front.
  private def level_program(hero_from)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      hero = sprite :hero, at: [enemy_at[0] + 8, hero_from]
      enemy = sprite :enemy, at: enemy_at
      draw_in_order hero, enemy
      game_loop { hero.y -= 1 if hero.y > enemy_at[1] }
    end
  end

  def test_level_things_keep_the_order_they_had_last_frame
    assert_equal RED, shown(level_program(ENEMY_AT[1]), frames: 12), "level from the start: declared order"
    walked = level_program(ENEMY_AT[1] + 6)

    assert_equal GREEN, shown(walked, frames: 12), "walked up to level from in front: still in front"
    assert_backends_agree(walked, frames: 12)
  end

  # A thing that shows again comes in at the back of the things level with it, as if newly added. The
  # hero walks up from in front to level with the enemy and stays in front; hidden on the twentieth
  # pass and shown again on the twenty-fourth, he comes back behind the enemy, level as they are.
  # A pixel lower on the thirty-fourth, he is in front again. A pool's thing taken away and a new
  # one put in its place comes in the same way, behind the hero standing level with it.
  private def shown_again_program
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      hero = sprite :hero, at: [enemy_at[0] + 8, enemy_at[1] + 6]
      enemy = sprite :enemy, at: enemy_at
      draw_in_order hero, enemy
      t = var :t, 0
      game_loop do
        t += 1
        hero.y -= 1 if hero.y > enemy_at[1] && t < 20
        hero.hide if t == 20
        hero.show if t == 24
        hero.y += 1 if t == 34
      end
    end
  end

  def test_a_thing_shown_again_comes_in_behind_the_things_level_with_it
    prog = shown_again_program

    assert_equal GREEN, shown(prog, frames: 16), "walked up to level from in front: in front"
    assert_equal RED, shown(prog, frames: 22), "hidden: the enemy alone"
    assert_equal RED, shown(prog, frames: 30), "shown again level: behind the enemy"
    assert_equal GREEN, shown(prog, frames: 40), "a pixel lower: in front again"
    assert_backends_agree(prog, frames: [22, 30, 40])
  end

  # The pool's older thing stands level with the hero and is in front of him, as a pool's older thing
  # is in front: taken away and spawned again on the same spot, it comes in behind him.
  private def pool_shown_again_program
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:walker, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      hero = sprite :hero, at: [enemy_at[0] + 8, enemy_at[1]]
      walkers = pool :walker, x: 0, y: 0, capacity: 3, image: :walker
      draw_in_order hero, walkers
      walkers.spawn(x: enemy_at[0], y: enemy_at[1])
      t = var :t, 0
      game_loop do
        t += 1
        walkers.each(&:remove) if t == 10
        walkers.spawn(x: enemy_at[0], y: enemy_at[1]) if t == 14
      end
    end
  end

  # Many coming and going at once: four sprites hidden and shown on passes of their own, some level
  # with each other, some passing, and a pool whose things are spawned and taken away, all over one
  # spot. Every run plays it against the interpreter on every pass; here the spot shows one of them.
  private def comings_and_goings_program
    block = BLOCK
    colors = SEVEN_COLORS.first(5)
    program do
      screen :tiled
      colors.each { |color| image(:"block_#{color}", "#" => color) { block } }
      things = colors.first(4).each_with_index.map do |color, i|
        sprite :"block_#{color}", at: [60 + (i * 2), 56 + ((i % 2) * 4)]
      end
      walkers = pool :walker, x: 0, y: 0, capacity: 4, image: :"block_#{colors.last}"
      draw_in_order(*things, walkers)
      t = var :t, 0
      game_loop do
        t += 1
        things.each_with_index do |thing, i|
          thing.hide if (t % (5 + i)) == 0
          thing.show if (t % (5 + i)) == 2
          thing.y = 56 + ((t / 3) % 7) if i == 2
        end
        walkers.spawn(x: 62, y: 56 + (t % 5)) if (t % 4) == 1
        walkers.each { |walker| walker.remove if walker.y == 58 } if (t % 6) == 3
      end
    end
  end

  def test_things_coming_and_going_among_level_ones_are_drawn_in_order
    shown_colors = SEVEN_COLORS.first(5).map { |color| color_named(color) }

    assert_includes shown_colors, shown(comings_and_goings_program, frames: 61)
    assert_backends_agree(comings_and_goings_program, frames: [13, 26, 37, 49, 61])
  end

  # The whole order turned round while things come and go: a pool of eight over one spot, every one
  # turned upside down each pass so every thing passes every other, which is the most a sort that
  # turns runs round (and moves things back past many) is given, with one taken away and another
  # spawned every few passes.
  private def turned_round_while_coming_and_going_program
    block = BLOCK
    program do
      screen :tiled
      image(:speck, "#" => :red) { block }
      image(:mark, "#" => :green) { block }
      crowd = pool :crowd, x: 0, y: 0, capacity: 8, image: :speck
      hero = sprite :mark, at: [62, 57]
      draw_in_order(crowd, hero)
      8.times { |i| crowd.spawn(x: 54 + i, y: 50 + ((i * 5) % 16)) }
      t = var :t, 0
      game_loop do
        t += 1
        crowd.each { |thing| thing.y = 115 - thing.y }
        hero.y = 115 - hero.y
        crowd.each { |thing| thing.remove if thing.y == 50 + ((t * 3) % 16) } if (t % 3) == 0
        crowd.spawn(x: 56 + (t % 8), y: 50 + (t % 16)) if (t % 3) == 1
      end
    end
  end

  def test_an_order_turned_round_while_things_come_and_go_is_drawn_in_order
    prog = turned_round_while_coming_and_going_program

    assert_kind_of Integer, shown(prog, frames: 40)
    assert_backends_agree(prog, frames: [10, 25, 40])
  end

  # Two pools of a scene in one order, things spawned and taken away in each, and the scene put down
  # and up again every so often: the places of a pool showing are its first, as many as it holds,
  # and none while its scene is down.
  private def scene_pools_coming_and_going_program
    block = BLOCK
    program do
      screen :tiled
      image(:speck, "#" => :red) { block }
      image(:dot, "#" => :blue) { block }
      image(:mark, "#" => :green) { block }
      state = var :state, 0
      t = var :t, 0
      scene(:playing) do
        specks = pool :specks, x: 0, y: 0, capacity: 5, image: :speck
        dots = pool :dots, x: 0, y: 0, capacity: 4, image: :dot
        hero = sprite :mark, at: [62, 57]
        draw_in_order(specks, hero, dots)
        specks.spawn(x: 56 + (t % 9), y: 50 + (t % 13)) if (t % 3) == 1
        dots.spawn(x: 58 + (t % 7), y: 52 + (t % 11)) if (t % 5) == 2
        specks.each { |thing| thing.remove if thing.y == 50 + ((t * 7) % 13) } if (t % 4) == 0
        dots.each { |thing| thing.remove if thing.x == 58 + ((t * 3) % 7) } if (t % 6) == 0
        hero.y = 50 + ((t / 2) % 13)
      end
      scene(:resting) {}
      game_loop do
        t += 1
        state = ((t / 11) % 4) == 3 ? 1 : 0
        call({ 0 => :playing, 1 => :resting }, number: :state)
      end
    end
  end

  def test_pools_of_a_scene_coming_and_going_in_one_order_are_drawn_in_order
    prog = scene_pools_coming_and_going_program

    assert_kind_of Integer, shown(prog, frames: 50)
    assert_backends_agree(prog, frames: [9, 21, 33, 46, 58, 70])
  end

  def test_a_pools_thing_spawned_again_comes_in_behind_the_things_level_with_it
    prog = pool_shown_again_program

    assert_equal RED, shown(prog, frames: 6), "the walker, named after the hero, is in front"
    assert_equal GREEN, shown(prog, frames: 12), "taken away: the hero alone"
    assert_equal GREEN, shown(prog, frames: 20), "spawned again level: behind the hero"
    assert_backends_agree(prog, frames: [12, 20])
  end

  # The number is the game's to work out. A puff of smoke starts a step nearer the front and
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

  # Numbers that all hold a fraction are put in order the way Ruby orders them: 54.5 is behind
  # 60.0, and 66.5 is in front of it. The hero's number is his y and a half, the enemy's its y,
  # given a fraction with `.to_f` (mixing the two kinds is refused; see the refusals below).
  private def fraction_program(hero_y)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      half = var :half, 0.5
      enemy = sprite :enemy, at: enemy_at
      hero = sprite :hero, at: [enemy_at[0] + 8, hero_y]
      draw_in_order(enemy, hero) { |thing| thing.equal?(hero) ? thing.y.to_f + half : thing.y.to_f }
      game_loop {}
    end
  end

  def test_numbers_that_all_hold_a_fraction_are_put_in_order
    assert_equal RED, shown(fraction_program(54)), "54.5 is behind 60, so the enemy covers the hero"
    assert_equal GREEN, shown(fraction_program(66)), "66.5 is in front of 60"
    assert_backends_agree(fraction_program(54), frames: 2)
  end

  # A pool's things take part one by one. Two of them are spawned so that the older — which
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

  # A pool alone, sorted among itself, beside an order of other things, the way one kind of thing in
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

  # A number read from another of a thing's fields. Most numbers are where a thing stands, which
  # the pool's copy for drawing already holds; this one adds a field of the pool's own, so it is
  # worked out as the copy is made. The older puff stands lower and would be in front, but the
  # younger is lifted twenty pixels nearer the front.
  private def lifted_program(lift)
    block = BLOCK
    program do
      screen :tiled
      colors :puff_colors, %i[transparent red]
      colors :young_colors, %i[transparent green]
      image(:puff, "#" => :red, colors: :puff_colors) { block }
      puffs = pool :puffs, x: 0, y: 0, lift: 0, capacity: 4, image: :puff
      draw_in_order(puffs) { |puff| puff.y + puff.lift }
      puffs.spawn(x: 60, y: 62, lift: 0)
      puffs.spawn(x: 64, y: 54, lift: lift)
      game_loop { puffs.each { |puff| puff.draw_with :young_colors if puff.y == 54 } }
    end
  end

  def test_a_pools_number_can_read_any_of_its_fields
    assert_equal RED, shown(lifted_program(0), frames: 3), "the lower puff is in front"
    assert_equal GREEN, shown(lifted_program(20), frames: 3), "the lifted puff is in front"
    assert_backends_agree(lifted_program(20), frames: 3)
  end

  # A pool's number below nought. The pool's places stay small, so a console may keep them and the
  # numbers worked out from them narrower than a whole number; a number below nought must still
  # come before every number above it. The puff stands higher than the hero, its number moved
  # +shift+ from where it stands.
  private def shifted_pool_program(shift)
    block = BLOCK
    program do
      screen :tiled
      image(:hero, "#" => :blue) { block }
      image(:puff, "#" => :red) { block }
      hero = sprite :hero, at: [62, 58]
      puffs = pool :puffs, x: 0, y: 0, capacity: 2, image: :puff
      draw_in_order(hero, puffs) { |thing| thing.equal?(hero) ? thing.y : thing.y + shift }
      puffs.spawn(x: 60, y: 54)
      game_loop {}
    end
  end

  def test_a_pools_number_below_nought_is_behind
    assert_equal BLUE, shown(shifted_pool_program(-80), frames: 3), "the puff's number is below nought, behind the hero's"
    assert_equal RED, shown(shifted_pool_program(80), frames: 3), "the puff's number is past the hero's"
    assert_backends_agree(shifted_pool_program(-80), frames: 3)
  end

  # --- seven in one order ---

  private def color_named(name) = VBlank::Graphics::Color.resolve(name)
  private def seven_shown(prog) = game_player.run(prog, frames: 3).screen.pixel(*SEVEN_AT)

  # Of seven standing in a muddle, the lowest is in front, wherever it was named.
  def test_of_seven_the_lowest_is_in_front
    assert_equal color_named(:green), seven_shown(seven_program([3, 6, 0, 5, 1, 4, 2]))
    assert_equal color_named(:red), seven_shown(seven_program([6, 5, 4, 3, 2, 1, 0]))
  end

  # front: :lowest turns it round: the highest of the seven is in front.
  def test_of_seven_the_highest_is_in_front_when_the_lowest_number_is
    assert_equal color_named(:blue), seven_shown(seven_program([3, 6, 0, 5, 1, 4, 2], front: :lowest))
  end

  # Seven standing level keep the order they were declared in, whichever end is in front: the
  # last one declared covers the rest, as it does with no order at all.
  def test_seven_standing_level_keep_the_order_they_were_declared_in
    assert_equal color_named(:white), seven_shown(seven_program([2] * 7))
    assert_equal color_named(:white), seven_shown(seven_program([2] * 7, front: :lowest))
  end

  # The seven stand at a new row of heights each pass, one after another, then stay at the last:
  # in a line, the line turned round, a turned-round run behind one that stands apart, the same with
  # two level in it, all level, turned round again, and a falling line with level pairs. Each row is
  # sorted from the order the row before left, so the order turns round whole and in part, and
  # things level keep the order they had. A checked run compares every pass's sprites with the
  # interpreter's; the last row, a muddle, puts the lowest, green, in front.
  TURNING_ROWS = [[0, 1, 2, 3, 4, 5, 6], [6, 5, 4, 3, 2, 1, 0], [2, 6, 5, 4, 3, 1, 0], [2, 6, 5, 5, 3, 1, 0],
                  [3] * 7, [6, 5, 4, 3, 2, 1, 0], [5, 4, 4, 3, 1, 0, 0], [3, 6, 0, 5, 1, 4, 2]].freeze

  private def turning_seven_program
    colors = SEVEN_COLORS
    rows = TURNING_ROWS
    small = Array.new(8) { "#" * 8 }.join("\n")
    program do
      screen :tiled
      heights = table :heights, rows.flatten, width: :byte
      row = var :row, 0
      things = colors.each_with_index.map do |color, i|
        image(:"small_#{color}", "#" => color) { small }
        sprite :"small_#{color}", at: [60 + i, 30]
      end
      draw_in_order(*things)
      game_loop do
        things.each_with_index { |thing, i| thing.y = 30 + heights[(row * 7) + i] }
        row += 1 if row < rows.length - 1
      end
    end
  end

  def test_seven_turned_round_whole_and_in_part_are_drawn_in_order
    assert_equal color_named(:green), game_player.run(turning_seven_program, frames: 12).screen.pixel(*SEVEN_AT)
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

  # A block that gives one thing a number with a fraction and another a whole number is refused,
  # naming both: the order would compare 54.5, kept multiplied up, against a plain 60.
  def test_a_fraction_beside_a_whole_number_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      half = var :half, 0.5
      enemy = sprite :enemy, at: [60, 60]
      hero = sprite :hero, at: [68, 54]
      draw_in_order(enemy, hero) { |thing| thing.equal?(hero) ? thing.y.to_f + half : thing.y }
    end

    assert_match(/a whole number for sprite :enemy/, message)
    assert_match(/a fraction for sprite :hero/, message)
    assert_match(/one kind only/, message)
  end

  def test_a_pools_fraction_beside_a_sprites_whole_number_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:walker, "#" => :red) { block }
      image(:hero, "#" => :blue) { block }
      walkers = pool :walker, x: 0, y: 0, lift: 0.0, capacity: 4, image: :walker
      hero = sprite :hero, at: [62, 58]
      draw_in_order(walkers, hero) { |thing| thing.equal?(hero) ? thing.y : thing.y.to_f + thing.lift }
    end

    assert_match(/a fraction for pool :walker/, message)
    assert_match(/a whole number for sprite :hero/, message)
  end

  # With no block the numbers are the bottoms of the boxes, and a pool whose places hold a fraction
  # has a bottom that holds one: the refusal then asks for a block.
  def test_a_pools_fraction_bottom_beside_a_sprites_whole_one_asks_for_a_block
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:walker, "#" => :red) { block }
      image(:hero, "#" => :blue) { block }
      walkers = pool :walker, x: 0.0, y: 0.0, capacity: 4, image: :walker
      hero = sprite :hero, at: [62, 58]
      draw_in_order walkers, hero
    end

    assert_match(/a fraction for pool :walker/, message)
    assert_match(/Give draw_in_order a block/, message)
  end

  # Two fractions with different bits are refused the same way. A game's own fractions all have
  # the default bits, so the coarse one is made by hand, as test_fraction_type.rb makes one.
  def test_fractions_of_different_bits_are_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      var :coarse, 0
      coarse = VBlank::DSL::Value.new(self, VBlank::IR::Build.var_ref(:coarse), name: :coarse, fraction_bits: 8)
      enemy = sprite :enemy, at: [60, 60]
      hero = sprite :hero, at: [68, 54]
      draw_in_order(enemy, hero) { |thing| thing.equal?(hero) ? coarse : thing.y.to_f }
    end

    assert_match(/16 bits of fraction for sprite :enemy/, message)
    assert_match(/8 bits of fraction for sprite :hero/, message)
    assert_match(/the same bits/, message)
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
      game_loop { call({ 0 => :playing }, number: :state) }
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

  # The order holds inside each layer. A hero and a guard standing in one layer, the lower one in
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

  # --- an order list the game writes itself ---

  # -1 is the green block, so it goes down first, under the red one; then the red one's entry is
  # taken off the end, and the list names green alone.
  def test_an_order_list_of_the_games_own_is_read_as_it_holds
    prog = hand_ordered_program do |order|
      order.push(-1)
      order.push 0
      n = var :n, 0
      game_loop do
        order.pop if n == 3
        n += 1
      end
    end

    assert_equal RED, shown(prog, frames: 2), "green goes down first, so red is in front"
    assert_equal RED, game_player.run(prog, frames: 2).screen.pixel(*RED_ALONE), "and red is drawn"
    assert_equal GREEN, shown(prog, frames: 6), "the list names green alone"
    refute_equal RED, game_player.run(prog, frames: 6).screen.pixel(*RED_ALONE), "and red is not drawn"
  end

  # A place that names none of the run's sprites stops the game, on every console as in the interpreter:
  # one past the last sprite, and one counting back past the first.
  def test_an_order_entry_naming_no_sprite_stops_the_game
    [2, -3].each do |none|
      prog = hand_ordered_program do |order|
        order.push 0
        order.push none
        game_loop {}
      end

      error = assert_raises(Reference::ProgramError) { game_player.run(prog, frames: 3) }
      assert_match(/draw order names sprite #{none} of the 2/, error.message)
    end
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
