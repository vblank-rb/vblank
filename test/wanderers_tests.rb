# frozen_string_literal: true

require VBlank.root.join("examples/wanderers").to_s

# FOUR PEOPLE WANDERING ONE MAP (examples/wanderers.rb), each in a colour the game picked when they
# joined. A build that plays on a computer seats four; a cartridge seats the one controller its
# console reads, so the game built for a cartridge is the one-player walk that
# test/all/examples/test_wanderers_example.rb plays on every run. These tests play the game as a
# computer builds it, so they are played through game_player by each run whose player reads four
# players: the interpreter (test/interpreter/examples/test_wanderers_interpreter.rb), and the game
# as C, as JavaScript and as Ruby, checked against it on every frame (the files named
# test_*_wanderers*.rb in the native, JavaScript and Ruby lowerings' examples/ folders). No
# cartridge run loads them, since every cartridge refuses a game that reads four players.
module WanderersTests
  # Where on a walker its own colour is sure to be, from its top left: the middle of its head
  # (Wanderers::WALKER_ART, row 3, column 3).
  BODY = [3, 3].freeze

  # The game as a computer builds it for this run's console: four seats.
  private def four_seat_program
    skip_unless_written_for Wanderers::GAME
    Wanderers::GAME.checked_program(err: nil, console: game_console)
  end

  private def layout
    width, height = VBlank::Console.described(game_console).screen_size
    Wanderers::Layout.new(width: width, height: height)
  end

  # Where +player+ stands after walking +dx+, +dy+ from where they start.
  private def place_of(player, dx = 0, dy = 0)
    x, y = layout.starts.fetch(player - 1)
    [x + dx, y + dy]
  end

  # The colour drawn at the head of a walker standing at +place+.
  private def head_color(run, place)
    x, y = place
    run.screen.pixel(x + BODY[0], y + BODY[1])
  end

  # The colour the game picked for +player+, as this run's console shows it.
  private def picked_color(run, player)
    hue = run[:"hue#{player}"]
    assert_includes 0...Wanderers::COLORS.size, hue, "player #{player} has a colour picked"
    shown(Wanderers::COLORS.fetch(hue))
  end

  # Whether any pixel of the walker-sized square at +place+ is in one of the walkers' colours.
  private def walker_drawn_at?(run, place)
    colors = Wanderers::COLORS.map { |color| shown(color) }
    x, y = place
    (0...Wanderers::SIZE).any? do |dy|
      (0...Wanderers::SIZE).any? { |dx| colors.include?(run.screen.pixel(x + dx, y + dy)) }
    end
  end

  # Each of the four holds a different way for eight frames, then lets go. The picture is read a
  # few frames after they stop, so the sprites stand where the last move put them on every console.
  private def four_ways_on(frame)
    frame <= 8 ? %i[right p2_left p3_up p4_down] : []
  end

  def test_four_players_each_walk_their_own_way_in_their_own_colour
    run = game_player.input_each_frame { |frame| four_ways_on(frame) }.run(four_seat_program, frames: 11)

    places = { 1 => place_of(1, 8, 0), 2 => place_of(2, -8, 0), 3 => place_of(3, 0, -8), 4 => place_of(4, 0, 8) }
    places.each do |player, place|
      assert_equal picked_color(run, player), head_color(run, place), "player #{player} walked to #{place.inspect}"
    end
  end

  def test_only_one_walker_is_drawn_while_only_the_first_players_buttons_are_held
    run = game_player.input_each_frame { |frame| frame <= 6 ? [:right] : [] }.run(four_seat_program, frames: 9)

    assert_equal picked_color(run, 1), head_color(run, place_of(1, 6, 0))
    (2..4).each do |player|
      refute walker_drawn_at?(run, place_of(player)), "player #{player} is not connected, so not drawn"
      assert_equal Wanderers::NOT_PICKED, run[:"hue#{player}"], "and has no colour yet"
    end
  end

  def test_a_player_who_joins_later_is_given_a_colour_as_they_join
    joins_on_frame_six = ->(frame) { frame == 6 ? [:p2_a] : [] }

    before = game_player.input_each_frame(&joins_on_frame_six).run(four_seat_program, frames: 4)
    assert_equal Wanderers::NOT_PICKED, before[:hue2]
    refute walker_drawn_at?(before, place_of(2))

    after = game_player.input_each_frame(&joins_on_frame_six).run(four_seat_program, frames: 10)
    assert_equal picked_color(after, 2), head_color(after, place_of(2))
  end

  # The first player walks right, straight through the second one's place and out the other side:
  # nothing stops them, and both are drawn where they stand.
  def test_players_walk_through_each_other
    presses = ->(frame) { [(:p2_a if frame == 1), (:right if frame <= 40)].compact }
    run = game_player.input_each_frame(&presses).run(four_seat_program, frames: 43)

    assert_equal picked_color(run, 1), head_color(run, place_of(1, 40, 0))
    assert_equal picked_color(run, 2), head_color(run, place_of(2))
  end

  # The colours come from the game's random numbers, which start from the game's seed: the same
  # presses pick the same colours every time, so machines sharing one match agree on them.
  def test_the_same_presses_pick_the_same_colours
    hues = Array.new(2) do
      run = game_player.input_each_frame { |frame| four_ways_on(frame) }.run(four_seat_program, frames: 3)
      (1..4).map { |player| run[:"hue#{player}"] }
    end

    assert_equal hues.first, hues.last
  end
end
