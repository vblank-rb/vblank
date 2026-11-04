# frozen_string_literal: true

module VBlank
  module Network
    # ONE MACHINE'S SIDE OF A MATCH PLAYED IN LOCKSTEP.
    #
    # WHY LOCKSTEP. A game here is a plain machine: the same program, given the same buttons on the
    # same passes, reaches the same state, every time, on every machine and in every lowering (that is
    # what the test suite proves, pass by pass). So two machines need not send each other the game.
    # Each runs the whole game, and they send only what a person did: each player's buttons for each
    # pass, a few numbers. A machine runs a pass only once it holds every player's buttons for it,
    # and so no machine is ever ahead of the others by more than the network is slow.
    #
    # PASSES, NOT FRAMES. The match counts passes of the game: a machine that is slow to finish a
    # pass makes every machine wait, and changes nothing in the game. The window may show fewer
    # pictures on that machine, but the game itself never skips a pass. Pass 1 sets the game up and
    # reads no buttons; pass 2 is the first that does.
    #
    # THE INPUT DELAY. A person's buttons are read at the end of pass p, and cannot be used until
    # every other machine has them. So they are sent labelled for pass p + 1 + delay, and used then;
    # the passes in between use the buttons that were sent delay passes ago. With a delay of two
    # the network has two passes of game time to carry a message before any machine has to wait: a
    # bigger delay hides a slower network and makes the buttons feel later. The host sets one delay
    # for the match, the same on every machine, because machines that used different delays would use
    # different buttons on the same pass.
    #
    # A MATCH IS: a handshake (Join, Welcome, Start: see Messages), then, at the end of each pass,
    # one Buttons message from each machine, and every so many passes one Checkpoint (a CRC-32 of the
    # whole game state) that each machine compares with the others'. Machines that differ stop with a
    # Desync naming the pass.
    #
    # A PLAYER WHO LEAVES is a message the room sends after the last message that player sent. Every
    # machine therefore knows the same last pass of that player's buttons, and from the pass after it
    # that player holds nothing, on every machine at once. Nobody waits for a player who has gone.
    #
    # THE TRANSPORT is whatever carries messages. It answers send_message(message), receive_message
    # (an Envelope, or nil when there is none yet), wait_for_message (returns once there is one, or
    # once the link is closed), id (the machine's number in the room, which is its player number),
    # close and closed?. A simulated network, a socket and a WebSocket each answer the same.
    class Lockstep
      HOST_PLAYER = 1

      # The first pass that reads buttons. Pass 1 is the one the game sets itself up in.
      FIRST_READING_PASS = 2

      DEFAULT_INPUT_DELAY_PASSES = 2
      DEFAULT_PASSES_BETWEEN_CHECKPOINTS = 8

      # The longest a line of chat is, in characters. A longer one is cut: a line is for a screen, and a room is
      # not for a stranger to fill with a book.
      MOST_CHAT_CHARACTERS = 200

      # What the host decides for every machine: the seed of the game's random numbers, the input
      # delay and checkpoint spacing in passes, and how many players the match holds.
      Settings = Data.define(:seed, :input_delay, :checkpoint_every, :players)

      # Something that happened to the match, on a pass: +kind+ is :left, a player who was in the
      # match and has gone, or :refused, a machine the host did not let in. +pass+ is the first pass
      # the event is seen on, which is the same pass on every machine.
      Event = Data.define(:pass, :kind, :player) do
        # The event as a line for a person to read, on the screen.
        def words
          case kind
          when :left then "Player #{player} left the match."
          when :refused then "A machine tried to join, and the host did not let it in."
          end
        end
      end

      attr_reader :player, :settings, :events, :chat_lines

      # The machine that makes the match: it is player 1, and decides every setting.
      def self.host(transport:, fingerprint:, players:, seed:, input_delay: DEFAULT_INPUT_DELAY_PASSES,
                    checkpoint_every: DEFAULT_PASSES_BETWEEN_CHECKPOINTS)
        settings = Settings.new(seed: seed, input_delay: input_delay, checkpoint_every: checkpoint_every, players: players)
        new(transport, fingerprint, settings)
      end

      # A machine that joins somebody else's match, and is told its settings.
      def self.join(transport:, fingerprint:) = new(transport, fingerprint, nil)

      def initialize(transport, fingerprint, settings)
        @transport = transport
        @fingerprint = fingerprint
        @settings = settings
        @player = transport.id
        @roster = [@player] # the players in the match, in the order they joined
        @started = false
        @events = []
        @chat_lines = [] # what the others have said, as ChatLine, in the order it came
        @played = [] # the buttons of each pass played, one list of numbers a pass, for the tape
        @inputs = Hash.new { |hash, player| hash[player] = {} } # player => { pass => buttons }
        @last_pass_heard = {} # player => the latest pass whose buttons that player has sent
        @left_after = {} # player => the last pass that player's buttons were sent for
        @checkpoints = Hash.new { |hash, pass| hash[pass] = {} } # pass => { player => crc }
      end

      def seed = @settings.seed

      def input_delay = @settings.input_delay

      def host? = @player == HOST_PLAYER

      # The handshake. Returns when the match has started, with the settings every machine now shares;
      # raises Refused on a machine the host would not let in. Asking again does nothing, so a window can
      # wait for the players before it opens and the session can ask as it starts.
      def begin_match
        return self if @begun

        host? ? gather_players : ask_to_join
        prepare_passes
        @begun = true
        self
      end

      # THE BUTTONS FOR THE PASS THAT STARTS, given the end of pass +pass+, as one number a player
      # (IR::Buttons.masks). +local_mask+ is what this machine's player holds now; +game+ answers
      # state_crc, which is asked only when this pass is a checkpoint. Returns once every player who
      # is still in the match has sent their buttons for the pass; raises Desync when a checkpoint
      # shows two machines no longer agree.
      def exchange(pass:, local_mask:, game:)
        send_buttons(pass + 1 + input_delay, local_mask)
        exchange_checkpoint(pass, game) if (pass % @settings.checkpoint_every).zero?
        coming = pass + 1
        wait_for_buttons(coming)
        masks = masks_for(coming)
        record_departures_on(coming)
        @played << masks
        masks
      end

      # Says a line of chat to the others of the room, now or any time: before the match, while others join, or
      # during it. It goes in the network's own message, never into the game. Control characters become spaces and a
      # long line is cut, so what arrives is one line of plain text; an empty line says nothing.
      def send_chat(text)
        line = plain_line(text)
        @transport.send_message(Chat.new(text: line)) unless line.empty?
      end

      # Tells the room this machine is going. The others see it as a player leaving.
      def leave = @transport.close

      # The presses of the match so far, as a tape of passes (Playthroughs::Tape): the buttons each
      # pass the game played was given, every player's, from the first pass that reads any. It plays on
      # the interpreter like any tape.
      def tape
        taping = Playthroughs::Tape::Taping.new
        @played.each { |masks| taping.hold(button_names(masks), 1) }
        Playthroughs::Tape.new(title: @fingerprint.title, checksum: @fingerprint.checksum,
                               starts_from: Playthroughs::Tape::POWER_ON, steps: taping.steps, in_passes: true)
      end

      private

      # --- the handshake ---

      # The host waits in the room until it is full, letting in each machine that is running the same
      # game, then tells everyone the match begins.
      def gather_players
        until @roster.size >= @settings.players
          receive_pending_messages
          break if @roster.size >= @settings.players

          @transport.wait_for_message
        end
        @started = true
        @transport.send_message(Start.new(players: @roster.sort))
      end

      def ask_to_join
        @transport.send_message(Join.new(fingerprint: @fingerprint))
        loop do
          receive_pending_messages
          raise_if_refused
          break if @started

          @transport.wait_for_message
          raise ConnectionLost if @transport.closed? && !@started
        end
      end

      def raise_if_refused
        return unless @refusal

        raise Refused.because(@refusal.reason, mine: @fingerprint, theirs: @refusal.fingerprint)
      end

      def admit_or_refuse(joining, join)
        reason = refusal_for(join.fingerprint)
        if reason
          @events << Event.new(pass: 0, kind: :refused, player: joining)
          @transport.send_message(Refuse.new(to: joining, reason: reason, fingerprint: @fingerprint))
        else
          @roster << joining
          @transport.send_message(Welcome.new(to: joining, seed: seed, input_delay: input_delay,
                                              checkpoint_every: @settings.checkpoint_every,
                                              players: @settings.players))
          @transport.send_message(Joined.new(player: joining))
        end
      end

      def refusal_for(theirs)
        return :started if @started
        return :different_console if theirs.console != @fingerprint.console
        return :different_game unless @fingerprint.same_as?(theirs)

        :full if @roster.size >= @settings.players
      end

      # --- taking messages in ---

      # Every message that has come, applied. Never waits.
      def receive_pending_messages
        while (envelope = @transport.receive_message)
          apply_message(envelope)
        end
      end

      def apply_message(envelope)
        message = envelope.message
        case message
        when Join then admit_or_refuse(envelope.from, message) if host?
        when Welcome then adopt_settings(message) if message.to == @player
        when Refuse then @refusal = message if message.to == @player
        when Joined then @roster |= [message.player]
        when Start then start_with(message.players)
        when Buttons then store_buttons(envelope.from, message)
        when Checkpoint then store_checkpoint(envelope.from, message)
        when Chat then @chat_lines << ChatLine.new(player: envelope.from, text: plain_line(message.text))
        when Left then record_departure(envelope.from)
        end
      end

      def adopt_settings(welcome)
        @settings = Settings.new(seed: welcome.seed, input_delay: welcome.input_delay,
                                 checkpoint_every: welcome.checkpoint_every, players: welcome.players)
      end

      # The match begins for the players in +players+. A machine that is in the room and not among them
      # (it asked to join too late, and the host has not yet told it so) does not begin: the host's
      # refusal is on its way, and is what ends its wait.
      def start_with(players)
        return unless players.include?(@player)

        @roster = players.dup
        @started = true
      end

      def store_buttons(from, message)
        @inputs[from][message.pass] = message.mask
        @last_pass_heard[from] = [@last_pass_heard.fetch(from, 0), message.pass].max
      end

      # A player has gone. Before the match starts that is a machine that gave up waiting; during it,
      # the player leaves after the last pass they sent buttons for.
      def record_departure(gone)
        return unless @roster.include?(gone)
        return @roster.delete(gone) unless @started

        @left_after[gone] ||= @last_pass_heard.fetch(gone, FIRST_READING_PASS + input_delay - 1)
      end

      # --- the passes ---

      # The buttons of the passes nobody has had time to send yet are nothing, for every player, so
      # that every machine starts the same way.
      def prepare_passes
        @roster.each do |each_player|
          (FIRST_READING_PASS..(FIRST_READING_PASS + input_delay - 1)).each { |pass| @inputs[each_player][pass] = 0 }
        end
      end

      def send_buttons(pass, mask)
        @inputs[@player][pass] = mask
        @transport.send_message(Buttons.new(pass: pass, mask: mask))
      end

      def wait_for_buttons(pass)
        loop do
          receive_pending_messages
          return if heard_everyone_for?(pass)

          if @transport.closed?
            @roster.each { |each_player| record_departure(each_player) unless each_player == @player }
          else
            @transport.wait_for_message
          end
        end
      end

      # Whether every player still in the match has sent their buttons for +pass+.
      def heard_everyone_for?(pass)
        @roster.all? { |each_player| @inputs[each_player].key?(pass) || gone_by?(each_player, pass) }
      end

      def gone_by?(each_player, pass)
        last = @left_after[each_player]
        !last.nil? && pass > last
      end

      def masks_for(pass)
        masks = Array.new(@roster.max) { |index| @inputs[index + 1][pass] || 0 }
        @inputs.each_value { |by_pass| by_pass.delete(pass - 1) }
        masks
      end

      # A player whose last pass was the one before this is seen leaving on this one, on every machine.
      def record_departures_on(pass)
        @left_after.each do |gone, last|
          @events << Event.new(pass: pass, kind: :left, player: gone) if last + 1 == pass
        end
      end

      # --- checkpoints ---

      def exchange_checkpoint(pass, game)
        crc = game.state_crc
        @checkpoints[pass][@player] = crc
        @transport.send_message(Checkpoint.new(pass: pass, crc: crc))
        compare_checkpoint(pass)
      end

      def store_checkpoint(from, message)
        @checkpoints[message.pass][from] = message.crc
        compare_checkpoint(message.pass)
      end

      # Raises when the states held for +pass+ are not all the same. A machine compares only once it
      # has its own, so every machine that has both of two numbers finds the same difference.
      def compare_checkpoint(pass)
        return unless @checkpoints[pass].key?(@player)
        return if @checkpoints[pass].values.uniq.one?

        raise Desync, DesyncReport.new(pass: pass, last_agreed_pass: last_agreed_before(pass),
                                       crcs: @checkpoints[pass].dup, tape: tape)
      end

      def last_agreed_before(pass)
        agreed = @checkpoints.select { |earlier, crcs| earlier < pass && crcs.size > 1 && crcs.values.uniq.one? }
        agreed.keys.max || 0
      end

      # +text+ as one line of plain text: control characters (a new line, an escape) are spaces, and it is at most
      # MOST_CHAT_CHARACTERS long. What arrives is cleaned too, since a machine cannot be trusted to have done it.
      def plain_line(text) = text.to_s.gsub(/[[:cntrl:]]/, " ").strip[0, MOST_CHAT_CHARACTERS]

      # --- the tape ---

      # The buttons of one pass as the names a tape holds, every player's.
      def button_names(masks)
        masks.each_with_index.flat_map do |mask, index|
          IR::Buttons::PLAYERS_NAMES[index].each_with_index.filter_map { |name, bit| name if mask[bit] == 1 }
        end
      end
    end

    # The link to the room closed while a machine waited to be let into a match.
    class ConnectionLost < StandardError
      def initialize = super("The connection closed before the match began. To fix this, check the address and join again.")
    end
  end
end
