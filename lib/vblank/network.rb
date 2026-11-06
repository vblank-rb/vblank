# frozen_string_literal: true

# MORE THAN ONE MACHINE PLAYING ONE MATCH. Every machine runs the whole game; only each player's
# buttons for each pass travel between them (see Network::Lockstep for why that is enough). This
# module is what two machines say to each other and how they keep in step: the messages, the
# fingerprint that tells one build of a game from another, the session each machine runs, and a
# network that lives in one process for a test to control.
#
# It is not part of the window's code (vblank/live) and does not need SDL. A Live::Session is given
# a lockstep session and asks it for the buttons of each pass, which is the only place the two meet.
require_relative "network/fingerprint"            # Which game on which console, as a number two machines can compare
require_relative "network/messages"               # What machines send each other
require_relative "network/wire"                   # Those messages as text, for a relay and a direct connection alike
require_relative "network/refused"                # The plain words told to a machine that cannot join
require_relative "network/desync"                 # What is reported when two machines stop agreeing
require_relative "network/lockstep"               # One machine's side of a match: handshake, buttons, checkpoints
require_relative "network/scheduler"              # Several copies of a game played in one process, a round at a time
require_relative "network/simulated_network"      # A network in this process, for a test to delay, hold back and cut
require_relative "network/relay_transport"        # A room on a relay, as a lockstep's transport
require_relative "network/stand_in_relay"         # A relay in Ruby, for the tests
require_relative "network/in_process_line"        # A link to the stand-in relay inside this process
require_relative "network/socket_end"             # Closing a socket without losing what was sent last
require_relative "network/line_channel"           # Text a line at a time over a socket
require_relative "network/direct_room"            # The host of a direct connection, a relay for the machines that connect
require_relative "network/direct_play"            # What `vblank run --host` and `--join` do
require_relative "network/web_socket"             # A WebSocket client in pure Ruby, for reaching a relay
require_relative "network/stand_in_relay_server"  # The stand-in relay with a WebSocket face, for the tests
require_relative "network/relay_play"             # What `vblank run --relay` does
