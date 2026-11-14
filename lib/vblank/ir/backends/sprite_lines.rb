# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # HOW MANY SPRITES A LINE OF THE SCREEN SHOWS. A console that draws a sprite as pieces, each
      # an entry of its sprite table, reads the table again for every line of the screen as it draws
      # it, and has time for only so much of it on one line. Each console runs out its own way:
      #
      # - THE GAME BOY COLOR takes the first ten entries that cover the line, in the table's order,
      #   and leaves the rest out of THAT LINE ONLY. Each entry is one piece eight pixels wide.
      # - THE SUPER NINTENDO takes the first 32 entries that reach the line, then fetches their
      #   pictures in slivers eight pixels wide, starting from the entry it took LAST and each entry's
      #   slivers left to right, and has time for 34 slivers. A sliver off the screen is not fetched.
      #   So past 32 entries the ones furthest back go, and past 34 slivers the entries IN FRONT lose
      #   their right-hand slivers first.
      # - THE GENESIS takes the first 20 entries that reach the line, then draws them front-most
      #   first until it has drawn 320 pixels: each spends its whole width, its blank pixels and those
      #   off the screen too, and the one that crosses 320 is drawn only as far as the pixels left.
      #
      # So a crowd of sprites side by side loses a slice of some of them, one line high, exactly where
      # the crowd is, and the same sprite is whole a line further down where fewer stand beside it.
      # The table lists the sprite in front first.
      #
      # Every backend draws a console's sprites this way (Console::Description
      # #sprite_pieces_drawn_a_line, #sprite_slivers_drawn_a_line and #sprite_pixels_drawn_a_line say
      # how many, nil where none counts them), the interpreter and the runtimes that play a game as
      # that console alike, so all of them leave out the same slices the cartridge does. The pieces
      # are the console's own (#picture_places): blank ones are not in the table, so they take
      # nothing; a piece wholly off the screen is not written into it either, so it takes nothing;
      # any other piece takes its place on each line it covers whether or not that line has room left
      # to draw it.
      #
      # HOW MANY SPRITES THE SCREEN SHOWS. The table itself holds only so many entries (the Color's
      # forty, the Super Nintendo's 128, the Genesis's 80: #sprite_pieces_drawn_a_screen). The Color's
      # cartridge fills it front-most first with every piece on the screen — a piece wholly off any
      # edge is not written — so with more than that, the pieces furthest back find it full. The
      # Super Nintendo's and the Genesis's place the sprite furthest back first, so there it is the
      # pieces in front that find it full (#sprite_table_filled_from; measured in bsnes and Genesis
      # Plus GX). A piece that finds it full is drawn on no line at all, and takes no place on a line
      # either, since the table never holds it.
      module SpriteLines
        SLIVER = SpritePieces::SIZE

        # What a console draws of the entries on one line (Console::Description says each): how many
        # entries, and of those how many slivers or how many pixels, nil where it counts no such thing.
        Limit = Data.define(:pieces, :slivers, :pixels) do
          # The limit +console+ draws to, or nil where every backend draws every sprite on a line.
          def self.of(console)
            most = console.sprite_pieces_drawn_a_line or return nil

            new(pieces: most, slivers: console.sprite_slivers_drawn_a_line, pixels: console.sprite_pixels_drawn_a_line)
          end
        end

        # WHERE EACH PIECE OF A PICTURE STANDS IN IT, [across, down, width, height] in pixels, in the
        # order the table holds them, the first in front, as a console whose entries are +shape+
        # (Console::Description#sprite_piece_shape) cuts it.
        #
        # :small, the Color's: a picture made of pieces (Assets::Image#pieces) is those, put together as
        # +piece_height+ asks; any other is cut into squares, blank ones left out.
        #
        # :squares, the Super Nintendo's (SNES::Art): a picture made of pieces is those, 8×8 and 16×16
        # alike, blank ones left out; any other is cut into squares of 8×8, and each square of 16×16 on
        # its grid with two or more of them drawn is one entry instead. Its pieces go into the table
        # from its last row up, so the last of them is in front. Where the build has no room for a
        # square's tiles it keeps the four apart, which this cannot know: #pieces_built says so.
        #
        # :rectangles, the Genesis's (Genesis::Art): a picture made of a console's own pieces in groups
        # is those, a group where it makes one rectangle; any other is covered by rectangles of up to
        # four squares each way (SpritePieces.cover), the last of them in front.
        def self.picture_places(image, piece_height:, shape: :small)
          case shape
          when :small then small_picture_places(image, piece_height)
          when :squares then square_picture_places(image)
          when :rectangles then rectangle_picture_places(image)
          else raise ArgumentError, "#{shape.inspect} is not a shape of sprite pieces"
          end
        end

        # PIECES AS THE BUILD MADE THEM. #picture_places cuts a picture by the console's rule, but a
        # console's build can choose otherwise where the rule cannot see why: the Super Nintendo's
        # gives up squares of 16×16 for pieces of 8×8 where its video memory has no room for them,
        # for a picture, a crowded screen or the whole game, and cuts a copy drawn in other colours
        # (`draw_with`) again on its grid (SNES::Art). Its cartridge then counts those pieces on a
        # line and in its table, so the interpreter and the runtimes count them too.
        #
        # So +program+'s console's kit is asked for what its build made (Console::Kit
        # #sprite_pieces_built): by each [picture's name, the list of colours it is drawn with or
        # nil], its places as #picture_places gives them, the first in front; or nil where the
        # build cuts by the rule, or cannot build the game. Asked once a program (Program
        # #sprite_pieces_built_on), and a build that has just made them records them there.
        def self.pieces_built(program)
          console = program.described_console.name
          program.sprite_pieces_built_on(console) { Console.for(console).sprite_pieces_built(program) }
        end

        # The places of picture +name+ drawn in +colors+ (nil for its own) as the build made them
        # (#pieces_built), a copy the build made no pieces of of its own taking the picture's, or nil
        # where the build made none.
        def self.places_built(program, name, colors)
          built = pieces_built(program) or return nil

          built[[name, colors]] || built[[name, nil]]
        end

        # The pieces of a picture the game paints from a list as it runs: every one of its grid,
        # left to right and then down, since what it will show is not known while it is built. On a
        # console whose pieces go into the table from its last row up (the Super Nintendo's), the
        # last of them is in front.
        def self.painted_places(width, height, piece_height:, shape: :small)
          tall = shape == :small ? piece_height : SLIVER
          places = (0...height).step(tall).flat_map { |down| (0...width).step(SLIVER).map { |across| [across, down, SLIVER, tall] } }
          shape == :small ? places : places.reverse
        end

        # The pieces of a pose drawn from a set of sprite tiles ([across, down, tile] each).
        def self.tile_pose_places(pieces, piece_height:)
          placed = piece_height == SLIVER ? pieces : SpritePieces.paired_tiles(pieces)
          placed.map { |dx, dy, _| [dx, dy, SLIVER, piece_height] }
        end

        def self.small_picture_places(image, piece_height)
          if image.pieces
            stacked = SpritePieces.stacked(image.small_pieces.map { |dx, dy, own| [dx, dy, own.bytes] }, piece_height: piece_height)
            return stacked.reject { |_, _, piece| piece.all?(&:zero?) }.map { |dx, dy, _| [dx, dy, SLIVER, piece_height] }
          end

          SpritePieces.cut(image.width, image.height, piece_height: piece_height) do |x, y|
            image.drawn_at?((y * image.width) + x) ? 1 : 0
          end.map { |dx, dy, _| [dx, dy, SLIVER, piece_height] }
        end

        def self.square_picture_places(image)
          if image.pieces
            given = image.pieces.reject { |_, _, own| own.bytes.all?(&:zero?) }
            return given.map { |dx, dy, own| side = Assets::Image.side(own); [dx, dy, side, side] }
          end

          drawn = SpritePieces.cut(image.width, image.height) { |x, y| image.drawn_at?((y * image.width) + x) ? 1 : 0 }
                              .map { |dx, dy, _| [dx, dy] }
          squares = SpritePieces.big_squares(drawn, image.width, image.height, least: SpritePieces::BIG_LEAST_SQUARES)
          inside = squares.flat_map { |across, down| SpritePieces.big_square_quarters(across, down) }
          big = SpritePieces::BIG
          (squares.map { |across, down| [across, down, big, big] } +
            (drawn - inside).map { |across, down| [across, down, SLIVER, SLIVER] }).reverse
        end

        def self.rectangle_picture_places(image)
          most = SpritePieces::RECTANGLE_SQUARES
          if image.piece_groups
            return SpritePieces.group_rectangles(image, most: most).map do |dx, dy, columns, rows, _|
              [dx, dy, columns * SLIVER, rows * SLIVER]
            end
          end

          cover = SpritePieces.cover(image.width, image.height, most: most) { |x, y| image.drawn_at?((y * image.width) + x) ? 1 : 0 }
          cover.map { |block| [block.across, block.down, block.columns * SLIVER, block.rows * SLIVER] }.reverse
        end
        private_class_method :small_picture_places, :square_picture_places, :rectangle_picture_places

        # WHICH SLICES OF A FRAME'S SPRITES ARE LEFT OUT. +sprites+ are the frame's, front-most first
        # (the table's order), each [x, y, places] with places as #picture_places gives them. +limit+
        # is what a line draws (a Limit, or nil for no limit) and +table_entries+ how many the table
        # holds, nil for no limit. What comes back is one entry for each sprite: nil for one drawn
        # whole, or for one that loses a slice, by each line of the screen it loses one on, the pieces
        # of it that cover that line as [across, width, from]: the piece's columns from +from+ on are
        # left out (+width+ for none, 0 for all of it). A pixel of it is then left out where
        # #left_out_at? answers true.
        #
        # +table_from+ is the end of the table a console's cartridge fills first: :front, the Color's,
        # so a full table leaves out the pieces furthest back; :back, the Super Nintendo's and the
        # Genesis's, whose runtimes place the sprite furthest back first, so a full table leaves out
        # the pieces IN FRONT. +entry_reach+ is how far past the screen's left or top edge a piece
        # still takes an entry, where that is further than the piece's own width or height (#entry_reach).
        def self.left_out(sprites, limit:, screen_width:, screen_height:, table_entries: nil, table_from: :front, entry_reach: nil)
          pieces = sprites.each_with_index.flat_map do |(x, y, places), at|
            places.map { |across, down, wide, tall| [at, across, x + across, y + down, wide, tall] }
          end
          taking = pieces.select do |_, _, left, top, wide, tall|
            left > -[wide, entry_reach || 0].max && left < screen_width && top > -[tall, entry_reach || 0].max && top < screen_height
          end
          filled = table_from == :back ? taking.reverse : taking
          left_out_of_table = Set.new.compare_by_identity.merge(table_entries ? filled.drop(table_entries) : [])
          lines = Hash.new { |all, line| all[line] = [] }
          cuts = sprites.map { {} }
          taking.each do |piece|
            at, across, left, top, wide, tall = piece
            next unless left > -wide && top > -tall

            in_table = !left_out_of_table.include?(piece)
            (top.clamp(0, nil)...[top + tall, screen_height].min).each do |line|
              slot = [across, wide, in_table ? wide : 0]
              (cuts[at][line] ||= []) << slot
              lines[line] << [left, slot] if in_table
            end
          end
          lines.each_value { |on_line| limit_line(on_line, limit, screen_width) } if limit
          cuts.map do |covered|
            covered.select! { |_, on_line| on_line.any? { |_, wide, from| from < wide } }
            covered.empty? ? nil : covered
          end
        end

        # HOW FAR OFF THE SCREEN A PIECE STILL TAKES AN ENTRY of +program+'s table, past its left or
        # top edge, where that is further than its own width or height; nil where it is not. The Super
        # Nintendo's runtime asks every piece about a square's reach in a game with any square of
        # 16×16 (SNES::Runtime::Picture#emit_sprites), so there a piece of 8×8 up to 15 pixels off
        # the left or the top takes a row and draws nothing (measured in bsnes). Such a game is one
        # whose sprites show a picture cut with one (SNES::Art#sprite_squares?), as its build made
        # them where it says (#pieces_built).
        def self.entry_reach(program, piece_height:)
          return nil unless program.described_console.sprite_piece_shape == :squares

          built = pieces_built(program)
          return (SpritePieces::BIG if built.each_value.any? { |places| places.any? { |_, _, wide, _| wide == SpritePieces::BIG } }) if built

          pictures = program.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node] }
          poses = program.walk.select { |node| node.kind == :object }.flat_map(&:poses).uniq
          squares = poses.any? do |name|
            node = pictures[name] or next false
            picture_places(Assets::Image.of(node), piece_height: piece_height, shape: :squares).any? { |_, _, wide, _| wide == SpritePieces::BIG }
          end
          SpritePieces::BIG if squares
        end

        # One line's entries, front-most first, each [left on the screen, its slot], held to +limit+:
        # each slot's +from+ set where the line leaves some of it out.
        def self.limit_line(pieces, limit, screen_width)
          kept = pieces.first(limit.pieces)
          pieces.drop(limit.pieces).each { |_, slot| slot[2] = 0 }
          limit_slivers(kept, limit.slivers, screen_width) if limit.slivers
          limit_pixels(kept, limit.pixels) if limit.pixels
        end

        # The Super Nintendo's: slivers fetched from the entry furthest back, each entry's left to
        # right, those on the screen counted until +most+; the rest of an entry from the first not
        # fetched is left out.
        def self.limit_slivers(kept, most, screen_width)
          fetched = 0
          kept.reverse_each do |left, slot|
            (0...slot[1]).step(SLIVER) do |offset|
              sliver = left + offset
              next unless sliver > -SLIVER && sliver < screen_width

              if fetched == most
                slot[2] = offset
                break
              end
              fetched += 1
            end
          end
        end

        # The Genesis's: entries drawn front-most first, each spending its whole width, until +most+
        # pixels; the entry that crosses it keeps the pixels left, from its left edge.
        def self.limit_pixels(kept, most)
          spent = 0
          kept.each do |_, slot|
            wide = slot[1]
            slot[2] = (most - spent).clamp(0, wide) if spent + wide > most
            spent += wide
          end
        end
        private_class_method :limit_line, :limit_slivers, :limit_pixels

        # Is column +col+ of a sprite's picture left out on screen line +line+? It is where a piece
        # covering it is left out there, and no piece drawn there covers it.
        def self.left_out_at?(lines, col, line)
          pieces = lines[line] or return false
          covering = pieces.select { |across, wide, _| col >= across && col < across + wide }
          !covering.empty? && covering.all? { |across, _, from| col - across >= from }
        end
      end
    end
  end
end
