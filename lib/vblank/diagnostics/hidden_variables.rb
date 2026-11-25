# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The variables a game never asked for, listed where somebody looking at what a cartridge costs
    # will see them. Normal Ruby sometimes needs a number kept that the author gave no `var`: a
    # swap, a name that holds nil, a number kept from a line above. Each takes one word of the
    # console's small working memory and a few instructions, and a game at the limit wants to
    # know which lines those were, and how to write them so nothing is needed.
    module HiddenVariables
      BYTES_EACH = 4

      WORDS = Ractor.make_shareable({
        copy: ["keeps the number it got on this line, as Ruby does.",
               IR::Guardrails::Checks::IwramBudget::COPY_ADVICE],
        swap: ["keeps one number while the others are written.", nil],
        handed_copy: ["keeps a number of its own, as Ruby does: this instance variable was handed another " \
                      "place's number, and game code gives it another.",
                      "Unneeded if you change the other place itself (`cursor.selection = 5`) where you mean " \
                      "it to change, or keep the number in a plain local where you only read it."],
        field: ["keeps the number a Struct's field was given, as Ruby does.",
                "Unneeded if the field is read before the numbers it was given from change."],
        picked: ["keeps the number the test picked.", nil],
        cell_number: ["keeps the cell number set_cell works out. Every such line of the routine uses this one.", nil],
        cell_block:["keeps a place or a size of this block of cells. It is worked out one time for all the block.",
                     "Unneeded if the place and the size are numbers or variables."],
        cell_block_pick: ["keeps the number that picks the tile of each cell in the block.", nil],
        cell_block_place: ["keeps the tile of the map that each cell gets back.", nil],
        number_source: ["keeps the number draw_number shows. Every such line of the routine uses this one.", nil],
        number_digit: ["keeps the digit draw_number draws. Every such line of the routine uses this one.", nil],
        number_started: ["keeps whether draw_number drew a digit. Every such line of the routine uses this one.", nil],
        join: ["keeps the answer of `&&` or `||`.", "Unneeded in an `if` with no `else`."],
        promoted: ["makes this name a variable, as a test the game makes changes it.", nil],
        list_answer: ["keeps the answer of sum, min, max or include? on a list as it walks the items.", nil],
        taken: ["keeps the item that shift or pop drops, as Ruby hands it back.",
                "Unneeded where the line does not use the item."],
        count_start: ["keeps the number the loop starts from, as Ruby does when the body changes it.",
                      "Unneeded if nothing in the loop changes that number."],
        counted: ["keeps how many things the test holds for, as it counts them.", nil],
        jump: ["keeps whether `break` or `next` ran in this round of the loop.", nil],
        position: ["keeps the place in the walk that each_with_index hands the block.", nil],
        clamped: ["keeps the thing that clamp hands back.", nil],
        found: ["keeps whether the Array held a thing for min or max to hand back.", nil],
        best: ["keeps the thing that min or max has found so far.", nil],
        kept: ["keeps which thing this name holds after the walk that handed it over.", nil],
        part_started: ["keeps whether this part, made on every pass, has put its first things in, so they go in once.",
                       "Unneeded if the part is made above the game loop."],
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
          count = same.length > 1 ? "#{same.length} of them, " : ""
          printer.puts("  #{place(source)}  #{line_text(source)}  #{said} (#{count}#{same.length * BYTES_EACH} bytes)")
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
        { at: place(note.source), line: line_text(note.source), why: note.why.to_s, bytes: BYTES_EACH, says: said,
          advice: advice }
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
