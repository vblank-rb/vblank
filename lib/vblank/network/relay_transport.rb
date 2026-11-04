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

      # Makes a room on the relay behind +line+. +code+ is what to tell the others.
      def self.make_room(line) = new(line).tap(&:make_room)

      # Joins the room that has +code+. Raises RoomRefused when there is none.
      def self.join_room(line, code) = new(line).tap { |transport| transport.join_room(code) }

      def initialize(line)
        @line = line
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

      def make_room
        @line.send_text(Wire.encode(RelayMakeRoom.new))
        made = answer
        @code = made.code
        @id = made.you
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
        @line.wait_for_text
        text = @line.receive_text or raise ConnectionLost
        reply = Wire.decode(text)
        return reply unless reply.is_a?(RelayError)
        raise VersionMismatch.by_relay(reply.supported) if reply.reason == :version

        raise RoomRefused.new(reply.reason, reply.words)
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
