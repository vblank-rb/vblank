# frozen_string_literal: true

module VBlank
  module Diagnostics
    # THE VARIABLES A GAME NEVER ASKED FOR, listed where somebody looking at what a cartridge costs
    # will see them. Normal Ruby sometimes needs a number kept that the author gave no `var`: a
    # swap, a name that holds nil, a number kept from a line above. Each takes one word of the
    # console's small working memory and a few instructions, and a game at the limit wants to
    # know which lines those were, and how to write them so nothing is needed.
    module HiddenVariables
      BYTES_EACH = 4

      WORDS = Ractor.make_shareable({
        copy: ["keeps its number from this line, as Ruby does.",
               "Unneeded if everything that reads it comes before the line that changes the number."],
        swap: ["keeps one number while the others are written.", nil],
        picked: ["keeps the number the test picked.", nil],
        join: ["keeps the answer of `&&` or `||`.", "Unneeded in an `if` with no `else`."],
        promoted: ["makes this name a variable, as a test the game makes changes it.", nil],
        truth: ["keeps a second hidden variable for nil, or for false beside a number.",
                "Unneeded if it starts with false, or a number such as -1."]
      })

      module_function

      def render(rom, printer)
        notes = rom.respond_to?(:hidden_variables) ? rom.hidden_variables : []
        return if notes.empty?

        printer.puts("hidden variables: #{notes.length} (#{notes.length * BYTES_EACH} bytes)")
        notes.group_by { |note| [note.source, note.why] }.each do |(source, why), same|
          said, advice = WORDS.fetch(why)
          count = same.length > 1 ? " (#{same.length} of them)" : ""
          printer.puts("  #{place(source)}  #{line_text(source)}  #{said}#{count}")
          printer.puts("    #{advice}") if advice
        end
        printer.puts("")
      end

      # The same list as data, for `rom.profile(format: :json)`.
      def as_json(rom)
        notes = rom.hidden_variables
        { hidden_variables: { count: notes.length, bytes: notes.length * BYTES_EACH,
                              lines: notes.map { |note| line_json(note) } } }
      end

      def line_json(note)
        said, advice = WORDS.fetch(note.why)
        { at: place(note.source), line: line_text(note.source), why: note.why.to_s, says: said, advice: advice }
      end

      def place(source) = source ? File.basename(source) : "the library"

      # What the author wrote there, which shows more than a line number on its own.
      def line_text(source)
        path, line = source.to_s.split(/:(\d+)\z/)
        return "" unless line && File.file?(path)

        File.readlines(path, chomp: true).fetch(line.to_i - 1, "").strip
      end
    end
  end
end
