# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # Which slot of a sprite palette each colour of a picture takes, worked out once for the whole
        # game before any sprite picture is cut into tiles.
        #
        # A Color sprite palette is four colours: see-through, then three. A pixel of a sprite's tile
        # is two bits naming one of those four slots, so which slot a colour is in is written into the
        # picture's tiles, and two pictures share a palette only where each colour of the one is in
        # the same slot as in the other. Left to itself a picture puts its colours in the order its
        # pixels first use them (Art.own_sprite_places), so two pictures drawn from one list, one red
        # then orange and the other orange then red, would need a palette each for the same colours:
        # [red, orange] and [orange, red].
        #
        # So each picture's colours are given their slots here, as a game's artist gave each sprite
        # its palette. Every way the picture can lay its colours out (three colours in three slots is
        # six ways) is tried against the palettes and tiles of the pictures laid out before it. Two
        # pictures of one shape in two orders of their colours share their tiles only while each
        # colour is in the same slot of its own palette, so sharing the palette can cost tiles: a
        # font's letters in white and in grey, put in one palette, are every letter copied. Which
        # costs more depends on whether the game's palettes run out, so the layout is made one of two
        # ways (::layout_for), and is used only where it helps:
        #
        # - Palettes to spare. Every picture in its own order needs no more than the eight. A palette
        #   freed then buys the game nothing, so the layout is the one cutting the fewest tiles first
        #   and the fewest palettes after, and is used only where it makes fewer palettes and cuts no
        #   more tiles than the pictures' own orders: nothing is lost, so it is taken.
        # - Palettes run out. In their own orders the pictures need more than the eight, and the
        #   build would lend them (Art::TooManySpriteLists), the slower way, a palette borrowed as
        #   each sprite is placed. Then a palette is weighed as the tiles it is the same share of
        #   (TILES_PER_PALETTE: one of eight, against 32 of 256), so a few tiles buy a palette fewer
        #   and a whole font copied does not, and the layout is used where it fits in the eight. One
        #   that does not would be lent all the same, and a game that lends is not laid out (below).
        #
        # Anything else builds the bytes it always did. Within a layout, ties go to the way filling
        # the fewest free slots of palettes already made, then to the picture's own order. A
        # palette's slots no picture has used yet are free, so a picture of two colours can take the
        # third slot of another's palette, and a picture of one colour any free slot.
        #
        # The pictures that keep their own order take some of the eight too: those the game paints
        # or loads the tiles of (Art#painted_sprite_palette), and those whose tiles are shared with no
        # other picture (Lowering::Picture#sprite_slots). Their palettes are reserved, counted against
        # the eight and never laid out.
        #
        # A picture is drawn in its own colours and in every list a sprite showing it is drawn with
        # (`draw_with`, Lowering::Picture#sets_drawn_with), each a colour for each of its places: its
        # DRAWINGS. Its tiles are cut once, so one way of laying out its places serves all of them,
        # and the ways are tried against every drawing together. The pictures with the most colours
        # and drawings go first, which is how a packing fills its bins with fewest.
        #
        # A greedy fit, not the fewest palettes there could be: finding those is a hard search, and
        # a game's sprites fit eight palettes by sharing obvious ones, which this finds. Only the
        # palettes a sprite asks for are kept (Art#sprite_palette), numbered as they are asked for.
        # Nothing changes a sprite palette while the game runs but the lending: the Color's build
        # refuses a sprite following a list the game changes.
        #
        # A game that lends the eight (Art::TooManySpriteLists) is not laid out at all
        # (Lowering::Picture#sprite_slots). There what counts is the lists on the screen at once, not
        # how many there are, and a list a second sprite wears is no longer one sprite's own to step
        # through (Art#lent_family): a sprite fading through lists of its own, one of them joined to
        # another sprite's, waits for a free one of the eight and is drawn in the wrong colours.
        #
        # A picture made of pieces, whose tiles are the pieces' own bytes (Art#pieced_sprite_picture),
        # is laid out in its own order alone (+fixed+): its palettes can be shared with others', its
        # places never move.
        class SpriteSlots
          # The slots a palette has for colours: the first of the four is see-through.
          SLOTS = Art::OWN_COLORS

          # One picture to lay out: its +name+, +width+ and +height+, the place of its own each pixel
          # takes (+places+, 0 for see-through, row by row), each of its +drawings+ (a colour for each
          # of its places, the first place first, nil for one it does not draw), and whether its
          # places must stay as they are (+fixed+).
          PictureColors = Data.define(:name, :width, :height, :places, :drawings, :fixed) do
            # How many places of its own it has.
            def place_count = places.max.to_i

            # The palettes Art makes of its drawings with no layout, four colours each, see-through
            # first: each in its own order, the backdrop in every slot it does not draw. None for a
            # picture of more colours than a palette holds, which Art refuses.
            def own_order_palettes
              return [] if place_count > SLOTS

              drawings.map { |drawing| [Art::BACKDROP, *Array.new(SLOTS) { |slot| drawing[slot] || Art::BACKDROP }] }
            end
          end

          # The tiles a palette is weighed as: the same share of the console's sprite tiles as one
          # palette is of its eight.
          TILES_PER_PALETTE = Art::MOST_SPRITE_TILES / Art::PALETTES

          # What laying a picture out one way costs: the tiles it cuts that none before it did, the
          # palettes it adds, and the free slots it fills. Compared as the class comment says: with
          # +tiles_per_palette+ a palette weighed as that many tiles, without it tiles first.
          Cost = Data.define(:new_tiles, :added_palettes, :filled_slots, :tiles_per_palette) do
            # The cost as the ways are compared by, the cheapest least.
            def sort_key
              return [new_tiles, added_palettes, filled_slots] unless tiles_per_palette

              [(added_palettes * tiles_per_palette) + new_tiles, filled_slots]
            end
          end

          # A picture's drawings laid out one way: the palettes then, the number of each drawing's
          # palette, the tiles it cuts that none before it did, and its Cost.
          Fit = Data.define(:palettes, :numbers, :tiles, :cost)

          # The layout for +pictures+ (PictureColors each) beside the +reserved+ palettes (four
          # colours each, see-through first) of the pictures that keep their own order, made as the
          # class comment says, or nil for every picture in its own order. +piece_height+ is
          # how tall the console draws a sprite's piece (Art#piece_height), which is how its tiles
          # are cut.
          def self.layout_for(pictures, reserved:, piece_height:)
            laid_out, apart = pictures.partition { |picture| picture.place_count.between?(1, SLOTS) }
            # A picture drawing nothing has a palette of the backdrop alone, which Art makes too.
            reserved = (reserved + apart.flat_map(&:own_order_palettes)).map { |colors| colors.drop(1) }.uniq
            own = new(laid_out, piece_height: piece_height, own_order: true)
            own_palettes = own.palette_count(reserved)
            if own_palettes > Art::PALETTES
              layout = new(laid_out, piece_height: piece_height, tiles_per_palette: TILES_PER_PALETTE)
              layout if layout.palette_count(reserved) <= Art::PALETTES
            else
              layout = new(laid_out, piece_height: piece_height)
              layout if layout.palette_count(reserved) < own_palettes && layout.tile_count <= own.tile_count
            end
          end

          # +pictures+ are each a PictureColors of no more colours than a palette holds. +own_order+
          # lays every picture out in its own order with the backdrop in every slot it does not draw,
          # as Art does where there is no layout, to count what that takes.
          def initialize(pictures, piece_height:, tiles_per_palette: nil, own_order: false)
            @piece_height = piece_height
            @tiles_per_palette = tiles_per_palette
            @own_order = own_order
            @order = {}      # a picture's name -> the slot each of its places takes, by place (0 is see-through)
            @palette_at = {} # [a picture's name, a palette by slot as it draws it] -> its number among @palettes
            @palettes = []   # each a colour for each slot, nil for one still free
            @tiles = Set.new # every tile cut so far, each as the first of its turnings
            pictures.each_with_index.sort_by { |picture, at| [-picture.place_count, -picture.drawings.length, at] }
                    .each { |picture, _| lay_out(picture) }
          end

          # How many palettes the layout and +reserved+ (three colours each, see-through left out) take.
          def palette_count(reserved) = (@palettes.map { |palette| palette.map { |color| color || Art::BACKDROP } } | reserved).length

          # How many tiles the layout cuts, a tile and its turnings counted once.
          def tile_count = @tiles.size

          # The slot each place of picture +name+ takes, by place, see-through at 0; nil for a picture
          # not laid out here, which keeps its own.
          def slot_order(name) = @order[name]

          # The palette picture +name+ is drawn in, four colours, when drawn as +slotted+: a colour for
          # each slot of the palette, see-through first, nil for a slot it does not draw. Nil for a
          # drawing not laid out here.
          def shared_palette(name, slotted)
            at = @palette_at[[name, slotted]]
            at && [Art::BACKDROP, *@palettes[at].map { |color| color || Art::BACKDROP }]
          end

          private

          def lay_out(picture)
            fits = slot_orders(picture).map { |way| [way, fit_drawings(picture, way)] }
            way, best = fits.each_with_index.min_by { |(_, fit), at| [*fit.cost.sort_key, at] }.first
            @palettes = best.palettes
            @tiles.merge(best.tiles)
            @order[picture.name] = [0, *way]
            picture.drawings.zip(best.numbers).each { |drawing, at| @palette_at[[picture.name, palette_by_slot(drawing, way)]] = at }
          end

          # Each way the picture's places can take slots, by place: its own order first.
          def slot_orders(picture)
            own = (1..picture.place_count).to_a
            return [own] if picture.fixed || @own_order

            [own, *(1..SLOTS).to_a.permutation(picture.place_count).reject { |way| way == own }]
          end

          # The picture laid out +way+ against the palettes and tiles made so far.
          def fit_drawings(picture, way)
            tiles = cut_tiles(picture, way).uniq.reject { |tile| @tiles.include?(tile) }
            palettes = @palettes.map(&:dup)
            added = filled = 0
            numbers = picture.drawings.map do |drawing|
              wanted = palette_by_slot(drawing, way).drop(1)
              wanted = wanted.map { |color| color || Art::BACKDROP } if @own_order
              at, fills = palettes.each_with_index.filter_map do |palette, number|
                fills = count_fills(palette, wanted)
                [number, fills] if fills
              end.min_by { |number, fills| [fills, number] }
              unless at
                palettes << Array.new(SLOTS)
                at = palettes.length - 1
                fills = 0
                added += 1
              end
              filled += fills
              wanted.each_with_index { |color, slot| palettes[at][slot] = color unless color.nil? }
              at
            end
            Fit.new(palettes: palettes, numbers: numbers, tiles: tiles,
                    cost: Cost.new(new_tiles: tiles.length, added_palettes: added, filled_slots: filled,
                                   tiles_per_palette: @tiles_per_palette))
          end

          # The picture's tiles with its places laid out +way+, as Art cuts them, each as the first of
          # the ways the console can turn it, since a tile turned is drawn from the same one.
          def cut_tiles(picture, way)
            slots = picture.places.map { |place| place.zero? ? 0 : way[place - 1] }
            SpritePieces.cut(picture.width, picture.height, piece_height: @piece_height) do |x, y|
              slots[(y * picture.width) + x]
            end.map { |_, _, tile| first_turning(tile) }
          end

          # The first of +tile+ as it is, mirrored, upside down and both, which every turning of it
          # shares.
          def first_turning(tile) = Art.turnings(tile).values.min

          # How many free slots of +palette+ the colours +wanted+ (by slot, nil for none) would fill,
          # or nil where a slot already holds another colour.
          def count_fills(palette, wanted)
            fills = 0
            wanted.each_with_index do |color, slot|
              next if color.nil?
              return nil unless palette[slot].nil? || palette[slot] == color

              fills += 1 if palette[slot].nil?
            end
            fills
          end

          # A drawing as a palette by slot, see-through first: each place's colour in the slot +way+
          # gives it, nil in a slot no place takes.
          def palette_by_slot(drawing, way)
            slots = Array.new(SLOTS + 1)
            drawing.each_with_index { |color, place| slots[way[place]] = color }
            slots
          end
        end
      end
    end
  end
end
