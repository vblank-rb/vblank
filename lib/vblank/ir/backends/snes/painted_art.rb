# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHAT A PAINTED SCREEN'S GAME PAINTS WITH, worked out while the game is built: its colours,
        # its pictures and text in the form Runtime::Paint copies them onto the screen, and the
        # rows it clears the screen with.
        #
        # THE COLOURS. A painted screen is one background of tiles whose pixels are eight bits each
        # (Runtime::Paint), so every pixel is one of 256 colours from one list, the console's colour
        # memory (CGRAM). Every colour the game can paint is known before it runs — each drawing
        # names its colours — so the list is made here, and the game paints a colour's place in it.
        # Place 0 is black: a pixel of place 0 is see-through on the console, and shows the colour
        # behind every layer, which is set to black too, the colour the screen starts in.
        #
        # A PICTURE is kept row by row, and each row as the tiles' rows it paints: a COLUMN of ten
        # bytes for every tile across it reaches — which of the tile's eight pixels the picture
        # draws (its MASK), twice, then the eight bits of their colours' places (its PLANES) in the
        # pairs a tile keeps them in (planes 0 and 1, 2 and 3...), leftmost pixel in the top bit, as
        # a tile of the console's keeps its pixels. So Runtime::Paint reads each 16-bit word ready to
        # write into a tile's row: the mask, then each pair of planes. A picture painted at a place
        # across that is not a multiple of eight falls across one tile more than its width, its
        # pixels shifted along; each row is kept already shifted for each place across modulo eight
        # it can be painted at, one RUN after the other, so the painting never shifts anything.
        #
        # THE RUNS KEPT. Eight runs a row is eight times the picture, so a picture keeps only the
        # runs for the places the game can paint it at (#paint_at, worked out by
        # Lowering::Paint.shifts_reachable): text written at one place keeps one run, a picture
        # whose place is worked out as the game runs keeps all eight. Each picture has a table of
        # where in a row each place's run starts (#run_starts), which the painting reads.
        class PaintedArt
          COLORS = 256
          BLACK = 0
          # The mask and the eight planes.
          ROWS_A_ROW = 9
          # A column's bytes: the mask twice, then the planes; and the places across modulo eight.
          COLUMN_BYTES = 10
          SHIFTS = 8

          # Raised when the game paints more colours than the console's colour memory holds.
          class TooMuch < LoweringError; end

          # One picture as Runtime::Paint reads it: its number, its size, how many tiles across a row
          # of it reaches (its bytes across, and one for a place off the tile edges), and the place
          # in the colour list of each pixel it draws ({[x, y] => place}).
          Picture = Data.define(:number, :width, :height, :across, :places) do
            # The bytes of one run of a row: a column for each tile across.
            def run_bytes = across * COLUMN_BYTES
          end

          attr_reader :pictures

          def initialize
            @colors = [BLACK]
            @places = { BLACK => 0 }
            @pictures = []
            @numbered = {}
            @shifts = {} # a picture's number -> the places across modulo eight it is painted at
          end

          # Says that picture +number+ is painted at the places across modulo eight +shifts+.
          def paint_at(number, shifts)
            @shifts[number] = (@shifts.fetch(number, []) | shifts).sort
          end

          # The places across modulo eight +picture+ keeps a run for: every one when nothing said
          # where it is painted, which is always right, only bigger.
          def shifts_kept(picture) = @shifts.fetch(picture.number, (0...SHIFTS).to_a)

          # Where each place across modulo eight's run starts in a row of +picture+, in bytes from the
          # row's start: eight words. A place the picture is never painted at reads its first run.
          def run_starts(picture)
            kept = shifts_kept(picture)
            Array.new(SHIFTS) { |shift| (kept.index(shift) || 0) * picture.run_bytes }
          end

          # +picture+'s rows, top to bottom, each its kept runs in order.
          def rows(picture)
            kept = shifts_kept(picture)
            Array.new(picture.height) do |y|
              kept.map do |shift|
                (0...picture.across).map { |column| column_bytes(picture, y, (column * 8) - shift) }.join
              end.join
            end
          end

          # The place of +color+ (15-bit) in the colour list, added there the first time.
          def place_of(color)
            @places[color] ||= begin
              refuse_too_many_colors! if @colors.length >= COLORS
              @colors << color
              @colors.length - 1
            end
          end

          def refuse_too_many_colors!
            raise TooMuch, "This game paints more than #{COLORS} different colours. A Super Nintendo shows " \
                           "#{COLORS} colours on a painted screen. To fix this, use fewer colours."
          end

          # The place of +color+ where place 0 may not stand for it: black, which is place 0, gets a
          # place of its own besides, the same black. The Super FX's PLOT leaves a pixel of place 0
          # as it was (Runtime::ChipColumns), so a picture it paints keeps place 0 for its
          # see-through pixels and paints its black from this other place.
          def place_never_nought(color)
            place = place_of(color)
            return place unless place.zero?

            @black_twin ||= begin
              refuse_too_many_colors! if @colors.length >= COLORS
              @colors << BLACK
              @colors.length - 1
            end
          end

          # The picture +key+ names, made once from a block that gives the picture's width, height and
          # the colour of each drawn pixel ({[x, y] => color}).
          def picture(key)
            @numbered[key] ||= begin
              width, height, drawn = yield
              made = make_picture(@pictures.length, width, height, drawn)
              @pictures << made
              made
            end
          end

          # A place of the colour list kept for one ink (Lowering::Paint#emit_draw_text): no other
          # colour is painted in it, so the colour it holds can change as the game runs. A picture
          # drawn with an Ink paints its place, not a colour's.
          Ink = Data.define(:place)

          # A new place of the colour list, holding +color+ (15-bit) at power-on.
          def ink(color)
            refuse_too_many_colors! if @colors.length >= COLORS
            @colors << color
            Ink.new(place: @colors.length - 1)
          end

          # How many places are left in the colour list.
          def places_left = COLORS - @colors.length

          # How many of the colour memory's colours the game paints in, from colour 0: the rest are
          # black and never painted with.
          def colors_painted = @colors.length

          # The colour list as the console's colour memory takes it: 256 colours, two bytes each.
          def cgram
            @colors.dup.fill(BLACK, @colors.length...COLORS).pack("v*")
          end

          private

          # The picture with its colours' places, given out now, top row first and left to right, so
          # the colour list is in the order the pictures are made whenever their rows are.
          def make_picture(number, width, height, drawn)
            places = {}
            height.times do |y|
              width.times do |x|
                color = drawn[[x, y]]
                places[[x, y]] = color.is_a?(Ink) ? color.place : place_of(color) unless color.nil?
              end
            end
            Picture.new(number: number, width: width, height: height, across: ((width + 7) / 8) + 1, places: places)
          end

          # The column of +picture+'s row +y+ whose eight pixels start at its pixel +left+ (which may
          # be off its left or right edge): the mask twice, then planes 0 to 7.
          def column_bytes(picture, y, left)
            planes = Array.new(ROWS_A_ROW, 0)
            8.times do |bit|
              place = picture.places[[left + bit, y]]
              next if place.nil?

              planes[0] |= 0x80 >> bit
              8.times { |plane| planes[plane + 1] |= 0x80 >> bit if place[plane] == 1 }
            end
            [planes[0], *planes].pack("C*")
          end
        end
      end
    end
  end
end
