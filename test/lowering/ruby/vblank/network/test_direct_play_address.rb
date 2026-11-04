# frozen_string_literal: true

require "test_helper"

# THE ADDRESS A MACHINE JOINS, written HOST:PORT, and what is said about one that cannot be used.
class TestDirectPlayAddress < Minitest::Test
  Address = VBlank::Network::DirectPlay::Address

  def test_a_host_and_a_port
    address = Address.parse("192.168.1.5:9000")

    assert_equal ["192.168.1.5", 9000], [address.host, address.port]
    assert_equal "192.168.1.5:9000", address.to_s
  end

  def test_a_host_alone_takes_the_default_port
    assert_equal VBlank::Network::DirectPlay::DEFAULT_PORT, Address.parse("game-room.local").port
  end

  def test_an_address_that_cannot_be_used_is_said_in_plain_words
    ["", ":7777", "host:", "host:abc", "host:0", "host:70000", "a:b:c"].each do |text|
      error = assert_raises(ArgumentError, text.inspect) { Address.parse(text) }

      assert_match(/is not an address/, error.message)
      assert_match(/HOST:PORT/, error.message)
    end
  end

  def test_the_command_says_where_a_host_can_be_found
    addresses = VBlank::Network::DirectPlay.addresses_for(7777)

    assert_equal "127.0.0.1:7777", addresses.last
    assert(addresses.all? { |each| each.end_with?(":7777") })
  end
end
