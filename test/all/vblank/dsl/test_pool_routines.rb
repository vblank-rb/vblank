# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# A ROUTINE THAT WORKS ON ONE INSTANCE: `guards.func(:chase) { |g| ... }`.
#
# A pool's behaviour starts inside `each` and moves into routines as a game grows — because a
# block written inline is emitted again at every place it is written, and because a game with
# states wants one routine per state. A routine is built once, wherever it is called from, so
# the one thing its own code cannot say is WHICH instance it is running for. The walk says it.
#
# So these tests are about that thread: the routine reaches the instance it ran for, two walks
# over one pool do not lose each other's place, a pool that declares no routines pays nothing
# for any of it, and calling such a routine from outside a walk is refused rather than quietly
# running on whoever was walked last.
class TestPoolRoutines < Minitest::Test
  include Differential

  private def program_with(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # --- the routine reaches its instance ---

  def test_a_routine_reads_and_writes_the_instance_it_ran_for
    program = program_with do
      screen :bitmap
      idler = var :idler, 0
      chaser = var :chaser, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| g.x += 1; idler = g.x }
      guards.func(:chase) { |g| g.x += 10; chaser = g.x }
      guards.spawn(x: 0)
      guards.spawn(x: 100, state: :chase)
      b = self
      game_loop do
        guards.each { |g| b.call g.state }
        b.halt
      end
    end
    interpreted = game_player.run(program)

    assert_equal 1, interpreted[:idler], "the idling guard started at 0 and crept by 1"
    assert_equal 110, interpreted[:chaser], "...and the chasing one started at 100 and moved by 10"
  end

  # Every instance verb the block form has, a routine has: this one retires the instance it
  # ran for, which is the pool's own bookkeeping rather than one of its fields.
  def test_a_routine_can_retire_the_instance_it_ran_for
    program = program_with do
      screen :bitmap
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| g.remove }
      3.times { |i| guards.spawn(x: i) }
      left = var :left, 99
      b = self
      game_loop do
        guards.each { |g| b.call g.state }
        left = guards.count
        b.halt
      end
    end

    assert_equal 0, game_player.run(program)[:left]
  end

  # TWO WALKS OVER ONE POOL, which is what a pairwise test is. The inner walk moves the pool's
  # place all the way to its last instance; the outer one has to carry on with its own. Without
  # the walk putting the place back as it leaves, every outer guard after the first inner walk
  # would run its routine on the last instance instead of itself.
  def test_a_walk_inside_a_walk_leaves_the_outer_one_where_it_was
    program = program_with do
      screen :bitmap
      seen = var :seen, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| seen += g.x }
      guards.spawn(x: 1)
      guards.spawn(x: 10)
      b = self
      game_loop do
        guards.each do |outer|
          guards.each { |inner| inner.x += 0 } # a walk that changes nothing but the place
          b.call :idle
        end
        b.halt
      end
    end

    assert_equal 11, game_player.run(program)[:seen],
                 "each outer guard ran on itself: 1 + 10, not the last one twice"
  end

  # A ROUTINE THAT WALKS ITS OWN POOL, which is how things of one pool bump into each other:
  # the routine steps one thing, then looks through the pool for another close by. Inside that
  # walk the routine's own thing is still itself, as it would be in plain Ruby, so `e.x` is
  # where the stepper stands and `other.x` where the one it is checked against stands.
  #
  # Two things walk toward each other two pixels a step, 60 apart. The first step that leaves
  # them nearer than 16 is the first thing's on pass 12, when it stands at 64 and the second at
  # 78. Reading the walk's thing for the routine's own would never find a meeting at all: every
  # thing the walk visited would look like the stepper itself.
  def test_a_routine_walking_its_own_pool_reads_its_own_instance_inside_the_walk
    program = program_with do
      screen :bitmap
      pass = var :pass, 0
      met_on = var :met_on, 0
      stepper_x = var :stepper_x, 0
      other_x = var :other_x, 0
      gap = var :gap, 0
      things = pool :thing, x: 0, dx: 0, capacity: 4
      things.func(:step) do |e|
        e.x += e.dx
        things.each do |other|
          if other.index != e.index
            gap = (other.x - e.x).abs
            if gap < 16 && met_on == 0
              met_on = pass
              stepper_x = e.x
              other_x = other.x
            end
          end
        end
      end
      things.spawn(x: 40, dx: 2)
      things.spawn(x: 100, dx: -2)
      b = self
      game_loop do
        pass += 1
        things.each { |_thing| b.call :step }
      end
    end
    played = game_player.run(program, frames: 20)

    assert_equal [12, 64, 78], [played[:met_on], played[:stepper_x], played[:other_x]],
                 "the first thing met the second on pass 12, at 64 and 78"
  end

  # ...and names given the routine's own slot and place before the walk keep them inside it,
  # as a name keeps the number of its line in plain Ruby.
  def test_names_set_from_a_routine_s_instance_before_its_walk_keep_that_instance
    program = program_with do
      screen :bitmap
      pass = var :pass, 0
      met_on = var :met_on, 0
      stepper_x = var :stepper_x, 0
      things = pool :thing, x: 0, dx: 0, capacity: 4
      things.func(:step) do |e|
        e.x += e.dx
        mover = e.index
        here = e.x
        things.each do |other|
          if other.index != mover && (other.x - here).abs < 16 && met_on == 0
            met_on = pass
            stepper_x = here
          end
        end
      end
      things.spawn(x: 40, dx: 2)
      things.spawn(x: 100, dx: -2)
      b = self
      game_loop do
        pass += 1
        things.each { |_thing| b.call :step }
      end
    end
    played = game_player.run(program, frames: 20)

    assert_equal [12, 64], [played[:met_on], played[:stepper_x]]
  end

  # --- and the console agrees ---

  # Each guard's routine paints a rectangle at its own x, so which instance each call ran for
  # is on the screen. Every pixel of both backends' pictures has to match.
  def test_both_backends_run_the_routine_for_the_same_instances
    program = program_with do
      screen :bitmap
      clear_screen :black
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |g| draw_rect_at g.x, 60, 20, 20, :red }
      guards.spawn(x: 10)
      guards.spawn(x: 90)
      guards.spawn(x: 170)
      b = self
      game_loop { guards.each { |g| b.call :idle } }
    end

    assert_backends_agree(program, frames: 3)
  end

  # A ROUTINE WITH NOTHING IN IT is a real routine: a kind of thing with nothing to do, in a
  # cast where every thing is told to do its part. It is called for each thing and changes
  # nothing either backend draws, and the routine called after it still runs for the right one.
  def test_a_routine_with_an_empty_body_changes_nothing_on_either_backend
    program = program_with do
      screen :bitmap
      clear_screen :black
      things = pool :thing, x: 0, y: 0, capacity: 2
      things.func(:waits) { |_thing| }
      things.func(:draws) { |thing| draw_rect_at thing.x, thing.y, 4, 4, :green }
      things.spawn(x: 20, y: 30)
      things.spawn(x: 60, y: 30)
      b = self
      game_loop do
        things.each do
          b.call :waits
          b.call :draws
        end
      end
    end
    seen = game_player.run(program, frames: 3).screen

    assert_equal [Color.resolve(:green)] * 2, [seen.pixel(21, 31), seen.pixel(61, 31)]
    assert_backends_agree(program, frames: 3)
  end

  # --- a pool that declares no routine pays nothing ---

  # The walk writes down which instance it is on only for a pool whose routines read it. A
  # pool drawn inline — which is most of them — is emitted exactly as it was.
  def test_a_pool_with_no_routine_of_its_own_writes_nothing_down
    program = program_with do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: 16
      bullets.spawn(x: 10, y: 10)
      game_loop { bullets.each { |bullet| bullet.y += 1 } }
    end
    written = program.walk.select { |node| node.kind == :set }.map(&:var)

    assert_empty written.grep(/current|pool_walk/),
                 "nothing reads which instance the walk is on, so nothing is written down"
  end

  # --- what it refuses ---

  def test_calling_it_outside_a_walk_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        guards = pool :guard, x: 0, capacity: 4
        guards.func(:chase) { |g| g.x += 1 }
        b = self
        game_loop { b.call :chase } # no walk anywhere: which guard is chasing?
      end
    end

    assert_match(/outside a walk/, err.message)
    assert_match(/each/, err.message, "and it says where to call it from")
  end

  # ...including from a plain routine in between, whose advice is to make that one a routine
  # of the pool as well, since that is what it is.
  def test_calling_it_from_a_routine_that_is_not_the_pool_s_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        guards = pool :guard, x: 0, capacity: 4
        guards.func(:chase) { |g| g.x += 1 }
        b = self
        b.func(:update) { b.call :chase }
        game_loop { guards.each { |g| b.call :update } }
      end
    end

    assert_match(/outside a walk/, err.message)
  end

  # ...but one of the pool's own routines can call another, which is how a state machine is
  # written: :idle sees the player and hands over to :chase.
  def test_one_routine_of_the_pool_can_call_another
    program = program_with do
      screen :bitmap
      chased = var :chased, 0
      guards = pool :guard, x: 0, state: :idle, capacity: 4
      guards.func(:idle) { |_g| call :chase }
      guards.func(:chase) { |g| g.x += 5; chased = g.x }
      guards.spawn(x: 20)
      b = self
      game_loop do
        guards.each { |g| b.call g.state }
        b.halt
      end
    end

    assert_equal 25, game_player.run(program)[:chased], "and it ran on the right guard"
  end

  def test_a_routine_needs_a_block
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        pool(:guard, x: 0, capacity: 4).func(:chase)
      end
    end

    assert_match(/needs a block/, err.message)
  end
end
