# frozen_string_literal: true

require "test_helper"

# PUBLIC ROOMS ON THE RELAY: a room made public is listed, with its name and how many are in it, to a machine
# running the same game, and to no machine running another. A client asks with RelayTransport.list_rooms. The
# relay's side of this is held to docs/network/exchanges.json by test_stand_in_relay.rb; this is what a game
# does with it, over a line to a relay in this process.
class TestPublicRooms < Minitest::Test
  Network = VBlank::Network

  PRINT = Network::Fingerprint.new(title: "WANDERERS", console: "gba", digest: "ab12cd34")
  OTHER = Network::Fingerprint.new(title: "OTHER", console: "gba", digest: "99887766")

  private def world
    relay = Network::StandInRelay.new
    [relay, Network::Scheduler.new(movement: -> { relay.pending? })]
  end

  private def line(relay, scheduler) = Network::InProcessLine.new(relay.connect, scheduler)

  # Runs +steps+ as one copy, in a scheduler, and gives back what it returns.
  private def as_one_copy(scheduler, &steps) = scheduler.play([steps]).first.then { |outcome| outcome.error ? raise(outcome.error) : outcome.value }

  def test_a_public_room_is_listed_to_the_same_game_with_its_name_and_how_many_are_in_it
    relay, scheduler = world

    code, rooms = as_one_copy(scheduler) do
      host = Network::RelayTransport.make_room(line(relay, scheduler), listing: Network::PublicListing.new(fingerprint: PRINT, name: "Friday game", seats: 4))
      [host.code, Network::RelayTransport.list_rooms(line(relay, scheduler), PRINT)]
    end

    assert_equal [Network::PublicRoom.new(code: code, name: "Friday game", members: 1, seats: 4)], rooms
  end

  def test_it_is_not_listed_to_another_game
    relay, scheduler = world

    rooms = as_one_copy(scheduler) do
      Network::RelayTransport.make_room(line(relay, scheduler), listing: Network::PublicListing.new(fingerprint: PRINT, name: "Friday game", seats: 4))
      Network::RelayTransport.list_rooms(line(relay, scheduler), OTHER)
    end

    assert_empty rooms
  end

  def test_a_room_made_with_no_listing_is_never_listed
    relay, scheduler = world

    rooms = as_one_copy(scheduler) do
      Network::RelayTransport.make_room(line(relay, scheduler))
      Network::RelayTransport.list_rooms(line(relay, scheduler), PRINT)
    end

    assert_empty rooms
  end

  def test_a_room_that_fills_is_dropped_from_the_list_and_so_is_one_that_empties
    relay, scheduler = world

    seen = as_one_copy(scheduler) do
      host = Network::RelayTransport.make_room(line(relay, scheduler), listing: Network::PublicListing.new(fingerprint: PRINT, name: "Pair", seats: 2))
      before = Network::RelayTransport.list_rooms(line(relay, scheduler), PRINT).size
      Network::RelayTransport.join_room(line(relay, scheduler), host.code)
      full = Network::RelayTransport.list_rooms(line(relay, scheduler), PRINT).size
      alone = Network::RelayTransport.make_room(line(relay, scheduler), listing: Network::PublicListing.new(fingerprint: PRINT, name: "Alone", seats: 3))
      alone.close
      [before, full, Network::RelayTransport.list_rooms(line(relay, scheduler), PRINT).size]
    end

    assert_equal [1, 0, 0], seen
  end
end
