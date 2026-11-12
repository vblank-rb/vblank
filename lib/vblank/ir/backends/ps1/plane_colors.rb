# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # THE COLOUR TABLE A BACKGROUND IS DRAWN THROUGH. A plane is kept in video RAM as places in a colour
        # table, 4 or 8 bits a texel, not as colours (Runtime::Tiles): the chip reads a quarter or half the
        # memory drawing it, and a colour the game changes is one entry of the table written again, not every
        # pixel of the plane drawn again.
        #
        # So each pixel of each of the background's tiles is given an ENTRY: the colours that pixel can show,
        # and what changes it. Most pixels show one colour for good. A pixel of a background the game draws
        # with other lists (`draw_with`, Nodes::BackgroundColors) shows a colour for each set the game can
        # name, and one of a background that follows a list the game changes (Background#follows_each) a
        # colour for each set that list can hold: the game naming a set writes each entry's colour in that
        # set into the table (Runtime::Colors). Two pixels with the same entry share a place in the table,
        # so a background has as many places as it has entries, the see-through one first.
        #
        # What each pixel shows in each set is the interpreter's own rule (Reference#tile_colors, with
        # #background_swap's swaps), worked out here for every set while the game is built.
        class PlaneColors
          # What changes an entry, and how many sets it can name: the background's own lists
          # ([:background, its object_id]) or a list of colours ([:list, its name]).
          Source = Data.define(:key, :sets) do
            # The source the declared list of colours +list+ is.
            def self.of_list(list) = new(key: [:list, list.name], sets: 1 + list.recolors.length)

            # The source +bg+'s own lists are (`draw_with`).
            def self.of_background(bg) = new(key: [:background, bg.object_id], sets: 1 + bg.recolors.length)
          end

          # One place in the table: its source (nil for a colour shown for good), and its colour in each of
          # the source's sets, the first the one it starts with.
          Entry = Data.define(:source, :colors)

          # +bg+ the background; +image_of+ gives a tile's picture by its name (BuildCache#image), +list_named+
          # a declared list of colours by its name.
          def initialize(bg, image_of:, list_named:)
            @bg = bg
            @image_of = image_of
            @list_named = list_named
            @tiles = {}
          end

          # Each pixel of tile number +tile+, row by row: nil where it is see-through, and its Entry.
          def tile_entries(tile)
            @tiles[tile] ||= begin
              image = @image_of.call(@bg.tiles.fetch(tile))
              source = source_of(image)
              sets = Array.new(source ? source.sets : 1) { |set| tile_colors(image, swaps_in_set(image, set)) }
              Array.new(image.width * image.height) do |at|
                next if sets.first[at].nil?

                Entry.new(source: source, colors: sets.map { |colors| colors[at] & 0x7FFF })
              end
            end
          end

          # Every entry its tiles have, each once, in the order they are first met.
          def entries = (@entries ||= @bg.tiles.each_index.flat_map { |tile| tile_entries(tile) }.compact.uniq)

          # Whether any entry changes as the game runs.
          def changes? = entries.any?(&:source)

          private

          # What changes the tile +image+'s colours: the background's own lists, the list it follows for the
          # tile's list, or nothing.
          def source_of(image)
            if @bg.follows_several?
              list = @bg.list_followed_by(image.list_drawn_from) or return nil
              Source.of_list(@list_named.call(list))
            elsif !@bg.recolors.empty?
              Source.of_background(@bg)
            end
          end

          # The swaps (Background#list_swaps) the tile +image+ is drawn with in set +set+ of its source: nil,
          # its own colours, in set 0 of the background's own lists.
          def swaps_in_set(image, set)
            if @bg.follows_several?
              list = @bg.list_followed_by(image.list_drawn_from) or return nil
              held = @bg.lists_followed.to_h { |name| [name, @list_named.call(name).colors] }
              held[list] = set_of_list(list, set)
              @bg.followed_list_swaps(held)
            elsif set.positive?
              @bg.list_swaps(set - 1)
            end
          end

          # The colours the list +name+ holds in set +set+: 0 those it was declared with, then each other.
          def set_of_list(name, set)
            list = @list_named.call(name)
            set.zero? ? list.colors : list.recolors.fetch(set - 1)
          end

          # Reference#tile_colors: each pixel of +image+ as drawn with +swaps+, nil where it is see-through.
          def tile_colors(image, swaps)
            swapped = swaps && swaps[image.list_drawn_from]
            recolor = swapped && Assets::Recolor.of(image, swapped)
            Array.new(image.width * image.height) do |at|
              next if image.tile_see_through_at?(at)

              color = image.color_at(at)
              recolor ? recolor.color_for(at, color) : color
            end
          end
        end
      end
    end
  end
end
