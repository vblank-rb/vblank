# frozen_string_literal: true

# MORE THAN ONE MACHINE PLAYING ONE MATCH. Every machine runs the whole game; only each player's
# buttons for each pass travel between them (see Network::Lockstep for why that is enough). This
# module is what two machines say to each other and how they keep in step: the messages, the
# fingerprint that tells one build of a game from another, the session each machine runs, and a
# network that lives in one process for a test to control.
#
# It is not part of the window's code (vblank/live) and does not need SDL. A Live::Session is given
# a lockstep session and asks it for the buttons of each pass, which is the only place the two meet.
require_relative "network/fingerprint" # which game, on which console, as a number two machines can compare
require_relative "network/messages" # what machines send each other
require_relative "network/wire" # ...as text, the one format a relay and a direct connection both speak
require_relative "network/refused" # the plain words a machine that cannot join a match is told
require_relative "network/desync" # what is said when two machines stop agreeing
require_relative "network/lockstep" # one machine's side of a match: handshake, buttons, checkpoints
require_relative "network/scheduler" # several copies of a game played in one process, a round at a time
require_relative "network/simulated_network" # a network in this process, for a test to delay, hold back and cut
require_relative "network/relay_transport" # a room on a relay, as a lockstep's transport
require_relative "network/stand_in_relay" # a relay in Ruby, for the tests
require_relative "network/in_process_line" # ...and a link to it that lives in this process
require_relative "network/line_channel" # text a line at a time over a socket, which is how machines reach each other
require_relative "network/direct_room" # the host of a direct connection, which is a relay for the machines that connect
require_relative "network/direct_play" # ...and what `vblank run --host` and `--join` do with them
require_relative "network/web_socket" # a WebSocket client in pure Ruby, which is how a machine reaches a relay
require_relative "network/stand_in_relay_server" # ...and the stand-in relay with a WebSocket face, for the tests
require_relative "network/relay_play" # ...and what `vblank run --relay` does with them
