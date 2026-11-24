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
end
