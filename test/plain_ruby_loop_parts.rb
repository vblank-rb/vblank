# frozen_string_literal: true

# Methods a game calls from its game loop, each counting in a name it sets to 0 on its first line,
# brought in by `VBlank.require_game_file` for test/all/vblank/dsl/test_plain_ruby_parts.rb. Called
# on every pass, each answers the same count on every pass: the first line sets the name where it
# runs, as Ruby's does. The part holds the game's builder and calls its verbs by name.
class LoopCountPart
  def initialize(build)
    @build = build
  end

  def counted_by_repeat(rounds)
    count = 0
    @build.repeat(rounds) { count += 1 }
    count
  end

  # The builder held in a local, not an instance variable.
  def counted_by_repeat_on_local(rounds)
    build = @build
    count = 0
    build.repeat(rounds) { count += 1 }
    count
  end

  # +rounds+ is a number the game keeps, so both loops are the game's.
  def counted_by_while_in_while(rounds)
    count = 0
    row = 0
    while row < rounds
      column = 0
      while column < rounds
        count += 1
        column += 1
      end
      row += 1
    end
    count
  end

  # The loop inside counts to a plain number, so Ruby writes it out; the loop around it is the game's.
  def counted_by_ruby_loop_in_while(rounds)
    count = 0
    row = 0
    until row == rounds
      column = 0
      while column < 2
        count += 1
        column += 1
      end
      row += 1
    end
    count
  end

  # A count set at the top of each round of a loop the game makes, changed in a `repeat` in it.
  def rounds_with_two_counted(rounds)
    matched = 0
    row = 0
    while row < rounds
      count = 0
      @build.repeat(row) { count += 1 }
      matched += 1 if count == 2
      row += 1
    end
    matched
  end

  def counted_over_ruby_list(rounds)
    count = 0
    [1, 2, 3].each_with_index { |_item, place| count += 1 if rounds > place }
    count
  end

  # The list is held in a name, so only running the line shows it is Ruby's and not a pool.
  def counted_over_named_ruby_list(rounds)
    places = [0, 1, 2]
    count = 0
    places.each_with_index { |_item, place| count += 1 if rounds > place }
    count
  end

  # Two names started on one line.
  def counted_in_one_of_two_names(rounds)
    count, other = 0, 0
    @build.repeat(rounds) { count += 1 }
    count + other
  end

  # A beat every second frame: 1 on a pass the beat falls on, and 0 on the others.
  def counted_by_every
    count = 0
    @build.every(2) { count += 1 }
    count
  end

  # A step taken once a pass from when it starts, counting in a name the method set before it.
  # A job is made once, so a game calls this while setting up.
  def steps_each_pass(name)
    steps = 0
    @build.each_pass(name) { |_job| steps += 1 }.start
    steps
  end

  # Once, two frames in: 1 on the pass that runs it, and 0 on the others.
  def counted_by_after
    count = 0
    @build.after(2) { count += 1 }
    count
  end

  # A row picked with A: 1 on the pass the press picks it, and 0 on the others.
  def picks_by_menu(name)
    picks = 0
    @build.menu(name, at: [40, 40], press: :a) { |rows| rows.item("GO") { picks += 1 } }
    picks
  end

  # A step taken once a frame, from power-on wherever it is written, so a game calls this while
  # setting up.
  def steps_once_a_frame
    steps = 0
    @build.once_a_frame { steps += 1 }
    steps
  end

  # A step taken on every tick of a timer the method makes, also while setting up.
  def steps_on_tick(name)
    steps = 0
    @build.timer(name, per_second: 120).on_tick { steps += 1 }
    steps
  end
end

# The beat and the job again, as methods of the game file's own with the verbs called bare: what
# the part's methods are held to.
def loop_count_by_bare_every
  count = 0
  every(2) { count += 1 }
  count
end

def loop_steps_each_pass_bare(name)
  steps = 0
  each_pass(name) { |_job| steps += 1 }.start
  steps
end

# A method of the game file's own, called bare from a game block, so its verbs are the builder's.
def loop_count_by_bare_repeat(rounds)
  count = 0
  repeat(rounds) { count += 1 }
  count
end

# The same, handed the builder as a name.
def loop_count_by_repeat_on(build, rounds)
  count = 0
  build.repeat(rounds) { count += 1 }
  count
end

# A local whose name no other local of this file uses, and which test/plain_ruby_game_parts.rb
# and a test's game block use too: each is its own variable, whichever runs first.
def steps_taken_by_bare_repeat(rounds)
  steps_taken = 0
  repeat(rounds) { steps_taken += 1 }
  steps_taken
end

# The verbs LoopCountPart's last methods call on the builder it holds, called bare: what those
# methods are held to.
def loop_count_by_bare_after
  count = 0
  after(2) { count += 1 }
  count
end

def loop_picks_by_bare_menu(name)
  picks = 0
  menu(name, at: [40, 40], press: :a) { |rows| rows.item("GO") { picks += 1 } }
  picks
end

def loop_steps_once_a_frame_bare
  steps = 0
  once_a_frame { steps += 1 }
  steps
end

def loop_steps_on_tick_bare(name)
  steps = 0
  timer(name, per_second: 120).on_tick { steps += 1 }
  steps
end
