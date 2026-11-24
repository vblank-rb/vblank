# frozen_string_literal: true

require "tmpdir"

module VBlank
  module Live
    # WHAT `vblank run --host` and `--join` do before and after a match is played: refuse a game for one
    # player, check --players, host the match or join one (over a direct connection or a relay), say
    # in plain words where the others can join, and turn what stopped a match into words. The match
    # itself is a Network::Lockstep, which a Session plays.
    #
    # It needs only the game's MatchFacts, not its program, so the window's own process (which holds
    # no build: WindowProcess) runs it from what the helper that built the game wrote out
    # (IR::Backends::Ruby::WrittenGame#match), and the command runs it the same way from a program it
    # built itself. It loads with the network module and Playthroughs::Tape, never the whole library.
    class MatchPlay
      # What a match needs to know of the game: its Network::Fingerprint's parts, whether it is
      # built for several players (IR::Program#several_players?), and the most it seats (nil for
      # no limit named).
      MatchFacts = Data.define(:title, :console, :digest, :several_players, :max_players) do
        def fingerprint = Network::Fingerprint.new(title: title, console: console, digest: digest)
      end

      # The MatchFacts of +program+, a program checked and built for a computer, titled +title+, as a
      # written game holds them (IR::Backends::Ruby#match_facts).
      def self.facts_of(program, title:) = facts_from_plain(IR::Backends::Ruby.new.match_facts(program, title: title))

      # MatchFacts from their plain values (WrittenGame#match).
      def self.facts_from_plain(plain) = MatchFacts.new(**plain.transform_keys(&:to_sym))

      # How a match is met, as #initialize takes it: the port to host on or true, the address or room
      # code to join, whether it is on the relay, and how many players a host waits for.
      Meeting = Data.define(:host, :join, :relay, :players)

      # The Meeting a match chosen in the window's menu asks for (a WindowMenu::MatchRequest): a host by
      # address listens on Network::DirectPlay::DEFAULT_PORT, a host with a room code makes a room on
      # the usual relay, and a join goes to the address or room code typed.
      def self.meeting_for(request)
        players = request.players
        case request.does
        when :host then Meeting.new(host: Network::DirectPlay::DEFAULT_PORT.to_s, join: nil, relay: nil, players: players)
        when :host_code then Meeting.new(host: true, join: nil, relay: true, players: players)
        when :join_address then Meeting.new(host: nil, join: request.text, relay: nil, players: nil)
        when :join_code then Meeting.new(host: nil, join: request.text, relay: true, players: nil)
        end
      end

      # What stops a match, each already in plain words.
      FAILURES = [Network::Refused, Network::Desync, Network::ConnectionLost, Network::MatchCutOff, Network::ConnectionFailed,
                  Network::VersionMismatch, Network::RoomRefused, Network::BadMessage].freeze

      # A match the game cannot play, said in plain words.
      class Refused < StandardError; end

      # +facts+ are the game's MatchFacts; +game_file+ is named in the line the others join with.
      # +host+ is the port to host on (or true, with +relay+), +join+ the address or room to join,
      # +relay+ the relay's URL (or true for the usual one), +players+ how many a host waits for and
      # +input_delay+ its passes of delay. +say+ is handed each line for the person.
      def initialize(facts, game_file:, host: nil, join: nil, relay: nil, players: nil, input_delay: nil, say: ->(line) { puts line })
        @facts = facts
        @game_file = game_file
        @host = host
        @join = join
        @relay = relay
        @players = players
        @input_delay = input_delay || Network::Lockstep::DEFAULT_INPUT_DELAY_PASSES
        @say = say
      end

      # The match hosted or joined, its lockstep not yet begun (Lockstep#begin_match). Refused for a
      # game for one player or too many players; a Network failure (FAILURES) as it comes.
      def open
        refuse_one_player_game!
        fingerprint = @facts.fingerprint
        if @relay then meet_on_relay(fingerprint)
        elsif @host then host_directly(fingerprint)
        else join_directly(fingerprint)
        end
      end

      # The line said while the others are waited for, for the one who hosts.
      def waiting_line = ("Waiting for the other players. Press Ctrl-C to give up." if @host)

      # The words for +error+, one of FAILURES. A machine whose game went another way than another
      # machine's first writes the tape of the match and the report into a new folder, which
      # nothing removes, and the words say where: the tape replays this machine's game on the
      # interpreter, pass for pass.
      def self.failure_message(error)
        return error.message unless error.is_a?(Network::Desync)

        error.report.written_message(error.report.write_in(Dir.mktmpdir("vblank-match-")))
      end

      # The lines that close a match that played to its end. +events_said+ is true where each event
      # was said as it came.
      def self.summary_lines(lockstep, events_said: false)
        [*(lockstep.events.map(&:words) unless events_said), "The match is over. The computers agreed on every checkpoint."]
      end

      private

      def refuse_one_player_game!
        return if @facts.several_players

        raise Refused, "#{@facts.title} is a game for one player, so it cannot play in a match. To fix this, say on " \
                       "VBlank.game how many players it takes, for example players: 1..2."
      end

      def players_in_match
        players = @players || 2
        most = @facts.max_players
        if most && players > most
          raise Refused, "--players #{players} is more than this game takes. The game takes at most #{most}. " \
                         "To fix this, give --players #{most} or fewer."
        end
        players
      end

      # A match through the relay: a host makes a room and says its code, a joiner joins one.
      def meet_on_relay(fingerprint)
        url = Network::RelayPlay.url_from(@relay)
        unless @host
          lockstep = Network::RelayPlay.join(url, @join, fingerprint: fingerprint)
          @say.call("Joined the room #{@join}.")
          return lockstep
        end

        lockstep, code = Network::RelayPlay.host(url, players: players_in_match, input_delay: @input_delay, fingerprint: fingerprint)
        @say.call("Made the room #{code} on the relay. The others can join with:")
        @say.call("  vblank run #{@game_file} --relay --join #{code}")
        lockstep
      end

      def host_directly(fingerprint)
        players = players_in_match
        lockstep, port = Network::DirectPlay.host(port: Integer(@host, 10), players: players, input_delay: @input_delay,
                                                  fingerprint: fingerprint)
        @say.call("Hosting a match for #{players} players on port #{port}. The others can join with one of:")
        Network::DirectPlay.addresses_for(port).each { |address| @say.call("  vblank run #{@game_file} --join #{address}") }
        lockstep
      end

      def join_directly(fingerprint)
        address = Network::DirectPlay::Address.parse(@join)
        @say.call("Joining the match at #{address}.")
        Network::DirectPlay.join(address, fingerprint: fingerprint)
      end
    end
  end
end
