# frozen_string_literal: true

module VBlank
  class Builder
    # The bitmap drawing verbs: pick a screen mode, then put color on the screen —
    # single pixels, filled rectangles (fixed or run-time positioned), a whole-screen
    # clear. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    #
    # The screen's size is the console's the game is built for (Builder#console), never one
    # console's numbers written here.
    module Drawing
      # The screens {#screen} knows by name: a pixel canvas, tile and sprite layers (most
      # games), and one background that turns and resizes with no scrolling ones. How each is
      # set up on a console is its lowering's business. The tear-proof double-buffered screen
      # isn't a separate name here: it's `screen :bitmap, tear_free: true`.
      SCREEN_NAMES = %i[bitmap tiled rotozoom].freeze

      # HOW BIG THE SCREEN IS, in pixels: 240 across and 160 down on a Game Boy Advance, 160 and
      # 144 on a Game Boy Color. A game written for both lays itself out from these rather than
      # from numbers for one screen, so the same block builds for either (see `consoles:` on
      # `VBlank.game`):
      #
      #   paddle_x = screen_width - 12
      #   draw_text "PONG", :center, screen_height / 4, :white
      #
      # On a screen of big pixels (`screen :bitmap, pixel_size: 2`) these are the small picture's
      # size, which is what the game draws in.
      def screen_width
        @screen_size_read = :screen_width
        console.screen_width
      end

      # See #screen_width.
      def screen_height
        @screen_size_read = :screen_height
        console.screen_height
      end

      # Choose what kind of screen you're drawing on.
      #
      # @param mode [Symbol, Integer] a friendly name or raw REG_DISPCNT value
      #
      # @example Friendly
      #   screen :bitmap          # a pixel canvas
      #   screen :tiled           # tile/sprite layers
      #
      # HOW MANY TILE LAYERS `screen :tiled` HAS IS NOT FIXED, and nothing in a program
      # names which arrangement it wants. The console lays its tile layers out two ways:
      # four that scroll, or two that scroll plus one that turns and resizes. A game gets
      # the second exactly when it turns a background (`background(...).rotate` /
      # `.scale`), because turning one IS asking for it — so the build reads the
      # arrangement off what was declared rather than off a name written here. Declaring
      # more scrolling layers than the arrangement holds is a friendly error naming both
      # counts, never a layer quietly left undrawn. See {Backends::GBA::Drawing#tiled_dispcnt}.
      #
      # @example Raw (full control, the Advance's display register written as it is)
      #   hw = VBlank::Console::Hardware
      #   screen hw::MODE_3 | hw::BG2_ENABLE | hw::OBJ_ENABLE
      #
      # Pass +tear_free: true+ to make `screen :bitmap` tear-proof: the framework
      # draws each frame to a hidden screen and shows it all at once, so the picture
      # can never tear no matter how much you draw. It costs some color range (a
      # 256-color palette built automatically from the colors you use), so it's
      # opt-in; plain `screen :bitmap` stays direct-color. (Under the hood this is
      # double buffering, which the IR and backend call "buffered".)
      #
      # @example Tear-proof
      #   screen :bitmap, tear_free: true
      #
      # Pass +colors:+ to set which colors the screen shows, instead of letting the
      # framework work them out from the ones you name. You want this only when your
      # pictures come from somewhere that already decided — art imported from another
      # game or a paint program, whose pixels are numbers that pick out of ITS table.
      # Give the colors in that table's order and the pictures line up. Everything
      # else is unchanged: you still write color names, and you never write a slot
      # number. A color you draw with that is not in the list is a friendly error.
      #
      # @example Colors that came with the art
      #   screen :bitmap, tear_free: true, colors: imported.colors
      #
      # Pass +late:+ to choose what the tear-free screen does with a page the game finished too
      # late for the break between pictures it was meant for. By default (+:wait+) it waits for
      # the next break, so it never tears — but a frame a little late then costs a whole frame,
      # and a game at sixty drops to thirty for it. +:show_now+ shows such a page as soon as
      # it is done, which can tear on those frames. A row number (0 to 159) shows it at once
      # only while the screen is still drawing above that row, where a tear is least seen, and
      # waits otherwise. A late page finished during the break itself is shown at once by
      # either, since nothing is being drawn then. Set per `screen`, so a scene can allow it while the
      # game plays and forbid it on a menu. `rom.profile` counts the pages it showed at once.
      #
      # +pace:+ sets what LATE means: the pictures a second the game aims for — 60 (the
      # default), 30, 20 or 15. A page is late when it misses the break that rate aims at. A
      # game that runs at thirty and sets `pace: 30` shows at once only the pages that ran
      # over thirty, and the ones on time at thirty wait as they always did.
      #
      # @example A late page shown at once, if the tear is in the top quarter
      #   screen :bitmap, tear_free: true, late: 40
      # @example A game at thirty that does not drop to twenty on a heavy frame
      #   screen :bitmap, tear_free: true, late: :show_now, pace: 30
      #
      # +backdrop:+ is the colour shown wherever nothing is drawn. It is a colour, or the name of
      # a `colors` list, which the backdrop then follows: whatever the game tells the list to hold
      # with `recolor`, the backdrop shows its first colour (+backdrop_place:+ picks another),
      # on the same frame as everything else drawn with the list. That is how a console game's
      # own fade takes the backdrop with the picture (see ColorLists#followed_backdrop_list).
      #
      # @example A backdrop that fades with the picture
      #   colors :screen_colors, [:navy, :white, :gray]
      #   screen :tiled, backdrop: :screen_colors
      #   recolor :screen_colors, color_walk(:screen_colors, from: :black), showing: step
      #
      # +backdrop:+ also takes a slot of colours of the data pack, or one bank of it, and is then
      # the colour the slot holds first (+backdrop_place:+ picks another): the colour the original's
      # own screen shows wherever none of its tiles draws (see DataPacks#pack_backdrop_color). It
      # is a colour like one written in the game, so a scene's own `screen` line takes it. A build
      # that reads its pack as the game starts reads the colour then
      # (DataPacks#pack_backdrop_in_start_file).
      #
      # @example A scene whose backdrop is the first colour its original loaded
      #   scene(:logos) do
      #     screen :tiled, backdrop: pack[:logo_colors]
      #     background :logos, tiles: pack[:logo_video], map: pack[:logo_map], colors: pack[:logo_colors], across: 32
      #   end
      #
      # +pixel_size: 2+ shows each pixel of a painted screen twice as wide and twice as tall: the
      # game draws a picture half the screen's width and height, and the console shows it filling
      # the screen. Everything the game draws costs a quarter of what it did — the old games that
      # drew a first-person view did this for speed — at a chunkier look. `screen_width` and
      # `screen_height` answer the small picture's size, and every verb draws in its pixels. It is
      # the whole game's, so it goes on the game's first `screen` line, before anything reads the
      # screen's size; every later screen is a painted one too.
      #
      # @example A first-person view drawn at half size
      #   screen :bitmap, tear_free: true, pixel_size: 2
      #
      # +shown_rows:+ gives up the rows of a painted screen outside a range: the picture stops
      # early, and those rows show black whatever is painted there. A console that can copy to its
      # video memory only while it is not drawing has those rows to copy in as well as the gap
      # between pictures, so a picture that changes a lot each pass arrives sooner. It is the whole
      # game's, so it goes on the game's first `screen` line, and every later screen is a painted one.
      #
      # @example A view 160 rows high, with more time each frame to send it
      #   screen :bitmap, shown_rows: 32...192
      def screen(mode, tear_free: false, colors: nil, late: :wait, pace: 60, backdrop: nil, backdrop_place: nil,
                 pixel_size: 1, shown_rows: nil)
        case mode
        when Symbol
          unless SCREEN_NAMES.include?(mode)
            raise ArgumentError, "unknown screen mode: #{mode}. Known: #{SCREEN_NAMES.join(', ')}"
          end
        when Integer
          # a raw REG_DISPCNT value — passed through untouched
        else
          raise ArgumentError,
                "screen needs a Symbol (a name like :bitmap) or an Integer (a raw register value). " \
                "Got #{mode.class}."
        end

        if tear_free && mode != :bitmap
          raise ArgumentError,
                "tear_free: true works only with `screen :bitmap`. It enables the tear-proof " \
                "double-buffered screen. #{mode.inspect} does not support it."
        end

        # Remember the mode by name so `sprite` knows which kind to make (a bitmap
        # screen draws sprites in software; a tiled screen uses the console's sprite
        # hardware). A raw register value doesn't map to a friendly name, so it leaves
        # the mode unnamed.
        size_said = apply_pixel_size!(pixel_size, mode)
        rows_kept = apply_shown_rows!(shown_rows, mode)
        @screen_line_written = true
        @screen_mode = mode if mode.is_a?(Symbol)
        @tear_free = tear_free
        late_rows = resolve_late_pages(late, tear_free)
        if backdrop.is_a?(DSL::PackSlot)
          refuse_backdrop_on_painted_screen!(mode)
          # A build that leaves its pack out keeps where the colour is in the pack, not the colour.
          backdrop_from_file = (pack_backdrop_in_start_file(backdrop, backdrop_place) if pack_left_out?)
          backdrop = backdrop_from_file ? nil : pack_backdrop_color(backdrop, backdrop_place)
          backdrop_place = nil
        end
        followed = followed_backdrop_list(backdrop, backdrop_place, mode)
        node = record(Build.screen(mode, buffered: tear_free, colors: resolve_screen_colors(colors, tear_free),
                                         late: late_rows, late_pace: resolve_late_pace(pace, late_rows),
                                         backdrop: followed ? followed.color : resolve_backdrop(backdrop, mode),
                                         pixel_size: size_said, backdrop_from_file: backdrop_from_file,
                                         shown_rows: rows_kept))
        @backdrop_list = followed.with(screen: node) if followed
        node
      end

      # SETS THE GAME'S PIXEL SIZE on the program and the builder's console, and returns it as the
      # screen node keeps it: nil for one. It is the whole game's, so it is set once, on the game's
      # first screen line, and the program carries it (Program#pixel_size). From that line on the
      # builder lays the game out on the small screen the console description then answers, which
      # is why nothing may have read the screen's size before it.
      private def apply_pixel_size!(size, mode)
        refuse_unpainted_screen_with_big_pixels!(mode) if @program.pixel_size
        return nil if size == 1

        unless Console::Description::PIXEL_SIZES.include?(size)
          raise ArgumentError, "`pixel_size: #{size.inspect}` is not a size the screen can show. Use 1 (the " \
                               "default) or 2."
        end
        unless mode == :bitmap
          raise ArgumentError, "`pixel_size: #{size}` works only with `screen :bitmap`. A screen of tiles cannot " \
                               "show its pixels bigger. To fix this, write `screen :bitmap, pixel_size: #{size}`."
        end
        if @screen_line_written || @building_scene
          raise ArgumentError, "`pixel_size: #{size}` must be on the game's first `screen` line, outside any " \
                               "scene. It sets the size of the screen for the whole game. To fix this, move " \
                               "pixel_size: to that line."
        end
        if @screen_size_read
          raise ArgumentError, "The game reads `#{@screen_size_read}` before `screen :bitmap, pixel_size: #{size}`. " \
                               "pixel_size: makes the screen smaller, so the size that the game read is wrong. To " \
                               "fix this, put the `screen` line first."
        end

        @program.pixel_size = size
        @console = @program.described_console
        size
      end

      # SETS THE ROWS THE GAME'S PICTURE SHOWS on the program, and returns them as the screen node
      # keeps them: [first, past], or nil for every row. Like the pixel size it is the whole game's,
      # set once on the game's first screen line (Program#shown_rows).
      private def apply_shown_rows!(rows, mode)
        refuse_unpainted_screen_with_shown_rows!(mode) if @program.shown_rows
        return nil if rows.nil?

        height = console.screen_height
        unless rows.is_a?(Range) && rows.begin.is_a?(Integer) && rows.end.is_a?(Integer)
          raise ArgumentError, "`shown_rows: #{rows.inspect}` is not a range of rows. To fix this, give the first " \
                               "row and the row after the last, like `shown_rows: 32...192`."
        end
        first = rows.begin
        past = rows.exclude_end? ? rows.end : rows.end + 1
        if first.negative? || past > height
          raise ArgumentError, "`shown_rows: #{rows.inspect}` goes past the screen. The screen has rows 0 to " \
                               "#{height - 1} (#{height} rows). To fix this, keep the range inside them."
        end
        if past <= first
          raise ArgumentError, "`shown_rows: #{rows.inspect}` shows no row. To fix this, give a range that holds " \
                               "one row or more, like `shown_rows: 32...192`."
        end
        unless mode == :bitmap
          raise ArgumentError, "`shown_rows:` works only with `screen :bitmap`. To fix this, write " \
                               "`screen :bitmap, shown_rows: #{rows.inspect}`."
        end
        if @program.pixel_size
          raise ArgumentError, "`shown_rows:` does not work with `pixel_size: #{@program.pixel_size}`. No console " \
                               "that gives up rows shows big pixels. To fix this, remove one of the two."
        end
        if @screen_line_written || @building_scene
          raise ArgumentError, "`shown_rows:` must be on the game's first `screen` line, outside any scene. It " \
                               "sets the rows of the screen for the whole game. To fix this, move shown_rows: " \
                               "to that line."
        end
        return nil if first.zero? && past == height

        @program.shown_rows = [first, past]
      end

      # A game that gives up rows shows every one of its screens through the painted screen.
      private def refuse_unpainted_screen_with_shown_rows!(mode)
        return if mode == :bitmap

        raise ArgumentError, "This game says `shown_rows:`, and this line asks for `screen #{mode.inspect}`. In " \
                             "a game that gives up rows, every screen must be `screen :bitmap`. To fix this, " \
                             "use `screen :bitmap` here, or remove shown_rows:."
      end

      # A game of big pixels shows every one of its screens through the painted screen.
      private def refuse_unpainted_screen_with_big_pixels!(mode)
        return if mode == :bitmap

        raise ArgumentError, "This game says `pixel_size: #{@program.pixel_size}`, and this line asks for " \
                             "`screen #{mode.inspect}`. In a game with big pixels, every screen must be " \
                             "`screen :bitmap`. To fix this, use `screen :bitmap` here, or remove pixel_size:."
      end

      # THE COLOUR A SCREEN SHOWS WHEREVER NOTHING IS DRAWN, as the IR keeps it: nil for a screen
      # that names none, which shows the game's (black, the colour every screen has shown there
      # before, unless the game's own `screen` names another). A painted screen draws every pixel, so
      # it has nowhere to show one.
      private def resolve_backdrop(backdrop, mode)
        return nil if backdrop.nil?

        refuse_backdrop_on_painted_screen!(mode)
        if backdrop.is_a?(Symbol) && !Graphics::Color::PRESETS.key?(backdrop)
          raise ArgumentError, "`screen ... backdrop: :#{backdrop}` names no color and no list of colors. " \
                               "To fix this, give a color name such as :blue, or declare the list first with " \
                               "`colors :#{backdrop}, [...]`."
        end

        Graphics::Color.resolve(backdrop) & 0x7FFF
      end

      private def refuse_backdrop_on_painted_screen!(mode)
        return unless mode == :bitmap

        raise ArgumentError, "`screen :bitmap` says backdrop:. A bitmap screen draws every pixel. No backdrop " \
                             "shows on it. To fill the screen with a color, use clear_screen."
      end

      # The breaks a pass may take and be on time, as the IR keeps them: nil for one.
      private def resolve_late_pace(pace, late_rows)
        breaks = IR::LatePages::PACES[pace]
        unless breaks
          raise ArgumentError, "pace: #{pace.inspect} is not a rate the screen can keep. Use 60, 30, 20 or 15 " \
                               "pictures a second."
        end
        if late_rows.nil? && breaks != 1
          raise ArgumentError, "pace: works only with late:. A screen that waits for every page has no late " \
                               "page to measure. To use pace:, add late: :show_now or a row."
        end
        breaks == 1 ? nil : breaks
      end

      # The rows a late page may still be shown at once above, as the IR keeps them: nil to
      # wait, the screen's height for :show_now, since every row is above that, else the row the game named.
      private def resolve_late_pages(late, tear_free)
        return nil if late == :wait
        unless tear_free
          raise ArgumentError, "late: works only with `screen :bitmap, tear_free: true`. Only that screen keeps a " \
                               "finished page to show. To use late:, add tear_free: true."
        end
        return console.screen_height if late == :show_now
        return late if late.is_a?(Integer) && (0...console.screen_height).cover?(late)

        raise ArgumentError, "late: #{late.inspect} is not a setting. Use :wait (the default), :show_now, or a " \
                             "row from 0 to #{console.screen_height - 1}."
      end

      # HOW MANY PICTURES THIS SCREEN KEEPS. A tear-free screen keeps two and shows
      # them in turn, so a change drawn once reaches only one of them; a plain screen
      # keeps one, so a change drawn once is done. This is the number of times a
      # picture that is drawn and then left alone has to be painted (Packs::KeepShowing).
      # A Game Boy Color keeps one page even then (Console::Description's painted_pages),
      # and the second paint there only draws the same picture again.
      def screen_pages = @tear_free ? 2 : 1

      # Everything the block draws stays inside this part of the screen. What falls outside is
      # CUT OFF rather than covered up: those pixels are never worked out, so the drawing costs
      # what fits and not what was asked for.
      #
      #   inside 0, 0, 240, 128 do
      #     ...the game...
      #   end
      #   draw_the_status_bar   # ...and this is outside it, so it draws
      #
      # This is what a game with a panel wants — a strip of world with a row of numbers under
      # it, a map beside it, a letterboxed cut scene. Without it the world is drawn over the
      # whole screen and the panel painted on top, and everything under the panel was drawn for
      # nothing. In a first-person view, where a near wall is drawn taller than the screen, that
      # is most of a near wall.
      #
      # It clips; it does not move. A pixel drawn at (10, 10) is at (10, 10) whatever area is in
      # force — so an area can be put round drawing that already works, and only the parts that
      # were falling outside change.
      #
      # The edges are settled while you write the program, because where a panel goes is part of
      # how a screen is laid out rather than something a game works out as it runs. Areas do not
      # nest inside each other.
      #
      # @param x [Integer] left edge
      # @param y [Integer] top edge
      # @param w [Integer] width in pixels
      # @param h [Integer] height in pixels
      def inside(x, y, w, h, &block)
        raise ArgumentError, "inside needs a block: inside(x, y, w, h) { ... }" unless block

        [["x", x], ["y", y], ["w", w], ["h", h]].each do |name, value|
          next if value.is_a?(Integer)

          raise ArgumentError,
                "`inside` needs edges settled while you build. Got #{name}: #{value.inspect}. " \
                "Where a part of the screen is belongs to how the screen is laid out, not to " \
                "something the game works out as it runs."
        end
        if @inside_area
          raise ArgumentError,
                "`inside` cannot go inside another `inside`. One area is in force at a time. " \
                "Close the one you are in, or give this one the edges you want."
        end

        @inside_area = [x, y, w, h]
        push_container(Build.inside(x, y, w, h)) { run_block(&block) }
      ensure
        @inside_area = nil
      end

      # Draw a single pixel in bitmap mode (MODE_3).
      # Writes a 15-bit color to VRAM at the (x, y) offset.
      #
      # @param x [Integer] horizontal position (0-239)
      # @param y [Integer] vertical position (0-159)
      # @param c [Symbol, String, Integer] color (see {Color.resolve})
      def pixel(x, y, c)
        validate_coords!(x, y)
        record(Build.pixel(x, y, c))
      end

      # Fill a rectangle in bitmap mode (MODE_3).
      #
      # A place and size written in the program are drawn by the fill made for them, unrolled
      # while building. Any of the four the game works out as it runs (a variable, an expression,
      # a variable's name) makes it the rectangle `draw_rect_at` draws, which every console
      # reads its numbers for as it runs: a game need not know which verb is which.
      #
      # @param x [Integer, Symbol, Value] left edge (0-239)
      # @param y [Integer, Symbol, Value] top edge (0-159)
      # @param w [Integer, Symbol, Value] width in pixels
      # @param h [Integer, Symbol, Value] height in pixels
      # @param c [Symbol, String, Integer] fill color
      def fill_rect(x, y, w, h, c)
        record_fixed_or_runtime_rect(:fill_rect, x, y, w, h, c) { |*fixed| Build.fill_rect(*fixed, c) }
      end

      # Clear the entire screen to a solid color.
      # Much faster than pixel-by-pixel: one DMA transfer fills all of VRAM.
      #
      # @param c [Symbol, String, Integer] fill color
      def clear_screen(c)
        record(Build.clear_screen(c))
      end

      # --- the camera ---

      # Move the visible window over the whole picture. `camera 0, 0` shows it as
      # drawn; any other offset slides everything on screen at once.
      #
      # Nothing is redrawn — the picture stays where it is and the window moves — so
      # this costs the same however much is on screen. Where the window falls outside
      # the picture there is nothing to show, and the backdrop appears along that edge,
      # which is why a shake keeps its offset small.
      #
      # ON A TILED SCREEN there is no one picture to slide. What the console shows is its
      # backgrounds and its sprites, each placed by the console as it draws, so the camera
      # moves every one of them by the same amount: each background's scroll registers get
      # the camera added to wherever the game scrolled it, and each sprite is placed that far
      # the other way. The game's own numbers never change — a sprite's x is still where the
      # game put it, and `blocked_by` still reads the world — only where the console shows
      # them. Past a background's edge shows what a scroll there shows. A status bar and the
      # letters of `draw_text`/`draw_number` stay where they are, as the part of the screen
      # that holds the score, and so does a turning background, which turns about a point
      # rather than scrolling.
      #
      # It is written in the gap between frames with the scrolls, so a background and a
      # sprite move on the same frame. Nothing here is one console's: every lowering already
      # writes a background's scroll and places its sprites, so each does this its own way
      # (see #finalize_tiled_camera). That is for a game whose every screen is tiled; a game
      # with a painted screen too keeps the camera for its painted one.
      #
      # @param x [Symbol, Integer, Value] the window's left edge, in pixels
      # @param y [Symbol, Integer, Value] the window's top edge, in pixels
      def camera(x, y)
        record(Build.camera(x: DSL::Value.node_for(x), y: DSL::Value.node_for(y)))
        ensure_var(x)
        ensure_var(y)
      end

      # The two variables a tiled screen's camera is kept in, across then down. Only a game
      # that moves the camera on a tiled screen has them, so every other builds as it did.
      TILED_CAMERA_VARS = %i[__camera_x __camera_y].freeze

      private

      # MOVE EVERYTHING ON A TILED SCREEN BY THE CAMERA, once the whole program is built (see
      # #camera), in a game whose every screen is tiled. Each `camera` becomes the two
      # variables the camera is kept in. Every sprite the console places is placed the
      # camera's distance the other way. Each background's scroll write then adds the camera
      # to the game's own scroll (Builder#finalize_background_scrolls), which makes one for a
      # background the game never scrolled. The camera's numbers are read where the sprite and
      # the scroll are placed, in the gap between frames, so both show the same frame's camera.
      #
      # Decided over the whole game rather than at the `camera` line, because the line that
      # moves the camera for a shake is in a routine every scene runs, built before anything
      # knows which screen is up when it runs.
      def finalize_tiled_camera
        cameras = @program.walk.select { |node| node.kind == :camera }
        return if cameras.empty? || !every_screen_tiled?

        @tiled_camera = TILED_CAMERA_VARS
        @tiled_camera.each do |var|
          at_boot(Build.set(var, Build.int(0)))
          ensure_var(var)
        end
        across, down = @tiled_camera
        moved = backgrounds_that { |background| moved_by_tiled_camera?(background) }
        moved.each do |name, background|
          background.scroll_x ||= IR::Nodes::Background.scroll_vars(name).first
          background.scroll_y ||= IR::Nodes::Background.scroll_vars(name).last
        end
        add_camera_to_scrolls_in_place(moved)
        cameras.each do |node|
          replace_statement_with(node, Build.set(across, node.x), Build.set(down, node.y),
                                 *scrolls_written_in_place(moved))
        end
        @program.walk.select { |node| moved_by_tiled_camera_object?(node) }.each do |object|
          object.x = Build.binop(:-, object.x, Build.var_ref(across))
          object.y = Build.binop(:-, object.y, Build.var_ref(down))
        end
      end

      # A game with no game loop has no gap between frames to write the scrolls in, so it keeps
      # each scroll where the game wrote it (Builder#write_between_frames). Those scrolls take the
      # camera too, and the camera writes the scroll of every background it moves where it is
      # moved. A game with a loop changes nothing here: its scrolls are written in the gap.
      def scrolls_written_in_place(moved)
        return [] unless @frame_boundaries.empty?

        moved.map { |name, background| scroll_write_node(name, background) }
      end

      def add_camera_to_scrolls_in_place(moved)
        return unless @frame_boundaries.empty?

        across, down = @tiled_camera
        @inline_scroll_nodes.each do |node|
          next unless moved.key?(node.name)

          node.x = Build.binop(:+, node.x, Build.var_ref(across))
          node.y = Build.binop(:+, node.y, Build.var_ref(down))
        end
      end

      # Whether the game shows tiled screens alone: it asks for `screen :tiled`, and no other kind. A
      # game that names no screen paints; one that turns a `screen :rotozoom` keeps the camera's
      # own meaning there.
      def every_screen_tiled?
        @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq == [:tiled]
      end

      # Put +fresh+ statements where +node+ is, in its parent's statements, each one's parent
      # that statement's. +node+ is a statement, never an operand.
      def replace_statement_with(node, *fresh)
        container = node.parent
        at = container.children.index { |child| child.equal?(node) }
        container.children[at, 1] = fresh
        fresh.each { |statement| statement.parent = container }
      end

      # Whether the tiled camera moves +background+ (a DeclaredBackground): every one but a
      # status bar and a turning background.
      def moved_by_tiled_camera?(background)
        !background.node.bar? && !background.node.affine && !background.turns_each_frame?
      end

      # Whether the tiled camera moves +node+, a sprite: every one but a letter or digit of
      # `draw_text`/`draw_number`, which is the score and the lives at a fixed place on the
      # screen and stays still as a status bar does, and one over a painted picture.
      def moved_by_tiled_camera_object?(node)
        node.kind == :object && !node.over_picture && !@hud_objects.include?(node.name)
      end

      # THE SCROLL WRITE OF BACKGROUND +name+ (a DeclaredBackground's), gated to its scenes: the
      # game's own scroll, plus the tiled camera where the game moves one and it moves this
      # background. Fresh nodes each call, so no node is in two places in the tree.
      def scroll_write_node(name, background)
        across, down = @tiled_camera if @tiled_camera && moved_by_tiled_camera?(background)
        scroll = Build.scroll_background(name, x: scroll_plus_camera(background.scroll_x, across),
                                               y: scroll_plus_camera(background.scroll_y, down))
        while_any_scene_up(background.scene_gates, scroll)
      end

      def scroll_plus_camera(scroll_var, camera_var)
        scroll = Build.var_ref(scroll_var)
        camera_var ? Build.binop(:+, scroll, Build.var_ref(camera_var)) : scroll
      end

      public

      # The colors a fade can go to. Black and white are what the display can blend
      # the whole screen toward without redrawing anything.
      FADE_COLORS = %i[black white].freeze

      # Fade the whole screen toward black or white.
      #
      # `amount` is how far, from 0 (the picture as drawn) to 100 (nothing left but
      # that color). Nothing is redrawn — the picture is all still there, and comes
      # back untouched when the fade lifts — so this costs the same however much is on
      # screen, and it works on either kind of screen.
      #
      #   fade :black             # black out
      #   fade :black, 0          # back to normal
      #   fade :white, 50         # halfway to white
      #
      # It sets the level at the moment you call it. To fade over time, move a
      # variable and pass it: this is the primitive `fade_in` / `fade_out` sit on.
      #
      #   level = var :level, 0
      #   game_loop do
      #     level.approach! 100, 4   # walk it up over a few frames
      #     fade :black, level
      #   end
      #
      # `under:` puts the fade at a place in the stack instead of over the whole
      # picture: it names a layer, and that layer and everything in front of it are
      # left alone. Fade the game out and keep the score showing:
      #
      #   layers :world, :actors, :ui
      #   fade :black, 100, under: :ui
      #
      # `inside:` holds the fade to a rectangle of the screen, `[x, y, width, height]`, and
      # leaves the rest as drawn; `outside:` fades everything but the rectangle. Fade the view
      # and keep the status bar under it, or dim a game behind a pause box:
      #
      #   fade :black, 100, inside: [0, 0, 240, 128]
      #   fade :black, 50, outside: [60, 40, 120, 80]
      #
      # The display does it with a window — a rectangle it is told about — and its darkening
      # switched on in one part and off in the other, so it is as free as a whole-screen fade.
      #
      # @param toward [Symbol] :black or :white
      # @param amount [Symbol, Integer, Float, Value] how far, 0 to 100 (a fraction asks for finer steps)
      # @param under [Symbol, nil] a layer this fade sits under, or nil for the whole screen
      # @param inside [Array<Integer>, nil] the rectangle the fade is held to
      # @param outside [Array<Integer>, nil] the rectangle the fade leaves alone
      def fade(toward, amount = 100, under: nil, inside: nil, outside: nil)
        unless FADE_COLORS.include?(toward)
          raise ArgumentError,
                "fade goes to :black or :white. You gave #{toward.inspect}."
        end
        node, bits = effect_amount(:fade, amount)
        reaches, area = fade_area(under, inside, outside)
        check_effect_layer!(:fade, under) if under

        record(Build.fade(toward: toward, amount: node, under: under, fraction_bits: bits, reaches: reaches,
                          area: area))
        ensure_var(amount)
      end

      private

      # Which side of a rectangle a fade reaches, and the rectangle as the display's window
      # takes it: [left, top, right, bottom], the right and bottom one past the last column and
      # row, clipped to the screen. A rectangle wholly off the screen, or of no width or
      # height, holds nothing. Nil and nil for a fade over the whole screen.
      def fade_area(under, inside, outside)
        return [nil, nil] if inside.nil? && outside.nil?

        refuse_fade_area_beside!(under, inside, outside)
        reaches, rect = inside ? [:inside, inside] : [:outside, outside]
        refuse_fade_area_shape!(reaches, rect)
        x, y, w, h = rect
        left, right = [x, x + w].map { |edge| edge.clamp(0, console.screen_width) }
        top, bottom = [y, y + h].map { |edge| edge.clamp(0, console.screen_height) }
        empty = left >= right || top >= bottom
        [reaches, empty ? [0, 0, 0, 0] : [left, top, right, bottom]]
      end

      def refuse_fade_area_beside!(under, inside, outside)
        if inside && outside
          raise ArgumentError, "fade takes `inside:` or `outside:`, not both. Give the one rectangle the fade " \
                               "is held to (`inside:`) or the one it leaves alone (`outside:`)."
        end
        return unless under

        raise ArgumentError, "fade takes `under:` or a rectangle, not both. `under:` places the fade in the " \
                             "stack, and `inside:` or `outside:` holds it to part of the screen. To fix this, " \
                             "give one of them."
      end

      def refuse_fade_area_shape!(word, rect)
        return if rect.is_a?(Array) && rect.size == 4 && rect.all?(Integer)

        raise ArgumentError, "fade `#{word}:` takes a rectangle as four whole numbers you write: " \
                             "[x, y, width, height], in pixels. You gave #{rect.inspect}."
      end

      public

      # Tint the whole screen toward a color — red for damage, blue for cold water,
      # orange for a sunset. `fade`'s sibling, for the colors a fade cannot reach.
      #
      # `amount` is how far, from 0 (the picture as drawn) to 100 (nothing left but
      # that color). Nothing is redrawn, so the picture is all still there and comes
      # back untouched when the tint lifts.
      #
      #   tint :red               # everything red
      #   tint :red, 0            # back to normal
      #   tint :orange, 30        # a warm wash over the picture
      #
      # Like `fade` it sets the level where you call it, so tinting over time is a
      # variable moved a little each frame:
      #
      #   hurt = var :hurt, 0
      #   game_loop do
      #     hurt.approach! 0, 6      # ease it back off
      #     tint :red, hurt
      #   end
      #
      # @param color [Symbol, String, Integer] the color to move the picture toward
      # @param amount [Symbol, Integer, Float, Value] how far, 0 to 100 (a fraction asks for finer steps)
      def tint(color, amount = 100)
        node, bits = effect_amount(:tint, amount)
        record(Build.tint(color: Graphics::Color.resolve(color), amount: node, fraction_bits: bits))
        ensure_var(amount)
      end

      # Show the whole screen in flat blocks — the pixelate effect of a scene change, a
      # hit, a dream, a teleport.
      #
      # `size` is how many pixels a block is each way: 1 is the picture as drawn, 8 is
      # blocks of eight by eight, and 16 is the biggest the console draws. Nothing is
      # redrawn — the console does it as it draws, so the picture is all still there and
      # comes back untouched — and it costs the same however much is on screen.
      #
      #   pixelate 8              # big blocks
      #   pixelate 1              # back to normal
      #
      # It sets the size where you call it, so pixelating over time is a variable moved
      # a little each frame:
      #
      #   blocks = var :blocks, 1
      #   game_loop do
      #     blocks.approach! 16, 1
      #     pixelate blocks
      #   end
      #
      # `under:` leaves part of the picture as drawn: it names a layer, and that layer and
      # everything in front of it stay sharp. Pixelate the game and keep the score readable:
      #
      #   layers :world, :actors, :ui
      #   pixelate 8, under: :ui
      #
      # A game names one place, and every `pixelate` in it names the same one.
      #
      # `sprites: false` puts the backgrounds alone in blocks and leaves every sprite as
      # drawn, which is all a Super Nintendo's display can do, so a game for one says it:
      #
      #   pixelate 16 - brightness, sprites: false
      #
      # It is one choice for the whole game too, like the place.
      #
      # A status bar stays as drawn unless the game writes `status_bar: true`: then it is in
      # blocks too, in the one grid from the top of the screen that everything else's blocks are
      # in. One choice for the whole game as well.
      #
      # @param size [Symbol, Integer, Value] how many pixels a block is each way, 1 to 16
      # @param under [Symbol, nil] a layer left as drawn with everything in front of it, or nil for the whole screen
      # @param sprites [Boolean] whether the sprites are put in blocks with the backgrounds
      # @param status_bar [Boolean] whether a status bar is put in blocks with the backgrounds
      def pixelate(size, under: nil, sprites: true, status_bar: false)
        refuse_unusable_block_size!(size)
        check_effect_layer!(:pixelate, under) if under
        refuse_second_pixelate_place!(under)
        refuse_second_pixelate_sprites!(sprites)
        refuse_second_pixelate_bar!(status_bar)

        record(Build.pixelate(size: DSL::Value.node_for(size), under: under, keeps_sprites: !sprites,
                              bar_in_blocks: status_bar))
        ensure_var(size)
      end

      # A light: the picture as drawn inside a circle, and darkened everywhere outside it.
      # A lantern in a cave, a torch in a dungeon, a searchlight sweeping a yard. Declare it
      # once, where it starts, and move it with the handle it hands back:
      #
      #   light = spotlight at: [120, 80], radius: 40, dark: 75
      #   game_loop do
      #     light.move_to hero.x + 8, hero.y + 8
      #   end
      #
      # `at:` is where the middle of the light starts, in screen pixels, `radius:` how far it
      # reaches, and `dark:` how dark the rest of the picture is, 0 (as drawn) to 100 (black).
      # All three are where it STARTS, applied once at power-on, the way `var` takes its
      # starting value; the handle's `x`, `y`, `radius` and `dark` are what the game changes.
      #
      # Nothing is redrawn. The console darkens the picture as it draws it, and is told
      # where the circle is one row at a time, so a light costs the same however much is on
      # screen: working its edge out for each row, in the gap before every frame.
      #
      # `spotlight` with nothing after it hands back the game's light, which is how anything
      # that works on the light finds it — an `iris_out`, a routine in another file. A game
      # with no light yet gets one that reaches past every edge of the screen and darkens
      # nothing, so the picture is as drawn until something moves it.
      #
      # `outside: :nothing` makes it a light that SHOWS NOTHING OUTSIDE IT, where a light
      # otherwise darkens what is there: outside the circle no layer and no sprite is drawn, so
      # the screen's backdrop colour shows, black unless the game gave the screen another. It
      # is the circle a scene change closes, and the one light that shares a scene with a
      # see-through layer, because it darkens nothing: the layer goes on mixing inside the
      # circle. Its `dark` is then a switch, 0 for off and 100 for on, which is what
      # `iris_out` and `iris_in` set. It is said once, where the game's light is declared:
      #
      #   spotlight outside: :nothing    # the game's light, off until an `iris_out` closes it
      #   spotlight at: [120, 80], radius: 40, outside: :nothing
      #
      # @param at [Array(Integer, Integer)] where the middle of the light starts, in screen pixels
      # @param radius [Integer] how far it reaches from its middle, in pixels
      # @param dark [Integer] how dark the picture is outside it, 0 to 100
      # @param outside [Symbol, nil] :darkened (what a light does unless told) or :nothing
      # @return [DSL::Spotlight]
      def spotlight(at: nil, radius: nil, dark: nil, outside: nil)
        refuse_unknown_light_outside!(outside)
        said = !(at.nil? && radius.nil? && dark.nil?)
        shuts_out = outside == :nothing
        if @spotlight && !said
          refuse_light_outside_changed!(shuts_out) unless outside.nil?
          return @spotlight
        end

        refuse_second_spotlight!
        refuse_spotlight_off_tiles!
        at ||= console.middle
        refuse_spotlight_with_no_radius! if said && radius.nil?
        radius ||= Spotlights::LARGEST
        dark ||= said ? Spotlights::DARK_UNSAID : 0
        refuse_spotlight_start!(at, radius, dark)

        light = DSL::Spotlight.new(x: var(Spotlights::X, at[0]), y: var(Spotlights::Y, at[1]),
                                   radius: var(Spotlights::RADIUS, radius), dark: var(Spotlights::DARK, dark),
                                   builder: self)
        @spotlight_tables = Spotlights.declare_tables(self)
        shade = Spotlights.shade_node(self, light, shuts_out: shuts_out)
        push_container(shade) { Spotlights.work_out_half_width(self, light, @spotlight_tables) }
        record(shade)
        @spotlight_shade = shade
        @spotlight_unsaid = !said && outside.nil?
        @spotlight = light
      end


      # THE HOOK BEHIND Spotlight#shape: the block's statements become the ones the light runs
      # once a row, and what it gives back the row's two edges, held to the screen. The circle
      # the light had is put aside.
      def record_light_shape(light, &block)
        refuse_light_shape_with_no_block!(block)
        refuse_second_light_shape!
        shade = @spotlight_shade
        before = @variables.to_a
        shade.children.clear
        edges = nil
        begin
          @shaping_light = true
          push_container(shade) { edges = yield(DSL::Value.handed_to_block(self, Build.var_ref(Spotlights::ROW))) }
        ensure
          @shaping_light = false
        end
        left, right = light_edges(light, edges)
        shade.left = DSL::Value.node_for(left)
        shade.right = DSL::Value.node_for(right)
        own = @variables.to_a - before
        refuse_light_shape_with_side_effects!(shade, own)
        start_own_variables_every_row(shade, own)
        @light_shape_own = own
        @light_shaped = true
      end

      # THE HOOK BEHIND Spotlight#circle: the statements that work out the light's circle on
      # +row+, into a variable of the shape's own, which is handed back.
      def light_circle(light, row)
        unless @shaping_light
          raise ArgumentError, "`light.circle` works out a row of the light's circle for a shape. " \
                               "To use it, call it inside `light.shape { |row| ... }`."
        end

        @light_circles = (@light_circles || 0) + 1
        Spotlights.work_out_half_width(self, light, @spotlight_tables, row: row, into: :"__spotlight_circle_#{@light_circles}")
      end

      # THE HOOK BEHIND Spotlight#show_now: the light worked out again here, for the picture
      # being drawn.
      def show_light_now
        record(Build.show_light_now)
      end

      # Fill a rectangle at a fixed position and size. A number the game works out makes it
      # the rectangle `draw_rect_at` draws, as for #fill_rect.
      #
      # @param x [Integer, Symbol, Value] left edge
      # @param y [Integer, Symbol, Value] top edge
      # @param w [Integer, Symbol, Value] width in pixels (must be even for the fast fill)
      # @param h [Integer, Symbol, Value] height in pixels
      # @param c [Symbol, String, Integer] fill color
      def dma_fill_rect(x, y, w, h, c)
        record_fixed_or_runtime_rect(:dma_fill_rect, x, y, w, h, c) { |*fixed| Build.dma_fill_rect(*fixed, c) }
      end

      # Draw ONE COLUMN of a picture, stretched to a height the game works out.
      #
      # This is what a first-person view is made of. For each strip across the screen a
      # game works out how far away the wall is, turns that into a height, and draws a
      # column of a wall picture that tall — near walls tall, far walls short. Do that
      # across the screen and a flat grid of cells looks like rooms you can walk through.
      #
      #   draw_column_at :bricks, slice: ray_hit, x: col * 2, top: top, height: tall
      #
      # +slice+ picks the column of the picture (which part of the wall you are looking
      # at); +x+ is where it lands on screen; +top+ and +height+ are where it starts and
      # how tall it is. All four can be worked out as the game runs.
      #
      # A height of zero or less draws nothing, and anything off the top or bottom of the
      # screen is clipped, so a wall you are nose-to-nose with needs no test around it.
      #
      # +width+ is how many pixels ACROSS the strip is, 1 by default. A view drawing
      # strips wider than a pixel wants this rather than a loop of its own: the whole
      # strip shows the same picture column at the same height, so one walk down the
      # screen fills all of it. Calling this once per pixel instead works out the same
      # answer that many times over.
      #
      # @param name [Symbol] a picture defined with {#image}
      # @param slice [Symbol, Integer, Value] which column of the picture
      # @param x [Symbol, Integer, Value] where it lands on screen
      # @param top [Symbol, Integer, Value] the screen row it starts on
      # @param height [Symbol, Integer, Value] how tall to stretch it
      # @param width [Integer] how many pixels across, settled while building
      # @param estimate [Object] does nothing but earn a warning (see Builder#record_estimate_line)
      def draw_column_at(name, slice:, x:, top:, height:, width: 1, estimate: nil)
        record_estimate_line(estimate)
        unless @images.key?(name)
          raise ArgumentError,
                "draw_column_at needs a picture. There is no image :#{name}. " \
                "Define it with `image :#{name} do ... end` first."
        end
        unless width.is_a?(Integer) && width.positive?
          raise ArgumentError,
                "draw_column_at needs a `width:` of 1 or more, settled while you build. " \
                "Got #{width.inspect}. A strip's width is a property of the view, not " \
                "something the game works out as it runs."
        end

        record(Build.draw_column_at(name, DSL::Value.node_for(slice), DSL::Value.node_for(x),
                                    DSL::Value.node_for(top), DSL::Value.node_for(height), width: width))
        [slice, x, top, height].each { |operand| ensure_var(operand) }
      end

      # Draw a filled rectangle at a position, and to a height, the game can work out
      # as it runs. The position and the height may each be a variable, an expression,
      # or a plain number; only the width is settled while building, and it must be
      # even (for the fast fill).
      #
      # A height the game computes is what a bar or a column needs — a health meter
      # that shrinks, a wall column in a first-person view, a tower that grows:
      #
      #   draw_rect_at 8, 8, 40, health, :red     # a meter as tall as the health left
      #
      # A height of zero or less draws nothing, so a bar can empty completely without
      # a test around it.
      #
      # @param x_pos [Symbol, Integer, Value] x position
      # @param y_pos [Symbol, Integer, Value] y position
      # @param w [Integer] width in pixels (must be even, settled while building)
      # @param h [Symbol, Integer, Value] height in pixels
      # @param c [Symbol, String, Integer] fill color
      # @param estimate [Object] does nothing but earn a warning (see Builder#record_estimate_line)
      def draw_rect_at(x_pos, y_pos, w, h, c, estimate: nil)
        record_estimate_line(estimate)
        record_runtime_rect(x_pos, y_pos, w, h, c)
      end

      # Lay out a board of equal cells and get a handle for painting them one at a
      # time. The game then works in cell coordinates (0, 1, 2 …) — set_cell and
      # clear_cell handle the pixel arithmetic — so a tile game reads as a tile game
      # and each step touches only the cells that changed. See {Grid}.
      #
      #   board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
      #   board.set_cell   x, y, :white   # paint one cell
      #   board.clear_cell x, y            # return it to the background (:black)
      #
      # @param name [Symbol] the board's name
      # @param cols [Integer] columns across
      # @param rows [Integer] rows down
      # @param cell [Integer] a cell's size in pixels (even)
      # @param over [Symbol, String, Integer] the background color a cleared cell shows
      # @return [Grid] a handle with set_cell / clear_cell
      def grid(name, cols:, rows:, cell:, over:)
        DSL::Grid.new(self, name: name, cols: cols, rows: rows, cell: cell, over: over)
      end

      private

      # Record the node the block builds from the rectangle's four numbers when each was
      # written in the program (a bare number, or a handle standing for one), or a
      # `draw_rect_at` when the game works any of them out as it runs. That one remembers
      # +verb+, the verb the author wrote, so a message about the line names it.
      def record_fixed_or_runtime_rect(verb, x, y, w, h, c)
        fixed = [x, y, w, h].map { |operand| DSL::Value.fixed_number(operand) }
        return record_runtime_rect(x, y, w, h, c, written_as: verb) if fixed.include?(nil)

        record(yield(*fixed))
      end

      # Record a rectangle whose four numbers are read as the program runs. +written_as+ is the
      # verb the author wrote, where it was not `draw_rect_at`.
      def record_runtime_rect(x, y, w, h, c, written_as: nil)
        record(Build.draw_rect_at(DSL::Value.node_for(x), DSL::Value.node_for(y),
                                  DSL::Value.node_for(w), DSL::Value.node_for(h), c, written_as: written_as))
        ensure_var(x)
        ensure_var(y)
        ensure_var(w)
        ensure_var(h)
      end

      # A block is a whole number of pixels, and the console has sizes from one pixel, which
      # is the picture as drawn, to sixteen. A size written in the program outside those is
      # a slip worth saying; one the game works out is held to them as it runs. A number
      # that holds a fraction keeps it in its low bits, so read as a size it would be
      # thousands of pixels.
      def refuse_unusable_block_size!(size)
        largest = IR::Backends::Blocks::LARGEST
        if DSL::Fraction.bits_of(size)
          raise ArgumentError,
                "pixelate's size is a whole number of pixels, and this one holds a fraction. " \
                "To fix this, write a whole number from 1 to #{largest}, or drop the fraction with `.to_i`."
        end

        fixed = DSL::Value.fixed_number(size)
        return if fixed.nil? || (1..largest).cover?(fixed)

        raise ArgumentError,
              "pixelate's size is how many pixels a block is each way, from 1 to #{largest}. " \
              "You gave #{fixed}. A size of 1 is the picture as drawn."
      end

      # WHICH THINGS ARE DRAWN IN BLOCKS IS SETTLED AS THE CARTRIDGE IS BUILT. The console
      # keeps that as a switch on each background and each sprite, and the switches are
      # set once: all that changes while the game runs is the size of a block. So a game
      # has one answer to "what is left as drawn", and two different ones is a friendly
      # error here rather than a second set of switches to keep in step every frame.
      def refuse_second_pixelate_place!(under)
        @pixelate_place = under unless defined?(@pixelate_place)
        return if @pixelate_place == under

        said = ->(place) { place ? "`under: :#{place}`" : "no `under:`" }
        raise ArgumentError,
              "This game already pixelates with #{said.call(@pixelate_place)}, and now with " \
              "#{said.call(under)}. A game pixelates from one place in the stack, because which " \
              "things are drawn in blocks is settled once, before it runs. To fix this, give " \
              "every `pixelate` the same `under:`."
      end

      # ...and so is whether the sprites are among them: one choice for the whole game.
      def refuse_second_pixelate_sprites!(sprites)
        unless [true, false].include?(sprites)
          raise ArgumentError, "The `sprites:` setting of `pixelate` must be true or false. You gave #{sprites.inspect}."
        end

        @pixelate_sprites = sprites unless defined?(@pixelate_sprites)
        return if @pixelate_sprites == sprites

        raise ArgumentError,
              "This game pixelates with `sprites: false` in one place and with the sprites in blocks " \
              "in another. The build sets which things are in blocks one time, before the game runs. " \
              "To fix this, give every `pixelate` the same `sprites:`."
      end

      # ...and whether a status bar is among them: one choice for the whole game.
      def refuse_second_pixelate_bar!(status_bar)
        unless [true, false].include?(status_bar)
          raise ArgumentError,
                "The `status_bar:` setting of `pixelate` must be true or false. You gave #{status_bar.inspect}."
        end

        @pixelate_bar = status_bar unless defined?(@pixelate_bar)
        return if @pixelate_bar == status_bar

        raise ArgumentError,
              "This game pixelates with `status_bar: true` in one place and with the status bar as drawn " \
              "in another. The build sets which things are in blocks one time, before the game runs. " \
              "To fix this, give every `pixelate` the same `status_bar:`."
      end

      # SWITCH THE LIGHT OFF IN THE SCENES IT IS OFF IN: those that see through a layer, or
      # fade under one (see IR::LightScenes). Each scene sets, as it starts its pass, whether
      # the light is on, and the light's darkness is that much of what the game sets — so
      # every backend works out the same picture from the program alone. A game whose light
      # is on in every scene gets none of this.
      def finalize_light_switch
        return unless @spotlight

        refuse_light_shape_variable_shared!
        dark = IR::LightScenes.dark(program)
        return if dark.empty?

        var(IR::LightScenes::ON, 1)
        scenes = IR::LightScenes.scenes(program)
        program.walk.select { |node| node.kind == :func && scenes.include?(node.name) }.each do |scene|
          switch = Build.set(IR::LightScenes::ON, Build.int(dark.key?(scene.name) ? 0 : 1))
          scene.children.unshift(switch)
          switch.parent = scene
        end
        light = IR::LightScenes.light_of(program)
        light.amount = Build.binop(:*, light.amount, Build.var_ref(IR::LightScenes::ON))
      end

      def refuse_light_shape_with_no_block!(block)
        return if block

        raise ArgumentError, "`light.shape` needs a block that gives back each row of the light: " \
                             "`light.shape { |row| 40 - (row - light.y).abs }`."
      end

      def refuse_second_light_shape!
        return unless @light_shaped

        raise ArgumentError, "This game gives the light a shape twice. A light has one shape. " \
                             "To fix this, keep one `light.shape`, and work the difference out inside it."
      end

      # A ROW'S TWO EDGES, held to the screen, from what a shape gave back: a half width either
      # side of the light's middle (never less than nothing), or [left, right] as they are.
      def light_edges(light, edges)
        screen = console.screen_width
        number = ->(edge) { edge.is_a?(Integer) || edge.is_a?(DSL::Value) }
        if edges.is_a?(Array) && edges.length == 2 && edges.all?(&number)
          left, right = edges
        elsif number.call(edges)
          half = edges.clamp(0, screen)
          left = light.x - half
          right = light.x + half
        else
          refuse_light_edges!(edges)
        end
        [left.clamp(0, screen), right.clamp(0, screen)]
      end

      def refuse_light_edges!(edges)
        raise ArgumentError, "`light.shape` needs a block that gives back a half width (a number) " \
                             "or a row's two edges, [left, right]. This one gave back #{edges.inspect}."
      end

      # WHAT A SHAPE MAY DO, and why it is a short list: the rows are worked out in the gap before
      # a frame, and the console skips them on a frame where nothing they read has changed. So a
      # row has to come out of the row and the game's numbers alone. A shape works numbers out —
      # from variables, tables and arithmetic — keeps them in variables of its own, branches and
      # loops; anything else would read something the console does not watch, or change the game
      # at different times on different machines.
      LIGHT_SHAPE_STATEMENTS = %i[set add sub copy negate abs negate_abs clamp if else repeat table].freeze
      LIGHT_SHAPE_VALUES = %i[int var_ref binop neg bit_not absolute clamped mul_fix div_fix shift_right
                              table_get data_byte].freeze

      # What the commonest things a shape cannot do are, said as the game writes them.
      LIGHT_SHAPE_CANNOT = { list_get: "read a list", list_len: "read a list", held: "read the buttons",
                             pressed: "read the buttons", players_connected: "read the buttons", chance: "pick a number at random",
                             call: "call a routine", call_one_of: "call a routine" }.freeze

      # Refused where the shape is written, so the error points at it: anything off the list above,
      # a random number, which moves the stream every other part of the game draws from, and a
      # change to any variable the shape did not declare.
      def refuse_light_shape_with_side_effects!(shade, own)
        [*shade.children, shade.left, shade.right].flat_map { |part| part.walk.to_a }.each do |node|
          written = IR::LightScenes.written_var(node)
          if written == Randomness::RNG_STATE
            raise ArgumentError, "The light's shape picks a number at random. The random numbers are one stream " \
                                 "that the whole game shares, and a shape cannot move it. To fix this, pick " \
                                 "the number outside the shape into a variable, and read that variable in the shape."
          end
          unless (node.value? ? LIGHT_SHAPE_VALUES : LIGHT_SHAPE_STATEMENTS).include?(node.kind)
            did = LIGHT_SHAPE_CANNOT.fetch(node.kind) { "use `#{Messages::PlainWords.verb_written(node)}`" }
            raise ArgumentError, "The light's shape tries to #{did}. A shape can only work numbers out from " \
                                 "the game's numbers and tables, keep them in variables it declares, branch and " \
                                 "repeat. To fix this, do the work outside the shape, keep the number in a " \
                                 "variable, and read that variable in the shape."
          end
          next if written.nil? || own.include?(written)

          raise ArgumentError,
                "The light's shape changes the variable :#{written}. A shape can change only the variables it " \
                "declares itself. To fix this, declare a variable inside the shape's block, or change " \
                ":#{written} outside the shape."
        end
      end

      # A SHAPE'S OWN VARIABLES START EVERY ROW AS THEY WERE DECLARED. Nothing then carries from
      # one row to the next, or from one frame to the next, so a row is the row and the game's
      # numbers and nothing else — which is what lets the console keep rows it worked out before.
      def start_own_variables_every_row(shade, own)
        own.reverse_each do |name|
          start = @boot_inits.find { |node| node.kind == :set && node.var == name }&.value
          reset = Build.set(name, start ? start.copy : Build.int(0))
          shade.children.unshift(reset)
          reset.parent = shade
        end
      end

      # The variables a shape declared are its alone: one the rest of the game also reads or
      # changes would be put back every row, so the game would see it change for no reason, and
      # on the console only on the frames whose rows are worked out again.
      def refuse_light_shape_variable_shared!
        return unless @light_shape_own&.any?

        in_shade = @spotlight_shade.walk.to_set
        program.walk.reject { |node| in_shade.include?(node) }.each do |node|
          named = node.kind == :copy ? [node.src, node.dest] : [IR::LightScenes.written_var(node), (node.name if node.kind == :var_ref)]
          shared = (named & @light_shape_own).first
          next unless shared

          raise ArgumentError,
                "The light's shape declares the variable :#{shared}, and the rest of the game uses it too. " \
                "A shape puts its own variables back on every row. To fix this, give the shape's variable " \
                "a name of its own."
        end
      end

      # A GAME HAS ONE LIGHT. The console has one window shaped row by row, and a light is
      # that window, so a second `spotlight` would quietly take the first one's place.
      def refuse_second_spotlight!
        return unless @spotlight

        if @spotlight_unsaid
          raise ArgumentError,
                "This game declares `spotlight` after an `iris_out` (or a `spotlight` with nothing " \
                "after it) already gave it a light. A game has one light. To fix this, declare " \
                "`spotlight at: [x, y], radius: r` before the first `iris_out`."
        end

        raise ArgumentError,
              "This game declares `spotlight` twice. A game has one light, and moves it with the " \
              "handle the first `spotlight` gives back. To fix this, keep the handle " \
              "(`light = spotlight at: [x, y], radius: r`) and change `light.x`, `light.y`, " \
              "`light.radius` and `light.dark` where the second light was."
      end

      LIGHT_OUTSIDES = %i[darkened nothing].freeze

      def refuse_unknown_light_outside!(outside)
        return if outside.nil? || LIGHT_OUTSIDES.include?(outside)

        raise ArgumentError,
              "`spotlight outside:` is what the picture is outside the light: `outside: :darkened` " \
              "(what a light does unless told) or `outside: :nothing` (nothing is drawn there). " \
              "You gave #{outside.inspect}."
      end

      # WHAT IS OUTSIDE THE LIGHT IS SETTLED AS THE CARTRIDGE IS BUILT, since it decides what
      # the display is told at power-on and which scenes the light can share. So it is set where
      # the game's one light is declared, and asking for the light again with the other answer
      # is refused rather than quietly ignored.
      def refuse_light_outside_changed!(shuts_out)
        return if @spotlight_shade.shuts_out == shuts_out

        wanted = shuts_out ? ":nothing" : ":darkened"
        if @spotlight_unsaid
          raise ArgumentError,
                "This game asks for `spotlight outside: #{wanted}` after an `iris_out` (or a `spotlight` " \
                "with nothing after it) already gave it a light. A game has one light. To fix this, " \
                "write `spotlight outside: #{wanted}` before the first `iris_out`."
        end

        raise ArgumentError,
              "This game asks for `spotlight outside: #{wanted}`, and its light was declared with the " \
              "other answer. A game has one light, and what is outside it is set once. To fix this, " \
              "give `outside: #{wanted}` to the `spotlight` that declares the light, and to no other."
      end

      # A light is a window in the picture the console composes from tiles. A bitmap screen
      # is one picture the game paints, with nothing composed to cut a window in; the
      # turning-background screen has the window, but this framework does not switch it on
      # there yet, and the console would darken the whole screen.
      def refuse_spotlight_off_tiles!
        return if @screen_mode.nil? || @screen_mode == :tiled

        raise ArgumentError,
              "`spotlight` needs a `screen :tiled`. This game is on `screen :#{@screen_mode}`, where " \
              "a light would darken the whole screen and not only the part outside it. To fix this, " \
              "use `screen :tiled` for the screen with the light."
      end

      def refuse_spotlight_with_no_radius!
        raise ArgumentError,
              "`spotlight` needs `radius:`, how far the light reaches in pixels: " \
              "`spotlight at: [120, 80], radius: 40`. To get the game's light back, write `spotlight` " \
              "with nothing after it."
      end

      # Where a light STARTS is a number, applied once at power-on like a variable's; where
      # it goes after that is the handle's.
      def refuse_spotlight_start!(at, radius, dark)
        unless at.is_a?(Array) && at.length == 2 && at.all?(Integer)
          raise ArgumentError,
                "`spotlight at:` is where the light starts, as two whole numbers: `at: [120, 80]`. " \
                "You gave #{at.inspect}. To move it as the game runs, use the handle: `light.move_to x, y`."
        end
        unless radius.is_a?(Integer) && radius >= 0
          raise ArgumentError,
                "`spotlight radius:` is how far the light reaches, as a whole number of pixels, 0 or " \
                "more. You gave #{radius.inspect}. To change it as the game runs, use `light.radius`."
        end
        return if dark.is_a?(Integer) && (0..100).cover?(dark)

        raise ArgumentError,
              "`spotlight dark:` is how dark the picture is outside the light, as a whole number from " \
              "0 to 100. You gave #{dark.inspect}. To change it as the game runs, use `light.dark`."
      end

      # A fade's or a tint's amount for the tree, and how many bits of fraction it carries
      # (nil for a whole percentage). An amount with a fraction — a Float, or a value that
      # holds one — is a percentage all the same, kept finer, and a long fade walked by it
      # moves a step on every frame rather than every other (see IR::Fading).
      def effect_amount(verb, amount)
        bits = DSL::Fraction.bits_of(amount)
        written = amount.is_a?(Float)
        node = written ? Build.int(DSL::Fraction.scale(amount, bits)) : DSL::Value.node_for(amount)
        fixed = written ? amount : DSL::Value.fixed_number(amount)
        fixed = fixed.fdiv(1 << bits) if fixed && bits && !written
        if fixed && !(0..100).cover?(fixed)
          raise ArgumentError,
                "#{verb}'s amount is how far to go, from 0 to 100. You gave #{fixed}."
        end

        [node, bits]
      end

      # The colors a screen was told to show, resolved the same way every draw verb
      # resolves one, so a name, a hex string and a raw value all mean the same thing
      # here as they do there.
      def resolve_screen_colors(colors, tear_free)
        return nil if colors.nil?

        unless colors.is_a?(Array) && !colors.empty?
          raise ArgumentError, "screen colors: needs a list of colors, like [:black, :red, ...]. Got #{colors.inspect}."
        end

        unless tear_free
          raise ArgumentError,
                "screen colors: works only with `screen :bitmap, tear_free: true`. A plain bitmap " \
                "screen holds a full color in every pixel, so it has no table to fill in."
        end

        if colors.length > IR::Palette::CAPACITY
          raise ArgumentError,
                "screen colors: got #{colors.length} colors, and the screen shows at most " \
                "#{IR::Palette::CAPACITY}. Give a shorter list."
        end

        colors.map { |spec| Graphics::Color.resolve(spec) }
      end

      def validate_coords!(x, y)
        width, height = console.screen_size
        raise ArgumentError, "x=#{x} is outside the screen. Use an x from 0 to #{width - 1}." unless (0...width).cover?(x)
        raise ArgumentError, "y=#{y} is outside the screen. Use a y from 0 to #{height - 1}." unless (0...height).cover?(y)
      end
    end
  end
end
