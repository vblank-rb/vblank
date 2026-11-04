#!/usr/bin/env ruby
# frozen_string_literal: true

# THE STAND-IN RELAY AS A PROGRAM, for something outside Ruby to play against: a node copy of a game, a
# desktop build, a person trying two windows. It listens on a WebSocket port, makes rooms with codes, and
# hands each message to the others of its room, as the real relay does (docs/network/protocol.md). It never
# runs the game.
#
#   ruby tools/stand_in_relay.rb [PORT]
#
# It says the address a client connects to on its first line, `listening on ws://127.0.0.1:PORT/`, and
# serves until it is stopped. PORT is 0 (the system chooses) unless given.

require_relative "../lib/vblank"

server = VBlank::Network::StandInRelayServer.new(port: Integer(ARGV.fetch(0, "0"), 10))
puts "listening on #{server.url}"
$stdout.flush
server.start
trap("TERM") { server.stop; exit }
trap("INT") { server.stop; exit }
sleep
