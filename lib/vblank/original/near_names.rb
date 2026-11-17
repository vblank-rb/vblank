# frozen_string_literal: true

module VBlank
  module Original
    # The names nearest one that is not there, for a refusal to offer: an original's names come in
    # families (Music_Title, Music_Credits) and a wrong one is nearly always a near miss.
    module NearNames
      module_function

      # Up to +count+ of +names+: those sharing the longest start with +name+, then those a letter or
      # two from it.
      def among(names, name, count: 4)
        (prefix_matches(names, name, count) + spelling_matches(names, name)).uniq.first(count)
      end

      def prefix_matches(names, name, count)
        name.length.downto(3) do |length|
          found = names.select { it.start_with?(name[0, length]) }
          return found.sort.first(count) unless found.empty?
        end
        []
      end

      def spelling_matches(names, name)
        return [] if name.length < 3

        names.select { (it.length - name.length).abs <= 2 && edit_distance(it, name) <= 2 }.sort
      end

      # Levenshtein distance: the fewest letters added, removed or changed to turn one name into another.
      def edit_distance(first, second)
        row = (0..second.length).to_a
        first.each_char.with_index(1) do |letter, at|
          previous = row.dup
          row[0] = at
          second.each_char.with_index(1) do |other, column|
            row[column] = [previous[column] + 1, row[column - 1] + 1, previous[column - 1] + (letter == other ? 0 : 1)].min
          end
        end
        row.last
      end

      private_class_method :prefix_matches, :spelling_matches, :edit_distance
    end
  end
end
