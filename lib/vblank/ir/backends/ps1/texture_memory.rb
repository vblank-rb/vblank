# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # THE PART OF VIDEO RAM BESIDE THE SCREEN'S PAGES, and the textures and colour tables kept there:
        # what the graphics chip reads a picture from. Anything the chip draws as a texture (a painted
        # picture's pieces, a word of text, a wall of a place) is added here while the program is built,
        # and once the last is added every one is given its depth, its colour table and its place.
        #
        # A TEXTURE IS READ THROUGH A TEXTURE PAGE: a window of video RAM 256 texels square, whose left
        # edge is a multiple of 64 halfwords (video RAM's 16-bit cells) and whose top is line 0 or 256. A
        # texel is named by a byte across (u) and a byte down (v) from the page's corner. How many texels a
        # halfword holds is the page's depth:
        #
        #   4 bits   four texels a halfword, each a number into a colour table of 16 (a CLUT)
        #   8 bits   two texels a halfword, each a number into a colour table of 256
        #   15 bits  one texel a halfword, the colour itself
        #
        # So a texture of 16 colours or fewer takes a quarter of the room it would at 15 bits, and one of
        # 256 or fewer half: each gets the smallest depth its colours allow. A colour table is a row of
        # video RAM, 16 or 256 halfwords long, starting at a multiple of 16 across; textures whose colours
        # together fit in one table share it, so a game's words in one colour, say, all read the same
        # sixteen entries.
        #
        # SEE-THROUGH AND BLACK. The chip leaves undrawn a texel whose colour is 0000h, whether it is in
        # the texture or in its table. So a pixel the picture leaves see-through is an entry of 0000h, and
        # every colour has its top bit set (Console::PS1Hardware::TEXEL_DRAWN): black is 8000h, drawn
        # black. The picture shown is read with the top bit dropped, as the television shows it.
        #
        # WHERE THEY GO. Textures go right of the screen's pages (from column 320, the whole height of
        # video RAM), in shelves: the tallest first, each shelf as tall as its first texture, a texture
        # never crossing line 256 and never running past the end of the page it starts in. Colour tables
        # go in the rows under each page (lines 240 to 255 and 496 to 511, which no picture is drawn in),
        # the tables of 256 first, one to a row, and those of 16 in what is left. Once those rows are full,
        # a texture that would need another table is kept at 15 bits instead.
        class TextureMemory
          h = Console::PS1Hardware
          PAGE_TEXELS = 256
          PAGE_STEP_HALFWORDS = 64
          FIRST_TEXTURE_COLUMN = h::SCREEN_WIDTH
          # The rows colour tables go in: the 16 under each page, which the screen never shows.
          TABLE_LINES = [*h::SCREEN_HEIGHT...PAGE_TEXELS, *(PAGE_TEXELS + h::SCREEN_HEIGHT)...h::VRAM_HEIGHT].freeze
          TABLE_ROW_HALFWORDS = h::SCREEN_WIDTH
          TABLE_STEP_HALFWORDS = 16
          # The draw mode's depth bits (7 and 8) for each depth, and how many texels a halfword holds.
          DEPTH_BITS = { 4 => 0 << 7, 8 => 1 << 7, 15 => h::TEXTURE_15_BIT }.freeze
          TEXELS_A_HALFWORD = { 4 => 4, 8 => 2, 15 => 1 }.freeze
          # How many colours a table of each depth holds.
          TABLE_COLORS = { 4 => 16, 8 => 256 }.freeze

          # Raised when the textures need more video RAM than there is.
          class Full < LoweringError; end

          # A colour table: its entries (each a colour as the chip reads it, 0000h the see-through one), how
          # many it may hold, and once placed, where it is.
          Table = Struct.new(:entries, :capacity, :x, :y) do
            # The chip's name for where it is, as a textured command takes it: x / 16, and y from bit 6.
            def field = (x / TABLE_STEP_HALFWORDS) | (y << 6)

            def index_of(entry) = entries.index(entry)
          end

          # One texture: its size in texels, its texels row by row (each a colour as the chip reads it), and
          # once allocated, its depth, its colour table (none at 15 bits) and its place in video RAM, in
          # halfwords across and lines down.
          Texture = Struct.new(:width, :height, :texels, :aligned, :depth, :table, :x, :y) do
            def colors = texels.uniq

            # How many halfwords across one row of it takes.
            def width_halfwords = (width + TEXELS_A_HALFWORD.fetch(depth) - 1) / TEXELS_A_HALFWORD.fetch(depth)

            # Whether +column+ and +line+ suit it: for an aligned texture, where in its page it starts must
            # be a multiple of its width across and of its height down.
            def aligned_at?(column, line)
              return true unless aligned

              (u_at(column) % width).zero? && ((line % PAGE_TEXELS) % height).zero?
            end

            # The draw mode (GP0 E1h) naming its texture page and its depth.
            def draw_mode
              h = Console::PS1Hardware
              h::GP0_DRAW_MODE | (x / PAGE_STEP_HALFWORDS) | ((y / PAGE_TEXELS) << 4) | DEPTH_BITS.fetch(depth) |
                h::DRAW_ON_SHOWN_PICTURE
            end

            # The word a textured command takes after its corner: the colour table << 16 | v << 8 | u, where
            # in its page the texture starts.
            def texture_corner = ((table ? table.field : 0) << 16) | ((y % PAGE_TEXELS) << 8) | u_at(x)

            # The texel across its page (u) that the halfword column +column+ is.
            def u_at(column) = (column % PAGE_STEP_HALFWORDS) * TEXELS_A_HALFWORD.fetch(depth)

            # Whether it ends inside both video RAM and the page it starts in, placed at +column+.
            def fits_at?(column)
              u_at(column) + width <= PAGE_TEXELS && column + width_halfwords <= Console::PS1Hardware::VRAM_WIDTH
            end

            # Its halfwords row by row, as video RAM holds them: at 4 and 8 bits each texel's number in its
            # table, the leftmost in the low bits, and a row's last halfword filled out with nought.
            def halfwords
              return texels if depth == 15

              texels_a_halfword = TEXELS_A_HALFWORD.fetch(depth)
              bits_a_texel = 16 / texels_a_halfword
              index_by_texel = table.entries.each_with_index.to_h
              texels.each_slice(width).flat_map do |row|
                row.each_slice(texels_a_halfword).map do |group|
                  group.each_with_index.sum { |texel, i| index_by_texel.fetch(texel) << (bits_a_texel * i) }
                end
              end
            end
          end

          # One copy into video RAM at power-on: where it goes, its size in halfwords and lines, and its
          # halfwords two to a word, the left one in the low half, as the chip's copy takes them.
          Upload = Data.define(:x, :y, :width, :height, :words)

          # A row of textures: its top line, how tall it is, and the first column still free.
          Shelf = Data.define(:top_line, :height, :free_column) do
            # The column +texture+ can start at on this shelf: the free column, or the next page's edge
            # when the texture would run past the end of the page the free column is in; nil when it fits
            # at neither, or is taller than the shelf.
            def column_for(texture)
              return nil if texture.height > height

              candidates = [free_column, ((free_column / PAGE_STEP_HALFWORDS) + 1) * PAGE_STEP_HALFWORDS]
              candidates.insert(1, aligned_column(texture)) if texture.aligned
              candidates.find { |column| texture.fits_at?(column) && texture.aligned_at?(column, top_line) }
            end

            # The first column from the free one where an aligned +texture+ starts at a multiple of its
            # width in its page.
            def aligned_column(texture)
              step = [texture.width / TEXELS_A_HALFWORD.fetch(texture.depth), PAGE_STEP_HALFWORDS].min
              ((free_column + step - 1) / step) * step
            end
          end

          # A colour as a texel holds it: 0000h for nil (see-through), any other with its top bit set.
          def self.texel_for_color(color) = color.nil? ? 0 : (color & 0x7FFF) | Console::PS1Hardware::TEXEL_DRAWN

          attr_reader :textures, :tables

          def initialize
            @textures = []
            @tables = []
            @first_column = FIRST_TEXTURE_COLUMN
            @extra_uploads = []
          end

          # PLANES: pictures of 15-bit colour each one or more whole texture pages, kept right of the screen's
          # pages before any texture, in a grid of PLANE_UNITS_ACROSS × PLANE_UNITS_DOWN pages (lines 0 and
          # 256): +sizes+ is each one's [width, height], 256 or 512 each way. The biggest are placed first, each
          # at the first free pages it fits. Returns each one's place (Plane), in the order given, or nil when
          # they do not all fit; and moves the textures along past the columns of pages they take. Called
          # once, before #allocate!.
          PLANE_SIDE = PAGE_TEXELS
          PLANE_UNITS_ACROSS = 2
          PLANE_UNITS_DOWN = Console::PS1Hardware::VRAM_HEIGHT / PAGE_TEXELS

          # A plane's corner in video RAM, and its size, in halfwords and lines.
          Plane = Data.define(:x, :y, :width, :height)

          def reserve_planes(sizes)
            taken = {}
            places = {}
            sizes.each_with_index.sort_by { |(width, height), i| [-(width * height), i] }.each do |(width, height), i|
              across = width / PLANE_SIDE
              down = height / PLANE_SIDE
              spot = (0...PLANE_UNITS_ACROSS).to_a.product((0...PLANE_UNITS_DOWN).to_a).find do |column, row|
                units = (column...(column + across)).to_a.product((row...(row + down)).to_a)
                column + across <= PLANE_UNITS_ACROSS && row + down <= PLANE_UNITS_DOWN && units.none? { |unit| taken[unit] }
              end
              return nil unless spot

              column, row = spot
              (column...(column + across)).to_a.product((row...(row + down)).to_a).each { |unit| taken[unit] = true }
              places[i] = Plane.new(x: FIRST_TEXTURE_COLUMN + (column * PLANE_SIDE), y: row * PLANE_SIDE, width: width, height: height)
            end
            columns = taken.keys.map(&:first).max.to_i + (taken.empty? ? 0 : 1)
            @first_column = FIRST_TEXTURE_COLUMN + (columns * PLANE_SIDE)
            Array.new(sizes.length) { |i| places.fetch(i) }
          end

          # +halfwords+ columns of video RAM, its whole height, kept for something only ever copied from (a sheet
          # of tiles), past whatever is kept already and before any texture. Returns the first column. Called
          # before #allocate!, after #reserve_planes.
          def reserve_columns(halfwords)
            @first_column.tap { @first_column += halfwords }
          end

          # One more copy into video RAM at power-on, of something not a texture: +halfwords+ row by row.
          def add_upload(x:, y:, width:, height:, halfwords:)
            @extra_uploads << upload(x, y, width, height, halfwords)
          end

          # A texture of +width+ × +height+ texels, from +colors+ row by row (a 15-bit colour, or nil where it
          # is see-through), to be given its depth, its table and its place by #allocate!. A texture is read
          # from one page, so it is at most a page across and down.
          #
          # ALIGNED (+align:+ true), it is placed where its page's u and v are multiples of its width and
          # height, which must be powers of two: then the chip's texture window (GP0 E2h) can repeat it
          # across a shape larger than itself, as a face of a place repeats its picture like wallpaper.
          #
          # +colors_kept+ keeps it at 15 bits, its colours themselves and no table: a tile copied into a plane
          # (Runtime::Tiles) is copied halfword for halfword, so it must be held as the plane holds its pixels.
          def add_texture(width:, height:, colors:, align: false, colors_kept: false)
            unless width.between?(1, PAGE_TEXELS) && height.between?(1, PAGE_TEXELS) && colors.length == width * height
              raise ArgumentError, "a texture is 1 to #{PAGE_TEXELS} texels each way, a colour for each; not #{width} × #{height} " \
                                   "with #{colors.length}"
            end
            if align && ![width, height].all? { |side| (side & (side - 1)).zero? }
              raise ArgumentError, "an aligned texture's sides are powers of two; not #{width} × #{height}"
            end

            Texture.new(width: width, height: height, texels: colors.map { |color| TextureMemory.texel_for_color(color) },
                        aligned: align, depth: (15 if colors_kept)).tap { |texture| @textures << texture }
          end

          # Every texture given its depth, its colour table and its place, and every table its place. Called
          # once, after the last texture is added.
          def allocate!
            share_tables
            place_tables
            place_textures
          end

          # What is copied into video RAM at power-on: every texture, then every colour table, then the rest
          # (#add_upload).
          def uploads
            textures.map { |texture| upload(texture.x, texture.y, texture.width_halfwords, texture.height, texture.halfwords) } +
              tables.map { |table| upload(table.x, table.y, table.capacity, 1, Array.new(table.capacity) { |i| table.entries[i] || 0 }) } +
              @extra_uploads
          end

          # How many halfwords of video RAM the textures and tables take.
          def halfwords_used = uploads.sum { |one| one.width * one.height }

          private

          def upload(x, y, width, height, halfwords)
            Upload.new(x: x, y: y, width: width, height: height,
                       words: halfwords.each_slice(2).map { |low, high| low | ((high || 0) << 16) })
          end

          # Each texture its depth, the smallest its colours allow, and a table: the first already made
          # with room for its colours, or a new one. See-through counts as one of the colours, since it is
          # an entry of the table. The textures of most colours are given tables first, so the ones of few
          # colours fit in theirs. When the rows for tables are full, a texture that needs a new one keeps
          # its colours themselves, at 15 bits: more room, but no table.
          def share_tables
            textures.reject(&:depth).sort_by { |texture| -texture.colors.length }.each do |texture|
              colors = texture.colors
              capacity = TABLE_COLORS.values.find { |most| colors.length <= most }
              texture.table = capacity && find_or_add_table(colors, capacity)
              texture.depth = texture.table ? TABLE_COLORS.key(capacity) : 15
            end
          end

          # The first table of +capacity+ entries with room for +colors+, or a new one, given them; nil when
          # a new one is needed and the rows for tables have no room left for it.
          def find_or_add_table(colors, capacity)
            table = tables.find { |one| one.capacity == capacity && (one.entries | colors).length <= capacity }
            unless table
              return nil unless room_for_table?(capacity)

              table = Table.new(entries: [], capacity: capacity).tap { |one| tables << one }
            end
            table.entries |= colors
            table
          end

          # Whether one more table of +capacity+ fits in the rows for tables, beside those already made: a
          # row holds one table of 256 and TABLE_ROW_HALFWORDS left for tables of 16 (#place_tables).
          def room_for_table?(capacity)
            large = tables.count { |table| table.capacity == TABLE_COLORS.fetch(8) }
            small = tables.length - large
            large += 1 if capacity == TABLE_COLORS.fetch(8)
            small += 1 if capacity == TABLE_COLORS.fetch(4)
            large <= TABLE_LINES.length && small <= small_table_slots(large).length
          end

          # Where the tables of 16 can go, [column, line] each, once +large+ tables of 256 have a row each.
          def small_table_slots(large)
            TABLE_LINES.each_with_index.flat_map do |line, row|
              first = row < large ? TABLE_COLORS.fetch(8) : 0
              (first...TABLE_ROW_HALFWORDS).step(TABLE_STEP_HALFWORDS).map { |column| [column, line] }
            end
          end

          # The tables of 256 one to a row from the left; then the tables of 16 in the room left in every row.
          # #find_or_add_table made no more than these rows hold.
          def place_tables
            large, small = tables.partition { |table| table.capacity == TABLE_COLORS.fetch(8) }
            large.zip(TABLE_LINES) { |table, line| table.x, table.y = 0, line }
            small.zip(small_table_slots(large.length)) { |table, (column, line)| table.x, table.y = column, line }
          end

          def place_textures
            shelves = []
            textures.sort_by { |texture| -texture.height }.each { |texture| place_texture(texture, shelves) }
          end

          # A texture goes on the first shelf it fits, or on a new shelf under the last in either half of
          # video RAM.
          def place_texture(texture, shelves)
            at = shelves.index { |shelf| shelf.column_for(texture) }
            unless at
              add_shelf(texture, shelves) or raise Full, full_message
              at = shelves.length - 1
            end
            shelf = shelves[at]
            texture.x = shelf.column_for(texture)
            texture.y = shelf.top_line
            shelves[at] = shelf.with(free_column: texture.x + texture.width_halfwords)
          end

          # A new shelf as tall as +texture+, added to +shelves+ under the last in the first half of video
          # RAM with room for it; nil when neither half has.
          def add_shelf(texture, shelves)
            [0, PAGE_TEXELS].each do |half|
              in_half = shelves.select { |shelf| shelf.top_line >= half && shelf.top_line < half + PAGE_TEXELS }
              top = in_half.map { |shelf| shelf.top_line + shelf.height }.max || half
              top = half + ((top - half + texture.height - 1) / texture.height * texture.height) if texture.aligned
              next if top + texture.height > half + PAGE_TEXELS

              return Shelf.new(top_line: top, height: texture.height, free_column: @first_column).tap { |shelf| shelves << shelf }
            end
            nil
          end

          def full_message
            "The pictures and words of this game need more video memory than the PlayStation has beside the " \
              "screen. A picture with 16 colours or fewer uses the least memory. A picture with more than 256 " \
              "colours uses the most. To fix this, use fewer pictures, smaller pictures, or fewer colours in each picture."
          end
        end
      end
    end
  end
end
