# frozen_string_literal: true

require "json"

module VBlank
  module Network
    # THE MESSAGES AS TEXT, the one format a direct connection and the relay both speak. A message is
    # one JSON object, sent as one WebSocket text message or as one line on a socket. Every message
    # carries +"v"+, the version of this format (WIRE_VERSION), and +"type"+, then its own fields:
    #
    #   {"v":1,"type":"buttons","pass":12,"mask":16}
    #
    # The room (the relay, or the host of a direct connection) adds +"from"+ to what it hands on, the
    # sender's number in the room, so a machine cannot say it is somebody else. The messages are in
    # messages.rb, each knowing its own name and fields; this only turns one into text and back.
    # docs/network/protocol.md says all of it in words, and docs/network/exchanges.json is the same
    # thing as examples that every implementation's tests read.
    #
    # A MESSAGE FROM ANOTHER VERSION IS SAID SO. A relay or a game that reads a version it does not
    # know refuses it with the versions it does know, in plain words (VersionMismatch), and does not guess.
    module Wire
      # The version of the format this code speaks. A change that an older reader would misunderstand
      # (a field renamed, a message's meaning changed) raises it; a new message or a new optional field
      # does not, and a reader ignores the fields it does not know.
      WIRE_VERSION = 1

      # Every message of the format, by the name it has on the wire.
      MESSAGES = [Join, Welcome, Refuse, Joined, Start, Buttons, Checkpoint, Chat, Left,
                  RelayMakeRoom, RelayRoomMade, RelayJoinRoom, RelayRoomJoined, RelayListRooms, RelayRooms,
                  RelayError].to_h do |message|
        [message.wire_type, message]
      end.freeze

      module_function

      # The text for +message+, with +from+ added when the room hands it on.
      def encode(message, from: nil)
        stamped = from ? { "from" => from } : {}
        JSON.generate({ "v" => WIRE_VERSION, "type" => message.class.wire_type }.merge(message.wire_fields, stamped))
      end

      # What +text+ says: an Envelope for a message of a match (its +from+ is nil until the room has
      # stamped it), or a Relay message for one between a machine and the relay. Raises BadMessage for
      # text that is not a message, and VersionMismatch for one of another version.
      def decode(text)
        object = parse(text)
        refuse_other_version!(object)
        type = MESSAGES.fetch(object["type"]) { raise BadMessage, "This message has a type the format does not have: #{object['type'].inspect}." }
        message = type.from_wire(object)
        type.relay_message? ? message : Envelope.new(from: object["from"], message: message)
      rescue KeyError => e
        raise BadMessage, "A #{object['type']} message needs the field #{e.key}."
      end

      def parse(text)
        object = JSON.parse(text)
        return object if object.is_a?(Hash)

        raise BadMessage, "A message must be a JSON object, and this is #{text[0, 40].inspect}."
      rescue JSON::ParserError
        raise BadMessage, "A message must be JSON, and this is #{text[0, 40].inspect}."
      end

      def refuse_other_version!(object)
        raise BadMessage, "This message has no version (\"v\"), so it is not a message of the format." unless object.key?("v")
        raise VersionMismatch.in_message(object["v"], [WIRE_VERSION]) unless object["v"] == WIRE_VERSION
      end
    end

    # Text that is not a message of the format.
    class BadMessage < StandardError; end

    # A MESSAGE FROM A VERSION OF THE FORMAT THIS PROGRAM DOES NOT SPEAK, or a relay that does not speak
    # this program's. The words say which versions each side knows, so a person can tell whether the game
    # or the relay is the one to update. +seen+ is the version of the message, and +supported+ the
    # versions the reader knows.
    class VersionMismatch < StandardError
      attr_reader :seen, :supported

      # A message that was read and has a version the reader does not know.
      def self.in_message(seen, supported)
        known = supported.join(", ")
        words = if seen.is_a?(Integer) && seen > supported.max
                  "This message is from a newer version of the network format (#{seen}), and this program knows version " \
                    "#{known}. To fix this, update this program."
                else
                  "This message is from an older version of the network format (#{seen.inspect}), and this program knows " \
                    "version #{known}. To fix this, update the program that sent it."
                end
        new(words, seen, supported)
      end

      # A relay that answered with an error: it does not know the version this program speaks.
      def self.by_relay(supported)
        known = supported.join(", ")
        words = if supported.max < Wire::WIRE_VERSION
                  "The relay knows version #{known} of the network format, and this game speaks version #{Wire::WIRE_VERSION}. " \
                    "To fix this, use a newer relay."
                else
                  "The relay speaks version #{known} of the network format, and this game speaks the older version " \
                    "#{Wire::WIRE_VERSION}. To fix this, update this game."
                end
        new(words, Wire::WIRE_VERSION, supported)
      end

      def initialize(words, seen, supported)
        @seen = seen
        @supported = supported
        super(words)
      end
    end
  end
end
