# frozen_string_literal: true

require "test_helper"
require "network_exchanges"

# THE STAND-IN RELAY HELD TO THE EXAMPLE EXCHANGES (docs/network/exchanges.json), which the real relay
# and every other implementation of the format are held to as well.
class TestStandInRelay < Minitest::Test
  StandInRelay = VBlank::Network::StandInRelay

  NetworkExchanges.all.each do |exchange|
    define_method("test_#{exchange['name'].gsub(/\W+/, '_')}") do
      relay = StandInRelay.new
      problems = NetworkExchanges.play(exchange) { relay.connect }

      assert_empty problems
    end
  end

  def test_a_room_holds_as_many_machines_as_a_match_has_players
    relay = StandInRelay.new
    host = relay.connect
    host.send_text('{"v":1,"type":"make_room"}')
    code = JSON.parse(host.receive_text).fetch("code")
    (StandInRelay::MOST_MEMBERS - 1).times { relay.connect.send_text(%({"v":1,"type":"join_room","code":"#{code}"})) }
    late = relay.connect
    late.send_text(%({"v":1,"type":"join_room","code":"#{code}"}))

    assert_equal "room_full", JSON.parse(late.receive_text).fetch("reason")
  end

  def test_a_code_is_found_whatever_its_case
    relay = StandInRelay.new(codes: %w[KQ7X].each)
    relay.connect.send_text('{"v":1,"type":"make_room"}')
    guest = relay.connect
    guest.send_text('{"v":1,"type":"join_room","code":"kq7x"}')

    assert_equal "room_joined", JSON.parse(guest.receive_text).fetch("type")
  end

  def test_an_empty_room_is_gone_so_its_code_is_no_room
    relay = StandInRelay.new(codes: %w[KQ7X].each)
    host = relay.connect
    host.send_text('{"v":1,"type":"make_room"}')
    host.close
    guest = relay.connect
    guest.send_text('{"v":1,"type":"join_room","code":"KQ7X"}')

    assert_equal "no_such_room", JSON.parse(guest.receive_text).fetch("reason")
  end

  def test_two_rooms_do_not_hear_each_other
    relay = StandInRelay.new
    a = relay.connect
    b = relay.connect
    [a, b].each { |machine| machine.send_text('{"v":1,"type":"make_room"}') }
    a.receive_text
    b.receive_text
    a.send_text('{"v":1,"type":"buttons","pass":2,"mask":1}')

    refute b.pending?
  end
end
