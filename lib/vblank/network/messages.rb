# frozen_string_literal: true

module VBlank
  module Network
    # WHAT MACHINES SAY TO EACH OTHER IN A MATCH, one small value for each thing. A machine sends a
    # message to the room it is in, and the room hands it to every other machine in it; what the
    # receiver is told is an Envelope: who sent it (the sender's number in the room, which is also the
    # sender's player number) and the message.
    #
    # THE ROOM IS EITHER A RELAY OR THE HOST. With a relay each machine is one connection to the relay,
    # which forwards. With a direct connection the host is the room: it takes each message from the
    # machine that sent it, and sends it on to the others. A machine cannot tell the two apart, so one
    # set of messages serves both.
    #
    # The room never plays the game and never reads the buttons in these messages.
    #
    # EACH MESSAGE KNOWS ITS NAME AND FIELDS ON THE WIRE (Wirable), so Wire needs no list of fields of
    # its own: a new message is a new class here and a line in Wire::MESSAGES.
    module Wirable
      def self.included(base) = base.extend(ClassMethods)

      # A fingerprint is written flat: its game's title, its console and its digest.
      def self.fingerprint_fields(fingerprint)
        { "game" => fingerprint.title, "console" => fingerprint.console, "digest" => fingerprint.digest }
      end

      def self.fingerprint_in(fields)
        Fingerprint.new(title: fields.fetch("game"), console: fields.fetch("console"), digest: fields.fetch("digest"))
      end

      # The fields a game, a console and a digest are written as, all text.
      FINGERPRINT_KINDS = { "game" => String, "console" => String, "digest" => String }.freeze

      # What a field's value must be, as #field_kinds names it, and how a person is told so.
      KIND_WORDS = { Integer => "a whole number", String => "text", integers: "a list of whole numbers",
                     objects: "a list of JSON objects" }.freeze

      # Whether +value+ is the kind of value +kind+ names.
      def self.kind_of_field?(value, kind)
        case kind
        when :integers then value.is_a?(Array) && value.all?(Integer)
        when :objects then value.is_a?(Array) && value.all?(Hash)
        else value.is_a?(kind)
        end
      end

      module ClassMethods
        # The name the message has on the wire: its +"type"+. Said once in the message's own class, with the
        # kind of value each field it needs must be (Integer, String, :integers for a list of whole numbers, or
        # :objects for a list of JSON objects), by wire name, which Wire checks when it reads one.
        def wire_type(name = nil, **kinds)
          return @wire_type unless name

          @field_kinds = kinds.transform_keys(&:to_s).freeze
          @wire_type = name
        end

        def field_kinds = @field_kinds || {}

        # Marks a message that is between a machine and the relay and is never handed on to the room.
        def relay_message! = @relay_message = true
        def relay_message? = @relay_message == true

        # The message the fields of a decoded object describe. A missing field is a KeyError.
        def from_wire(fields) = new(**members.to_h { |member| [member, fields.fetch(member.to_s)] })
      end

      # The message's own fields as they are written, by wire name.
      def wire_fields = to_h.transform_keys(&:to_s)
    end

    # A message and who sent it. +from+ is the sender's number in the room, stamped by the room and
    # not by the sender, so a machine cannot say it is somebody else.
    Envelope = Data.define(:from, :message)

    # --- before the match: finding out whether two machines can play together ---

    # "I want to play in this match." Sent by a machine that has joined the room to the host, with
    # what it is running: the game's title (for a person), its console, and its digest.
    Join = Data.define(:fingerprint) do
      include Wirable
      wire_type "join", **Wirable::FINGERPRINT_KINDS

      def self.from_wire(fields) = new(fingerprint: Wirable.fingerprint_in(fields))
      def wire_fields = Wirable.fingerprint_fields(fingerprint)
    end

    # The host's answer to a Join that is let in. +to+ is the number of the machine it is for. The
    # rest is what every machine must share, and only the host decides: the seed for the game's random
    # numbers, how many passes a person's buttons wait before they count (+input_delay+), how many
    # passes lie between two checkpoints, and how many players the match holds when it is full.
    Welcome = Data.define(:to, :seed, :input_delay, :checkpoint_every, :players) do
      include Wirable
      wire_type "welcome", to: Integer, seed: Integer, input_delay: Integer, checkpoint_every: Integer, players: Integer
    end

    # The host's answer to a Join that is not let in, with the reason as a symbol (see Refused) and
    # what the host is running, so the refusal can name it.
    Refuse = Data.define(:to, :reason, :fingerprint) do
      include Wirable
      wire_type "refuse", to: Integer, reason: String, **Wirable::FINGERPRINT_KINDS

      def self.from_wire(fields)
        new(to: fields.fetch("to"), reason: fields.fetch("reason").to_sym, fingerprint: Wirable.fingerprint_in(fields))
      end

      def wire_fields = { "to" => to, "reason" => reason.to_s }.merge(Wirable.fingerprint_fields(fingerprint))
    end

    # Said by the host to everybody when a machine has been let in, so each can show who is here.
    Joined = Data.define(:player) do
      include Wirable
      wire_type "joined", player: Integer
    end

    # "The match begins." Said by the host once the match is full. +players+ is the list of player
    # numbers in it. Pass 2, the first pass that reads buttons, comes next.
    Start = Data.define(:players) do
      include Wirable
      wire_type "start", players: :integers
    end

    # --- during the match ---

    # What the sender's player will hold on pass +pass+, as one number a bit a button
    # (IR::Buttons). It is sent a few passes before the pass is played (the input delay), which is
    # what gives the network that long to carry it.
    Buttons = Data.define(:pass, :mask) do
      include Wirable
      wire_type "buttons", pass: Integer, mask: Integer
    end

    # A short number (a CRC-32) of the whole of the sender's game state as it stood after pass
    # +pass+. Machines that run the same game on the same buttons have the same number at the same
    # pass, so a difference is a machine that has gone wrong.
    Checkpoint = Data.define(:pass, :crc) do
      include Wirable
      wire_type "checkpoint", pass: Integer, crc: Integer
    end

    # A line of chat from a player, for the others of the room to read. It is not a button and not state: the
    # game never sees it, and no checkpoint covers it, so it can never make machines disagree. The sender is
    # only the number the room stamps on it.
    Chat = Data.define(:text) do
      include Wirable
      wire_type "chat", text: String
    end

    # A line of chat as a machine shows it: who said it (a player number, since no name goes over the network) and
    # the text.
    ChatLine = Data.define(:player, :text) do
      def words = "Player #{player}: #{text}"
    end

    # Said by the room, never by a machine: the machine in +from+ has gone. Every message that machine
    # sent has been handed on before this, in order, so every other machine knows the same last pass of
    # its buttons, and the player leaves on the same pass everywhere.
    Left = Data.define do
      include Wirable
      wire_type "left"
    end

    # --- between a machine and a relay (never handed on to the room) ---

    # A ROOM A MACHINE WANTS LISTED: the game it plays (its fingerprint), a name for the room that tells nobody who
    # made it, and how many players the match holds. The relay lists it to machines that play the same game while
    # it has a place free.
    PublicListing = Data.define(:fingerprint, :name, :seats)

    # A room in the relay's list: its +code+ to join it, its +name+, how many machines are in it (+members+) and how
    # many it holds (+seats+).
    PublicRoom = Data.define(:code, :name, :members, :seats) do
      def self.from_wire(fields) = new(code: fields.fetch("code"), name: fields.fetch("name"), members: fields.fetch("members"), seats: fields.fetch("seats"))
      def wire_fields = { "code" => code, "name" => name, "members" => members, "seats" => seats }
    end

    # Asks the relay for a new room, which the sender then is in, as player 1. With +public+ the room is listed to
    # machines that play the game with this +digest+ (see PublicListing), until it fills or empties.
    RelayMakeRoom = Data.define(:public, :digest, :name, :seats) do
      include Wirable
      wire_type "make_room"
      relay_message!

      def initialize(public: false, digest: nil, name: nil, seats: nil) = super

      def self.from_wire(fields) = new(public: fields["public"] == true, digest: fields["digest"], name: fields["name"], seats: fields["seats"])
      def wire_fields = public ? { "public" => true, "digest" => digest, "name" => name, "seats" => seats }.compact : {}
    end

    # Asks the relay which public rooms there are for the game with this +digest+.
    RelayListRooms = Data.define(:digest) do
      include Wirable
      wire_type "list_rooms", digest: String
      relay_message!
    end

    # The relay's list: the rooms (PublicRoom) for the game that was asked about, in the order they were made.
    RelayRooms = Data.define(:rooms) do
      include Wirable
      wire_type "rooms", rooms: :objects
      relay_message!

      def self.from_wire(fields) = new(rooms: fields.fetch("rooms").map { |each| PublicRoom.from_wire(each) })
      def wire_fields = { "rooms" => rooms.map(&:wire_fields) }
    end

    # The relay's answer: the code to give to the others, and the sender's number.
    RelayRoomMade = Data.define(:code, :you) do
      include Wirable
      wire_type "room_made", code: String, you: Integer
      relay_message!
    end

    # Asks the relay to put the sender in the room that has +code+.
    RelayJoinRoom = Data.define(:code) do
      include Wirable
      wire_type "join_room", code: String
      relay_message!
    end

    # The relay's answer: the code, the sender's number, and who is in the room already.
    RelayRoomJoined = Data.define(:code, :you, :members) do
      include Wirable
      wire_type "room_joined", code: String, you: Integer, members: :integers
      relay_message!
    end

    # The relay's refusal, with a +reason+ (see docs/network/protocol.md), +words+ for a person, and for
    # a version the relay does not know, the versions it +supported+.
    RelayError = Data.define(:reason, :words, :supported) do
      include Wirable
      wire_type "error", reason: String
      relay_message!

      def self.from_wire(fields) = new(reason: fields.fetch("reason").to_sym, words: fields["words"], supported: fields["supported"])
      def wire_fields = { "reason" => reason.to_s, "words" => words, "supported" => supported }.compact
    end

  end
end
