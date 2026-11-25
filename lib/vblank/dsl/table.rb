# frozen_string_literal: true

module VBlank
  module DSL
    # A table of numbers in the cartridge
    #
    # `table` hands this back: numbers the game reads and never changes, such as a sine wave
    # or a level's map. They are kept in the cartridge, so they cost no memory the game
    # changes. Read an entry with `[]`, at a number the game works out as it plays, and use it
    # like any other number.
    #
    # ```ruby
    # sin = table :sin, SIN
    # y = 80 + sin[angle]
    # ```
    #
    # Its size is fixed when the game is built. For numbers the game changes, make a `list`.
    class Table
      Build = IR::Build

      # @param builder [Builder] the build reads record into
      # @param name [Symbol] the table's name
      # @param count [Integer] how many elements it holds
      # @param fraction_bits [Integer, nil] fraction bits its values carry, if any
      # @param width [Symbol] how big one entry is: :byte, :half or :word
      def initialize(builder, name, count, fraction_bits: nil, width: :half)
        @builder = builder
        @name = name
        @count = count
        @fraction_bits = fraction_bits
        @width = width
      end

      # The table's name.
      attr_reader :name

      # How many of the low bits of each entry hold a fraction, or nil for whole numbers.
      attr_reader :fraction_bits # :nodoc:

      # How big one entry is: `:byte`, `:half` or `:word`.
      attr_reader :width # :nodoc:

      # The entry at `index`, as a number: a number written in the game, or one it works out
      # as it plays.
      #
      # An index past either end is made safe: a table whose size is a power of two wraps it
      # round, and any other size holds it at the first or the last entry. A table written
      # with decimal numbers gives numbers that hold a fraction, so a sine table reads as a
      # sine.
      #
      # ```ruby
      # wall = world[row * 32 + column]
      # ```
      def [](index)
        Value.new(@builder, Build.table_get(@name, Value.node_for(index)), fraction_bits: @fraction_bits)
      end

      # A table is stored in the cartridge, so nothing can be written into it as the game runs.
      def fill(*) # :nodoc:
        raise ArgumentError, "table :#{@name} is read-only: it is stored in the cartridge, so `fill` cannot " \
                             "change it. To fill numbers the game changes, keep them in an Array, like " \
                             "`cells = Array.new(64, 0)`."
      end

      # How many entries the table holds, as a plain Ruby number, since the size is fixed
      # when the game is built.
      #
      # ```ruby
      # step = (step + 1) % sway.length
      # ```
      def length
        @count
      end
    end
  end
end
