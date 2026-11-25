# frozen_string_literal: true

module VBlank
  class Builder
    # The game being built on this thread now, if one is: its builder, and whether game code is
    # being recorded. Plain Ruby asks here, since a part of a game is a plain object with no
    # builder of its own, and a line of it must know whether it runs as game code.
    #
    # Kept on the thread, not the Ractor: two threads of one Ractor can build two games at once
    # (minitest's threads, with --no-ractor), and each game's code must find its own build. A
    # thread variable is shared by the thread's fibers, so a build stepped through an Enumerator
    # still finds it. Each Ractor has threads of its own, so this is per Ractor as well.
    #
    # ### How long one lasts
    #
    # A build opens one with #building, which puts back the session before it when the block
    # ends, however it ends. So a program built inside a game's build (a data pack's unpacking)
    # leaves the game current again, and a build that fails leaves nothing behind.
    #
    # A builder made by hand (`Builder.new` in a test or a tool, with no build open) is made the
    # thread's current game (#make_current) until another is made by hand: such a builder is driven
    # a verb at a time and has no end to close it at. A build ends by putting back what was current
    # before it, so a part made after a finished build finds no game only where no builder made by
    # hand was current before the build; where one was, the part is that builder's, as it would be
    # had the build not run. Tests that drive a Builder by hand rely on that, and so does a data
    # pack built on one (test_pack_cache_parts.rb), whose unpacking reaches the hand-made game's
    # objects.
    #
    # ### A game's variables after its build
    #
    # A part made outside the game's block (in a constant of a game file) outlives the build that
    # gave it variables, and the next build of the game (for another console) starts it again
    # from Ruby's number (#game_ended?). A program built as part of a game (+part_of+, a data
    # pack's unpacking) is no game of its own: while that game is being built, a variable the
    # program made, reached from another program of the game, is still that program's, and the
    # data pack refuses the read. Once the game's build has ended too, it is Ruby's number again.
    #
    # ### Plain Ruby on purpose
    #
    # Code that runs a game's parts as plain Ruby, with no game, says so with
    # #running_as_plain_ruby: an Array made with `capacity:` is then Ruby's own Array. With no
    # session at all, such an Array is refused, since a part made there cannot be in any game.
    class Session
      KEY = :vblank_build_session

      # The session open on this thread, or nil.
      def self.current = Thread.current.thread_variable_get(KEY)

      def self.current=(session)
        Thread.current.thread_variable_set(KEY, session)
      end
      private_class_method :current=

      # The builder of the game being built on this thread, or nil.
      def self.builder = current&.builder

      # Is game code being recorded now, rather than set up?
      def self.recording? = current&.recording? || false

      # Is +owner+, what a rewritten line runs on, the builder recording game code now? A part of
      # a game is no builder, so its lines answer false (PlainRuby::Writes decides those itself).
      def self.records_for?(owner) = recording? && builder.equal?(owner)

      # Are a game's parts run as plain Ruby on purpose (#running_as_plain_ruby)?
      def self.plain_ruby? = current&.plain_ruby? || false

      # Opens a session for the builder +make+ makes, yields that builder, and puts back the
      # session before it when the block ends. +part_of+ is the builder of the game this program
      # is built for, where it is not a game of its own.
      def self.building(make, part_of: nil)
        was = current
        session = new(standing: false, part_of: part_of)
        self.current = session
        session.take(make.call)
        yield session.builder
      ensure
        session&.end!
        self.current = was
      end

      # Runs the block as plain Ruby, with no game being built (#plain_ruby?).
      def self.running_as_plain_ruby
        was = current
        self.current = new(standing: false, plain_ruby: true)
        yield
      ensure
        self.current = was
      end

      # Makes +builder+, made by hand, the thread's current game, and ends the one made by hand
      # before it. Does nothing while a build opened with #building is open: that build's own
      # builder stays current (Builder#initialize).
      def self.make_current(builder)
        return unless current.nil? || current.standing?

        current&.end!
        self.current = new(standing: true).tap { |session| session.take(builder) }
      end

      def initialize(standing:, plain_ruby: false, part_of: nil)
        @standing = standing
        @plain_ruby = plain_ruby
        @part_of = part_of
        @ended = false
      end

      # The builder of this session's game, or nil while it is being made.
      attr_reader :builder

      # Makes +builder+ this session's.
      def take(builder)
        @builder = builder
        builder.build_session = self
      end

      def standing? = @standing

      def plain_ruby? = @plain_ruby

      def recording? = !@builder.nil? && @builder.recording_game_code?

      def end! = @ended = true

      # Has this game's build ended, with the game it is part of (+part_of+), if any? A data pack's
      # unpacking ends before its game does, and the game's other programs still reach what it
      # made; once the game has ended too, a later separate build takes its variables for Ruby's
      # numbers.
      def game_ended?
        return false unless @ended
        return true if @part_of.nil?

        @part_of.build_session&.game_ended? || false
      end
    end
  end
end
