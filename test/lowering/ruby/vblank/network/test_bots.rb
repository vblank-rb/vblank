# frozen_string_literal: true

require "test_helper"
require "zlib"
require "vblank/live"
require VBlank.root.join("examples/wanderers").to_s

# A BOT IS A PLAYER WITH NO WINDOW AND NO PERSON (Bots): a script that reads its own copy of the game and
# chooses its buttons each pass, and that joins a match like any machine. These play it through the
# stand-in relay, in this process, with the copies taking turns (Network::Scheduler), so a run is the same run
# every time. Wanderers keeps each walker's place in the variables of its sprite, `__obj1_x` for the first
# player's walker (the sprites are made in player order), which is what the chaser reads.
class TestBots < Minitest::Test
  Network = VBlank::Network
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless
  BotDevice = VBlank::Live::BotDevice

  PASSES = 70

  private def program = @program ||= Wanderers::GAME.checked_program(err: nil, console: :gba, settings: { you_line: false })

  # A bot that walks its walker toward the first player's, on a line across and then up or down.
  private def chaser
    VBlank::Bots::Bot.define("chaser") do |game|
      mine = ->(axis) { game.var(:"__obj#{game.player}_#{axis}") }
      theirs = ->(axis) { game.var(:"__obj1_#{axis}") }
      [(:left if mine.call(:x) > theirs.call(:x)), (:right if mine.call(:x) < theirs.call(:x)),
       (:up if mine.call(:y) > theirs.call(:y)), (:down if mine.call(:y) < theirs.call(:y))]
    end
  end

  # Plays a match through the relay in this process: +machines+ is a list of devices, each given the bot (or
  # nothing) that decides its buttons. The first makes the room.
  private def match(devices)
    relay = Network::StandInRelay.new
    scheduler = Network::Scheduler.new(movement: -> { relay.pending? })
    code = []
    print = Network::Fingerprint.of(program, title: "WANDERERS")
    copies = devices.each_with_index.map do |device, index|
      line = Network::InProcessLine.new(relay.connect, scheduler)
      lambda do
        lockstep = if index.zero?
                     transport = Network::RelayTransport.make_room(line)
                     code << transport.code
                     Network::Lockstep.host(transport: transport, fingerprint: print, players: devices.size, seed: 0, input_delay: 2,
                                            checkpoint_every: 4)
                   else
                     Network::Lockstep.join(transport: Network::RelayTransport.join_room(line, code.first), fingerprint: print)
                   end
        Session.new(program, network: lockstep).play(device)
        lockstep
      end
    end
    [scheduler.play(copies), devices]
  end

  private def distance(view, from, to)
    [(view.var(:"__obj#{from}_x") - view.var(:"__obj#{to}_x")).abs, (view.var(:"__obj#{from}_y") - view.var(:"__obj#{to}_y")).abs]
  end

  def test_a_bot_joins_as_player_two_and_walks_toward_player_one_and_every_pass_agrees
    person = Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, [:up]] }) # player 1 walks up
    bot = BotDevice.new(chaser, passes: PASSES)

    outcomes, = match([person, bot])

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    assert_equal 2, bot.view.player
    first, second = distance(bot.view, 2, 1)
    # Player 2 started 24 across and level with player 1, who has walked up since: the bot has closed the
    # gap across and is following up.
    assert_operator first, :<, 24
    assert_operator second, :<, (PASSES / 2)
  end

  def test_a_bot_reads_the_game_and_never_writes_it
    view_class = VBlank::Bots::GameView
    refute view_class.public_instance_methods(false).any? { |name| name.to_s.end_with?("=") || %i[set write store].include?(name) }
  end

  def test_a_bot_that_answers_a_name_that_is_not_a_button_is_told_in_plain_words
    bad = VBlank::Bots::Bot.define("wrong") { |_game| [:p2_left] }

    error = assert_raises(ArgumentError) { bad.buttons_for(nil) }

    assert_match(/not a button/, error.message)
    assert_match(/plain names/, error.message)
  end

  def test_a_variable_the_game_does_not_have_is_said_with_the_ones_it_has
    bot = VBlank::Bots::Bot.define("curious") { |game| game.var(:no_such) && nil }
    device = BotDevice.new(bot, passes: 3)

    outcomes, = match([Headless.new(frames: 3), device])

    error = outcomes.filter_map(&:error).first
    assert_kind_of ArgumentError, error
    assert_match(/no variable named :no_such/, error.message)
    assert_match(/hue1/, error.message)
  end

  def test_bots_that_play_a_tape_give_the_match_the_tape_was_made_of
    pictures = lambda do |devices|
      devices.map { |device| Zlib.crc32(device.last_picture.pixels.pack("v*")) }.uniq
    end
    tape = recorded_tape
    played_locally = tape.play(VBlank::Playthroughs::UnbuiltGame.new(program, title: "WANDERERS", source: "w"), on: "interpreter")
    local = Zlib.crc32(played_locally.game.frame_gba.pack("v*"))

    bots = [1, 2].map { |player| BotDevice.new(VBlank::Bots::TapeBot.new(tape, player: player), passes: PASSES, keep_picture: true) }
    outcomes, = match(bots)

    outcomes.each { |outcome| assert_nil outcome.error, outcome.error.inspect }
    assert_equal [local], pictures.call(bots)
  end

  # The tape of a match two people played: player 1 walks right and player 2 left, as it was kept.
  private def recorded_tape
    machines = [[:right], [:left]].map { |walk| Headless.new(frames: PASSES, buttons: (2..PASSES).to_h { |pass| [pass, walk] }) }
    outcomes, = match(machines)
    outcomes.each { |outcome| assert_nil outcome.error }
    outcomes.first.value.tape
  end
end
