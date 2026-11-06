# frozen_string_literal: true

module VBlank
  module Network
    # THE ROOM A RELAY KEEPS, as a Lockstep's transport. It makes a room or joins one by its code, and
    # from then on carries the match's messages as text (Wire), one for each message, over a line that can
    # send and receive text: a WebSocket to the real relay, or a link to a stand-in in this process.
    #
    # The number the relay gives the machine in the room is its player number (#id). The relay stamps
    # each message it hands on with who sent it, so the Envelopes come out as the transport promises.
    class RelayTransport
      attr_reader :id, :code

      # HOW LONG A MACHINE WAITS FOR THE RELAY TO ANSWER a request (make a room, join one, list them) before it
      # says the relay is not answering. A person waits this long at most, and is told what to do. A relay on
      # the other side of the world answers in well under a second, so this is room for a slow network, not a
      # guess at the relay's speed. A test passes a short one, so a lost answer fails at once.
      ANSWER_SECONDS = 15

      # Makes a room on the relay behind +line+. +code+ is what to tell the others. With +listing+ (a PublicListing)
      # the relay lists the room to machines that play the same game.
      def self.make_room(line, listing: nil, answer_seconds: ANSWER_SECONDS)
        new(line, answer_seconds: answer_seconds).tap { |transport| transport.make_room(listing) }
      end

      # The public rooms on the relay behind +line+ for the game with +fingerprint+: an Array of PublicRoom.
      def self.list_rooms(line, fingerprint, answer_seconds: ANSWER_SECONDS)
        new(line, answer_seconds: answer_seconds).list_rooms(fingerprint)
      end

      # Joins the room that has +code+. Raises RoomRefused when there is none.
      def self.join_room(line, code, answer_seconds: ANSWER_SECONDS)
        new(line, answer_seconds: answer_seconds).tap { |transport| transport.join_room(code) }
      end

      def initialize(line, answer_seconds: ANSWER_SECONDS)
        @line = line
        @answer_seconds = answer_seconds
      end

      def send_message(message) = (@line.send_text(Wire.encode(message)) unless closed?)

      # The next message of the match as an Envelope, or nil when there is none yet.
      def receive_message
        text = @line.receive_text or return nil

        Wire.decode(text)
      end

      def wait_for_message = @line.wait_for_text

      def close = @line.close
      def closed? = @line.closed?

      def make_room(listing = nil)
        request = listing ? RelayMakeRoom.new(public: true, digest: listing.fingerprint.digest, name: listing.name, seats: listing.seats) : RelayMakeRoom.new
        @line.send_text(Wire.encode(request))
        made = answer
        @code = made.code
        @id = made.you
      end

      def list_rooms(fingerprint)
        @line.send_text(Wire.encode(RelayListRooms.new(digest: fingerprint.digest)))
        answer.rooms
      end

      def join_room(code)
        @line.send_text(Wire.encode(RelayJoinRoom.new(code: code)))
        joined = answer
        @code = joined.code
        @id = joined.you
      end

      private

      # The relay's reply to what was just asked, or an error in plain words.
      def answer
        VBlank.logger.debug("network") { "waiting up to #{@answer_seconds} s for the relay to answer" }
        @line.wait_for_text(@answer_seconds) or raise RelayNotAnswering, @answer_seconds
        text = @line.receive_text or raise ConnectionLost
        VBlank.logger.debug("network") { "the relay answered #{text}" }
        reply = Wire.decode(text)
        return reply unless reply.is_a?(RelayError)
        raise VersionMismatch.by_relay(reply.supported) if reply.reason == :version

        raise RoomRefused.new(reply.reason, reply.words)
      end
    end

    # A relay that did not answer a request in RelayTransport::ANSWER_SECONDS (or the time a caller gave).
    class RelayNotAnswering < StandardError
      attr_reader :seconds

      def initialize(seconds)
        @seconds = seconds
        super("The relay did not answer in #{seconds} seconds. To fix this, check the network and try again. " \
              "If it happens again, set VBLANK_LOG=debug and send what it says.")
      end
    end

    # A relay that would not make a room or join one. +reason+ is the relay's (Wire's RELAY_ERRORS).
    class RoomRefused < StandardError
      attr_reader :reason

      def initialize(reason, words)
        @reason = reason
        super(words || "The relay did not do that (#{reason}). To fix this, check the code and try again.")
      end
    end
  end
end
