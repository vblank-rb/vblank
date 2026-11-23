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
    # leaves the game current again, a build that fails leaves nothing behind, and a part made
    # after a finished build finds no game.
    #
    # A builder made by hand (`Builder.new` in a test or a tool, with no build open) stands as the
    # thread's session until another is made by hand: such a builder is driven a verb at a time
    # and has no end to close it at.
    #
    # ### A game's variables after its build
    #
    # A part made outside the game's block (in a constant of a game file) outlives the build that
    # gave it variables, and the next build of the game (for another console) starts it again
    # from Ruby's number (#ended_alone?). A program built as part of a game (+part_of+, a data
    # pack's unpacking) is no game of its own: a variable it made, reached from another program of
    # that game, is still that program's, and the data pack refuses the read.
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

      # The game file at +path+ is loaded by the block of the game being built: what its source
      # names counts for this build (PlainRuby::InstanceVariables.record_file_names). True where a
      # build opened with #building is open; a builder made by hand has no block to load it from.
      def self.note_game_file(path)
        session = current
        return false if session.nil? || session.standing? || session.plain_ruby?

        session.game_files << path
        true
      end

      # The game files the block of the game being built loaded (#note_game_file), in no order.
      def self.game_files = current&.game_files || NO_FILES

      NO_FILES = Set.new.freeze

      # Opens a session for the builder +make+ makes, yields that builder, and puts back the
      # session before it when the block ends. +part_of+ is the builder of the game this program
      # is built for, where it is not a game of its own.
      def self.building(make, part_of: nil)
        was = current
        session = new(standing: false, part_of: part_of)
        # A program of a game reads the game's files as the game does.
        session.game_files.merge(was.game_files) if part_of && was
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

      # +builder+ was made by hand: it stands as the thread's session, and the one that stood
      # before it has ended. With a build open, the build's own builder stays current
      # (Builder#initialize).
      def self.stand(builder)
        return unless current.nil? || current.standing?

        current&.end!
        self.current = new(standing: true).tap { |session| session.take(builder) }
      end

      def initialize(standing:, plain_ruby: false, part_of: nil)
        @standing = standing
        @plain_ruby = plain_ruby
        @part_of = part_of
        @ended = false
        @game_files = Set.new
      end

      # The builder of this session's game, or nil while it is being made.
      attr_reader :builder

      # The game files this build's block loaded (.note_game_file).
      attr_reader :game_files

      # Makes +builder+ this session's.
      def take(builder)
        @builder = builder
        builder.build_session = self
      end

      def standing? = @standing

      def plain_ruby? = @plain_ruby

      def recording? = !@builder.nil? && @builder.recording_game_code?

      def end! = @ended = true

      # Has this game's build ended, and was it a game of its own (no +part_of+)?
      def ended_alone? = @ended && @part_of.nil?
    end
  end
end
