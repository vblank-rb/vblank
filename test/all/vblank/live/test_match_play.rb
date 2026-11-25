# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# How `vblank run` meets a match: here, the match a player chose in the window's menu, met as the
# command's flags would meet it (--host, --join, --relay, --players).
class TestMatchPlay < Minitest::Test
  MatchPlay = VBlank::Live::MatchPlay
  MatchRequest = VBlank::Live::WindowMenu::MatchRequest

  def test_each_match_line_meets_the_match_as_its_flags_would
    {
      MatchRequest.new(does: :host, text: nil, players: 3) =>
        MatchPlay::Meeting.new(host: VBlank::Network::DirectPlay::DEFAULT_PORT.to_s, join: nil, relay: nil, players: 3),
      MatchRequest.new(does: :host_code, text: nil, players: 2) =>
        MatchPlay::Meeting.new(host: true, join: nil, relay: true, players: 2),
      MatchRequest.new(does: :join_address, text: "192.168.1.5:7777", players: nil) =>
        MatchPlay::Meeting.new(host: nil, join: "192.168.1.5:7777", relay: nil, players: nil),
      MatchRequest.new(does: :join_code, text: "AB12", players: nil) =>
        MatchPlay::Meeting.new(host: nil, join: "AB12", relay: true, players: nil)
    }.each { |request, meeting| assert_equal meeting, MatchPlay.meeting_for(request), request.does }
  end

  private def facts = MatchPlay::MatchFacts.new(title: "WORDS", console: "gba", digest: "0" * 64, several_players: true, max_players: 4)

  # A player who chose a match in the menu gave no flag, so nothing said to them names one.
  def test_a_room_code_chosen_in_the_menu_with_no_relay_set_says_so_in_menu_words
    [true, false].each do |host|
      play = MatchPlay.new(facts, game_file: "words.rb", host: (true if host), join: ("AB12" unless host), relay: true,
                                  players: (2 if host), from_menu: true, environment: {}, say: ->(_line) {})
      error = assert_raises(VBlank::Network::ConnectionFailed) { play.open }

      assert_match(/No relay is set/, error.message)
      refute_match(/--/, error.message)
    end
  end

  def test_an_address_where_nobody_hosts_chosen_in_the_menu_says_so_in_menu_words
    play = MatchPlay.new(facts, game_file: "words.rb", join: "127.0.0.1:1", from_menu: true, say: ->(_line) {})
    error = assert_raises(VBlank::Network::ConnectionFailed) { play.open }

    assert_match(/Nobody is hosting a match at 127\.0\.0\.1:1/, error.message)
    refute_match(/--/, error.message)
  end

  def test_a_host_chosen_in_the_menu_waits_saying_escape_and_one_with_flags_ctrl_c
    assert_match(/Press Escape/, MatchPlay.new(facts, game_file: "w.rb", host: "0", from_menu: true).waiting_line)
    assert_match(/Press Ctrl-C/, MatchPlay.new(facts, game_file: "w.rb", host: "0").waiting_line)
  end

  # The menu checks an address where the network is not loaded (WindowMenu.address_problem), and the
  # network reads it (DirectPlay::Address.parse): the two take and refuse the same addresses, so one the
  # menu lets through never ends the game.
  def test_the_menu_and_the_network_take_the_same_addresses
    %w[host host:1 1.2.3.4:65535 a-b.c:7777 host: :7777 1.2.3.4:99999 1.2.3.4:0 h:x h:1:2].each do |text|
      parsed = begin
        VBlank::Network::DirectPlay::Address.parse(text)
      rescue ArgumentError
        nil
      end
      assert_equal parsed.nil?, !VBlank::Live::WindowMenu.address_problem(text).nil?, text
    end
  end
end
