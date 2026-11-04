# frozen_string_literal: true

module VBlank
  module Network
    # A NETWORK IN ONE PROCESS, for a test to play with. Machines join one room, as they would on a
    # relay; what one sends, every other receives, in the order it was sent. Nothing here keeps time
    # or draws a random number, so a test replays exactly. A test can:
    #
    #   net.delay(from: 1, to: 2, rounds: 3)   messages from machine 1 reach machine 2 three rounds late
    #   net.hold(from: 1, to: 2)               ...none reach it until net.release(from: 1, to: 2)
    #   net.disconnect(2)                      machine 2 drops: the others see it leave, after every
    #                                          message it had already sent
    #   net.at_round(10) { net.release(...) }  do any of these on a round of the test's choosing
    #
    # TIME IS ROUNDS. #play runs each copy of the game in a Fiber and takes them round by round, in the
    # order they were given (see Scheduler). A copy runs until it must wait for a message (see
    # Endpoint#wait_for_message), and the next copy then runs. A delay of three rounds means three trips
    # round all the copies, which is how a delay is felt by a game that waits on it. That keeps the whole
    # run in order, whatever the machine running the test does.
    #
    # THE ROOM NEVER READS A MESSAGE. It stamps who sent it and hands it on, as a relay does, and it
    # tells every machine when another has dropped.
    class SimulatedNetwork
      # A message on its way: +due+ is the round it can first be received on, +sequence+ puts all the
      # messages of the network in the order they were sent.
      Pending = Data.define(:sequence, :from, :to, :due, :message)

      attr_reader :round

      def initialize
        @round = 0
        @sequence = 0
        @endpoints = {}
        @links = Hash.new { |hash, link| hash[link] = [] } # [from, to] => messages in order
        @delays = Hash.new(0) # [from, to] => rounds
        @held = Set.new
        @scheduled = [] # [round, action]
        @scheduler = Scheduler.new(movement: -> { movement_possible? }, stalled_words: -> { held_words },
                                   before_round: lambda { |round|
                                     @round = round
                                     run_scheduled
                                   })
      end

      # A machine's end of its link to the room. Its number is the next one, from 1, and is the
      # machine's player number.
      def connect
        id = (@endpoints.keys.max || 0) + 1
        @endpoints[id] = Endpoint.new(self, id)
      end

      # Messages from +from+ to +to+ take +rounds+ more rounds to arrive than the one before could.
      def delay(from:, to:, rounds:) = @delays[[from, to]] = rounds

      # Nothing from +from+ reaches +to+ until it is released; what comes after waits behind it.
      def hold(from:, to:) = @held << [from, to]
      def release(from:, to:) = @held.delete([from, to])

      # Machine +id+ drops off the network. Every message it sent before is still handed on, and then
      # every other machine is told it has left. It sends and receives nothing more.
      def disconnect(id)
        endpoint = @endpoints.fetch(id)
        return if endpoint.closed?

        endpoint.mark_closed
        @links.delete_if { |(_from, to), _pending| to == id }
        others(id).each { |other| queue(id, other.id, Left.new) }
      end

      # Runs +action+ at the start of round +number+.
      def at_round(number, &action) = @scheduled << [number, action]

      # Plays +copies+, each something callable, round by round until every one has finished or failed.
      # Gives back a Scheduler::Outcome for each, in order. A copy's error ends only that copy.
      def play(copies) = @scheduler.play(copies)

      # --- for an Endpoint ---

      def send_from(from, message)
        others(from).each { |other| queue(from, other.id, message) }
      end

      def next_envelope_for(to)
        chosen = ready_messages_for(to).min_by(&:sequence) or return nil
        @links[[chosen.from, to]].shift
        Envelope.new(from: chosen.from, message: chosen.message)
      end

      def inside_play? = @scheduler.inside?

      # Gives the other copies their turn: called by a copy that waits for a message.
      def wait_for_turn = @scheduler.wait

      def message_ready_for?(to) = ready_messages_for(to).any?

      private

      # The first message of each link into +to+ that can be received this round.
      def ready_messages_for(to)
        @links.filter_map do |(from, target), pending|
          head = pending.first
          head if target == to && head && head.due <= @round && !@held.include?([from, target])
        end
      end

      def others(id) = @endpoints.values.reject { |endpoint| endpoint.id == id || endpoint.closed? }

      # A message on a link is never due before the one before it, so a link keeps its order even
      # when a test changes its delay part way.
      def queue(from, to, message)
        link = @links[[from, to]]
        due = [@round + @delays[[from, to]], link.last&.due || 0].max
        @sequence += 1
        link << Pending.new(sequence: @sequence, from: from, to: to, due: due, message: message)
      end

      def run_scheduled
        due, @scheduled = @scheduled.partition { |round, _action| round <= @round }
        due.each { |_round, action| action.call }
      end

      # Whether the next round can differ from this one: a message that can be received, now or on
      # a later round, or something the test scheduled.
      def movement_possible?
        return true unless @scheduled.empty?

        @links.any? { |link, pending| pending.any? && !@held.include?(link) }
      end

      def held_words
        held = @held.map { |from, to| "#{from} to #{to}" }
        "Held back: #{held.join(', ')}." unless held.empty?
      end

      # THE END OF ONE MACHINE'S LINK TO THE ROOM, which is what a Lockstep gives its messages to.
      class Endpoint
        attr_reader :id

        def initialize(network, id)
          @network = network
          @id = id
          @closed = false
        end

        def send_message(message)
          @network.send_from(@id, message) unless @closed
        end

        # The next message that has arrived, as an Envelope, or nil.
        def receive_message = @closed ? nil : @network.next_envelope_for(@id)

        # Gives the other copies their turn until a message has arrived. Played outside
        # SimulatedNetwork#play there are no other copies to give a turn to, so a wait that nothing
        # will end is an error.
        def wait_for_message
          until @closed || @network.message_ready_for?(@id)
            unless @network.inside_play?
              raise Scheduler::Stalled, "This machine waits for a message and no other copy is playing to send one. " \
                             "To fix this, play every copy with SimulatedNetwork#play."
            end
            @network.wait_for_turn
          end
        end

        def close = @network.disconnect(@id)
        def closed? = @closed
        def mark_closed = @closed = true
      end
    end
  end
end
