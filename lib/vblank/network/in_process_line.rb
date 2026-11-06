# frozen_string_literal: true

module VBlank
  module Network
    # A MACHINE'S LINK TO A RELAY THAT IS IN THIS PROCESS (StandInRelay): text goes in, text comes out, and
    # a wait gives the other copies their turn (Scheduler). It answers what a RelayTransport asks of any
    # line, as a WebSocket does for the real relay: send_text, receive_text, wait_for_text, close, closed?.
    class InProcessLine
      def initialize(connection, scheduler)
        @connection = connection
        @scheduler = scheduler
      end

      def send_text(text) = @connection.send_text(text)
      def receive_text = @connection.receive_text
      def close = @connection.close
      def closed? = @connection.closed?

      # Returns true once there is text to receive, or the link is closed. The other copies play meanwhile.
      # +_seconds+ is taken as any line takes it and not used: in one process nothing comes late, and a wait
      # that can never end raises Scheduler::Stalled instead.
      def wait_for_text(_seconds = nil)
        until @connection.pending? || @connection.closed?
          unless @scheduler.inside?
            raise Scheduler::Stalled, "This machine waits for the relay and no other copy is playing. " \
                                      "To fix this, play every copy with Scheduler#play."
          end
          @scheduler.wait
        end
        true
      end
    end
  end
end
