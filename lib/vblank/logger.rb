# frozen_string_literal: true

module VBlank
  # WHERE THE LIBRARY SAYS WHAT IT IS DOING, for somebody finding out why something went wrong: a
  # match over the network that stops, a relay that does not answer. It takes the calls a Ruby
  # Logger takes, with a block so nothing is worked out when the level leaves the line out:
  #
  #   VBlank.logger.debug("network") { "sent make_room" }
  #
  # By default it writes to standard error, not standard output, since the Ruby and C builds' test
  # runs read a game's standard output line by line. It says only warnings and worse unless
  # VBLANK_LOG names a lower level (debug, info). A test hands it a StringIO and reads what was said:
  #
  #   VBlank.logger = VBlank::Logger.new(io = StringIO.new, level: :debug)
  #
  # WHY NOT RUBY'S OWN LOGGER: Ractors. The library's tests play in Ractors, and so can a game, and
  # each Ractor makes its own logger (below). Ruby's Logger (the logger gem) cannot be made in any
  # Ractor but the main one: Logger.new sets its level through Logger::Severity.coerce, which reads
  # Logger::Severity::LEVELS, a constant the gem never makes shareable, so the call raises
  # Ractor::IsolationError. Working round it means freezing the gem's own constants from here, or
  # keeping every test that logs out of the Ractors, and either costs more than these few lines. Tried
  # with logger 1.7.0 on Ruby 4.0. If a later logger makes its constants shareable, swap this class
  # for it: the calls are the same, so nothing that logs changes.
  #
  # Anything that takes the same calls can stand in, Ruby's own Logger included on the main Ractor.
  #
  # Each Ractor keeps its own, since a test in a Ractor cannot reach one the whole process shares; a
  # Ractor that set none gets a new default. Threads in one Ractor share it.
  #
  # What the library says to the author while a game BUILDS (its warnings and progress) is
  # Messages', not this: this is for what runs.
  class Logger
    LEVELS = %i[debug info warn error].freeze
    SETTING = "VBLANK_LOG"
    # The level VBLANK_LOG named when the library loaded, warn when it named none.
    DEFAULT_LEVEL = ENV.fetch(SETTING, "").downcase.then { |name| LEVELS.include?(name.to_sym) ? name.to_sym : :warn }

    attr_reader :level

    def initialize(io = $stderr, level: DEFAULT_LEVEL)
      @io = io
      @level = level.to_sym
      raise ArgumentError, "#{level.inspect} is not a level. Use one of: #{LEVELS.join(', ')}." unless LEVELS.include?(@level)
    end

    # Written out rather than made in a loop: a method made from a block cannot be called from a Ractor.
    def debug(part = nil, &words) = write(:debug, part, words)
    def info(part = nil, &words) = write(:info, part, words)
    def warn(part = nil, &words) = write(:warn, part, words)
    def error(part = nil, &words) = write(:error, part, words)

    def debug? = at_least?(:debug)
    def info? = at_least?(:info)
    def warn? = at_least?(:warn)
    def error? = at_least?(:error)

    private

    def at_least?(name) = LEVELS.index(name) >= LEVELS.index(@level)

    # One line: the time, the level, the part of the library, and the words, worked out only when the
    # level lets the line through. A line that cannot be written is dropped: telling must never stop a game.
    def write(name, part, words)
      return unless at_least?(name)

      text = words ? words.call : part
      part = nil unless words
      @io.puts(format("%s %-5s %s%s", Time.now.strftime("%H:%M:%S.%L"), name.upcase, part ? "[#{part}] " : "", text))
    rescue IOError, SystemCallError
      nil
    end
  end

  def self.logger
    ::Ractor.current[:vblank_logger] ||= Logger.new
  end

  def self.logger=(logger)
    ::Ractor.current[:vblank_logger] = logger
  end
end
