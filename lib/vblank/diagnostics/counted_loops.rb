# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The counted Ruby loops of game code whose count was known while building (`16.times`,
    # `0.upto(7)`), each with what the build made of it: its rounds written out, which is quick and
    # costs room for each round, or one loop the game runs, which costs one round of room and a
    # little time each round (DSL::PlainRuby::Counts::KnownRounds). Listed for a game near the end
    # of its cartridge or its frame, to see which lines chose which.
    #
    # One line of the report for each line of the game: a loop inside another written-out loop is
    # chosen again in each outer round, and is told once for each choice it got.
    module CountedLoops
      # What each choice means, for the author.
      WORDS = Ractor.make_shareable({
        loop: "is one loop the game runs, since written out its rounds would be too large.",
        written_out: "is written out once for each round, since its rounds are small.",
        rounds_differ: "is written out once for each round: its rounds differ in more than a number that counts " \
                       "up, such as a colour or a test picked while building, so they cannot be one loop."
      })

      module_function

      def render(rom, printer)
        notes = rom.respond_to?(:counted_loops) ? rom.counted_loops : []
        return if notes.empty?

        printer.puts("counted loops: #{line_count(notes)}")
        told(notes).each do |note|
          printer.puts("  #{HiddenVariables.place(note.source)}  #{HiddenVariables.line_text(note.source)}  " \
                       "#{note.rounds} rounds #{WORDS.fetch(note.choice)} (#{size_words(note)})")
          printer.puts("    #{time_words(note)}") if note.choice == :loop
        end
        printer.puts("")
      end

      # The same list as data, for `rom.profile(format: :json)`.
      def as_json(rom)
        notes = rom.counted_loops
        { counted_loops: { count: line_count(notes), lines: told(notes).map { |note| line_json(note) } } }
      end

      def line_json(note)
        { at: HiddenVariables.place(note.source), line: HiddenVariables.line_text(note.source), rounds: note.rounds,
          choice: note.choice.to_s, written_size: note.written_size, worked_out: note.worked_out,
          says: WORDS.fetch(note.choice), costs: note.choice == :loop ? time_words(note) : nil }
      end

      # How many lines of the game hold a counted loop.
      def line_count(notes) = notes.map(&:source).uniq.size

      # Each line once for each choice it got.
      def told(notes) = notes.uniq { |note| [note.source, note.choice] }

      def size_words(note)
        "size #{note.written_size} written out; the most written out is " \
          "#{DSL::PlainRuby::Counts::KnownRounds::WRITTEN_OUT_MOST}"
      end

      # What a loop costs each round that rounds written out do not.
      def time_words(note)
        numbers = case note.worked_out
                  when 0 then ""
                  when 1 then ", and works out 1 number from the round number with a multiply and an add"
                  else ", and works out #{note.worked_out} numbers from the round number with a multiply and an add each"
                  end
        "Each round costs time that a round written out does not: the loop counts the round and " \
          "goes back#{numbers}. That is #{note.rounds} times for each time the loop runs."
      end
    end
  end
end
