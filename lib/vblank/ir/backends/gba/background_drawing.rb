# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # The code that puts backgrounds up on a tiled screen, and changes them while the game
        # runs. The console draws each background layer itself, every frame, from a map in
        # its memory — a grid saying which tile goes in each cell — and a few registers saying
        # where the layer is scrolled to, or, for the layer that turns, how it is turned and
        # sized. So a background here is a map copied into place and those registers set;
        # after that, scrolling it, swapping its map, changing one cell or recolouring it is a
        # write or a copy, and nothing is redrawn.
        #
        # Which layer each background uses and where its tiles and map sit was settled before
        # any code existed (see {ScreenLayout}); this writes the code that carries it out.
        class BackgroundDrawing
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[
            scroll_background place_bar box_background affine_background set_tile set_tile_block show_map show_held_tiles
            copy_tiles copy_owed_tiles background_colors
          ].freeze

          def emit_statement(node)
            case node.kind
            when :scroll_background then emit_scroll_background(node)
            when :place_bar then emit_place_bar(node)
            when :box_background then emit_box_background(node)
            when :affine_background then emit_affine_background(node)
            when :set_tile then emit_set_tile(node)
            when :set_tile_block then emit_set_tile_block(node)
            when :show_map then emit_show_map(node)
            when :show_held_tiles then emit_show_held_tiles(node)
            when :copy_tiles then emit_copy_tiles(node)
            when :copy_owed_tiles then emit_copy_owed_tiles(node)
            when :background_colors then emit_background_colors(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware
          include MapStreaming
          include HeldTiles

          def initialize(emitter:, primitives:, lowering:, divide:, raster:, palette_tint:, uploads:, lists:,
                         placement:, memory:)
            @emitter = emitter
            @memory = memory
            @primitives = primitives
            @lowering = lowering
            @lists = lists
            @divide = divide
            @raster = raster
            @palette_tint = palette_tint
            @uploads = uploads
            @placement = placement
            @layout = nil
          end

          attr_writer :layout

          # The notes saying whose scenery is up (see SceneEntry), which Drawing keeps and hands
          # over once it is made.
          attr_writer :scene_entry

          # A line that changes a background by name, for a name declared in several scenes: each
          # scene's declaration sits in a place of its own (see ScreenLayout#declared_background),
          # and the line is reached from the gap between frames, which every scene passes through.
          # So the line's code is written once for each declaration, each part run only while its
          # scene's scenery is up — a compare and a branch a declaration. For every other
          # background the block gets its one placement, or nil where it has none (a background
          # on a screen with no tiled layer), and nothing is compared.
          #
          # The block is run once for each declaration, so it leaves with `next`, never `return`.
          def emit_for_each_declaration(name)
            declared = @layout.screen.declarations_of(name)
            return yield(@layout.screen.backgrounds[name]) if declared.empty?

            declared.each { |scene, bg| @scene_entry.emit_if_scene_up(:scenery, scene) { yield bg } }
          end

          # The per-layer control and scroll registers, indexed by BG number (0..3), so a
          # layer configures and scrolls its own hardware layer.
          BG_CNT_REGS  = [REG_BG0CNT, REG_BG1CNT, REG_BG2CNT, REG_BG3CNT].freeze
          BG_HOFS_REGS = [REG_BG0HOFS, REG_BG1HOFS, REG_BG2HOFS, REG_BG3HOFS].freeze
          BG_VOFS_REGS = [REG_BG0VOFS, REG_BG1VOFS, REG_BG2VOFS, REG_BG3VOFS].freeze

          # Upload the one palette and the one run of tile pictures every layer draws from,
          # once at boot — the pictures to the start of video memory, the colors to
          # background palette memory. It is one run however many layers there are; where
          # in it each layer starts counting its tile numbers is a per-layer setting, and
          # goes in with the rest of them below. Each layer's map and control register are
          # set later, when its background node is reached (emit_background_hardware).
          def emit_boot_backgrounds
            @uploads.emit_dma_blob(BG_SHARED_PAL, BG_PALETTE, @layout.screen.bg_shared.palette_units)  # colors -> palette memory
            @uploads.emit_dma_blob(BG_SHARED_CHAR, VRAM_START, @layout.screen.bg_shared.tile_units)    # pictures -> video memory
            @palette_tint.emit_tint_reset_if_tinting # the table now holds the originals again
            @palette_tint.emit_record_bg_palette_source # ...the first area's, for a game that walks between areas
            @palette_tint.emit_changed_bg_lists_again # ...and the groups drawn from another list put back over it
            emit_boot_box_window
            # The bar shown early, not up yet (Drawing#emit_bar_beside)
            return unless @layout.screen.handover.bar_shown_early

            @primitives.store_word_immediate(0, @primitives.var_addr(Drawing::BAR_SHOWN_EARLY))
          end

          # Point one layer's hardware at its data: DMA its map into its own screen block,
          # then set its control register (how its pixels are stored, where it counts its
          # tile numbers from, that screen block, and its paint-order priority) and reset
          # its scroll to the top-left. Drawn once — after that the hardware repaints the
          # whole layer every frame for free, and composites the layers by priority so
          # nearer ones sit in front.
          def emit_background_hardware(node)
            bg = @layout.screen.declared_background(node)
            emit_forget_held_tiles(node, bg)
            return emit_affine_background_hardware(bg) if bg.affine

            # A map brought in a strip at a time is put up as its first map, filled round the
            # top-left corner (see MapStreaming). The corner, and not wherever the game last
            # put the view: the scroll is put back to the corner a few lines down, and that
            # is what the display shows until the gap after this pass, when the game's own
            # place for the view is written and the cells round that are brought in. Filled
            # round the place the view was left, a scene coming back showed that place's
            # cells at the corner for a frame.
            if bg.stream
              @emitter.emit_number(ACC, 0)
              @primitives.store_var(ACC, IR::Nodes::Background.stream_vars(node.name).first)
              # A map the game changes goes up as declared, copied again (MapStreaming#emit_kept_map_source).
              emit_kept_map_forgotten(bg.stream) if bg.stream.kept
              emit_stream_fill(bg, at_corner: true)
            else
              @uploads.emit_dma_blob(bg.map, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES), bg.map_units)
            end
            depth = bg.small ? 0 : BG_256_COLOR # a small layer's tiles each name their own bank
            @emitter.write_reg16(BG_CNT_REGS[bg.bg], bg.priority | bg.in_blocks | depth | (bg.char_base << CHAR_BASE_SHIFT) |
                                            (bg.screen_block << 8) | bg.size)
            # Start unscrolled. A bent one's sideways place is its table's on every line, so its
            # rows are put back to the corner there instead.
            # In a border the corner is the game's screen's, so the layer is scrolled by it (see
            # BorderSprites).
            if @raster.bent_from_table?(node.name)
              @raster.emit_bend_put_up(node.name)
            else
              @emitter.write_reg16(BG_HOFS_REGS[bg.bg], unscrolled(:x))
            end
            @emitter.write_reg16(BG_VOFS_REGS[bg.bg], unscrolled(:y))
            # ...and a status bar starts at the row it was declared with, until the gap after
            # this pass places it where the game sets (Reference#bar_top_shown).
            emit_bar_registers(bg, top: node.bar_top) if node.bar?
          end

          # Put a status bar's top at a row (Reference#exec_place_bar), kept between 0 and the
          # bottom of the screen. BAR_ROW holds the layer's scroll while ACC becomes the window's.
          BAR_ROW = 2

          def emit_place_bar(node)
            bg = @layout.screen.backgrounds[node.name]
            return if bg.nil? || @layout.screen.picture.scenery.none? { |each| each.name == node.name && each.bar? }

            emit_bar_top(node, bg)
            emit_bar_covers(bg, node.covers) if node.covers
          end

          def emit_bar_top(node, bg)
            known = @primitives.const_int(node.top)
            return emit_bar_registers(bg, top: known) if known

            @lowering.value(node.top)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))
            @emitter.emit(ASM.cmp_imm(ACC, bar_screen_height))
            @emitter.emit(ASM.mov_imm_cond(:gt, ACC, bar_screen_height))
            emit_bar_registers(bg, top: nil)
          end

          # The rows a status bar's top is kept to: the screen's, or in a border the game's screen's.
          def bar_screen_height = @layout.border ? @layout.border.game_screen_height : SCREEN_HEIGHT

          # A bar that covers sprites (StatusBar#covers_sprites=): the sprites are left out of the
          # layers shown inside the bar's window, which the display reads pixel by pixel, so a
          # sprite across the bar's top shows its part above.
          def emit_bar_covers(bg, covers)
            @lowering.value(covers)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:ne, ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:eq, ACC, WIN_OBJ))
            return @layout.border.emit_bar_covers(bg.bg) if @layout.border

            @emitter.emit(ASM.orr_imm(ACC, ACC, (1 << bg.bg) | WIN_EFFECT))
            @emitter.emit(ASM.lsl_imm(ACC, ACC, WIN1_SHIFT))
            @primitives.store_halfword_acc(REG_WININ)
          end

          # A status bar on the Advance is one of its background layers, read from its own map's
          # top-left corner at the bar's top row, and kept to the rows from there down by the
          # display's second window: inside the window the display draws the bar's layer and the
          # sprites and nothing else, so the backgrounds under the bar are not drawn there and its
          # see-through pixels show the backdrop. Outside it, the bar's layer is left out.
          #
          # The window is told its place, and which layers show inside and outside it, wherever
          # the bar is placed. Those are the display's settings for this screen alone, and a game
          # with a bar uses no other window (Checks::TooManyStatusBars refuses the ones that do).
          #
          # +top+ is a row written in the program, or nil for the row in ACC, already kept to the
          # screen.
          #
          # In a border the bar is in the game's screen, and the windows are laid out another way
          # (BorderSprites#emit_bar_registers).
          def emit_bar_registers(bg, top:)
            if @layout.border
              return @layout.border.emit_bar_registers(bg.bg, top: top, x_scroll: BG_HOFS_REGS[bg.bg],
                                                              y_scroll: BG_VOFS_REGS[bg.bg], scratch: BAR_ROW)
            end

            top = top.clamp(0, SCREEN_HEIGHT) if top
            if top
              @emitter.write_reg16(BG_VOFS_REGS[bg.bg], -top & 0x1FF)
              @emitter.write_reg16(REG_WIN1V, (top << 8) | SCREEN_HEIGHT)
            else
              @emitter.emit(ASM.rsb_imm(BAR_ROW, ACC, 0)) # the map's top row is drawn at the bar's top row
              @emitter.emit_number(TMP, BG_VOFS_REGS[bg.bg])
              @emitter.emit(ASM.store_halfword(BAR_ROW, TMP))
              @emitter.emit(ASM.lsl_imm(ACC, ACC, 8))
              @emitter.emit(ASM.orr_imm(ACC, ACC, SCREEN_HEIGHT))
              @primitives.store_halfword_acc(REG_WIN1V)
            end
            # Every write from here loads its own number, so these come after ACC is done with.
            @emitter.write_reg16(BG_HOFS_REGS[bg.bg], 0)
            @emitter.write_reg16(REG_WIN1H, SCREEN_WIDTH) # from the left edge to the right
            bar_layer = 1 << bg.bg
            @emitter.write_reg16(REG_WININ, (bar_layer | WIN_OBJ | WIN_EFFECT) << WIN1_SHIFT)
            @emitter.write_reg16(REG_WINOUT, (WIN_ALL_LAYERS & ~bar_layer) | WIN_EFFECT)
          end

          # A background held to a BOX (Reference#exec_box_background) is the display's second window.
          #
          # A window is a rectangle of the screen the display is told about, and two switches for
          # each layer: whether it is drawn inside the rectangle, and whether outside every window.
          # The display reads those switches for each pixel as it draws, so the layer is never
          # drawn outside the box at all, and the layers behind it and the backdrop show there.
          # Inside window 1 every layer is on, set once at boot (#emit_boot_box_window); outside,
          # every layer but the boxed one is. The rectangle is told as two pairs of edges, the left
          # and the one just past the right in one register, the top and the one just past the
          # bottom in another, each a byte, which is why the box is kept to the screen first.
          #
          # Held to no box, the boxed layer's switch outside is on again, and the window no longer
          # hides anything. A box with nothing on the screen is a window with nothing in it, edges
          # of nought, so the layer is hidden everywhere.
          BOX_LEFT = 4
          BOX_TOP = 5
          BOX_RIGHT = 6
          BOX_BOTTOM = 7

          def emit_box_background(node)
            bg = @layout.screen.backgrounds[node.name]
            # The same layer for every declaration of one name (see ScreenLayout#layer_slots); a
            # background on a screen with no tiled layer has none, and nothing is told; nor is
            # anything in a game whose boxes only ever show everywhere, which has no window.
            return if bg.nil?
            return emit_layer_switch(node, bg) if node.whole
            return unless @layout.screen.boxes_backgrounds?

            outside = (WIN_ALL_LAYERS & ~(1 << bg.bg)) | WIN_EFFECT
            everywhere = @emitter.gensym
            empty = @emitter.gensym
            done = @emitter.gensym
            @lowering.value(node.held)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, everywhere, cond: :eq)
            [[node.x, BOX_LEFT], [node.y, BOX_TOP], [node.width, BOX_RIGHT], [node.height, BOX_BOTTOM]].each do |value, reg|
              @lowering.value(value)
              @emitter.emit(ASM.mov_reg(reg, ACC))
            end
            # A width or height of nought or less holds nothing; otherwise the far edges are the
            # near ones and the size, and then all four are kept to the screen.
            [BOX_RIGHT, BOX_BOTTOM].each do |size|
              @emitter.emit(ASM.cmp_imm(size, 0))
              @emitter.emit_branch(:bcond, empty, cond: :le)
            end
            @emitter.emit(ASM.add_reg(BOX_RIGHT, BOX_LEFT, BOX_RIGHT))
            @emitter.emit(ASM.add_reg(BOX_BOTTOM, BOX_TOP, BOX_BOTTOM))
            [[BOX_LEFT, SCREEN_WIDTH], [BOX_RIGHT, SCREEN_WIDTH], [BOX_TOP, SCREEN_HEIGHT], [BOX_BOTTOM, SCREEN_HEIGHT]].each do |reg, edge|
              @emitter.emit(ASM.cmp_imm(reg, 0))
              @emitter.emit(ASM.mov_imm_cond(:lt, reg, 0))
              @emitter.emit(ASM.cmp_imm(reg, edge))
              @emitter.emit(ASM.mov_imm_cond(:gt, reg, edge))
            end
            # ...and a box wholly off the screen has nothing left once it is.
            @emitter.emit(ASM.cmp_reg(BOX_RIGHT, BOX_LEFT))
            @emitter.emit_branch(:bcond, empty, cond: :le)
            @emitter.emit(ASM.cmp_reg(BOX_BOTTOM, BOX_TOP))
            @emitter.emit_branch(:bcond, empty, cond: :le)
            @emitter.emit(ASM.orr_reg_lsl(ACC, BOX_RIGHT, BOX_LEFT, 8))
            @primitives.store_halfword_acc(REG_WIN1H)
            @emitter.emit(ASM.orr_reg_lsl(ACC, BOX_BOTTOM, BOX_TOP, 8))
            @primitives.store_halfword_acc(REG_WIN1V)
            @emitter.write_reg16(REG_WINOUT, outside)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(empty)
            @emitter.write_reg16(REG_WIN1H, 0)
            @emitter.write_reg16(REG_WIN1V, 0)
            @emitter.write_reg16(REG_WINOUT, outside)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(everywhere)
            @emitter.write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT)
            @emitter.place_label(done)
          end

          # WINDOW 1 FOR A GAME THAT HOLDS A BACKGROUND TO A BOX, set at boot: every layer and the
          # colour effect inside it and outside, and a rectangle with nothing in it, so the window
          # changes nothing until a box is set. It is switched on with the layers (see
          # Drawing#tiled_dispcnt), and a game with a box has no other window (see
          # Checks::BoxedBackgroundCannotShare).
          def emit_boot_box_window
            return unless @layout.screen.boxes_backgrounds?

            @emitter.write_reg16(REG_WIN1H, 0)
            @emitter.write_reg16(REG_WIN1V, 0)
            @emitter.write_reg16(REG_WININ, (WIN_ALL_LAYERS | WIN_EFFECT) << WIN1_SHIFT)
            @emitter.write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT)
          end

          # A scene putting its backgrounds up shows them everywhere: the last scene's box is set
          # aside, and this scene's own, if it sets one, is told in the gap after this pass. The
          # layers of +scenery+ are no longer switched off either (#emit_layer_switch): the scene
          # switches its layers on as its sending ends, and a background every scene shows keeps
          # its switch.
          def emit_box_set_aside(scenery = [])
            @emitter.write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT) if @layout.screen.boxes_backgrounds?
            return unless @layout.screen.hides_layers?

            bits = scenery.filter_map { |node| @layout.screen.backgrounds[node.name] }
                          .reduce(0) { |all, bg| all | layer_switch_bit(bg) }
            return if bits.zero?

            @primitives.load_var(ACC, LAYERS_SWITCHED_OFF)
            @emitter.emit(ASM.bic_imm(ACC, ACC, bits))
            @primitives.store_var(ACC, LAYERS_SWITCHED_OFF)
          end

          # A background hidden whole (Nodes::BoxBackground#whole, `hide`) is its layer switched
          # OFF. The display's settings have a bit for each of the four background layers, and a
          # layer whose bit is clear is not drawn at all, so what is behind it and the backdrop
          # show (GBATEK, LCD I/O Display Control, DISPCNT bits 8 to 11). No window is used, so
          # a light or a status bar can have both.
          #
          # The bit is changed here, in the gap between frames, where nothing is being drawn. But
          # other writes switch the layers on later in a pass: a game whose scenes use different
          # layers writes all of them every pass (Drawing#emit_scene_layers), and sending tiles
          # with the layers off switches them back on after (#emit_layers_back_on_or_held), and
          # entering a screen drawn from tiles writes them all (#emit_display_control_written). So the
          # layers hidden are kept here too, and each of those writes leaves them off
          # (#emit_without_switched_off_layers). Shown again, the bit is set only where this
          # switched it off, so a layer off for another reason is left alone.
          #
          # What it costs, in every gap while its scene is up: the value's load and a compare. Shown,
          # a load of the note and a test of the bit, and nothing more unless it was hidden. Hidden,
          # every gap writes the note again and reads, changes and writes the display's settings
          # (with the interrupts held off around the pair in a game that holds its layers), whether
          # or not anything changed since the gap before. Each write of the layers elsewhere costs
          # a load of the note and one instruction more. A game that never hides a background whole
          # emits none of this.
          LAYERS_SWITCHED_OFF = :_layers_switched_off

          def layer_switch_bit(bg) = BG0_ENABLE << bg.bg

          def emit_layer_switch(node, bg)
            bit = layer_switch_bit(bg)
            shown = @emitter.gensym
            done = @emitter.gensym
            @lowering.value(node.held)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, shown, cond: :eq)
            @primitives.load_var(ACC, LAYERS_SWITCHED_OFF)
            @emitter.emit(ASM.orr_imm(ACC, ACC, bit))
            @primitives.store_var(ACC, LAYERS_SWITCHED_OFF)
            emit_display_control_changed { @emitter.emit(ASM.bic_imm(ACC, ACC, bit)) }
            @emitter.emit_branch(:b, done)
            @emitter.place_label(shown)
            @primitives.load_var(ACC, LAYERS_SWITCHED_OFF)
            @emitter.emit(ASM.and_imm(TMP, ACC, bit))
            @emitter.emit(ASM.cmp_imm(TMP, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit(ASM.bic_imm(ACC, ACC, bit))
            @primitives.store_var(ACC, LAYERS_SWITCHED_OFF)
            emit_display_control_changed { @emitter.emit(ASM.orr_imm(ACC, ACC, bit)) }
            @emitter.place_label(done)
          end

          # At power-on no layer is switched off, whatever the memory held.
          def emit_no_layers_switched_off
            @primitives.store_word_immediate(0, @primitives.var_addr(LAYERS_SWITCHED_OFF)) if @layout&.screen&.hides_layers?
          end

          # Write the whole of the display's settings, +value+, as a screen drawn from tiles is
          # entered, save the layers the game has hidden (#emit_layer_switch). A hidden background
          # every screen shows stays off as the screen comes back from one of another kind, as the
          # interpreter shows it, until it is put back as declared and the gap after shows it again.
          # So the note is cleared only at power-on and as a scene puts its own scenery up
          # (#emit_box_set_aside). A game that hides none writes +value+ as it is.
          def emit_display_control_written(value)
            return @emitter.write_reg16(REG_DISPCNT, value) unless @layout&.screen&.hides_layers?

            @emitter.emit_number(ACC, value)
            emit_without_switched_off_layers(ACC)
            @emitter.emit_number(TMP, REG_DISPCNT)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # Clear from +reg+, the display's settings about to be written, the layers the game has
          # hidden (#emit_layer_switch). Uses +scratch+. Nothing in a game that hides none.
          def emit_without_switched_off_layers(reg, scratch: TMP)
            return unless @layout&.screen&.hides_layers?

            @primitives.load_var(scratch, LAYERS_SWITCHED_OFF)
            @emitter.emit(ASM.bic_reg(reg, reg, scratch))
          end

          # Read the display's settings into ACC, let the block change them, write them back. Where
          # the screen's interrupt can switch held layers on, with it off between the read and the
          # write (Primitives#with_interrupts_held_off). Uses ACC and TMP.
          def emit_display_control_changed
            write = lambda do
              @emitter.emit_number(TMP, REG_DISPCNT)
              @emitter.emit(ASM.load_halfword(ACC, TMP))
              yield
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
            holds_layers? ? @primitives.with_interrupts_held_off(&write) : write.call
          end

          # A block of cells (Nodes::SetTileBlock) is its cells written one by one, as its children
          # write them: this lowering writes each cell straight into the map where the line is.
          def emit_set_tile_block(node) = node.children.each { |stmt| @lowering.statement(stmt) }

          # Put a different tile in one cell, while the game runs.
          #
          # A background's map is a grid of half-word cells in video memory, each naming
          # the tile to draw there, so changing one is one half-word written to a place
          # worked out from the cell's column and row.
          #
          # When the write happens, which is the question this raises and which is worth
          # writing down because the obvious worry turns out not to hold. The display
          # reads the map while it draws, so a write can land between two scanlines of the
          # very cell being drawn — and then that cell shows the old tile on its top rows
          # and the new one on its bottom rows, for one frame.
          #
          # It is not a torn or corrupt picture: a cell is a half-word, and a half-word
          # store is one write. Nothing can be read half-written. The whole effect is that
          # one 8-pixel cell is split across a single frame, and only when a write lands
          # inside that cell's own six-thousandths of a frame.
          #
          # So this writes straight away rather than holding the frame's changes and
          # applying them between frames. Holding them costs a buffer in the console's
          # scarcest memory, a policy for when it fills, and about four times the
          # instructions — to remove an artifact of one frame of one cell, on the things
          # this exists for: a door opening, a pot breaking, a bombable wall. What that
          # bargain does not cover is a bulk change — a whole room swapped in one frame —
          # where half the old room and half the new really would show at once. That wants
          # a verb of its own, handing over a map in one go between frames.
          #
          # ...and a background declared `held: true` asks for the other bargain: its changes
          # wait for the gap between frames and go in together (see HeldTiles).
          #
          # A tile picked as the program runs is written as the tests it stands for
          # (IR::PickedTile), each with a store of its own: this lowering keeps no table of a
          # background's cells to index yet.
          def emit_set_tile(node)
            if node.picked?
              tests = PickedTile.tests(node)
              return tests && @lowering.statement(tests)
            end
            emit_for_each_declaration(node.name) do |bg|
              next if bg.nil? # a background with no tiled layer (a bitmap-mode program)
              next emit_streamed_tile_change(node, bg) if bg.stream

              grid = bg.grid or raise_no_cells_to_change(node.name)
              # A tile only another scene's declaration of this name has, from a line written
              # for that scene: this declaration's part of the line writes nothing.
              entry = grid.cells[node.tile] or next
              fixed = [@primitives.const_int(node.col), @primitives.const_int(node.row)]
              next emit_fixed_tile_write(node, bg, grid, entry, *fixed) if fixed.all?

              emit_computed_tile_write(node, bg, grid, entry)
            end
          end

          # A cell of a map brought into view a strip at a time (MapStreaming#emit_streamed_tile_write).
          # A tile only another scene's declaration has writes nothing here, as on a grid.
          def emit_streamed_tile_change(node, bg)
            if node.held
              raise LoweringError, "The background :#{node.name} has maps of different sizes or a map bigger than 64x64 " \
                                   "cells, and it holds its cell changes (`held: true`). The Game Boy Advance build does " \
                                   "not make that yet. To fix this, remove `held: true`."
            end
            entry = bg.stream.cells[node.tile] or return
            emit_streamed_tile_write(node, bg, entry)
          end

          # A background that turns and resizes holds a tile number in each cell and nothing
          # else, so the framework has no way yet to change one cell of it while the game runs.
          def raise_no_cells_to_change(name)
            raise LoweringError,
                  "The background :#{name} turns and resizes, so one cell of it cannot be changed " \
                  "while the game runs. Its cells hold a tile number and nothing else. To fix this, " \
                  "stop turning this background, or change the whole map with show_map."
          end

          # A cell settled while the program was written: the address is worked out here,
          # in Ruby, and the console does one store.
          def emit_fixed_tile_write(node, bg, grid, entry, col, row)
            return emit_fixed_tile_held(bg, grid, entry, col, row) if node.held
            return unless grid.holds?(col, row)

            @emitter.write_reg16(map_cell_address(bg, grid, col, row), entry)
          end

          # The address of one cell, and why it is not simply row times width.
          #
          # A map wider or taller than 32 cells is stored as several 32x32 SQUARES — left
          # then right, top pair before bottom pair — so a cell's place depends on which
          # quarter of the map it is in. 32 is a power of two, so that is shifts and masks
          # rather than division.
          def map_cell_address(bg, grid, col, row)
            quarter = ((row / MAP_CELLS) * (grid.cols / MAP_CELLS)) + (col / MAP_CELLS)
            index = (quarter * MAP_CELLS * MAP_CELLS) + ((row % MAP_CELLS) * MAP_CELLS) + (col % MAP_CELLS)
            VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES) + (index * 2)
          end

          # A cell the game works out. The two coordinates are held in scratch registers
          # while the address is assembled, and a cell outside the map is skipped rather
          # than written somewhere else — so a coordinate that ran off the edge costs a
          # test and changes nothing.
          TILE_COL = 4
          TILE_ROW = 5
          TILE_ADDR = 6

          def emit_computed_tile_write(node, bg, grid, entry)
            @lowering.value(node.col)
            @emitter.emit(ASM.mov_reg(TILE_COL, ACC))
            @lowering.value(node.row)
            @emitter.emit(ASM.mov_reg(TILE_ROW, ACC))

            done = @emitter.gensym
            # One unsigned compare catches both ends: a negative coordinate reads as a
            # very large number, so anything outside 0...size fails the same test.
            @emitter.emit(ASM.cmp_imm(TILE_COL, grid.cols))
            @emitter.emit_branch(:bcond, done, cond: :hs)
            @emitter.emit(ASM.cmp_imm(TILE_ROW, grid.rows))
            @emitter.emit_branch(:bcond, done, cond: :hs)

            emit_cell_index(grid)
            if node.held
              emit_computed_tile_held(bg, entry)
              return @emitter.place_label(done)
            end

            @emitter.emit_number(TMP, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES))
            @emitter.emit(ASM.lsl_imm(TILE_ADDR, TILE_ADDR, 1)) # two bytes a cell
            @emitter.emit(ASM.add_reg(TILE_ADDR, TMP, TILE_ADDR))
            @emitter.emit_number(ACC, entry)
            @emitter.emit(ASM.store_halfword(ACC, TILE_ADDR))
            @emitter.place_label(done)
          end

          # The cell's index within the whole map, built from the column and row into
          # TILE_ADDR. Which quarter of the map it is in rides in bits 10 and up; a map
          # that fits one square has no quarters and needs neither shift.
          def emit_cell_index(grid)
            @emitter.emit(ASM.and_imm(TILE_ADDR, TILE_ROW, MAP_CELLS - 1))
            @emitter.emit(ASM.lsl_imm(TILE_ADDR, TILE_ADDR, 5))
            @emitter.emit(ASM.and_imm(TMP, TILE_COL, MAP_CELLS - 1))
            @emitter.emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
            return if grid.cols == MAP_CELLS && grid.rows == MAP_CELLS

            unless grid.rows == MAP_CELLS
              # The bottom half of a tall map is a whole square further on — two of them
              # when the map is also wide, since a row of squares comes first.
              @emitter.emit(ASM.lsr_imm(TMP, TILE_ROW, 5))
              @emitter.emit(ASM.lsl_imm(TMP, TMP, grid.cols == MAP_CELLS ? 10 : 11))
              @emitter.emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
            end
            return if grid.cols == MAP_CELLS

            @emitter.emit(ASM.lsr_imm(TMP, TILE_COL, 5))
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 10))
            @emitter.emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
          end

          # Hand a background a whole different map.
          #
          # A background's maps all live in the cartridge, laid end to end and all the same
          # size, so the map numbered N starts N strides along from the first. Copying one
          # into the layer's cells is then a single DMA — the same copy the boot upload
          # already does, at an address worked out rather than known.
          #
          # Why this can be arithmetic rather than a test per map, which is what makes a
          # game with hundreds of rooms affordable: the stride is settled while the program
          # is built, so a room number becomes an address in two instructions however many
          # rooms there are. A chain of comparisons would grow with the game.
          #
          # The stride is a power of two for a regular layer (a grid is 32 or 64 cells a
          # side, two bytes a cell) so the multiply is a shift; a rotate/scale layer's byte
          # map is a power of two too. Anything else multiplies, which is still one
          # instruction on this chip.
          #
          # WHEN it happens is decided above this: the framework puts the copy in the gap
          # between frames, on the frame the answer changed and no other (see
          # Builder#finalize_background_maps). Thousands of cells cannot go in while the
          # display is reading them, or the screen shows half of each map.
          # A map number naming no map leaves the cells as they are — the same policy
          # set_tile takes for a cell off the edge of the map, and for the same reason: a
          # number the game worked out can be anything, and a game should not need a test
          # around it to stay safe.
          def emit_show_map(node)
            emit_for_each_declaration(node.name) do |bg|
              next if bg.nil? || bg.map_count < 2 # no tiled layer, or nothing else to show

              done = @emitter.gensym
              emit_call_set_swap_if_changing(node, bg, done) if bg.sets
              emit_map_copy(node, bg, done)
              @emitter.place_label(done)
            end
          end

          def emit_map_copy(node, bg, done)
            return emit_stream_map_change(node, bg, done) if bg.stream

            emit_map_source(bg, node.which, done) # from that map in the cartridge
            @emitter.note_video_copy("handing background :#{node.name} another map", bg.map_units * 2)
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(ACC), to: map_vram_address(bg),
                                   control: bg.map_units | DMA_ENABLE) # 16-bit, both ends advancing
          end

          # Where the display's settings are kept while a set of tiles is brought in with the
          # background layers switched off.
          SET_SWAP_DISPLAY = :_set_swap_display

          # ...and where the number of the map coming in is kept while its set is brought in.
          SET_SWAP_MAP = :_set_swap_map

          # ...and whether a set came in in this gap, for the sprite work after it (see
          # SpriteDrawing#emit_unless_set_just_came_in).
          SET_CAME_IN = :_set_came_in

          # Registers held while a set is brought in: the set that is coming in, and the size
          # of one set's colour table. Nothing reading a variable or a cartridge address touches
          # either, so they last across those.
          SET_PICKED = 3
          SET_STRIDE = 2

          # Is the map numbered +which+ of another set of tiles than the one in place? Then call
          # the routine that brings that set in, and the map with it (see
          # #emit_set_swap_routines). A map of the set already in place falls through to the
          # plain map copy, and nothing else.
          #
          # This is all of it that the caller holds, and the caller is the game loop: the gap
          # between frames, which every frame of every screen passes through and which is the
          # first thing kept in the console's quick memory. A game changes area a handful of
          # times an hour. Written out here, bringing a set in was the larger part of the loop
          # of a game that walks between areas, once for each background that does — code that
          # took the quick memory from routines every frame of play runs.
          def emit_call_set_swap_if_changing(node, bg, done)
            same = @emitter.gensym
            @lowering.value(node.which)
            @emitter.emit(ASM.cmp_imm(ACC, bg.map_count))
            @emitter.emit_branch(:bcond, done, cond: :hs) # a number naming no map changes nothing
            @emitter.emit_load_data_address(TMP, bg.sets.sets_of_maps)
            @emitter.emit(ASM.ldrb_reg(SET_PICKED, TMP, ACC)) # the set that map draws from
            @primitives.load_var(TMP, bg.sets.var)
            @emitter.emit(ASM.cmp_reg(SET_PICKED, TMP))
            @emitter.emit_branch(:bcond, same, cond: :eq)
            # The routine is handed the map's number and its set, in the registers that hold
            # them here already.
            @placement.emit_call_cold_routine(set_swap_routine_label(node.name, bg))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(same)
          end

          # The routine that brings one of background +name+'s sets in, named for the
          # background, and for the +scene+ of its declaration too for a background declared in
          # several (see ScreenLayout#declared_background).
          def self.set_swap_routine(name, scene: nil)
            return Messages::MadeNames.make(:set_swap, background: name) unless scene

            Messages::MadeNames.make(:set_swap_in_scene, background: name, scene: IR::Modes.strip_scene_prefix(scene))
          end

          # The label of the routine that brings one of +bg+'s sets in, reserved the first
          # time a map of that background is shown and emitted once, later, by
          # #emit_set_swap_routines — however many places show it a map.
          def set_swap_routine_label(name, bg)
            @pending_set_swaps ||= {}
            @pending_set_swaps[bg.sets.routine] ||= [name, bg]
            bg.sets.routine
          end

          # Bring in the set of tiles a map draws from, for a background that walks between
          # areas — and the map with it, while the layers are off. One routine a background,
          # emitted after the program's own code and reached only by the call above, which
          # hands it the map's number.
          #
          # Every set sits in the same stretch of tile memory, so the set in place is the only
          # one the console can draw, and a map of another set shown over it would draw every
          # cell with the wrong picture. So the map is copied in only once its set is, and the
          # background layers are switched off for both copies: a set is thousands of bytes,
          # more than the gap between frames always holds, and with the layers off the console
          # draws the backdrop rather than a part-copied set. Ending with the layers on again is
          # the same picture the next frame was going to show.
          #
          # It always runs from the cartridge. Most of what it costs is the copies, which the
          # console stops the processor for wherever the code asking for them runs from. The
          # view of a big map is filled by that background's own routine, which the build can
          # keep in the quick memory (see MapStreaming#emit_stream_view_routine). What is left
          # running from the cartridge is the colours of a game that tints or fades, blended
          # one at a time.
          def emit_set_swap_routines
            (@pending_set_swaps || {}).each do |label, (name, bg)|
              @emitter.emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
              @emitter.place_label(label)
              @emitter.emit(ASM.push(14))
              emit_bring_set_in(name, bg)
              @emitter.emit(ASM.pop(15))
              # Where it ends, so a profile of the finished game can name it (see
              # GBA#lowered_routine_addresses).
              @emitter.place_label(DerivedNames.routine_end(label))
            end
            (@pending_walking_colors || {}).each do |label, bg|
              @emitter.emit(ASM.loop_forever)
              @emitter.place_label(label)
              @emitter.emit(ASM.push(14))
              emit_walking_colors_send(bg)
              @emitter.emit(ASM.pop(15))
              @emitter.place_label(DerivedNames.routine_end(label))
            end
          end

          # The body of that routine. The map's number arrives in the first register and the
          # set it draws from in SET_PICKED. The caller has made sure the number names a map,
          # so the test the map copy below makes of it again never fails here.
          def emit_bring_set_in(name, bg)
            swap = bg.sets
            @primitives.store_var(ACC, SET_SWAP_MAP)
            @emitter.emit(ASM.mov_reg(ACC, SET_PICKED))
            @primitives.store_var(ACC, swap.var)
            @emitter.emit_number(ACC, 1)
            @primitives.store_var(ACC, SET_CAME_IN)

            emit_layers_off_for_sending(SET_SWAP_DISPLAY)

            emit_copy_set_tiles(swap)
            emit_set_char_base(bg, swap) if swap.char_base_table
            emit_walking_runs_again(swap)

            layers_back_on = @emitter.gensym
            emit_map_copy(Build.show_map(name, which: Build.var_ref(SET_SWAP_MAP)), bg, layers_back_on)
            emit_stream_fill(bg) if bg.stream # ...the view of it, while the layers are still off
            emit_point_colors_at_area(name, bg)
            emit_area_colors_unless_up(name, bg)
            @emitter.place_label(layers_back_on)
            @primitives.load_var(ACC, SET_SWAP_DISPLAY)
            emit_layers_back_on_or_held(ACC)
          end

          # The layers held off until the next gap, as their bits of the display's settings: nought
          # while none is held.
          #
          # Sending a set of tiles or a scene's scenery happens with the layers off, and the
          # console goes on drawing while it does. When the work is bigger than the gap between
          # pictures, it ends part way down a picture, and a layer switched on there shows from
          # that row down: the top of the picture is the backdrop and the rest the new scenery,
          # torn at a row set by how many cycles the work took. So the layers due back on part
          # way down a picture are kept off for the rest of it and switched on by the screen's
          # own interrupt at the start of the next gap (#emit_held_layers_on), whatever the game
          # is doing then: waiting, showing a late page, or stopped. The picture is the backdrop,
          # top to bottom, and the next one is whole. A sending that ends inside the gap shows
          # its scenery on the picture after it, as the interpreter does.
          #
          # The sprites are held with the backgrounds, off for the sending and for the picture it
          # ran into. The rest of the pass writes to the display too (a blend, a window), and
          # those writes land part way down that picture at a row set by timing; over the bare
          # backdrop they show nowhere, but on a sprite they would, so two builds of one game a
          # few hundred cycles apart would draw that picture's sprites differently.
          #
          # A sending that ends in a later gap than the one its pass started in is held too: the
          # picture after that gap is drawn while the pass is late, and is held whichever side of
          # the gap's end the sending finished on (#emit_branch_unless_in_pass_gap).
          #
          # A scene's sending counted at more than half the gap is held on
          # every build, wherever it ends (Drawing#first_picture_held?). For a smaller one in a
          # pass on time, which side of the gap's end it finishes on is still timing:
          # one that ends in the last lines of the gap shows the scene, a little later the
          # backdrop. Hold every
          # sending instead and the first picture of every scene would be the backdrop, where
          # the interpreter, and every game's scene that fits the gap, shows the scenery.
          # (GBATEK, LCD I/O Display Control: DISPCNT takes effect from the line being drawn;
          # VCOUNT is that line, 0 to 159 on the picture and 160 to 227 in the gap; the V-Blank
          # interrupt is requested as line 160 starts.)
          #
          # What it holds is the layers the game wants on now: a write of the scene's layers on
          # every pass puts its own wanted layers here while a hold lasts
          # (#emit_display_control_keeping_held_off), and sending something new with the layers
          # off takes the hold over (#emit_layers_off_for_sending), so the interrupt never
          # switches on a layer the game has turned off since, or one being sent to.
          LAYERS_HELD = :_layers_held

          # The display settings' bits that switch the four background layers on.
          BG_LAYER_BITS = BG0_ENABLE | BG1_ENABLE | BG2_ENABLE | BG3_ENABLE

          # The bits a sending holds off: the background layers and the sprites.
          HELD_LAYER_BITS = BG_LAYER_BITS | OBJ_ENABLE

          # ...save in a game in a border, which is drawn with sprites (BorderSprites) and stays
          # up through every picture, as SpriteDrawing#emit_switch_sprite_layer keeps it. So a
          # bordered game's held picture keeps its sprites, and for it a write to the display
          # landing part way down that picture can still show on them: the timing edge the
          # sprites are held for elsewhere remains there.
          def held_layer_bits = @layout.border ? BG_LAYER_BITS : HELD_LAYER_BITS

          # Does this game switch layers back on after sending them something, and
          # wait for frames, so that it has a gap to hold them for? A game that does neither
          # emits none of this.
          def holds_layers? = !@layout.nil? && @layout.holds_layers?

          # Before sending: keep the display's settings in +saved+, with any layers held from an
          # earlier sending counted as on (they are this sending's now), and switch the layers
          # off: the background layers, and in a game that holds them, the sprites unless it is in
          # a border (#held_layer_bits). Uses ACC, TMP
          # and ADDR.
          def emit_layers_off_for_sending(saved)
            unless holds_layers?
              @emitter.emit_number(TMP, REG_DISPCNT)
              @emitter.emit(ASM.load_halfword(ACC, TMP))
              @primitives.store_var(ACC, saved)
              @emitter.emit(ASM.bic_imm(ACC, ACC, BG_LAYER_BITS))
              return @emitter.emit(ASM.store_halfword(ACC, TMP))
            end

            # The hold is read before it is cleared, and the display after: an interrupt between
            # any two of them leaves the held bits in ACC or on the display, never lost.
            @primitives.load_var(ACC, LAYERS_HELD)
            @emitter.emit_number(TMP, 0)
            @primitives.store_var(TMP, LAYERS_HELD)
            @emitter.emit_number(TMP, REG_DISPCNT)
            @emitter.emit(ASM.load_halfword(ADDR, TMP))
            @emitter.emit(ASM.orr_reg(ACC, ACC, ADDR))
            @primitives.store_var(ACC, saved)
            @emitter.emit(ASM.bic_imm(ACC, ACC, held_layer_bits))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # After sending: write +reg+, the display's settings with the layers wanted back on: as
          # they are in the gap the pass started in, and with the layers held off anywhere else,
          # for the screen's interrupt to switch on at the start of the next gap
          # (#emit_branch_unless_in_pass_gap). With +held+ they are held wherever the sending ended,
          # for a scene whose sending can run past the gap (Drawing::SENDING_ROOM_CYCLES).
          # Uses TMP and ADDR.
          def emit_layers_back_on_or_held(reg, held: false)
            emit_without_switched_off_layers(reg) # ...save the ones the game hid
            unless holds_layers?
              @emitter.emit_number(TMP, REG_DISPCNT)
              return @emitter.emit(ASM.store_halfword(reg, TMP))
            end

            @primitives.with_interrupts_held_off do
              write = @emitter.gensym
              unless held
                held_label = @emitter.gensym
                emit_branch_unless_in_pass_gap(held_label)
                @emitter.emit_number(TMP, 0) # on now, so nothing is held from an earlier sending
                @primitives.store_var(TMP, LAYERS_HELD)
                @emitter.emit_branch(:b, write)
                @emitter.place_label(held_label)
              end
              @emitter.emit(ASM.and_imm(TMP, reg, held_layer_bits))
              @primitives.store_var(TMP, LAYERS_HELD)
              @emitter.emit(ASM.bic_imm(reg, reg, held_layer_bits))
              @emitter.place_label(write)
              @emitter.emit_number(TMP, REG_DISPCNT)
              @emitter.emit(ASM.store_halfword(reg, TMP))
            end
          end

          # When a sending's layers may come on at once: in the gap the pass started in, and only
          # there. Part way down a picture they would tear it (LAYERS_HELD). In a later gap, which
          # a pass reaches only after running past the start of one, the picture after is drawn
          # while the pass is still finishing: the pass's own picture is the one after its wait,
          # where the interpreter shows the scene. Switched on there, that late picture showed the
          # scene where the sending ended in the gap and the backdrop where it ran a few lines on,
          # so two builds of one game whose pictures take different times to send differed on it.
          # Held, the late picture is the backdrop whichever way the sending ended, and the scene
          # comes up at the start of the gap the pass's wait ends in.
          #
          # A gap has started since the pass began when the screen's interrupt has counted one
          # (Frames: COUNT moved from SEEN, the mark taken as the pass began) or has one waiting,
          # which it does when the gap started while interrupts were held off (GBATEK, Interrupt
          # Control: IF bit 0 is set as V-Blank starts, and stays set until the handler clears it).
          # Before the game loop's first mark the marks are not yet a pass's, and the layers are
          # held: the picture is off until the first wait anyway (Drawing#initial_forced_blank_bit),
          # and the interrupt that wakes it switches them on. Jumps to +held+ unless the layers may
          # come on. Interrupts must be held off. Uses TMP and ADDR.
          def emit_branch_unless_in_pass_gap(held)
            @emitter.emit_number(TMP, REG_VCOUNT)
            @emitter.emit(ASM.load_halfword(TMP, TMP))
            @emitter.emit(ASM.cmp_imm(TMP, SCREEN_HEIGHT))
            @emitter.emit_branch(:bcond, held, cond: :lo)
            @emitter.emit_number(TMP, REG_IF)
            @emitter.emit(ASM.load_halfword(TMP, TMP))
            @emitter.emit(ASM.tst_imm(TMP, IRQ_VBLANK))
            @emitter.emit_branch(:bcond, held, cond: :ne)
            @primitives.load_var(TMP, IR::Frames::COUNT)
            @primitives.load_var(ADDR, IR::Frames::SEEN)
            @emitter.emit(ASM.cmp_reg(TMP, ADDR))
            @emitter.emit_branch(:bcond, held, cond: :ne)
          end

          # The hold and the display's settings are written as a pair (Primitives
          # #with_interrupts_held_off). The screen's interrupt switches on what is held, so one
          # landing between the two writes would OR the held layers into the settings about to
          # be replaced and clear the hold, and the write after would switch the layers off with
          # nothing left to bring them back.

          # Write +reg+, the display's settings written whole on every pass, to the display; where
          # a hold lasts, with the layers (backgrounds and sprites) taken out and held instead, so
          # the write does not switch them on part way down the picture they are held for, and the
          # interrupt switches on the ones this pass wants. The hold and the write are one pair
          # (Primitives#with_interrupts_held_off). Uses TMP.
          def emit_display_control_keeping_held_off(reg)
            @primitives.with_interrupts_held_off do
              none = @emitter.gensym
              @primitives.load_var(TMP, LAYERS_HELD)
              @emitter.emit(ASM.cmp_imm(TMP, 0))
              @emitter.emit_branch(:bcond, none, cond: :eq)
              @emitter.emit(ASM.and_imm(TMP, reg, held_layer_bits))
              @primitives.store_var(TMP, LAYERS_HELD)
              @emitter.emit(ASM.bic_imm(reg, reg, held_layer_bits))
              @emitter.place_label(none)
              @emitter.emit_number(TMP, REG_DISPCNT)
              @emitter.emit(ASM.store_halfword(reg, TMP))
            end
          end

          # Switch the layers held off back on, from the screen's interrupt as the gap between
          # pictures starts, where nothing is being drawn. Nothing on a frame none is held. Uses
          # ACC, TMP and ADDR, which the interrupt saves. On a painted screen (modes 3 to 5) the
          # bits are harmless: GBATEK has those modes show BG2 alone, their picture.
          def emit_held_layers_on
            return unless holds_layers?

            none = @emitter.gensym
            @primitives.load_var(ACC, LAYERS_HELD)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, none, cond: :eq)
            @emitter.emit_number(TMP, REG_DISPCNT)
            @emitter.emit(ASM.load_halfword(ADDR, TMP)) # the variables' scratch register: free until the store below
            @emitter.emit(ASM.orr_reg(ADDR, ADDR, ACC))
            @emitter.emit(ASM.store_halfword(ADDR, TMP))
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, LAYERS_HELD)
            @emitter.place_label(none)
          end

          # Copy the tiles of the set in SET_PICKED over the stretch of tile memory every set of
          # that background sits in.
          #
          # Must copy nothing for sets that hold no tiles of their own. The build keeps two tiles
          # of the same pixels once, so a walking background declared after one that stays can
          # find every tile of every area in video memory already, and its sets are then empty.
          # The copy engine reads a count of nought as its biggest count, not as nothing: asked
          # for no words it copies more than all of video memory holds, from past the end of the
          # sets, over every tile and every map on the screen.
          def emit_copy_set_tiles(swap)
            return if swap.stride.zero?

            @emitter.emit_number(TMP, swap.stride)
            @emitter.emit(ASM.mul(ACC, SET_PICKED, TMP)) # r0 = how far along the blob that set starts
            @emitter.emit_load_data_address(TMP, swap.tiles)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
            @emitter.note_video_copy(Messages::MadeNames.words_for_made_name(swap.routine), swap.stride)
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(ACC), to: VRAM_START + swap.at,
                                   control: (swap.stride / 4) | DMA_ENABLE | DMA_32BIT)
          end

          # A walking background put up as declared is back in its first area, tiles and all, so
          # the colours go back to that area's too. One send serves every walking background,
          # since they all start in the same area. Nothing for scenery that stays in one area.
          def emit_first_area_colors(nodes, up: :unknown)
            walking = @layout.screen.walking_placements(nodes).first
            return unless walking

            nodes.each do |node|
              bg = @layout.screen.declared_background(node)
              emit_point_colors_at_area(node.name, bg, first: true) if bg&.sets
            end
            @emitter.emit_number(ACC, walking.sets.areas.first)
            @primitives.store_var(ACC, ScreenLayout::AREA_COLORS_UP)
            emit_area_colors(walking.sets, up: up)
          end

          # The colours of the area a set was just brought in from, unless they are up already.
          # Backgrounds that walk change area together and read one table, so the first of them
          # into an area sends its colours, and the next finds them up (see
          # ScreenLayout::AREA_COLORS_UP). Sent again, the whole table went through the tint
          # once more, and every borrowed group after it: as long again as bringing the set's
          # tiles in. All the next one sends is its own groups of a list it was told to draw
          # with, which the first left alone.
          def emit_area_colors_unless_up(name, bg)
            swap = bg.sets
            walk = @emitter.gensym
            sent = @emitter.gensym
            @primitives.load_var(TMP, swap.var)
            @emitter.emit_load_data_address(ACC, swap.area_numbers)
            @emitter.emit(ASM.ldrb_reg(ACC, ACC, TMP)) # the area that set is of
            @primitives.load_var(TMP, ScreenLayout::AREA_COLORS_UP)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, walk, cond: :ne)
            if bg.colors&.area_bytes
              @primitives.load_var(ACC, bg.colors.at)
              @emitter.emit(ASM.cmp_imm(ACC, 0)) # told nothing: the area's own colours are right
              @emitter.emit_branch(:bcond, sent, cond: :eq)
              @placement.emit_call_cold_routine(walking_colors_routine_label(name, bg))
            end
            @emitter.emit_branch(:b, sent)
            @emitter.place_label(walk)
            @primitives.store_var(ACC, ScreenLayout::AREA_COLORS_UP)
            emit_area_colors(swap, from_var: true)
            @emitter.place_label(sent)
          end

          # A walking layer told `draw_with` keeps a version of its lists for each area (see
          # ScreenLayout#walking_color_lists), so the version it shows is pointed at the area
          # just brought in — its first with +first+, otherwise the one its set names — before
          # the area's colours go in, which put the version back over the groups it reads (see
          # PaletteTint#emit_send_bg_colors). The list the game set stays set: an area walked
          # into shows it on the lists of its own the game named, and its own colours on the
          # rest. A layer told nothing yet keeps nought there, and the area's own table is right.
          def emit_point_colors_at_area(name, bg, first: false)
            lists = bg.colors
            return unless lists&.area_bytes

            told_nothing = @emitter.gensym
            @primitives.load_var(ACC, lists.at)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, told_nothing, cond: :eq)
            @primitives.load_var(ACC, IR::Nodes::Background.live_colors_var(name))
            emit_version_address(bg, lists, first: first)
            @primitives.store_var(ACC, lists.at)
            @emitter.place_label(told_nothing)
          end

          # Send in the colours of the area a walking background's set belongs to: the set
          # named by its variable, or, without +from_var+, its first set, which is what a
          # background put up as declared starts in. +up+ is the scene taking over, where this
          # is part of it doing so (see PaletteTint#emit_recolored_banks).
          def emit_area_colors(swap, from_var: false, up: :unknown)
            @emitter.emit_load_data_address(ACC, swap.colors)
            if from_var
              @primitives.load_var(TMP, swap.var)
              @emitter.emit_number(SET_STRIDE, swap.color_units * 2)
              @emitter.emit(ASM.mul(TMP, SET_STRIDE, TMP)) # how far along the blob that set's table is
              @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
            end
            @palette_tint.emit_send_bg_colors(swap.color_units, up: up)
          end

          # Point the layer at where the set now in place (r3) counts its tiles from, for sets
          # that start counting from different places.
          def emit_set_char_base(bg, swap)
            @emitter.emit_load_data_address(TMP, swap.char_base_table)
            @emitter.emit(ASM.ldrb_reg(ACC, TMP, SET_PICKED))
            @emitter.emit(ASM.lsl_imm(ACC, ACC, CHAR_BASE_SHIFT))
            depth = bg.small ? 0 : BG_256_COLOR
            @emitter.emit_number(TMP, bg.priority | bg.in_blocks | depth | (bg.screen_block << 8) | bg.size)
            @emitter.emit(ASM.orr_reg(ACC, ACC, TMP))
            @emitter.emit_number(TMP, BG_CNT_REGS[bg.bg])
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # Paint a run of tiles from its list: one copy, from the list straight into the video
          # memory its tiles were given, a word at a time. The list already holds the pixels
          # the way that memory does (two to a byte, the left one in the low half), which is
          # what lets this be a plain copy rather than a loop that packs them.
          #
          # When it happens is decided above this, the same as a map copy: in the gap between
          # frames, on a frame the game called `changed` (see Builder::TileRuns). A run that no
          # background shows has nowhere on screen to go, so it copies nothing.
          def emit_copy_tiles(node)
            run = @layout&.screen&.painted_vram&.[](node.name)
            return if run.nil?

            emit_copy_painted_run(node.name, run)
          end

          # Load tiles of a set of sprite tiles from the cartridge (Nodes::LoadSpriteTiles): one copy,
          # from the table straight into the set's room in sprite memory, where every pose drawn
          # from the set reads them. The table keeps a tile the way sprite memory does, so the copy
          # is plain. It is made where the game asks for it, as `changed now: true` copies a painted
          # picture, so the tiles are in the picture of this pass; the console may be drawing the
          # screen as it copies, and for that one frame the top of a sprite can be old and the
          # bottom new. A load that reaches past the end of the set or of the table is skipped, for
          # one unsigned compare each: a negative number reads as a very large one.
          LOAD_FROM = 4
          LOAD_TO = 5

          def emit_load_sprite_tiles(node, table)
            room, count = @layout&.screen&.sprite_tiles_vram&.[](node.name)
            return if room.nil? # no sprite shows the set, so nothing in sprite memory is its

            bounds = LoweringPlan.sprite_tile_load_bounds(node, table_bytes: table.count * table.elem_bytes, set_count: count)
            return unless bounds

            done = @emitter.gensym
            # The first number waits on the stack while the second is worked out, since working out
            # a value may use any register.
            @lowering.value(node.at)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.to)
            @emitter.emit(ASM.mov_reg(LOAD_TO, ACC))
            @emitter.emit(ASM.pop(LOAD_FROM))
            [LOAD_FROM, LOAD_TO].zip(bounds) do |register, (_, most)|
              @emitter.emit_number(TMP, most + 1)
              @emitter.emit(ASM.cmp_reg(register, TMP))
              @emitter.emit_branch(:bcond, done, cond: :hs)
            end
            @emitter.emit(ASM.lsl_imm(LOAD_FROM, LOAD_FROM, 5)) # 32 bytes a tile
            @emitter.emit_load_data_address(TMP, node.table)
            @emitter.emit(ASM.add_reg(LOAD_FROM, TMP, LOAD_FROM))
            @emitter.emit(ASM.lsl_imm(LOAD_TO, LOAD_TO, 5))
            @emitter.emit_number(TMP, VRAM_START + room)
            @emitter.emit(ASM.add_reg(LOAD_TO, TMP, LOAD_TO))
            @emitter.note_video_copy("loading sprite_tiles :#{node.name}", node.count * 32)
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(LOAD_FROM), to: Primitives::InRegister.new(LOAD_TO),
                                   control: (node.count * 8) | DMA_ENABLE | DMA_32BIT)
            @emitter.place_label(done)
          end

          # The set just brought in holds its painted tiles blank, and the game's list holds what
          # they show, so each is copied over again, to where it sits in this set.
          def emit_walking_runs_again(swap)
            (@layout&.screen&.painted_vram || {}).each do |name, run|
              emit_copy_painted_run(name, run) if run.walk&.var == swap.var
            end
          end

          # Set where a run in a background that walks between areas sits now, from the set of
          # tiles in place (see ScreenLayout::WalkingRun), or 0 on a screen that does not show it.
          def emit_walking_run_place(name, run, shown: true)
            place = ScreenLayout::PaintedRun.place_var(name)
            return @primitives.store_word_immediate(0, @primitives.var_addr(place)) unless shown

            @primitives.load_var(TMP, run.walk.var)
            @emitter.emit_load_data_address(ACC, run.walk.table)
            @emitter.emit(ASM.ldr_reg_lsl(ACC, ACC, TMP, 2))
            @primitives.store_var(ACC, place)
          end

          def emit_copy_painted_run(name, run)
            list = painted_run_list(name, run)

            emit_walking_run_place(name, run) if run.walk
            if run.moves?
              done = @emitter.gensym
              emit_load_painted_run_place(ScreenLayout::PaintedRun.place_var(name), done)
            end
            @emitter.note_video_copy("painting #{run.what} :#{name}", run.bytes)
            from = list.base
            if held_tile_run?(run)
              @primitives.load_var(2, ScreenLayout::PaintedRun.held_var(name))
              from = Primitives::InRegister.new(2)
            end
            @primitives.emit_start_copy_engine(from: from, to: run.moves? ? Primitives::InRegister.new(ACC) : VRAM_START + run.at,
                                   control: (run.bytes / 4) | DMA_ENABLE | DMA_32BIT)
            @emitter.place_label(done) if done
          end

          # Is +run+ a group of `tile_pictures`, shown from the cartridge?
          def held_tile_run?(run) = !run.held_in.nil?

          # Every painted run owed a copy, as one walk over a table (see Nodes::CopyOwedTiles).
          # Written out run by run, a test and a copy came to about thirty instructions each, so a
          # game with a box of text, a row of name tags and a few portraits carried kilobytes of
          # them. Walked, the code is the same for one run as for twenty: each run is a row of
          # six words, and two instructions of its own.
          #
          # A row is: where its pending bits are, which bit is its own, where its list starts,
          # where it goes in video memory, how many words it is, and how far into the steps
          # below its own step is. Where it goes is either the place itself, or — for a run that
          # sits in different places on different screens — where the variable holding the place
          # is, marked by its lowest bit (no place in video memory and no variable is at an odd
          # address). That variable holds 0 on a screen that does not show the run, and then the
          # run is skipped, as it was when each had its own copy.
          #
          # The two instructions each run keeps are the one that starts its copy and a jump back.
          # Every run could start its copy at one shared instruction, and the profile could then
          # no longer say which picture the bytes went to: it counts copies by how many times the
          # instruction that starts each one ran, and reads nothing else off the cartridge.
          COPY_ROW_BYTES = 24

          def emit_copy_owed_tiles(node)
            rows = owed_copy_rows(node)
            return if rows.empty?

            table = @emitter.gensym
            loop_top = @emitter.gensym
            direct = @emitter.gensym
            step = @emitter.gensym
            after = @emitter.gensym
            # Interrupts are held off for the walk: a timer's handler can use the same copying
            # engine, and one landing between a row's setup writes would start this copy with
            # the handler's addresses. r2 and r3 hold the walk; this step is only ever the body
            # of the routine that copies, whose callers expect it to use them.
            @emitter.emit_number(TMP, REG_IME)
            @emitter.emit(ASM.load_halfword(ACC, TMP))
            @emitter.emit(ASM.push(ACC))
            @emitter.emit_number(ACC, 0)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
            @emitter.emit_load_label_address(2, table)
            @emitter.emit_number(3, rows.size)
            @emitter.place_label(loop_top)
            @emitter.emit(ASM.ldr_offset(ACC, 2, 0))
            @emitter.emit(ASM.ldr(ACC, ACC))                 # its pending bits
            @emitter.emit(ASM.ldr_offset(TMP, 2, 4))
            @emitter.emit(ASM.and_reg(ACC, ACC, TMP))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, step, cond: :eq)    # not owed a copy
            @emitter.emit(ASM.ldr_offset(ACC, 2, 12))        # where it goes
            @emitter.emit(ASM.tst_imm(ACC, 1))
            @emitter.emit_branch(:bcond, direct, cond: :eq)
            @emitter.emit(ASM.bic_imm(ACC, ACC, 1))
            @emitter.emit(ASM.ldr(ACC, ACC))                 # ...read from the variable this screen set
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, step, cond: :eq)    # nowhere on this screen
            @emitter.place_label(direct)
            # The engine's three registers, written by hand rather than through
            # Primitives#emit_start_copy_engine: the write that starts the copy is each run's
            # own instruction, further down, and that call makes all three in one place.
            @emitter.emit_number(ADDR, REG_DMA3SAD)
            @emitter.emit(ASM.ldr_offset(TMP, 2, 8))
            if rows.any? { |row| row[:held] } # a group of `tile_pictures`: the place in the cartridge is in a variable
              from_list = @emitter.gensym
              @emitter.emit(ASM.tst_imm(TMP, 1))
              @emitter.emit_branch(:bcond, from_list, cond: :eq)
              @emitter.emit(ASM.bic_imm(TMP, TMP, 1))
              @emitter.emit(ASM.ldr(TMP, TMP))
              @emitter.place_label(from_list)
            end
            @emitter.emit(ASM.str_offset(TMP, ADDR, 0))                        # from its list
            @emitter.emit(ASM.str_offset(ACC, ADDR, Primitives::COPY_TO_STEP)) # to its place
            @emitter.emit(ASM.ldr_offset(TMP, 2, 16))        # how much, and go
            @emitter.emit(ASM.ldr_offset(ACC, 2, 20))
            # Into the run's own step: the processor reads pc as two instructions on, which is
            # the first step, so the filler between is never run.
            @emitter.emit(ASM.add_reg(15, 15, ACC))
            @emitter.emit(ASM.nop)
            rows.each do |row|
              @emitter.note_video_copy("painting #{row[:what]} :#{row[:name]}", row[:bytes])
              @emitter.emit(ASM.str_offset(TMP, ADDR, Primitives::COPY_START_STEP))
              @emitter.emit_branch(:b, step)
            end
            @emitter.place_label(step)
            @emitter.emit(ASM.add_imm(2, 2, COPY_ROW_BYTES))
            @emitter.emit(ASM.subs_imm(3, 3, 1))
            @emitter.emit_branch(:bcond, loop_top, cond: :ne)
            @emitter.emit(ASM.pop(ACC))
            @emitter.emit_number(TMP, REG_IME)
            @emitter.emit(ASM.store_halfword(ACC, TMP))      # the interrupt switch as it was
            @emitter.emit_branch(:b, after)
            @emitter.place_label(table)
            rows.each_with_index do |row, i|
              (row[:words] + [i * 8]).each { |word| @emitter.emit([word].pack("V")) } # its step is the i-th, 8 bytes each
            end
            @emitter.place_label(after)
          end

          # One table row per run a background or a sprite on some screen shows, in the shape
          # #emit_copy_owed_tiles reads. A run nothing shows has nowhere to go, and no row.
          def owed_copy_rows(node)
            per = Nodes::CopyOwedTiles::RUNS_PER_MASK
            node.runs.each_with_index.filter_map do |name, i|
              run = @layout&.screen&.painted_vram&.[](name)
              next if run.nil?

              list = painted_run_list(name, run)
              place = run.moves? ? @primitives.var_addr(ScreenLayout::PaintedRun.place_var(name)) | 1 : VRAM_START + run.at
              held = held_tile_run?(run)
              from = held ? @primitives.var_addr(ScreenLayout::PaintedRun.held_var(name)) | 1 : list.base
              Primitives.refuse_copy_of_nothing!(run.bytes / 4) # the walk writes this control word by hand
              { name: name, what: run.what, bytes: run.bytes, held: held,
                words: [@primitives.var_addr(node.masks.fetch(i / per)), 1 << (i % per), from, place,
                        (run.bytes / 4) | DMA_ENABLE | DMA_32BIT] }
            end
          end

          # The list a run paints from. The builder refuses a shifted one
          # (Builder#refuse_shifted_tile_run_lists!); this is the lowering's own invariant, for a
          # tree that reached it some other way.
          def painted_run_list(name, run)
            list = @lists.list_info(run.list)
            raise LoweringError, "#{run.what} :#{name} paints from list :#{run.list}, which the game shifts." if list.ring

            list
          end

          # A run shown in several scenes, in different places: the scene up now has put where
          # the run sits on its screen in a variable (see Drawing#emit_painted_run_places), so
          # the copy goes there. On a screen that does not show the run the variable holds 0,
          # and the copy is skipped — there is nowhere on this screen for it to go, and video
          # memory at any fixed place would be some other picture's. Leaves that place in ACC.
          def emit_load_painted_run_place(var, done)
            @primitives.load_var(ACC, var)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
          end

          # ACC = where the map numbered +which+ starts, or a jump to +done+ if it names no
          # map. A number settled while the program was written is worked out here, in Ruby;
          # one the game works out is checked and multiplied by the stride at run time.
          def emit_map_source(bg, which, done)
            fixed = @primitives.const_int(which)
            return emit_fixed_map_source(bg, fixed, done) if fixed

            @lowering.value(which)
            # One unsigned compare catches both ends: a negative number reads as a very
            # large one, so anything outside 0...count fails the same test.
            @emitter.emit(ASM.cmp_imm(ACC, bg.map_count))
            @emitter.emit_branch(:bcond, done, cond: :hs)
            emit_map_stride(bg)
            @emitter.emit_load_data_address(ACC, bg.map)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
          end

          def emit_fixed_map_source(bg, fixed, done)
            return @emitter.emit_branch(:b, done) unless fixed >= 0 && fixed < bg.map_count

            @emitter.emit_load_data_address(ACC, bg.map)
            return if fixed.zero?

            @emitter.emit_number(TMP, fixed * bg.map_bytes)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
          end

          # TMP = how far along the blob this map starts. The stride is a power of two for
          # every grid the console offers, so this is a shift; the multiply is here for a
          # stride that is not, and costs one instruction either way on this chip.
          def emit_map_stride(bg)
            shift = Math.log2(bg.map_bytes).to_i
            if 2**shift == bg.map_bytes
              @emitter.emit(ASM.lsl_imm(TMP, ACC, shift))
            else
              @emitter.emit_number(TMP, bg.map_bytes)
              @emitter.emit(ASM.mul(TMP, ACC, TMP))
            end
          end

          # Draw a whole layer from another list of colours: put that list into the group of
          # sixteen its tiles read.
          #
          # Nothing about the layer itself is touched — not a cell, not a tile, not a pixel.
          # Every pixel on this console is a small number that picks a colour out of a shared
          # table, so changing the sixteen entries the layer's numbers pick from changes
          # every one of its pixels at once, and costs the same whatever is on screen. That
          # is why shafts of light can shimmer for the price of one copy.
          #
          # Why the group is the layer's own: this write lands in the table, where anything
          # else drawing from those sixteen would pick up the change too. The build gives a
          # layer that can be recoloured a group nobody else reads (see
          # PaletteBanks::Picture#keeps_to), so the write reaches this layer and nothing more.
          #
          # WHEN it happens is decided above this: the framework puts the copy in the gap
          # between frames, on the frame the answer changed and no other (see
          # Builder#finalize_background_colors). The whole screen is drawn through this table,
          # so a write while the display is reading shows the top of the screen in one set of
          # colours and the bottom in another.
          #
          # A number naming none of the lists hands over the layer's own colours, which sit
          # last in the blob — so that case is a conditional move rather than a branch, and
          # a counter that has run off the end looks right rather than wrong.
          def emit_background_colors(node)
            emit_for_each_declaration(node.name) do |bg|
              lists = bg&.colors
              next if lists.nil? # no tiled layer here, or nothing else to draw it with

              emit_color_list_send(node, bg, lists)
            end
          end

          # Send the list +node+ picks out of +lists+ into the groups the layer's tiles read.
          def emit_color_list_send(node, bg, lists)
            @lowering.value(node.which)
            emit_version_address(bg, lists)
            # Remembered as well as written, because a tint walks the whole table from the
            # cartridge and would otherwise put the colours the tiles were drawn in back over
            # these groups. See PaletteTint#emit_recolored_banks, which reads this.
            @primitives.store_var(ACC, lists.at)
            if lists.area_bytes
              @placement.emit_call_cold_routine(walking_colors_routine_label(node.name, bg))
            else
              emit_groups_send(lists, lists.banks)
            end
            emit_forget_own_version(node, lists)
          end

          # The routine that sends a walking layer's version into the groups of the area up, one a
          # layer, reserved the first time a line sends it and emitted once, later, beside the
          # set swaps (#emit_set_swap_routines). A walking layer's groups are the area's that is
          # up: each area hands its groups out again, and another walking layer can be drawing
          # from one of this area's. So the send is a test of the area and a walk of each group
          # it has, for every area that borrows — written out in the gap between frames, which
          # is the first thing kept in the console's quick memory, a house of many borrowed
          # lists took that room from routines every frame of play runs. The send happens on the
          # frame a list changes, and from the cartridge it costs the same copies.
          def walking_colors_routine_label(name, bg)
            label = DerivedNames.sub_label(bg.sets.routine, :colors)
            (@pending_walking_colors ||= {})[label] ||= bg
            label
          end

          # The body of that routine: the version's start is in the layer's variable already.
          def emit_walking_colors_send(bg)
            lists = bg.colors
            lists.banks.each_with_index do |groups, set|
              next if groups.empty?

              other_area = @emitter.gensym
              @primitives.load_var(TMP, bg.sets.var)
              @emitter.emit(ASM.cmp_imm(TMP, set))
              @emitter.emit_branch(:bcond, other_area, cond: :ne)
              @primitives.load_var(ACC, lists.at)
              emit_groups_send(lists, groups)
              @emitter.place_label(other_area)
            end
          end

          # A layer given its own colours back is as it was before it was told anything: the
          # table in the console holds them, as the cartridge does. So where its version starts
          # goes back to nought, which every tint, area and scene reads as "nothing to put back"
          # (PaletteTint#emit_recolored_banks, #emit_point_colors_at_area). Kept, the version
          # would be its own colours written again over the same colours on every tint, for the
          # rest of the game.
          def emit_forget_own_version(node, lists)
            borrowed = @emitter.gensym
            @lowering.value(node.which)
            @emitter.emit(ASM.cmp_imm(ACC, lists.count)) # unsigned, as #emit_version_address reads it
            @emitter.emit_branch(:bcond, borrowed, cond: :lo)
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, lists.at)
            @emitter.place_label(borrowed)
          end

          # One list into each of +groups+, side by side in the version that ACC and +lists+'s
          # variable hold where it starts. The groups themselves need not be side by side, so each
          # is a copy of its own.
          def emit_groups_send(lists, groups)
            groups.each_with_index do |bank, at|
              unless at.zero?
                @primitives.load_var(ACC, lists.at)
                @emitter.emit(ASM.add_imm(ACC, ACC, at * COLOR_LIST_BYTES))
              end
              @palette_tint.emit_colors_into_bank(BG_PALETTE + (bank * COLOR_LIST_BYTES), COLOR_LIST_UNITS)
            end
          end

          # ACC = where the version numbered by ACC starts in +lists+'s blob. One unsigned compare
          # catches both ends: a negative number reads as a very large one, so anything outside
          # 0...count fails the same test and picks the layer's own colours, last in the blob.
          # A walking layer's versions are the area's, a multiply along (see
          # ScreenLayout#walking_color_lists): the area its set names, or its first with +first+.
          def emit_version_address(bg, lists, first: false)
            @emitter.emit(ASM.cmp_imm(ACC, lists.count))
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, lists.count))
            @emitter.emit(ASM.lsl_imm(TMP, ACC, lists.shift))
            if lists.area_bytes && !first
              @primitives.load_var(ACC, bg.sets.var)
              @emitter.emit_number(SET_STRIDE, lists.area_bytes)
              @emitter.emit(ASM.mul(ACC, SET_STRIDE, ACC))
              @emitter.emit(ASM.add_reg(TMP, TMP, ACC))
            end
            @emitter.emit_load_data_address(ACC, lists.blob)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
          end

          # A group is sixteen colours, and a colour is two bytes — so a list is 32 bytes and
          # the list numbered N starts 32 * N along the blob, which is a shift rather than a
          # multiply (the same arithmetic #emit_map_stride does for a map).
          COLOR_LIST_UNITS = 16
          COLOR_LIST_BYTES = COLOR_LIST_UNITS * 2
          COLOR_LIST_SHIFT = 5

          # Where a background's cells live: its own screen block in video memory.
          def map_vram_address(bg) = VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES)

          # Bit 13: the map wraps at its edge instead of showing the backdrop past it — the
          # same torus every `screen :tiled` background already is.
          AFFINE_WRAP = 0x2000

          # Put BG2's rotate/scale registers back to "no transform" — matrix identity,
          # zero reference point — the same state #emit_affine_background_hardware boots
          # an affine background to. Only a program with an affine background at all
          # needs this: those registers are also what Modes 3/4/5 render their bitmap
          # framebuffer through (see #emit_affine_background's comment), so switching
          # INTO any other mode has to leave BG2 neutral, or a bitmap/tiled scene
          # entered right after an affine one keeps showing whatever turn or zoom the
          # affine scene last left sitting in hardware.
          def reset_bg2_affine_if_needed
            return unless @layout.screen.backgrounds.values.any?(&:affine)

            reset_bg2_affine_matrix
          end

          # The actual identity-matrix write, factored out so it can be called from
          # three places that each need it exactly once: leaving affine mode (above),
          # genuinely entering it (Drawing#enter_affine_mode), and the plain single-mode boot
          # path (Drawing#emit_screen) — never from #emit_affine_background_hardware, which
          # runs every frame a scene-owned background's own node re-executes and would
          # otherwise stomp a growing rotate/scale right back to "no transform" before
          # the console ever shows it.
          def reset_bg2_affine_matrix
            @emitter.write_reg16(REG_BG2PA, FIXED_ONE)
            @emitter.write_reg16(REG_BG2PB, 0)
            @emitter.write_reg16(REG_BG2PC, 0)
            @emitter.write_reg16(REG_BG2PD, FIXED_ONE)
            @primitives.store_word_immediate(0, REG_BG2X)
            @primitives.store_word_immediate(0, REG_BG2Y)
            forget_told_turns
          end

          # The display has just been put back upright, so whatever turn and size it was last
          # told are no longer on it. A turn is only told again when it differs from the one
          # told last (see Builder#affine_write_if_changed), so forgetting the size — which is
          # never nought — makes the next frame tell it the turn the game has now. Without this a
          # background turned before a screen of another kind came back upright after it.
          def forget_told_turns
            @layout.screen.backgrounds.each do |name, background|
              next unless background.affine

              @primitives.store_word_immediate(0, @primitives.var_addr(Messages::MadeNames.make(:told_turn, background: name, part: :size)))
            end
          end

          # Point the console's rotate/scale layer (BG2) at an affine background's map
          # and tiles — its own node in the scene body, so it may run every frame the
          # owning scene is active (harmless: same map, same control bits, every time).
          # The matrix itself is not reset here — a scene-owned background is turned or
          # resized by a per-frame write inserted at the frame boundary (see
          # Builder#finalize_background_affine), which runs before this node in program
          # order each frame; resetting the matrix here would throw that away before
          # the console ever displayed it. The one-time "upright, undistorted" starting
          # matrix is set at genuine mode entry instead (Drawing#enter_affine_mode, or here at
          # boot for a single-mode program — see Drawing#emit_screen).
          def emit_affine_background_hardware(bg)
            @uploads.emit_dma_blob(bg.map, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES), bg.map_units)
            @emitter.write_reg16(REG_BG2CNT,
                        bg.priority | bg.in_blocks | BG_256_COLOR | (bg.char_base << CHAR_BASE_SHIFT) |
                        (bg.screen_block << 8) | AFFINE_WRAP | bg.size)
          end

          # Scratch memory the affine background's matrix numbers pass through on their
          # way to the hardware registers — a background keeps only one matrix (unlike a
          # sprite's per-slot OAM group), so there's nowhere else to park PA-PD while the
          # reference point below is worked out from them.
          BG_AFFINE_PA = :_bg_affine_pa
          BG_AFFINE_PB = :_bg_affine_pb
          BG_AFFINE_PC = :_bg_affine_pc
          BG_AFFINE_PD = :_bg_affine_pd
          BG_AFFINE_SCALE_RECIP = :_bg_affine_scale_recip

          # Where the picture turns around is the program's to name and rides on the
          # statement that turns it (see IR::Nodes::AffineBackground); the middle of the
          # screen is only what it holds when nothing set otherwise.

          # Turn/resize the affine background: work out this frame's rotate/scale matrix
          # and write it to BG2's registers, then move the reference point so the turn
          # pivots on the middle of the screen (see #emit_bg_affine_reference_point for
          # why that needs its own step).
          def emit_affine_background(node)
            # Outside `screen :rotozoom` there's no rotate/scale layer prepared for this
            # background to write into — and unlike a plain scroll's fallback registers
            # (harmlessly inert when that layer isn't on), BG2's affine registers are
            # never inert: a bitmap screen reads them too (Modes 3/4's framebuffer is
            # itself rendered through this same BG2 matrix). So rather than fall back
            # onto them, this does nothing at all, the same choice #emit_scroll_background
            # makes for a background outside tile mode.
            return unless @layout.screen.backgrounds[node.name]&.affine

            # WHEN this runs is decided above it, in the tree, rather than here: the
            # statement sits inside a test for the turn having moved since the display was
            # last told, itself inside a test for the owning scene being the live one (see
            # Builder#affine_write_if_changed). So reaching this is already the answer
            # to both questions, and what is left is the write.
            emit_bg_affine_matrix(node)
            emit_bg_affine_reference_point(node.around_x, node.around_y, node.map_x, node.map_y)
          end

          # The same numbers a turning hardware sprite reads (see
          # SpriteDrawing#emit_object_affine_matrix, whose steps this mirrors) — one sine-table lookup
          # for sin and cos, scaled by one over the size — except there is no OAM group to
          # drop them into, so each one goes to hardware AND to a scratch variable, which
          # the reference point step below reads back.
          def emit_bg_affine_matrix(node)
            emit_bg_affine_scale_reciprocal(node.scale)
            @lowering.value(node.angle)                       # r0 = angle in degrees (0..359)
            @emitter.emit_load_data_address(TMP, OBJ_SINE_BLOB)   # r1 = sine table base
            @emitter.emit(ASM.lsl_imm(2, ACC, 1))                 # r2 = angle * 2 (halfword offset)
            @emitter.emit(ASM.add_reg(ADDR, TMP, 2))
            @emitter.emit(ASM.ldrsh(2, ADDR))                     # r2 = sin(angle)
            @emitter.emit(ASM.add_imm(3, ACC, 90))                # r3 = angle + 90
            @emitter.emit(ASM.lsl_imm(3, 3, 1))
            @emitter.emit(ASM.add_reg(ADDR, TMP, 3))
            @emitter.emit(ASM.ldrsh(3, ADDR))                     # r3 = sin(angle + 90) = cos(angle)
            emit_bg_scale_sine_and_cosine
            @emitter.emit(ASM.rsb_imm(ACC, 2, 0))                 # r0 = -sin(angle)
            @emitter.emit_number(TMP, REG_BG2PA)
            @emitter.emit(ASM.store_halfword(3, TMP))
            @primitives.store_var(3, BG_AFFINE_PA)
            @emitter.emit_number(TMP, REG_BG2PB)
            @emitter.emit(ASM.store_halfword(2, TMP))
            @primitives.store_var(2, BG_AFFINE_PB)
            @emitter.emit_number(TMP, REG_BG2PC)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
            @primitives.store_var(ACC, BG_AFFINE_PC)
            @emitter.emit_number(TMP, REG_BG2PD)
            @emitter.emit(ASM.store_halfword(3, TMP))
            @primitives.store_var(3, BG_AFFINE_PD)
          end

          # One over this frame's size, the same divide a resizing sprite does (see
          # SpriteDrawing#emit_object_scale_reciprocal) — a background always carries a size variable
          # once it's ever turned or resized (rotate and scale share the same pair of
          # variables), so this runs every frame rather than only when scale is in play.
          def emit_bg_affine_scale_reciprocal(scale)
            @lowering.value(scale)                                    # r0 = size, in SCALE_ONE-ths
            @emitter.emit(ASM.cmp_imm(ACC, Affine::MIN_SCALE))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, Affine::MIN_SCALE))
            @emitter.emit_number(Divide::DIV_NUM, Build::SCALE_ONE * Affine::ONE_TH)
            @divide.emit_call_divide_routine
            @emitter.emit_number(TMP, Affine::MAX)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))
            @primitives.store_var(ACC, BG_AFFINE_SCALE_RECIP)
          end

          # Scale the sine and cosine in r2/r3 by the reciprocal above, back down into
          # 256ths — the background's own copy of SpriteDrawing#emit_scale_sine_and_cosine.
          def emit_bg_scale_sine_and_cosine
            @primitives.load_var(4, BG_AFFINE_SCALE_RECIP)
            @emitter.emit(ASM.mul(5, 2, 4))
            @emitter.emit(ASM.asr_imm(2, 5, 8))
            @emitter.emit(ASM.mul(5, 3, 4))
            @emitter.emit(ASM.asr_imm(3, 5, 8))
          end

          # The matrix pivots on the layer's own top-left corner by itself — turn or
          # resize without this and the whole picture swings away from under the point it
          # is meant to turn around instead of turning in place. Moving the pivot to
          # (+px+, +py+) means telling the console the texture point that should land
          # there, worked backwards through the very matrix just written: for a screen
          # point this far from (0, 0), the matrix gives how far that is from the
          # reference point in texture space, so read backwards, the reference point is
          # the pivot's texture position minus that offset. One multiply-and-subtract per
          # axis whatever the pivot is, so naming one costs nothing; the same shape a
          # turned sprite gets for free by centering its drawing box (see
          # SpriteDrawing#emit_draw_object_transformed) — a background has no box of its own to offset,
          # so this stands in for it.
          #
          # The point of the picture that lands there is the same pair of numbers, which is
          # what makes a pivot free of side effects: at its drawn size, upright, the matrix
          # is the identity and the reference point comes out at nought wherever the pivot
          # is, so a background that is not turning lands in exactly the same place.
          #
          # (+map_x+, +map_y+) is the point of the map that lands at the pivot: those same two
          # numbers for a map hung from the screen's corner, or the point the game named
          # (Nodes::AffineBackground). It is the "pivot's texture position" above, a number
          # written in the cartridge either way, so naming one costs no instruction.
          def emit_bg_affine_reference_point(px, py, map_x, map_y)
            @primitives.load_var(2, BG_AFFINE_PA)
            @emitter.emit_number(3, px)
            @emitter.emit(ASM.mul(4, 2, 3))                       # r4 = PA * px
            @primitives.load_var(2, BG_AFFINE_PB)
            @emitter.emit_number(3, py)
            @emitter.emit(ASM.mul(5, 2, 3))                       # r5 = PB * py
            @emitter.emit(ASM.add_reg(4, 4, 5))                   # r4 = PA*px + PB*py
            @emitter.emit_number(ACC, map_x * Affine::ONE_TH)
            @emitter.emit(ASM.sub_reg(ACC, ACC, 4))
            @primitives.store_word_acc(REG_BG2X)

            @primitives.load_var(2, BG_AFFINE_PC)
            @emitter.emit_number(3, px)
            @emitter.emit(ASM.mul(4, 2, 3))                       # r4 = PC * px
            @primitives.load_var(2, BG_AFFINE_PD)
            @emitter.emit_number(3, py)
            @emitter.emit(ASM.mul(5, 2, 3))                       # r5 = PD * py
            @emitter.emit(ASM.add_reg(4, 4, 5))                   # r4 = PC*px + PD*py
            @emitter.emit_number(ACC, map_y * Affine::ONE_TH)
            @emitter.emit(ASM.sub_reg(ACC, ACC, 4))
            @primitives.store_word_acc(REG_BG2Y)
          end

          # Scroll one layer: write the window's top-left offset into that layer's scroll
          # registers. The tile hardware does the rest — it draws the layer starting at
          # that offset and wraps the map around, so a moving offset scrolls the whole
          # layer for free (no redrawing). Two layers scrolled at different speeds give
          # parallax. The offset is evaluated at run time from the game's scroll variables.
          def emit_scroll_background(node)
            # In tile mode this names a real layer; outside it (a bitmap-mode program that
            # still declares a background) there's no tiled layer, so fall back to BG0 —
            # the scroll registers do nothing when that layer isn't on, matching the
            # interpreter's harmless handling.
            bg = @layout.screen.backgrounds[node.name]
            bg_num = bg&.bg || 0 # the same layer for every declaration of one name (see ScreenLayout#layer_slots)
            emit_view_along_map(node) # the cells around the view, before the view moves
            # A bending layer's sideways position is settled row by row instead, and every
            # one of those rows already has this scroll in it (see Raster). Writing it here
            # too would only undo the top row's bend until the display asked for the next.
            border = @layout.border
            unless @raster.row_bends.key?(node.name)
              @lowering.value(node.x)        # r0 = scroll x (pixels)
              border&.emit_corner_off_scroll(:x) # ...less the corner of a game's screen in a border
              @primitives.store_halfword_acc(BG_HOFS_REGS[bg_num])
            end
            @lowering.value(node.y)          # r0 = scroll y
            border&.emit_corner_off_scroll(:y)
            @primitives.store_halfword_acc(BG_VOFS_REGS[bg_num])
          end

          # What a layer's scroll register holds for the map's corner at the screen's: nought, or in a
          # border, the corner taken off.
          def unscrolled(way) = @layout.border ? @layout.border.scroll_value(0, way) : 0

          # Bring a big map's view along, for the scroll write of +node+ — but for a background a
          # scene puts up as it takes over, only once it has. The write is gated on the variable
          # that picks the scene, and a game that picks the next scene at the end of a pass (a file
          # screen on START) has that variable naming the new scene in the gap before its first
          # pass: the view was filled there, into cells the scene had not put up yet and that may
          # still hold the scene leaving, and then filled again as the scene took over.
          #
          # A background of one name declared in several scenes has a view of its own for each
          # declaration, and the scene up is the one whose view comes along.
          def emit_view_along_map(node)
            several = @layout.screen.declarations_of(node.name)
            several.each do |scene, bg|
              @scene_entry.emit_if_scene_up(:scenery, scene) { emit_stream_view(bg.stream, node.x, node.y) } if bg.stream
            end
            return unless several.empty?

            stream = @layout.screen.backgrounds[node.name]&.stream or return
            declared = @layout.screen.picture.scenery.find { |scenery| scenery.name == node.name }
            return emit_stream_view(stream, node.x, node.y) unless declared && @layout.screen.handover.on_arrival?(declared)

            @scene_entry.emit_if_scene_up(:scenery, declared.scene) { emit_stream_view(stream, node.x, node.y) }
          end
        end
      end
    end
  end
end
