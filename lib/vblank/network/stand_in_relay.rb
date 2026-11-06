# frozen_string_literal: true

require "json"

module VBlank
  module Network
    # A RELAY IN RUBY, standing in for the real one in the tests. The real relay is another program
    # that VBlank knows only by its address and what it says on the wire: nothing here assumes how or
    # where it runs. This one does what docs/network/protocol.md says and nothing else: it makes a room
    # with a code, puts machines in rooms, and hands each message of a machine to the other machines of
    # its room, with the sender's number added. It never runs the game and never reads the buttons: it
    # reads only the JSON object's +type+, to tell its own messages from a match's, and +v+, for the version.
    #
    # It works on text and nothing else: a machine gives it a message as text and takes the messages
    # for it as text. That is why it answers to a socket or a WebSocket as readily as to a test, and why
    # the examples in docs/network/exchanges.json can drive it.
    #
    #   relay = StandInRelay.new
    #   host = relay.connect
    #   host.send_text('{"v":1,"type":"make_room"}')
    #   host.receive_text   # => '{"v":1,"type":"room_made","code":"AAAA","you":1}'
    class StandInRelay
      # A room holds as many machines as a match holds players.
      MOST_MEMBERS = IR::Buttons::MOST_PLAYERS

      # What a room code is made of: letters and digits that are not mistaken for each other.
      CODE_LETTERS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
      CODE_LENGTH = 4

      # The messages only the relay sends, which a machine may not send to it. +left+ is the room's word for a
      # machine that has gone, so a machine that sent it could say another had gone.
      RELAY_ONLY_TYPES = %w[room_made room_joined rooms error left].freeze

      # The versions of the format it knows.
      SUPPORTED_VERSIONS = [Wire::WIRE_VERSION].freeze

      # A room: its +code+ and the machines in it by their numbers (a number is never used twice), and, for a room
      # that asked to be listed, what to list: the game's +digest+, a +name+ and how many +seats+.
      Room = Struct.new(:code, :members, :last_number, :digest, :name, :seats)

      # The longest a room's name is listed as.
      MOST_NAME_CHARACTERS = 40

      # One machine's link to the relay: text goes in with #send_text, and the relay's text for the
      # machine comes out of #receive_text, in order.
      class Connection
        attr_reader :room, :number

        def initialize(relay)
          @relay = relay
          @outbox = []
          @closed = false
        end

        def send_text(text) = (@relay.receive(self, text) unless @closed)

        # The next text the relay has for this machine, or nil.
        def receive_text = @outbox.shift

        def pending? = !@outbox.empty?
        def closed? = @closed

        # The machine goes away. The others in its room are told.
        def close
          return if @closed

          @closed = true
          @relay.drop(self)
        end

        # For the relay: text for this machine, and where it stands in a room.
        def deliver(text) = (@outbox << text unless @closed)

        def enter(room, number)
          @room = room
          @number = number
        end
      end

      # +codes+ gives the room codes, one for each room made; it is a counter unless given, so a test
      # gets the same codes every run.
      def initialize(codes: nil)
        @codes = codes || counting_codes
        @rooms = {}
        @connections = []
      end

      def connect
        Connection.new(self).tap { |connection| @connections << connection }
      end

      # Whether any machine has text waiting for it, which a scheduler asks to know the match is moving.
      def pending? = @connections.any?(&:pending?)

      # What a machine's text asks for. Called by Connection.
      def receive(connection, text)
        message = parse(text) or return reply_error(connection, :bad_message, "That text is not a message. Messages are JSON objects.")
        return reply_unknown_version(connection, message["v"]) unless SUPPORTED_VERSIONS.include?(message["v"])

        case message["type"]
        when "make_room" then make_room(connection, message)
        when "list_rooms" then list_rooms(connection, message["digest"])
        when "join_room" then join_room(connection, message["code"])
        when *RELAY_ONLY_TYPES, nil then reply_error(connection, :bad_message, "A machine cannot send that kind of message.")
        else hand_on(connection, message)
        end
      end

      # A machine has gone: the others in its room are told, after everything it sent.
      def drop(connection)
        @connections.delete(connection)
        room = connection.room or return
        room.members.delete(connection.number)
        @rooms.delete(room.code) if room.members.empty?
        say_to(room, except: nil, text: Wire.encode(Left.new, from: connection.number))
      end

      private

      def parse(text)
        object = JSON.parse(text)
        object if object.is_a?(Hash) && object.key?("v")
      rescue JSON::ParserError
        nil
      end

      def make_room(connection, message)
        return reply_error(connection, :already_in_a_room, "You are in a room already. A machine is in one room at a time.") if connection.room

        code = next_code or return reply_error(connection, :no_more_rooms, "This relay makes no more rooms. To fix this, join a room with its code.")
        room = Room.new(code, {}, 0)
        list_as_public(room, message) if message["public"] == true
        @rooms[room.code] = room
        number = admit(room, connection)
        connection.deliver(Wire.encode(RelayRoomMade.new(code: room.code, you: number)))
      end

      def join_room(connection, code)
        return reply_error(connection, :already_in_a_room, "You are in a room already. A machine is in one room at a time.") if connection.room

        room = @rooms[code.to_s.upcase]
        return reply_error(connection, :no_such_room, "There is no room with the code #{code}. Check the code and try again.") unless room
        return reply_error(connection, :room_full, "That room is full. It holds #{MOST_MEMBERS} machines.") if room.members.size >= MOST_MEMBERS

        others = room.members.keys
        number = admit(room, connection)
        connection.deliver(Wire.encode(RelayRoomJoined.new(code: room.code, you: number, members: others)))
      end

      # The room is to be listed: it keeps the game, a name that tells nobody who made it, and its seats.
      def list_as_public(room, message)
        room.digest = message["digest"].to_s
        room.name = message["name"].to_s.strip[0, MOST_NAME_CHARACTERS]
        room.name = "Room #{room.code}" if room.name.empty?
        room.seats = message["seats"].is_a?(Integer) ? message["seats"].clamp(1, MOST_MEMBERS) : MOST_MEMBERS
      end

      # The public rooms for the game with +digest+ that still have a place, in the order they were made. A room
      # that has filled, or emptied (it is gone then), is not listed.
      def list_rooms(connection, digest)
        open = @rooms.values.select { |room| room.digest && room.digest == digest.to_s && room.members.size < room.seats }
        rooms = open.map { |room| PublicRoom.new(code: room.code, name: room.name, members: room.members.size, seats: room.seats) }
        connection.deliver(Wire.encode(RelayRooms.new(rooms: rooms)))
      end

      def admit(room, connection)
        number = (room.last_number += 1)
        room.members[number] = connection
        connection.enter(room, number)
        number
      end

      # A message of the match goes to every other machine of the room, with who sent it.
      def hand_on(connection, message)
        room = connection.room or return reply_error(connection, :not_in_a_room, "Make a room or join one before you send this.")

        say_to(room, except: connection.number, text: JSON.generate(message.merge("from" => connection.number)))
      end

      # +text+ to every machine of +room+ but the one numbered +except+.
      def say_to(room, except:, text:)
        room.members.each { |number, member| member.deliver(text) unless number == except }
      end

      def reply_error(connection, reason, words)
        connection.deliver(Wire.encode(RelayError.new(reason: reason, words: words, supported: nil)))
      end

      def reply_unknown_version(connection, version)
        words = "This relay speaks version #{SUPPORTED_VERSIONS.join(', ')} of the network format, and the message is version #{version}. " \
                "To fix this, use a game and a relay of the same version."
        connection.deliver(Wire.encode(RelayError.new(reason: :version, words: words, supported: SUPPORTED_VERSIONS)))
      end

      # The code for the next room, or nil when the codes given have run out. A direct host is given one code, its
      # own room's, so a machine that joined it and asks for a room of its own is told no rather than ending the room.
      def next_code
        @codes.next
      rescue StopIteration
        nil
      end

      def counting_codes
        Enumerator.new do |codes|
          count = 0
          loop do
            letters = Array.new(CODE_LENGTH) { |place| CODE_LETTERS[(count / (CODE_LETTERS.size**place)) % CODE_LETTERS.size] }
            codes << letters.reverse.join
            count += 1
          end
        end
      end
    end
  end
end
