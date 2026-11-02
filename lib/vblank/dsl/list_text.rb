# frozen_string_literal: true

module VBlank
  module DSL
    # WORDS NOBODY KNEW WHEN THE CARTRIDGE WAS BUILT, on a painted screen: `draw_text name_list, x, y,
    # :white`, the list holding character codes. A name the player typed, a line of a high score
    # table.
    #
    # The words `draw_text` knows ahead of time are painted into the code a pixel at a time, which
    # is no use here, so this reads a letter out of the font's tables as the game runs, as a canvas
    # does (Builder::Canvases#canvas_font_tables), and each letter takes its own width, so a
    # proportional font stays proportional. Every step is one a game could write itself, which is
    # why it works the same on every console and in the interpreter.
    #
    # ONE ROUTINE FOR A LIST, A FONT AND A COLOUR, however many places draw it, since a high score
    # table draws the same list ten times over and each place only sets four numbers.
    class ListText
      def initialize(builder, number:, list:, font:, color:)
        @builder = builder
        @number = number
        @list = list
        @font = font
        @color = color
      end

      def draw(x, y, from, length)
        var(:pen).store! x
        var(:top).store! y
        var(:at).store! from
        var(:letters).store! length
        @builder.call(routine)
        nil
      end

      private

      def part(what) = Messages::MadeNames.make(:list_text_part, number: @number, part: what)

      def var(what)
        @variables ||= {}
        @variables[what] ||= @builder.var(part(what), 0)
      end

      def routine
        @routine ||= begin
          name = part(:line)
          tables = @builder.canvas_font_tables(@font)
          builder = @builder
          list = @list
          color = @color
          pen = var(:pen)
          top = var(:top)
          at = var(:at)
          letters = var(:letters)
          code = var(:code)
          wide = var(:wide)
          bits = var(:bits)
          rows = tables.rows
          widths = tables.widths
          tall = tables.height
          gap = tables.spacing
          @builder.func(name) do
            builder.repeat(letters) do
              code = list[at]
              wide = widths[code]
              builder.repeat(tall) do |row|
                bits = rows[(code * tall) + row]
                builder.repeat(wide) do |col|
                  builder.draw_rect_at(pen + col, top + row, 1, 1, color) if ((bits >> (wide - 1 - col)) & 1) == 1
                end
              end
              pen += wide + gap
              at += 1
            end
          end
          name
        end
      end
    end
  end
end
