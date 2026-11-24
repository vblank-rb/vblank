# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Direct-color (Mode 3) drawing, and the screen-mode/page management around it:
        # which kind of screen is up, what a scene does to it as it takes over, the shapes
        # and pictures a game paints itself, and text.
        #
        # What the console draws for the game lives beside this, one file each: the sprites
        # ({SpriteDrawing}), the background layers ({BackgroundDrawing}), and what happens to
        # the whole picture — camera, fade, tint ({ScreenEffects}). Copying data into video
        # memory, which all of them do, is {BlobUpload}. A change of screen sets the sprites
        # and backgrounds up again, which is why this holds the first two.
        #
        # What the prepare passes decide about a program — which images it has, where every
        # background and sprite went ({ScreenLayout}), the shared palette, the mode facts —
        # arrives as one record, `layout`, handed over through `layout=` once
        # those passes finish (the same shape Functions#modes= is set in: none of it
        # exists yet when this object is built). Clip/column/digit-glyph work shared
        # with the tear-free screen lives in {Framebuffer}; the tear-free screen's own
        # drawing lives in {Buffered}, an explicit collaborator here rather than a bare
        # cross-file call.
        #
        # Ten statement kinds fork on which screen is live —
        # `return @buffered.emit_x_buffered(node) if @lowering.mode == :buffered` — and
        # that fork stays written out here rather than moving into the Lowering's
        # dispatch table, which would otherwise have to pick one of two handlers per
        # kind instead of one.
        class Drawing
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[
            screen pixel fill_rect clear_screen draw_rect_at draw_column_at draw_text draw_digit
            blit blit_pose background save_region restore_region
          ].freeze

          def emit_statement(node)
            case node.kind
            when :screen then emit_screen(node)
            when :pixel then emit_pixel(node)
            when :fill_rect then emit_fill_rect(node)
            when :clear_screen then emit_clear_screen(node)
            when :draw_rect_at then emit_draw_rect_at(node)
            when :draw_column_at then emit_draw_column_at(node)
            when :draw_text then emit_draw_text(node)
            when :draw_digit then emit_draw_digit(node)
            when :blit then emit_blit(node)
            when :blit_pose then emit_blit_pose(node)
            when :background then emit_background(node)
            when :save_region then emit_save_region(node)
            when :restore_region then emit_restore_region(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware

          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, raster:, palette_tint:,
                          layer_blend:, effects:, buffered:, uploads:, sprite_drawing:, background_drawing:,
                          lists:, placement:, frames:)
            @emitter = emitter
            @frames = frames # how many breaks a pass took, which shows whether its page is late
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @raster = raster
            @palette_tint = palette_tint
            @layer_blend = layer_blend
            @effects = effects # what is done to the whole picture, which a change of screen puts back
            @buffered = buffered
            @uploads = uploads # copies data out of the cartridge into video memory (see {BlobUpload})
            # The sprites' and the backgrounds' own code, which a change of screen sets up again
            # (see {SpriteDrawing} and {BackgroundDrawing}).
            @sprite_drawing = sprite_drawing
            @background_drawing = background_drawing
            @lists = lists # where a backing buffer is (Lists#backing_info)
            @placement = placement
            # What a scene does once as it takes over, and the notes saying whose is up.
            @scene_entry = SceneEntry.new(emitter: emitter, primitives: primitives)
            @background_drawing.scene_entry = @scene_entry
            @layout = nil
          end

          def layout=(value)
            @layout = value
            @scene_entry.layout = value
          end

          # The notes saying whose scenery and sprite pictures are up, for code outside a scene
          # that touches what the scene put up (see PaletteTint#emit_recolored_banks).
          attr_reader :scene_entry

          # What brings the sets of picture groups up, made once this has made the notes above
          # (see PictureGroupCopying); a scene taking over puts its own sets down.
          attr_writer :picture_group_copying

          # Mark no scene's scenery or sprite pictures as up (see SceneEntry#emit_clear_used_markers).
          def emit_clear_used_scene_markers = @scene_entry.emit_clear_markers_at_power_on

          # The prepare-pass results this file reads, bundled into one record and handed
          # over through #layout= once every pass that decides them has run.
          # Where a background's cells are and what to write into one is on its own placement
          # record (see ScreenLayout::MapGrid), which is what a run-time tile change reads. Which screen
          # mode each scene draws in is on +modes+ (see IR::Modes), which is asked rather than
          # copied out field by field.
          #
          # Where every background and sprite went, and what each scene sends as it takes
          # over, is the +screen+ ({ScreenLayout}) itself, read as +layout.screen+ rather than
          # copied out, so a thing the layout decides has one home.
          Layout = Data.define(:screen, :bitmaps, :palette, :indexed_bitmaps, :blob_codecs, :blob_raw_bytes,
                                :modes, :fading, :tiled, :has_objects, :scene_blend, :movement,
                                :scene_sprites, :gated_sprites, :waits_for_frames, :draw_runs, :pose_sent_bytes,
                                :room_tables, :late_pages, :held_sprites, :border, :pixel_size) do
            # +border+ is the border round a smaller screen shown in the middle of the Advance's
            # (BorderSprites), or nil for a game shown on the whole screen. +pixel_size+ is how many
            # of the console's pixels across and down one of the game's is shown as (1, or 2 for
            # `screen :bitmap, pixel_size: 2`: Drawing#emit_bigger_pixels).
            def initialize(held_sprites: nil, border: nil, pixel_size: 1, **rest) = super

            # How many rows of the painted screen's memory the console shows: every row, or the
            # small picture's alone in a game of big pixels. A whole-screen fill fills these and
            # leaves the rows under them, which are never shown.
            def shown_rows = SCREEN_HEIGHT / pixel_size

            # ...and how many of each row's columns, the same share.
            def shown_columns = SCREEN_WIDTH / pixel_size

            # Does a whole-screen fill leave out part of each row it fills, which the display never
            # reads? Only in a game of big pixels, and only where the shown part of a row of
            # +pixel_bytes+ bytes a pixel is a whole number of words.
            def fills_shown_rows_alone?(pixel_bytes) = pixel_size > 1 && ((shown_columns * pixel_bytes) % 4).zero?

            # Does the game switch layers off to send them something, and wait for frames, so that
            # a sending can hold them for a picture (BackgroundDrawing::LAYERS_HELD)?
            def holds_layers? = waits_for_frames && screen.layers_off_while_sending?
            # The backgrounds that turn AND sit on the tiled screen — the ones that decide
            # which way the console arranges that screen's layers. A background that turns
            # on `screen :rotozoom` is on a screen of its own, up at a different moment, so
            # it does not (see Guardrails::Checks::TooManyBackgroundLayers, which asks the
            # same question to work out how many scrolling layers are left).
            def turning_layers = modes.select_on_tiled_screen(screen.picture.scenery.select(&:affine))
          end

          # Fill the area itself, which is what clearing means when only part of the picture may
          # be painted: a row-at-a-time block fill over exactly those edges, whatever width the
          # author set, with no narrow-row stores (an area is seldom that narrow).
          #
          # An area of no width fills nothing, and must copy nothing: the copy engine reads a count
          # of nought as its biggest count, and would fill all of video memory.
          def emit_fill_area(color)
            return unless @framebuffer.clip_right > @framebuffer.clip_left

            emit_rows_filled(@framebuffer.clip_left, @framebuffer.clip_right,
                             (@framebuffer.clip_top...@framebuffer.clip_bottom), color)
          end

          # Turn the screen on by writing the chosen mode to the display-control
          # register. Until this runs the screen stays black.
          #
          # In a program that switches the hardware per scene — some scene double-
          # buffered, or crossing the bitmap/tiled boundary — the screen mode is managed
          # for the whole program by the boot setup and each scene's mode-switch
          # preamble, so a `screen` node is only a build-time declaration of a scene's
          # mode and emits nothing here. Otherwise it's the plain one-time register write.
          #
          # A `screen` a scene declares, on a screen of the same kind as the game's, writes nothing
          # either: the display is already as it asks, and its statement runs on every pass the
          # scene runs, so writing the display's settings there held the picture off on every one
          # (#initial_forced_blank_bit). What else it sets, its backdrop, is the scene's arrival's
          # (#emit_scene_backdrop).
          #
          # In a game where a screen sets a backdrop, every `screen` outside a scene's top also
          # writes the one it means (IR::SceneHandover#backdrop_of) where the console keeps it: a
          # game with no backgrounds sends no table of colours that would carry it.
          def emit_screen(node)
            emit_late_pages_setting(IR::LatePages.setting_of(node))
            return if @layout.modes.switched_per_scene? || scene_handover.scene_screen?(node)

            backdrop = scene_handover.backdrop_of(node) # nil: it follows a list, and stays as the list has it
            emit_backdrop_color(backdrop) if scene_handover.backdrops? && node.mode != :bitmap && backdrop

            mode = node.mode
            value = if mode == :tiled
                      # A single-mode program never runs #enter_tiled_mode (that's only for
                      # per-scene mode switching), so a turning layer's one-time "no turn, no
                      # resize yet" starting matrix is set here instead.
                      @background_drawing.reset_bg2_affine_if_needed
                      tiled_dispcnt
                    elsif mode == :rotozoom
                      # The rotate/scale layer: this feature always lands the one affine
                      # background it supports on BG2 (see AFFINE_BG in gba.rb), so that's the
                      # one layer Mode 2 needs on here. A single-mode program never runs
                      # #enter_affine_mode (that's only for per-scene mode switching), so the
                      # one-time "no turn, no resize yet" starting matrix is set here instead.
                      @background_drawing.reset_bg2_affine_matrix
                      MODE_2 | BG2_ENABLE
                    elsif mode.is_a?(Integer)
                      mode
                    else
                      emit_painted_screen_settings
                      SCREEN_MODES.fetch(mode) do
                        raise LoweringError, "the GBA backend cannot lower screen mode #{mode.inspect} yet"
                      end
                    end
            # Turn the sprite layer on alongside the chosen mode when the program has
            # sprites, and pick the simple 1D tile arrangement they're packed for.
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            value |= display_window_bits
            late = late_layer_enable_bits
            return @background_drawing.emit_display_control_written(value | initial_forced_blank_bit) if late.zero?

            emit_display_control_keeping(value & ~late, late)
          end

          # A game that never calls `screen` DRAWS ON A BITMAP SCREEN, as if its first line were
          # `screen :bitmap` — the interpreter and the native build have always drawn it there.
          # The console needs telling: at power-on its display-control register holds "mode 0,
          # every layer off", so a pixel written to video memory sits there unseen and the
          # screen shows nothing but the backdrop colour. So the build writes the bitmap screen
          # here, at boot, ahead of the game's first statement. A program that draws nothing
          # has nothing to show, and is left exactly as it was.
          def emit_default_screen(program)
            nodes = program.walk.to_a
            return if nodes.any? { |node| node.kind == :screen }
            return unless nodes.any? { |node| node.category == :draw }

            emit_screen(Build.screen(:bitmap))
          end

          # A screen the game paints is one background to the console — its third — and that
          # background's own settings set whether it is drawn in blocks, as any background's
          # do. Nothing else on such a screen reads those settings, so in a game that
          # pixelates they are written whole, as the screen is set up. With the size of a
          # block left at one pixel the picture is as drawn, so this costs nothing until the
          # game sets a size (see Pixelation). A game that never pixelates writes nothing.
          def emit_painted_screen_in_blocks
            @emitter.write_reg16(REG_BG2CNT, BG_MOSAIC) if @layout.screen.pixelation.pixelates?
          end

          # Everything the painted screen's background is told as the screen is set up: whether it is
          # drawn in blocks, and how big its pixels are. Each way into a painted screen calls this
          # one, so none of them can leave a setting out.
          def emit_painted_screen_settings
            emit_painted_screen_in_blocks
            emit_bigger_pixels
          end

          # A game of big pixels (`screen :bitmap, pixel_size: 2`) draws a small picture in the top
          # left of the painted screen's memory, and the display shows it bigger, copying nothing.
          #
          # The painted screen is the console's third background, the one that can turn and resize:
          # for each pixel of the screen it shows, the display steps through the picture by the
          # amounts in four registers, a step across and a step down, in 8 fraction bits. One whole
          # pixel a step shows the picture as drawn. Half a pixel a step (0x80) shows every pixel of
          # the picture twice across and twice down, so the picture's top left 120×80 fills the
          # screen, each pixel a square of four, exactly: the display works out which pixel of the
          # picture a pixel of the screen is by shifting away the fraction, so screen pixel 2x and
          # 2x + 1 are both picture pixel x. The picture keeps its rows 240 pixels apart in memory,
          # as every painted screen does, so every drawing verb writes where it always did; it only
          # draws in fewer of them.
          #
          # This is the hardware's way and not mosaic. Mosaic shows blocks of the whole picture
          # — the top left pixel of each square shown for all four — so the game would still draw
          # a picture of the screen's size, and only a quarter of what it drew would be seen.
          #
          # Written as the painted screen is set up, so a game that never sets pixel_size: writes
          # nothing. Nothing else writes these registers on a painted screen of big pixels: the
          # camera, which does, is refused there (Guardrails::Checks::BiggerPixelsNotMadeYet).
          def emit_bigger_pixels
            return if @layout.pixel_size == 1

            step = FIXED_ONE / @layout.pixel_size
            @emitter.write_reg16(REG_BG2PA, step)
            @emitter.write_reg16(REG_BG2PB, 0)
            @emitter.write_reg16(REG_BG2PC, 0)
            @emitter.write_reg16(REG_BG2PD, step)
          end

          # A layer of a program shown as it is declared waits for its own background.
          #
          # The screen is declared before the backgrounds on it, and a background's own
          # statement is what copies its map in and tells its layer where that map is. A layer
          # switched on before then is not blank: its map is taken to be at the very start of
          # video memory, which is where the tile pictures are, so the console draws the art as
          # though it were a grid for however many rows setting the background up takes.
          #
          # A program with a game loop never shows that, because its picture is held off until
          # the first frame is set up (see #initial_forced_blank_bit). A program with no loop
          # has nothing holding it off, so there the screen is declared with these layers left
          # off, and each background switches its own on once it is pointed
          # (#emit_enable_late_layer). What shows in between is the backdrop.
          #
          # Not in a program that changes the hardware from scene to scene: there boot and each
          # scene's own setup write the display's settings, and `screen` writes nothing.
          def late_layers?
            @layout.tiled && !@layout.waits_for_frames && !@layout.modes.switched_per_scene?
          end

          def late_layer_enable_bits
            return 0 unless late_layers?

            scene_handover.always_up.scenery.reduce(0) { |bits, node| bits | layer_enable_bit(node) }
          end

          def layer_enable_bit(background) = BG_ENABLES[@layout.screen.backgrounds.fetch(background.name).bg]

          # Write the display's settings as +value+, keeping whichever of the +late+ layers is
          # on already: a background written above its `screen` has switched its own on by
          # now, and writing the whole register would switch it off again for good. The value
          # goes in a byte at a time, since that is the most one instruction can hold.
          def emit_display_control_keeping(value, late)
            change_display_control do
              @emitter.emit(ASM.and_imm(ACC, ACC, late))
              [value & 0x00FF, value & 0xFF00].reject(&:zero?).each { |byte| @emitter.emit(ASM.orr_imm(ACC, ACC, byte)) }
              @background_drawing.emit_without_switched_off_layers(ACC, scratch: 2) # TMP holds the register's address
            end
          end

          def emit_enable_late_layer(background)
            return unless late_layers?

            change_display_control do
              @emitter.emit(ASM.orr_imm(ACC, ACC, layer_enable_bit(background)))
              @background_drawing.emit_without_switched_off_layers(ACC, scratch: 2) # ...save one the game hid
            end
          end

          # Keep the picture switched off until the first frame has been set up.
          #
          # Everything a game sets up before its loop — a screen painted, a flash it opens on — is
          # carried onto the screen by work done between frames: the effect a routine writes
          # there, the sprites placed there. Switching the picture on where the screen is
          # declared shows it before any of that has happened, and when setting up runs past the
          # end of a frame, which painting the whole screen does, that frame goes out as the
          # bare picture: a game opening on a white flash shows its first picture at full
          # brightness first.
          #
          # So the screen is declared with the picture held off, and the first wait for the gap
          # between frames switches it on (#emit_end_forced_blank). That gap is the one moment
          # nothing is drawn, and the work between frames runs in it too, so the first line
          # the display draws has all of it in force whichever of them comes first. A game that
          # sets up inside one frame loses nothing: the gap it waits for is the one it would
          # have been shown after anyway. A program that never waits for a frame has no gap to
          # switch it on in, so it is shown as soon as it is declared, as before.
          #
          # What a console shows while its picture is held off is plain white.
          def initial_forced_blank_bit = @layout.waits_for_frames ? FORCED_BLANK : 0

          # Switch the picture on, at the gap between frames. Every frame rather than the
          # first alone, because it is three instructions where remembering whether it was
          # the first would cost the same; on every frame after the first it changes nothing.
          def emit_end_forced_blank
            return unless @layout.waits_for_frames

            @emitter.emit_number(TMP, REG_DISPCNT)
            @emitter.emit(ASM.load_halfword(ACC, TMP))
            @emitter.emit(ASM.bic_imm(ACC, ACC, FORCED_BLANK))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # Which of the console's tile arrangements this program needs, and which layers
          # to turn on — the whole display-control value for a tiled screen.
          #
          # The console arranges its tile layers two ways, and the difference is what the
          # layers are rather than how many: mode 0 is four layers that scroll and nothing
          # that turns; mode 1 is two that scroll plus one that turns and resizes. A game
          # needs the second exactly when it turns a background — a title where something
          # flies at the player over a backdrop, a map that spins inside a fixed frame, a
          # road that banks under a sky — and nothing in a program asks for it, because
          # turning a background is asking for it. (The third arrangement, mode 2, is `screen
          # :rotozoom`: two turning layers and nothing else, and it keeps its own path.)
          # +on+ names the layers to switch on, +turning+ which arrangement this screen
          # wants, and +bar+ whether it shows a status bar's window. Given none of them, this is the
          # value for the screen the console is set up for before any scene has run — see
          # #first_scene_layers. The sprite layer is added by the
          # callers, which all do it the same way for every screen.
          def tiled_dispcnt(on = nil, turning: nil, bar: nil)
            boot = (on.nil? && turning.nil?) ? first_scene_layers : nil
            on = boot.on if boot
            turning = (boot ? boot.turning : turning_background?) if turning.nil?
            bar = (boot ? boot.bar : bar_on_screen?) if bar.nil?
            (turning ? MODE_1 : MODE_0) | tiled_bg_enable_bits(*[on].compact) | bar_window_bit(bar)
          end

          # The window a status bar on this screen is shown through: the second, or in a border the
          # first, since the second is the game's screen there (BorderSprites#emit_bar_registers).
          def bar_window_bit(bar)
            return (bar ? WIN0_ENABLE : 0) if @layout.border

            bar || @layout.screen.boxes_backgrounds? ? WIN1_ENABLE : 0
          end

          # The screen the console is set up for before any scene has run, or nothing at all
          # for a game whose scenes all want the same one — there the whole program is the
          # screen and every layer in it belongs on.
          #
          # Where the scenes differ, boot names the first scene's layers rather than the
          # union of every background in the game. A layer switched on before its own scene
          # has told it where its map is does not draw blank: nought points at the start of
          # video memory, which is where the tile pictures are, so it draws the art as
          # though it were a grid, in front of everything. Naming too few layers instead is
          # a black frame, which is the safe way to be wrong for the one frame it lasts.
          def first_scene_layers = (@layout.screen.first_scene_screen if @layout.screen.layers_differ_by_scene?)

          def turning_background? = @layout.turning_layers.any?

          # Whether a status bar is up on a screen of a game whose screens all show the same
          # layers: then a bar anywhere is on the one screen there is.
          def bar_on_screen? = @layout.screen.picture.scenery.any?(&:bar?)

          # The DISPCNT enable bit per layer, and the OR of them for the layers this
          # program's backgrounds actually landed on — at least BG0, so a tiled screen
          # always has one layer on. Read off the placements rather than counted, because
          # a turning layer is always BG2 (that is where the console keeps the hardware)
          # however few plain layers sit beside it.
          BG_ENABLES = [BG0_ENABLE, BG1_ENABLE, BG2_ENABLE, BG3_ENABLE].freeze
          def tiled_bg_enable_bits(used = program_bg_layers)
            bits = used.reduce(0) { |on, layer| on | BG_ENABLES[layer] }
            # ...and the object window, for a program that keeps sprites out of a fade.
            bits |= OBJ_WINDOW_ENABLE if @layout.screen.placed_fade.any?
            # ...and the first window, for a program with a light: its edges are the circle,
            # fed a row at a time (see Raster#emit_boot_shade).
            bits |= WIN0_ENABLE if @raster.feeds_light?
            bits | display_window_bits
          end

          # The first window, on every screen of a game that holds a fade to a rectangle (see
          # ScreenEffects#emit_fade_window). The window is switched on here, in the display's
          # settings, and those are written whole each time the screen changes kind, so every
          # one of them carries it — the bitmap screens' too, where the picture is the console's
          # third layer and the window cuts the effect on it like any other.
          #
          # A game shown in a border has the second window on every screen: it is the game's
          # screen, the only place the blend reaches (see BorderSprites). The checks refuse a fade
          # held to a rectangle in such a game, and a background held to a box, which would want
          # the windows too.
          def display_window_bits
            return WIN1_ENABLE if @layout.border

            @layout.fading.rectangle_fades? ? WIN0_ENABLE : 0
          end

          # The layers a program that declares no scenes uses — every one its
          # backgrounds landed on, and the first layer for a program with none, so a tiled
          # screen always has one on.
          #
          # A scene that names none of them is a different thing and keeps its empty list:
          # it draws no scenery, so it wants no layer, and handing it one anyway leaves that
          # layer on with nobody to point it anywhere. A title screen of sprites and words
          # showed the game's tile pictures as a grid behind them for exactly that reason.
          def program_bg_layers
            used = @layout.screen.backgrounds.each_value.map(&:bg).uniq
            used.empty? ? [0] : used
          end

          # One-time boot for a program that switches the hardware per scene: put the
          # display in the default scene's mode. A buffered program also uploads its
          # color table here (palette memory survives mode switches), then starts by
          # showing page 0 and drawing into page 1; a tiled default brings up the tile
          # layers and sprites; a direct default is the plain Mode 3 write.
          def emit_boot_screen
            upload_palette if @layout.modes.any_buffered? # the palette exists only for the buffered path
            # Held off until the first frame is set up, as a single-screen game's is (see
            # #initial_forced_blank_bit). Only here: a scene changing the screen later is
            # changing a picture already showing, and must not switch it off.
            held = initial_forced_blank_bit
            case @layout.modes.default_mode
            when :tiled then enter_tiled_mode(held)
            when :affine then enter_affine_mode(held)
            when :buffered then enter_buffered_mode(held)
            else enter_direct_mode(held)
            end
          end

          # Switch the hardware into double-buffered (Mode 4): remember the live DISPCNT
          # so a flip is a cheap bit-toggle, draw into page 1 first, show page 0, and
          # record that buffered is now the live mode.
          # +held+, here and in the three below, is the bit that keeps the picture switched off,
          # given only by the boot (see #emit_boot_screen).
          def enter_buffered_mode(held = 0)
            @background_drawing.reset_bg2_affine_if_needed
            emit_painted_screen_settings
            emit_sprites_over_picture_again
            base = MODE_4 | BG2_ENABLE | display_window_bits | sprites_over_picture_bits
            @primitives.store_word_immediate(base, @primitives.var_addr(DISPCNT_STATE))
            @primitives.store_word_immediate(PAGE1, @primitives.var_addr(BACKBUF))
            @emitter.write_reg16(REG_DISPCNT, base | held)
            emit_game_window_without_bar
            @primitives.store_word_immediate(MODE_BUFFERED, @primitives.var_addr(MODE_STATE))
            @scene_entry.emit_clear_used_markers # a new display: nothing any scene put up is there
            @background_drawing.emit_forget_all_held_tiles # ...nor any cell change waiting for it
            # In a program that crosses to the tiled screen, that screen's own colors have been in
            # this table since, so every number this screen painted would mean another color. So
            # put the originals back, which is also what makes a remembered tint true again. A
            # scene that tints leaves its color table blended, and a plain bitmap screen's tint
            # writes its color over this table's first entry, which are the other reasons to.
            if @layout.modes.crosses_display_systems? ||
               (@palette_tint.moves_color_table? && @palette_tint.tint_crosses_screens?)
              upload_palette
            end
            @effects.emit_kept_tint_on_entry(IR::Modes::BUFFERED)
          end

          # Switch the hardware into direct-color (Mode 3) and record it as live. Writing
          # the whole register also turns the tile and sprite layers off, so nothing a
          # tiled scene left on screen bleeds under the bitmap one — only BG2 (the
          # framebuffer) shows, which the bitmap scene redraws.
          def enter_direct_mode(held = 0)
            @background_drawing.reset_bg2_affine_if_needed
            emit_painted_screen_settings
            emit_sprites_over_picture_again
            @emitter.write_reg16(REG_DISPCNT, MODE_3 | BG2_ENABLE | display_window_bits | sprites_over_picture_bits | held)
            emit_game_window_without_bar
            @primitives.store_word_immediate(MODE_DIRECT, @primitives.var_addr(MODE_STATE))
            @scene_entry.emit_clear_used_markers # a new display: nothing any scene put up is there
            @background_drawing.emit_forget_all_held_tiles # ...nor any cell change waiting for it
            @effects.emit_kept_tint_on_entry(IR::Modes::DIRECT)
          end

          # Switch the hardware into tiled mode (Mode 0). Because the bitmap framebuffer
          # and the tiles share video memory, a bitmap scene overwrites the tile data, so
          # the tile pictures/colors and sprite tiles are (re)uploaded here on entry —
          # cheap, and only on the actual switch. Then turn on the declared background
          # layers (plus the sprite layer if the game has sprites) and record it live.
          # Each background's map and control register are re-set by its own node in the
          # scene body, which runs right after this preamble.
          def enter_tiled_mode(held = 0)
            @background_drawing.reset_bg2_affine_if_needed
            @background_drawing.emit_boot_backgrounds if @layout.tiled && !@layout.screen.backgrounds.empty? # shared BG palette + tile pictures
            emit_objects_again
            @layer_blend.emit_layer_blend_on_entry if @layer_blend.see_through? # ...and which one is see-through
            @effects.emit_kept_tint_on_entry(IR::Modes::TILED)
            value = tiled_dispcnt
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @background_drawing.emit_display_control_written(value | held)
            @primitives.store_word_immediate(MODE_TILED, @primitives.var_addr(MODE_STATE))
            @scene_entry.emit_clear_used_markers # a new display: nothing any scene put up is there
          end

          # Send the sprites' colours and pictures again and clear their table, coming back to a
          # screen that draws sprites from one that painted over the memory they live in. The
          # colours that go up are the ones the game was built with, so a list of sprite colours
          # that has been told to hold others since is given them again. A game that starts on
          # such a screen comes through here at power-on too, before its own first statement,
          # which is why what this reads is written before the screen is set up at all (see
          # PaletteTint#emit_changed_lists_at_power_on).
          def emit_objects_again
            return unless @layout.has_objects

            @sprite_drawing.emit_boot_objects # sprite palette + tiles, and clear the sprite table
            @palette_tint.emit_changed_obj_lists_again(up: nil)
          end

          # A painted screen with sprites shown over it (`sprite ..., over_picture: true`) keeps
          # the sprite layer on, as a tiled screen does: the display draws those sprites over
          # the picture as it sends it to the screen. Their pictures are in the half of sprite
          # memory no painted picture reaches (ScreenLayout#first_sprite_tile), so they are only
          # sent again here because this is also how a game starts on such a screen, and the
          # table of sprites is cleared with them. A game with no such sprite emits nothing.
          def sprites_over_picture? = @layout.screen.sprites_over_picture?

          def sprites_over_picture_bits = sprites_over_picture? ? OBJ_ENABLE | OBJ_1D_MAP : 0

          def emit_sprites_over_picture_again
            emit_objects_again if sprites_over_picture?
          end

          # Switch the hardware into the affine layer (Mode 2): re-upload the shared BG
          # palette/tile pictures on entry, same reason #enter_tiled_mode does — bitmap
          # and tile VRAM overlap, so a bitmap scene overwrites what the affine
          # background's tiles need. Its own map/matrix are re-set right after this by
          # the background's own node in the scene body (see BackgroundDrawing#emit_background_hardware),
          # the same as a regular tiled layer's.
          def enter_affine_mode(held = 0)
            @background_drawing.reset_bg2_affine_matrix # the one-time "no turn, no resize yet" starting matrix
            @background_drawing.emit_boot_backgrounds if @layout.tiled && !@layout.screen.backgrounds.empty?
            emit_objects_again
            @layer_blend.emit_layer_blend_on_entry if @layer_blend.see_through?
            @effects.emit_kept_tint_on_entry(IR::Modes::AFFINE)
            value = MODE_2 | BG2_ENABLE | display_window_bits
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @background_drawing.emit_display_control_written(value | held)
            @primitives.store_word_immediate(MODE_AFFINE, @primitives.var_addr(MODE_STATE))
            @scene_entry.emit_clear_used_markers # a new display: nothing any scene put up is there
          end

          # Emitted at the top of each scene when a program switches the hardware per
          # scene: switch into this scene's mode, but only if it isn't already there (a
          # transition). Steady frames — the same scene running again — cost just the
          # compare, and a buffered scene's DISPCNT is left to the page flip.
          # What a scene tells the display as it takes over. Both halves are skipped by the
          # programs that do not need them, so a game with one screen and one set of layers
          # emits nothing here at all.
          #
          # Set up, then switch on — the order matters and cannot be seen by reading the
          # registers once a frame. Pointing a layer at its map is the long part (a map per
          # layer, sent in one go) and the console draws the picture while it happens, so a
          # layer switched on first draws the tile pictures as a grid for whatever is left of
          # the frame. Switched on last, a layer either draws its own scenery or is not on
          # yet, and not on yet is one frame of backdrop.
          def emit_scene_preamble(name)
            emit_painted_scene_without_backdrop(name) if @palette_tint.tints_screen_backdrops?
            emit_scene_mode(name) if @layout.modes.switched_per_scene?
            emit_painted_run_places(name)
            emit_scene_scenery(name)
            # ...and its own sprite pictures, which scenes share the room for, so a scene taking
            # over sends its own and one already running sends nothing. Straight after scenery
            # it sends, so one hold covers both (#emit_with_layers_held_for_art). A scene with no
            # scenery of its own sends them after its backdrop, blend and light instead: those
            # writes then land at the start of the gap, not part way down a picture the copy ran
            # into, where a backdrop or a brightness changed under the hold would tear its colour.
            sends_scenery = scene_handover.arrival(name).scenery.any?
            emit_scene_art_upload(name) if sends_scenery
            emit_scene_backdrop(name) if scene_handover.backdrops?
            @raster.emit_light_leaving(name, @layout.scene_blend.fetch(name, BLD_OFF))
            emit_scene_blend(name)
            @raster.emit_light_for_lit_scene(name)
            emit_scene_layers(name)
            emit_scene_art_upload(name) unless sends_scenery
          end

          # The colour this scene shows wherever nothing is drawn, in a game where a screen sets one
          # (IR::SceneHandover::Arrival#backdrop). The console keeps it in the first place of its
          # background colours, which every tile's see-through pixels and every empty cell show;
          # it is written as the scene takes over, after the scene's own colours, whose table
          # carries it too (ScreenLayout#with_backdrop). A painted screen draws every pixel, and
          # keeps a tint's colour in that place, so it is left alone there. A backdrop that follows
          # a list is the list's, which the scene's colours going in put back
          # (PaletteTint#emit_recolored_banks), so the scene writes none of its own.
          def emit_scene_backdrop(name)
            arrival = scene_handover.arrival(name)
            return unless IR::SceneHandover.tiles?(IR::Modes::SCREEN_OF_MODE.fetch(arrival.mode)) && arrival.backdrop

            @scene_entry.emit_once_on_arrival(:backdrop, name) { emit_backdrop_color(arrival.backdrop) }
          end

          # A painted scene taking over, in a build that puts a screen's backdrop back after a walk
          # of the colours (PaletteTint#prepare_screen_backdrops): it has no backdrop to put back,
          # and says so before its screen and colours go up, since a tint kept across the change
          # walks them as they do. A scene drawn from tiles writes its own after (#emit_scene_backdrop).
          def emit_painted_scene_without_backdrop(name)
            return if IR::SceneHandover.tiles?(IR::Modes::SCREEN_OF_MODE.fetch(scene_handover.arrival(name).mode))

            @scene_entry.emit_once_on_arrival(:backdrop, name) { @palette_tint.emit_no_screen_backdrop }
          end

          # The colour +color+ into the first place of the background colours: the backdrop. A
          # build that walks its colour tables puts it in through the tint in force.
          def emit_backdrop_color(color)
            return @palette_tint.emit_backdrop_through_tint(color) if @palette_tint.tints_screen_backdrops?

            @emitter.emit(ASM.load_immediate(ACC, color))
            @emitter.emit(ASM.load_immediate(TMP, PALETTE_START))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # Which layers this scene blends, for a game whose scenes want different answers.
          #
          # The blend unit is told which layers to mix by number, and scenes take turns with
          # the console's layers — so the number the see-through layer sits on belongs to
          # the scene rather than to the game. A scene that sees through nothing sets that
          # here too, which is what stops whichever background inherited that number being
          # blended in its place.
          #
          # A game whose scenes all want the same thing has nothing here: boot's one write
          # stands for the whole run (see LayerBlend#blend_control_by_scene).
          #
          # It is written on every pass the scene runs, so it too leaves a fade that holds the
          # blend where it is (see LayerBlend#emit_scene_blend_control).
          #
          # A scene with a light leaves the register to the light, whose word on this pass is the
          # one that stands. Writing its own first would put a value there that the very next
          # write replaces, and an interrupt landing between the two would leave rows of the
          # picture drawn from it: the light's window right, and nothing outside it darkened.
          #
          # A fade placed in the stack is left in the register by a scene that takes over, since it
          # is the game's and stays until the game lifts it. The one scene that takes it off is a
          # scene the light is on in, which the fade takes turns with. A scene whose light shows
          # nothing outside it therefore mixes nothing unless it has an answer of its own: that
          # light leaves the register alone, and the fade of the scene before would stay in it.
          def emit_scene_blend(name)
            wanted = @layout.scene_blend[name]
            wanted ||= BLD_OFF if @raster.shut_out_light_lifts_fade?(name)
            if wanted && @raster.light_owns_blend_in?(name)
              @layer_blend.emit_remember_scene_blend_control(wanted)
            elsif wanted
              @layer_blend.emit_scene_blend_control(wanted)
            end
            @layer_blend.emit_screen_marker(name)
          end

          # Set where each painted run sits on this scene's screen, for a run shown in several
          # scenes that each lay it out somewhere else (see ScreenLayout::PaintedRun). The copy
          # that paints it reads this, both the one as the scene takes over and the one the
          # game asks for with `changed`; a scene that does not show the run sets 0, so a copy
          # asked for there goes nowhere rather than over this screen's own pictures.
          #
          # Written every pass rather than guarded, the same as #emit_scene_layers: it is one
          # store of a number settled during the build, which costs what the guard would. A
          # game whose runs each sit in one place emits none of this.
          def emit_painted_run_places(name)
            (@layout.screen&.painted_vram || {}).each do |run_name, run|
              next unless run.moves?
              next @background_drawing.emit_walking_run_place(run_name, run, shown: run.shown_in?(name)) if run.walk

              at = run.places[name]
              @primitives.store_word_immediate(at ? VRAM_START + at : 0, @primitives.var_addr(ScreenLayout::PaintedRun.place_var(run_name)))
            end
          end

          # Put this scene's backgrounds up, once, as it takes over.
          #
          # Pointing a layer at a background sends the whole map into video memory and puts
          # the layer's scroll back to the top-left corner. That is right the first time and
          # wrong every time after: a background declared inside a scene has its statement in
          # that scene's own routine, which runs on every frame the scene is active, so doing
          # it there undid the scroll the game had asked for and any cell it had changed.
          #
          # Guarded the same way a scene's sprite pictures are, and for the same reason:
          # staying in a scene costs one compare a frame, changing scene costs the setup.
          # A game whose scenery belongs to no scene emits none of this.
          def emit_scene_scenery(name)
            arrival = scene_handover.arrival(name)
            # A scene with no scenery of its own still takes the last one's down, so it marks
            # nobody's as up. Without this, a scene that comes back after one with no
            # scenery found its own marked as still up and skipped putting it up again —
            # keeping the cells and painted tiles of the last visit, where the scene rules
            # say it goes up as declared (see IR::SceneHandover). It is one store a frame,
            # and only in a game where some scene has scenery of its own.
            if arrival.scenery.empty?
              @scene_entry.emit_clear_marker(:scenery) if arrival.takes_down_scenery?
              return
            end

            @scene_entry.emit_once_on_arrival(:scenery, name) do
              emit_with_bg_layers_disabled(name) do
                # Its colours first: the groups its tiles name are this scene's now (see
                # ScreenLayout#assign_tile_banks).
                colors = @layout.screen.scene_send(name).bg_palette
                @palette_tint.emit_send_scene_bg_colors(colors, @layout.screen.bg_shared.palette_units, name) if colors
                (@layout.screen.scene_send(name).tiles || []).each do |stretch|
                  @uploads.emit_dma_blob(stretch.blob, VRAM_START + stretch.offset, stretch.units)
                end
                arrival.scenery.each { |node| @background_drawing.emit_background_hardware(node) }
                @background_drawing.emit_box_set_aside(arrival.scenery)
                arrival.painted_tiles.each { |run| @background_drawing.emit_copy_tiles(Build.copy_tiles(run.name)) }
                @raster.emit_bends_on_arrival(name)
              end
              # The maps just sent are the first ones declared, so what marks which map is
              # showing goes back to the first as well (see IR::SceneHandover).
              arrival.map_choices.each { |var| @primitives.store_word_immediate(0, @primitives.var_addr(var)) }
              @background_drawing.emit_first_area_colors(arrival.scenery, up: name) # ...and a walking one to its first area's colours
              emit_bar_beside(nil) if scene_handover.bar_put_up_on_arrival?(arrival)
            end
          end

          # Switch the layers off while a scene's scenery is sent, and on again after.
          #
          # Scenes that take turns put their pictures and maps in the same room (see
          # ScreenLayout#place_each_scene), so sending this scene's writes over what the last
          # scene's layers are still pointed at. The console goes on drawing while the copy
          # runs, and a layer left on would show the last scene's maps drawn out of this
          # scene's pictures — garbage — for whatever is left of the frame. Off, it shows the
          # backdrop, which is the safe way to be wrong for part of one frame; the frame after
          # is this scene's scenery, whole. Where the sending runs past the gap into a picture,
          # the layers stay off for the rest of it, so that whole picture is the backdrop (see
          # BackgroundDrawing::LAYERS_HELD).
          #
          # Only the layers are touched: the background layers, and in a game that waits for
          # frames the sprites too, unless the game is in a border, which is sprites (see
          # BackgroundDrawing#held_layer_bits). The arrangement and the rest of the display's
          # settings stay as they were. A scene not drawn from tiles has no layers to switch, and
          # is left alone.
          BG_ENABLE_MASK = BG0_ENABLE | BG1_ENABLE | BG2_ENABLE | BG3_ENABLE

          def emit_with_bg_layers_disabled(name)
            screen = @layout.screen.scene_send(name).screen
            return yield unless screen

            on = screen.on.reduce(0) { |bits, layer| bits | BG_ENABLES[layer] }
            return emit_with_layers_held_for_sending(on, name) { yield } if @background_drawing.holds_layers?

            change_display_control { @emitter.emit(ASM.bic_imm(ACC, ACC, BG_ENABLE_MASK)) }
            yield
            return if on.zero?

            change_display_control do
              @emitter.emit(ASM.orr_imm(ACC, ACC, on))
              @background_drawing.emit_without_switched_off_layers(ACC, scratch: 2) # TMP holds the register's address
            end
          end

          # The same, in a game that waits for frames: the background layers and the sprites go
          # off for the sending, and come back on, the scene's layers in place of the last
          # scene's, at once in the gap or at the start of the next gap where the sending ran
          # into a picture (see BackgroundDrawing::LAYERS_HELD). Where the scene's sprite pictures
          # are sent next, the layers stay off for them, and they come on after (see
          # #emit_with_layers_held_for_art).
          def emit_with_layers_held_for_sending(on, name)
            art_follows = art_held?(name)
            @scene_entry.emit_unless_scene_up(:art, name) { @sprite_drawing.emit_hide_game_rows } if art_follows && @layout.border
            @background_drawing.emit_layers_off_for_sending(SCENE_SEND_DISPLAY)
            yield
            @primitives.load_var(ACC, SCENE_SEND_DISPLAY)
            @emitter.emit(ASM.bic_imm(ACC, ACC, BG_ENABLE_MASK))
            @emitter.emit(ASM.orr_imm(ACC, ACC, on)) unless on.zero?
            return @background_drawing.emit_layers_back_on_or_held(ACC, held: first_picture_held?(name)) unless art_follows

            # The pictures are sent when the note of whose are up names another scene, as
            # SceneEntry#emit_once_on_arrival reads it: then the layers stay off for them.
            @primitives.store_var(ACC, SCENE_SEND_DISPLAY)
            @emitter.emit_number(ACC, 1)
            @primitives.store_var(ACC, SCENE_ART_FOLLOWS)
            @scene_entry.emit_if_scene_up(:art, name) do
              @emitter.emit_number(ACC, 0)
              @primitives.store_var(ACC, SCENE_ART_FOLLOWS)
              @primitives.load_var(ACC, SCENE_SEND_DISPLAY)
              @background_drawing.emit_layers_back_on_or_held(ACC, held: first_picture_held?(name))
            end
          end

          # Where the display's settings are kept while a scene's scenery is sent.
          SCENE_SEND_DISPLAY = :_scene_send_display

          # Switch on the layers held off for the picture just drawn, in the gap
          # between frames (see BackgroundDrawing::LAYERS_HELD).
          def emit_held_layers_on = @background_drawing.emit_held_layers_on

          # Read the display's settings into ACC, let the block change them, write them back.
          # Where the screen's interrupt can switch held layers on, with the interrupt switch off
          # between the read and the write (SpriteDrawing#changing_display_control).
          def change_display_control(&change)
            @sprite_drawing.changing_display_control do
              @emitter.emit_number(TMP, REG_DISPCNT)
              @emitter.emit(ASM.load_halfword(ACC, TMP))
              change.call
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
          end

          # What a scene does to the screen as it takes over, worked out once for both backends.
          def scene_handover = @layout.screen.handover

          # The screen this scene draws on, in a program whose scenes differ. One that does
          # not leaves each `screen` node to write the display control inline. Whether it is a
          # change depends on the scene before, so it is a compare as the scene takes over:
          # entering a mode writes MODE_STATE itself, since boot enters one too.
          def emit_scene_mode(name)
            mode = scene_handover.arrival(name).mode
            @scene_entry.emit_unless_holds(MODE_STATE, mode_state_marker(mode)) do
              emit_painted_screen_wiped(name, mode)
              enter_mode(mode)
              emit_always_up if IR::SceneHandover.tiles?(IR::Modes::SCREEN_OF_MODE.fetch(mode))
            end
          end

          # A painted screen reached from one drawn from tiles starts as the backdrop. The picture
          # of the painted screen and the tiled screen's tiles and maps are the same video memory,
          # so what was tiles would show as coloured noise wherever the scene does not paint, on
          # both of a tear-free screen's pages. One painted screen reached from the other keeps the
          # picture, as the interpreter does (Reference#exec_screen). A game that never leaves its
          # painted screens pays nothing, and one that does pays a fill on the pass it crosses.
          def emit_painted_screen_wiped(scene, mode)
            return unless @layout.modes.crosses_display_systems?
            return unless [IR::Modes::DIRECT, IR::Modes::BUFFERED].include?(mode)

            backdrop = scene_handover.arrival(scene).backdrop
            direct = mode == IR::Modes::DIRECT
            @scene_entry.emit_unless_holds(MODE_STATE, direct ? MODE_BUFFERED : MODE_DIRECT) do
              direct ? emit_screen_filled(backdrop) : @buffered.emit_both_pages_filled(backdrop)
            end
          end

          # Put up again what every screen drawn from tiles shows, on the way back from a screen
          # of another kind (see IR::SceneHandover#always_up). Entering the mode sends the
          # pictures again; the maps of the scenery declared in no scene, and what the game
          # paints from lists, were sent once at power-on and nothing else sends them. The maps
          # go up as declared, so what marks which one is showing goes back to the first.
          def emit_always_up
            always = scene_handover.always_up
            always.scenery.each { |node| @background_drawing.emit_background_hardware(node) }
            emit_bar_beside(scene_handover.bar_shown_early) if scene_handover.bar_shown_early # ...the bar among them
            always.map_choices.each { |var| @primitives.store_word_immediate(0, @primitives.var_addr(var)) }
            @background_drawing.emit_first_area_colors(always.scenery)
            (always.painted_tiles + always.painted_pictures).each do |run|
              @background_drawing.emit_copy_tiles(Build.copy_tiles(run.name))
            end
          end

          # Switch on the layers this scene uses, and only those.
          #
          # Scenes take turns, so they share the console's four layers rather than each
          # having some of their own (see ScreenLayout#layer_slots). A scene that uses fewer than
          # the one before it would otherwise leave the extra ones switched on, still
          # pointed at the last scene's maps, and they would show through wherever this
          # scene's own scenery has a hole in it.
          #
          # It is written every pass rather than guarded by a compare, because it is one
          # store of a number settled during the build — the guard would cost as much as the
          # write. A program whose scenes all use the same layers emits none of this.
          def emit_scene_layers(name)
            return unless @layout.screen.layers_differ_by_scene?

            wanted = @layout.screen.scene_send(name).screen
            return unless wanted

            value = tiled_dispcnt(wanted.on, turning: wanted.turning, bar: wanted.bar)
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            # Leaves the sprites off on a frame hide_sprites asked for, the layers
            # off for the rest of a picture the scene's setup ran into, and the layers the game
            # hid off (BackgroundDrawing#emit_layer_switch).
            if @background_drawing.holds_layers?
              @sprite_drawing.emit_screen_layers(value) do |reg|
                @background_drawing.emit_without_switched_off_layers(reg)
                @background_drawing.emit_display_control_keeping_held_off(reg)
              end
            elsif @layout.screen.hides_layers?
              @sprite_drawing.emit_screen_layers(value) do |reg|
                @background_drawing.emit_without_switched_off_layers(reg)
                @emitter.emit_number(TMP, REG_DISPCNT)
                @emitter.emit(ASM.store_halfword(reg, TMP))
              end
            else
              @sprite_drawing.emit_screen_layers(value)
            end
            emit_game_window_without_bar unless wanted.bar
          end

          # A screen with no status bar, in a border, shows every layer in the game's screen again: a
          # screen with a bar left its layer out there (BorderSprites#emit_bar_registers), and the
          # layer may be another background's on this screen, or the painted picture's. A game with no
          # bar, or none in a border, emits nothing.
          def emit_game_window_without_bar
            @layout.border.emit_game_window_without_bar if @layout.border && bar_on_screen?
          end

          # Send a scene's sprite pictures when it takes over. Scenes share the room above
          # whatever is always there, so this is what makes a game's budget one scene's
          # rather than the whole game's — and it is guarded, so staying in a scene costs
          # one compare a frame while changing scene costs the copy.
          #
          # A pool's pictures are not among them: each pose goes in the first time one of its
          # things shows it (see PoseSends), so here the pool's record of what has been sent goes
          # back to nothing instead.
          #
          # A scene with no art of its own emits nothing at all, which is every scene in a
          # game that declares its sprites at the top level. A scene whose characters keep one
          # frame at a time has art of its own even when it has nothing to send: another
          # scene's pictures go into the same memory, so taking over has to mark those frames
          # as gone and mark this scene as the one loaded.
          #
          # The copy lands where the scene's own routine runs, after its scenery, so in the gap
          # or past it. A copy that runs on into the picture would show the rows above the line
          # it had reached without the scene's sprites and the rows below with them, the line
          # set by how many cycles the pass spent getting there. So in a game that holds its
          # layers, the copy is a sending like the scenery's (#emit_with_layers_held_for_art).
          def emit_scene_art_upload(name)
            own = @layout.screen.scene_send(name)
            art = own.art || []
            rooms = @layout.screen.objects.each_value.select { |obj| obj.scene == name && obj.frames }
            colors = own.obj_palette
            arrival = @layout.screen.handover.arrival(name)
            painted = arrival.painted_pictures
            pools = @layout.screen.pools_sending_poses_in(name)
            owns_groups = @picture_group_copying.sets_of?(name)
            if art.empty? && rooms.empty? && colors.nil? && painted.empty? && pools.empty? && !owns_groups
              # A scene with no sprite art of its own normally leaves the last scene's marked as
              # loaded, which is right: nothing overwrote it. A painted picture is the exception,
              # since its list can change while its scene is away and it goes up from the list
              # as it is then — so in a game with one, this scene marks nobody's as loaded.
              @scene_entry.emit_clear_marker(:art) if @layout.screen.scene_art? && arrival.takes_down_art?
              return
            end

            @scene_entry.emit_once_on_arrival(:art, name) do
              emit_with_layers_held_for_art(name) do
                # Its colours first: the groups its sprites name are this scene's now (see
                # ScreenLayout#build_shared_object_palette). A scene the scene dispatch picks has them
                # sent with its sprites instead (see SpriteDrawing#emit_scene_colors_on_change).
                @palette_tint.emit_send_scene_obj_palette(colors, @layout.screen.obj_palette_units, name) if sends_scene_colors?(name)
                art.each { |blob, at, units| @uploads.emit_dma_blob(blob, SpriteDrawing::OBJ_TILE_BASE + (at * 32), units * 16) }
                @sprite_drawing.emit_reset_resident_frames(rooms)
                pools.each { |pool| @sprite_drawing.emit_forget_poses_sent(pool) }
                @picture_group_copying.emit_forget_sets_of(name) # the groups it wants copied in before its sprites

                # A picture the game paints goes up from its list as it is now: the scene before
                # used the same memory (see IR::SceneHandover).
                painted.each { |run| @background_drawing.emit_copy_tiles(Build.copy_tiles(run.name)) }
              end
            end
          end

          # Does +name+ send its sprites' colours as it takes over, rather than with its sprites?
          def sends_scene_colors?(name)
            @layout.screen.scene_send(name).obj_palette && !@layout.screen.scene_colors_picked?(name)
          end

          # IS +name+'S SPRITE PICTURES' SENDING HELD (#emit_with_layers_held_for_art)? On a scene
          # drawn from tiles in a game that holds its layers, where the scene sends its sprites'
          # colours or copies pictures, since either landing part way down a picture tears it. A
          # scene that only marks what it has sent writes nothing seen.
          def art_held?(name)
            own = @layout.screen.scene_send(name)
            arrival = scene_handover.arrival(name)
            sends = sends_scene_colors?(name) || !(own.art || []).empty? || !arrival.painted_pictures.empty?
            sends && IR::SceneHandover.tiles?(IR::Modes::SCREEN_OF_MODE.fetch(arrival.mode)) && @background_drawing.holds_layers?
          end

          # A scene's sprite pictures sent as its scenery is, with the layers and the sprites off,
          # and back on in the gap or held for the picture the copy ran into (see
          # BackgroundDrawing::LAYERS_HELD). The sprites' rows were written in the gap before
          # this, so a picture the copy reaches part way down would show them torn at a row set by
          # timing; held, that picture is the backdrop whole in every build, and the next is the
          # scene whole. A copy that ends inside the gap shows the scene on the picture after it,
          # as the interpreter does. A scene with no scenery of its own is held the same way: the
          # pair keeps the display's settings as they were and puts them back.
          #
          # One hold for the scenery and the pictures. Where the scene's scenery was sent just
          # before, with the layers off, they are still off (SCENE_ART_FOLLOWS): switched on between
          # the two, a line drawn in that moment would show the scene with the last scene's sprite
          # pictures, at a row set by timing.
          #
          # In a border the sprites stay on through a hold, since the border is sprites, so the
          # game's own rows of the sprite table are hidden instead (SpriteDrawing#emit_hide_game_rows),
          # and copied in again (#emit_game_rows_back_in_gap).
          def emit_with_layers_held_for_art(name)
            return yield unless art_held?(name)

            off = @emitter.gensym
            @sprite_drawing.emit_hide_game_rows if @layout.border
            @primitives.load_var(ACC, SCENE_ART_FOLLOWS)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, off, cond: :ne)
            @background_drawing.emit_layers_off_for_sending(SCENE_SEND_DISPLAY)
            @emitter.place_label(off)
            yield
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, SCENE_ART_FOLLOWS)
            @primitives.load_var(ACC, SCENE_SEND_DISPLAY)
            @background_drawing.emit_layers_back_on_or_held(ACC, held: first_picture_held?(name))
            emit_game_rows_back_in_gap if @layout.border && !first_picture_held?(name)
          end

          # A scene whose sending can run past the gap holds its first picture whatever the timing.
          #
          # Where a sending ends decides whether the picture after it shows the scene (in the gap)
          # or the backdrop (past it), and two builds of one game move their pictures from different
          # memories at different speeds: the all-in-one build from the cartridge, one built with
          # its data pack left out from the pack's copy in work memory. Near the gap's end one shows
          # the scene and the other holds it. So a scene whose sending can need more than the room
          # the gap leaves it (SENDING_ROOM_CYCLES) is held for the picture after it on every build,
          # wherever it ends, and the scene shows on the one after that. The count is made from
          # what the sending moves, which is the same on every build of a game, so every build
          # decides alike. A scene whose sending fits is left to the timing, as before (see
          # BackgroundDrawing::LAYERS_HELD).
          #
          # What it moves is counted at the slowest source any build reads it from. The copying
          # engine reads a halfword and writes it for each unit (GBATEK, "DMA Transfers": 2N +
          # 2(n-1)S + xI): from the cartridge at the power-on wait states a build keeps with
          # `fast_cartridge: false` a sequential halfword is three cycles, from work memory three
          # too (two wait states), and the write to video or palette memory one (GBATEK, "GBA
          # Memory Map", "System Control"). Four cycles a halfword is two a byte.
          SENDING_CYCLES_A_BYTE = 2

          # A map filled by the processor rather than copied whole: the view of a background whose
          # map is bigger than video memory keeps, filled round its corner a row at a time
          # (MapStreaming). Counted as the block of cells the console keeps for it, each read and
          # written by a few instructions: a fixed eight cycles a cell.
          STREAM_FILL_CYCLES = MapStreaming::STREAM_CELLS * MapStreaming::STREAM_CELLS * 8

          # The room a scene's sending has: half the gap between pictures (GBATEK, "LCD Dimensions
          # and Timings": 228 lines of 1232 cycles, 160 of them drawn). The other half is for the
          # pass's own work in the gap before the scene's routine runs: the sprite table and the
          # sound's handover, and whatever the game's loop does before it picks the scene. The game
          # decides how much that is, and the build cannot count it, so the room keeps half the gap
          # for it rather than a figure that one game's loop already passes.
          LINE_CYCLES = 1232
          GAP_CYCLES = LINE_CYCLES * (228 - SCREEN_HEIGHT)
          SENDING_ROOM_CYCLES = GAP_CYCLES / 2

          # Is +name+'s first picture held whatever the timing (see SENDING_ROOM_CYCLES)? Never in a
          # game that does not hold its layers, which has no gap to hold them for.
          def first_picture_held?(name)
            (@first_picture_held ||= {}).fetch(name) do
              @first_picture_held[name] = @background_drawing.holds_layers? && scene_sending_cycles(name) > SENDING_ROOM_CYCLES
            end
          end

          # The cycles +name+'s sending is counted to take as it takes over: its tile pictures, maps
          # and colours, its painted tiles, and its sprite pictures and colours (#emit_scene_scenery,
          # #emit_scene_art_upload), at SENDING_CYCLES_A_BYTE, and STREAM_FILL_CYCLES for each map
          # the processor fills. A map the BIOS unpacks into place is counted as the bytes it
          # unpacks to, at the copying engine's rate.
          def scene_sending_cycles(name)
            own = @layout.screen.scene_send(name)
            arrival = scene_handover.arrival(name)
            halfwords = (own.tiles || []).sum(&:units) + (own.art || []).sum { |_blob, _at, units| units * 16 }
            halfwords += @layout.screen.bg_shared.palette_units if own.bg_palette
            halfwords += @layout.screen.obj_palette_units if sends_scene_colors?(name)
            filled = 0
            arrival.scenery.each do |node|
              bg = @layout.screen.declared_background(node)
              bg.stream ? filled += 1 : halfwords += bg.map_units
            end
            painted = (arrival.painted_tiles + arrival.painted_pictures).sum do |run|
              @layout.screen.painted_vram&.[](run.name)&.bytes || 0
            end
            (((halfwords * 2) + painted) * SENDING_CYCLES_A_BYTE) + (filled * STREAM_FILL_CYCLES)
          end

          # Set while a scene's scenery has been sent and its sprite pictures are about to be, with
          # the layers left off between the two (#emit_with_layers_held_for_art).
          SCENE_ART_FOLLOWS = :_scene_art_follows

          # In a border, the game's rows of the sprite table copied in again where the sending
          # ended in the gap; one that ran into the picture leaves them hidden for it, and the next
          # pass copies them in the gap after (SpriteDrawing#emit_present_objects).
          def emit_game_rows_back_in_gap
            past = @emitter.gensym
            @emitter.emit_number(TMP, REG_VCOUNT)
            @emitter.emit(ASM.load_halfword(TMP, TMP))
            @emitter.emit(ASM.cmp_imm(TMP, SCREEN_HEIGHT))
            @emitter.emit_branch(:bcond, past, cond: :lo)
            @sprite_drawing.emit_game_rows_copied_in
            @emitter.place_label(past)
          end

          # End the pass a scene that loads first takes over on (see SceneEntry).
          def emit_return_on_arrival_pass(name) = @scene_entry.emit_return_on_arrival_pass(name)

          # A scene's resolved mode -> the marker stored in MODE_STATE, and the routine
          # that switches the hardware into it.
          def mode_state_marker(mode) = MODE_MARKERS.fetch(mode, MODE_DIRECT)

          def enter_mode(mode)
            case mode
            when :tiled then enter_tiled_mode
            when :affine then enter_affine_mode
            when :buffered then enter_buffered_mode
            else enter_direct_mode
            end
          end

          # Copy the color table from the cartridge into background palette memory —
          # one DMA of `size` 16-bit entries, source and destination both advancing.
          def upload_palette
            @emitter.emit_load_data_address(ACC, PALETTE_BLOB) # r0 = table address in the cartridge
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(ACC), to: BG_PALETTE, # the table, into palette memory
                                   control: @layout.palette.size | DMA_ENABLE) # 16-bit, both ends advancing
            @palette_tint.emit_tint_reset_if_tinting # the table now holds the originals again
          end

          # This file's own seams, called as bare methods.
          def backing_info(name) = @lists.backing_info(name)
          def placed_fade = @layout.screen.placed_fade
          def emit_call_cold_routine(label) = @placement.emit_call_cold_routine(label)

          # What the screen up now does with a page finished too late (see IR::LatePages), kept
          # where the end of a pass can read it: nothing to wait, else one more than the row a
          # late page is still shown at once above — so a row of nothing, which shows a late
          # page only when it is finished during the break, is not mistaken for waiting.
          # Written, with the pace a late page is measured against (see Frames), at power-on,
          # wherever a `screen` is, and at the top of every scene's routine on every pass (see
          # #emit_scene_late_pages), in a game where any screen shows a late page at once — and
          # nowhere in a game where none does.
          LATE_PAGE_ROWS = :__late_page_rows

          def emit_late_pages_setting(setting)
            return unless @layout.late_pages.any?

            # Counted in the console's lines, which a game shown in a border starts below its top.
            lines = @layout.late_pages.lines_above(setting)
            @primitives.store_word_immediate(lines ? lines + 1 : 0, @primitives.var_addr(LATE_PAGE_ROWS))
            @frames.emit_set_pace(setting.pace)
          end

          # What the screen a scene draws on does with a late page — its own `screen`, or the
          # game's — set at the top of the scene's routine every pass. That is every scene,
          # however the game reaches it: one the game loop picks with a scene dispatch and one it
          # calls by a name it keeps in a variable alike. A routine that is not a scene is on
          # whatever screen is up, and sets nothing.
          def emit_scene_late_pages(name)
            return unless @layout.late_pages.any? && IR::LatePages.scene?(name)

            emit_late_pages_setting(@layout.late_pages.setting_on(scene_handover.arrival(name).screen))
          end

          # What the game's own screen does, and no page late yet, before anything has run.
          def emit_late_pages_at_power_on
            return unless @layout.late_pages.any?

            emit_late_pages_setting(@layout.late_pages.game_setting)
            @frames.emit_pace_at_power_on
          end

          # Jump to +shown+ instead of waiting, when the screen up asks to show a late page at once
          # and the page just finished may be shown now. Waiting means sleeping until the next
          # break between pictures, which for a page that missed its break is a whole picture.
          #
          # A page is late when the pass missed the break the game's pace aims at (see
          # Frames#emit_branch_if_on_pace) — so a game aiming at thirty does not show its page at
          # once on every pass, only on the ones that ran over thirty. A page on time waits.
          #
          # Where the screen has got to is the console's own count of the line it is sending, 0 to
          # 159 down the picture and 160 to 227 through the break after it, and it decides the
          # rest:
          #
          #   - In the break, nothing is being sent, so showing the page cannot tear, and a late
          #     page is shown.
          #   - Part way down the picture, showing it tears there, so a late page is shown only
          #     above the row the game named — and, just after a page was shown part way down,
          #     only if it is late counting from the break after the coming one, so one tear does
          #     not set off another.
          #
          # The page itself is shown by the page flip after the wait, which is where this jumps
          # to, so a page shown at once is shown exactly the way a page that waited is. Each way
          # of showing is counted where it runs, for the profile (see Emit#note_late_page_shown).
          def emit_skip_wait_for_late_page(shown)
            return unless @layout.late_pages.any?

            wait = @emitter.gensym
            in_break = @emitter.gensym
            @frames.emit_branch_if_on_pace(wait)
            @primitives.load_var(ACC, LATE_PAGE_ROWS)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, wait, cond: :eq) # this screen waits
            @emitter.emit_number(TMP, REG_VCOUNT)
            @emitter.emit(ASM.load_halfword(TMP, TMP))
            @emitter.emit(ASM.cmp_imm(TMP, SCREEN_HEIGHT))
            @emitter.emit_branch(:bcond, in_break, cond: :ge)
            @emitter.emit(ASM.add_imm(TMP, TMP, 1))
            @emitter.emit(ASM.cmp_reg(TMP, ACC))
            @emitter.emit_branch(:bcond, wait, cond: :ge) # below the row the game allows
            @frames.emit_branch_if_on_pace(wait, spent: true)

            @emitter.note_late_page_shown(tears: true)
            @frames.emit_note_break_spent(true)
            @emitter.emit_branch(:b, shown)

            @emitter.place_label(in_break)
            @emitter.note_late_page_shown(tears: false)
            @frames.emit_note_break_spent(false)
            @emitter.emit_branch(:b, shown)

            @emitter.place_label(wait)
            @frames.emit_note_break_spent(false)
          end

          # At the vblank boundary, flip the pages — but only while a buffered scene is
          # live (a direct scene draws straight to the screen and has nothing to flip).
          # The runtime check costs a compare; the mode rarely changes.
          def emit_flip_if_buffered
            @primitives.load_var(ACC, MODE_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, MODE_BUFFERED))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :ne)
            emit_flip
            @emitter.place_label(skip)
          end

          # Present the page just drawn and start drawing the other one — the page
          # flip, run once per frame at the vblank boundary. Toggle the DISPCNT bit
          # that selects the shown page (so the finished page becomes visible), then
          # point the back buffer at the other page (its address is the pair's sum
          # minus the current one).
          def emit_flip
            @primitives.load_var(ACC, DISPCNT_STATE)
            @emitter.emit_number(TMP, DISPCNT_FRAME_SELECT)
            @emitter.emit(ASM.eor_reg(ACC, ACC, TMP))            # flip the page-select bit
            @primitives.store_var(ACC, DISPCNT_STATE)
            @emitter.emit_number(TMP, REG_DISPCNT)
            @emitter.emit(ASM.store_halfword(ACC, TMP))          # the finished page is now shown

            @primitives.load_var(ACC, BACKBUF)
            @emitter.emit_number(TMP, PAGE_PAIR_SUM)
            @emitter.emit(ASM.sub_reg(ACC, TMP, ACC))            # the other page
            @primitives.store_var(ACC, BACKBUF)
          end

          # Plot one pixel. With constant coordinates the VRAM address is known now,
          # so it's a single store. With a computed coordinate (e.g. a variable) the
          # address is built at run time from the evaluated x/y.
          def emit_pixel(node)
            return @buffered.emit_pixel_buffered(node) if @lowering.mode == :buffered

            color = Graphics::Color.resolve(node.color)
            xi = @primitives.const_int(node.x)
            yi = @primitives.const_int(node.y)

            if xi && yi
              return unless @framebuffer.in_bounds?(xi, yi) # off-screen: clip, like the framebuffer

              @emitter.write_reg16(VRAM_START + ((yi * SCREEN_WIDTH) + xi) * 2, color)
            else
              # Video memory is the picture: row after row of 16-bit colours, so the pixel at
              # (x, y) is the halfword at VRAM_START + (y * SCREEN_WIDTH + x) * 2.
              #
              #   VRAM_START ->  [ row 0: x = 0 ... SCREEN_WIDTH-1 ][ row 1 ] ... [ row y ] ...
              #                                                          the pixel: ^ x halfwords in
              #
              # Working it out takes the registers below; the store at the end is the pixel
              # appearing on the screen, nothing more is needed to draw it.
              @lowering.value(node.y)            # r0 = y
              @emitter.emit(ASM.push(ACC))       # the x side may use every scratch register: keep y on the stack
              @lowering.value(node.x)            # r0 = x
              @emitter.emit(ASM.pop(TMP))              # r1 = y
              @emitter.emit_number(2, SCREEN_WIDTH)    # r2 = the width of a row, in pixels
              @emitter.emit(ASM.mul(3, TMP, 2))        # r3 = y * width: the first pixel of row y
              @emitter.emit(ASM.add_reg(3, 3, ACC))    # r3 = y*width + x: pixels from the start
              @emitter.emit(ASM.lsl_imm(3, 3, 1))      # r3 = offset * 2 bytes
              @emitter.emit_number(2, VRAM_START)      # r2 = where video memory starts
              @emitter.emit(ASM.add_reg(3, 2, 3))      # r3 = VRAM address
              @emitter.emit_number(ACC, color)         # r0 = the colour, 15 bits
              @emitter.emit(ASM.store_halfword(ACC, 3)) # one halfword store: the pixel is drawn
            end
          end

          # From this many pixels across, a row of a rectangle is filled by the copy engine
          # rather than a store per pixel.
          #
          # Counted off the emitted code, which a fixed rectangle unrolls, so the instructions
          # written are the instructions run. A pixel stored is four instructions: three to
          # build its address and the store. A row the copy engine fills is eleven, whatever
          # its width: the engine's address, the fill word's address, the row's own address
          # and the control word, each stored into the engine's three registers (GBATEK,
          # "DMA Transfers"). The rectangle also pays three instructions more, once, to put its
          # colour where the engine reads it. So from four pixels a row the engine is the
          # smaller.
          #
          # It is the quicker from four pixels too, played from the cartridge, where most of
          # a game's code runs: the processor waits while the engine copies, but the engine
          # moves a pixel in a cycle or two, where four instructions fetched from the
          # cartridge take several times that. Measured in the emulator, a row of four stored
          # pixels takes longer than a transfer and a row of three a little less. Code placed
          # in fast memory runs its stores quicker, and there they win a pixel or two further, but
          # at four instructions a pixel they spend that small memory fastest of all.
          ENGINE_FILL_MIN_WIDTH = 4

          # Fill a rectangle of constant size, held to the area (off-screen pixels are
          # clipped). A wide one fills each row with one transfer of the copy engine; a narrow
          # one loads the colour once and stores each pixel.
          def emit_fill_rect(node)
            return @buffered.emit_fill_rect_buffered(node) if @lowering.mode == :buffered

            x, y, w, h = @primitives.constant_ints!(node, x: node.x, y: node.y, w: node.w, h: node.h)
            # Every row of a rectangle spans the same columns, so where it starts and how far it
            # reaches is one answer, settled before a single row is emitted.
            left = [x, @framebuffer.clip_left].max
            right = [x + w, @framebuffer.clip_right].min
            top = [y, @framebuffer.clip_top].max
            bottom = [y + h, @framebuffer.clip_bottom].min
            return if right <= left || bottom <= top

            if right - left >= ENGINE_FILL_MIN_WIDTH
              emit_rows_filled(left, right, (top...bottom), node.color)
            else
              emit_pixels_stored(left, right, (top...bottom), node.color)
            end
          end

          # Fill each of +rows+ from column +left+ up to +right+ with one transfer of the copy
          # engine, repeating one fixed word of the colour. Two pixels a transfer needs an even
          # left column and an even width; any other row goes a pixel a transfer, which still
          # lands where it was asked (Framebuffer#fill_control_for_column).
          def emit_rows_filled(left, right, rows, color)
            scratch = @framebuffer.emit_color_fill_word(color)
            control = @framebuffer.fill_control_for_column(left, right - left)
            rows.each do |row|
              @framebuffer.emit_dma_fill_row(scratch, VRAM_START + ((row * SCREEN_WIDTH) + left) * 2, control)
            end
          end

          # Store each pixel of +rows+ from column +left+ up to +right+, the colour loaded once.
          def emit_pixels_stored(left, right, rows, color)
            @emitter.emit_number(ACC, Graphics::Color.resolve(color))
            rows.each do |row|
              (left...right).each do |col|
                @emitter.emit_number(TMP, VRAM_START + ((row * SCREEN_WIDTH) + col) * 2)
                @emitter.emit(ASM.store_halfword(ACC, TMP))
              end
            end
          end

          # Clear the whole screen with one DMA transfer: repeat a packed two-pixel
          # word across VRAM. The DMA engine copies far faster than a pixel loop.
          def emit_clear_screen(node)
            return @buffered.emit_clear_screen_buffered(node) if @lowering.mode == :buffered
            # Inside an area, "the whole screen" is that area — which is a rectangle, and there
            # is already one way to fill one of those.
            return emit_fill_area(node.color) if @framebuffer.clipping?

            emit_screen_filled(Graphics::Color.resolve(node.color))
          end

          # The whole picture of the painted screen in +color+, a 15-bit colour.
          def emit_screen_filled(color)
            # Two pixels share one 32-bit word, so the copy engine fills the picture two pixels at
            # a time: +count+ words, all read from the same place.
            #
            #   scratch (one word: colour, colour) --x count--> video memory, filling forward
            word = (color << 16) | color
            count = SCREEN_WIDTH * @layout.shown_rows / 2
            scratch = @primitives.var_addr(Primitives::FILL_SCRATCH)

            @primitives.store_word_immediate(word, scratch) # hold the fill word in IWRAM
            if @layout.fills_shown_rows_alone?(2)
              return @framebuffer.emit_shown_rows_filled(scratch, first: VRAM_START, rows: @layout.shown_rows,
                                                                  row_bytes: @layout.shown_columns * 2,
                                                                  stride: SCREEN_WIDTH * 2)
            end

            # From that one fixed word, to the screen. The control word's fill flag keeps the
            # source from stepping, so the engine writes the same word every time (GBATEK, "DMA
            # Transfers"); writing it starts the copy.
            @primitives.emit_start_copy_engine(from: scratch, to: VRAM_START, control: @framebuffer.dma_fill_control(count))
          end

          # One column of a picture, stretched to a height worked out as the game runs. The
          # whole of a first-person view is this, once per strip across the screen.
          #
          # It walks down the screen, asking which row of the picture belongs at each screen
          # row. The other way round — walking the picture and working out where each of its
          # rows lands — leaves gaps when stretching and writes some rows twice when squashing.
          # The interpreter walks the same way, which is what makes the two agree pixel for
          # pixel.
          # One walk fills the whole strip. Every pixel across a strip shows the same picture
          # column at the same height, so working the walk out once and writing its answer
          # across is not an optimisation — calling this once per pixel instead asks for the
          # same answer that many times over.
          def emit_draw_column_at(node)
            return @buffered.emit_draw_column_at_buffered(node) if @lowering.mode == :buffered

            bmp = @layout.bitmaps.fetch(node.name) do
              raise LoweringError, "draw_column_at of undefined image #{node.name.inspect}"
            end
            width = node.width || 1
            # Whether a row is asked if its pixel is see-through: not when every row the walk
            # reaches is a pixel.
            see_through = bmp.transparent && !@framebuffer.column_rows_all_pixels?(node.name)

            done = @emitter.gensym
            @framebuffer.emit_column_setup(node, bmp, done)
            @framebuffer.emit_column_runs(node.name, bmp, done) do |leave|
              @framebuffer.emit_clip_column_rows(leave)

              # The left and right edges are settled once here, because a strip has one x for
              # its whole height. A strip wholly inside them then writes with nothing to test;
              # one hanging over an edge takes a second copy of the rows that tests each pixel,
              # which is the rare case and pays for itself only there. A strip one pixel wide
              # has no second case: it is inside or it draws nothing.
              clipped = @emitter.gensym
              @emitter.emit(ASM.cmp_imm(COLUMN_X, @framebuffer.clip_left))
              @emitter.emit_branch(:bcond, clipped, cond: :lt)
              @emitter.emit_number(TMP, @framebuffer.clip_right - width)
              @emitter.emit(ASM.cmp_reg(COLUMN_X, TMP))
              @emitter.emit_branch(:bcond, clipped, cond: :gt)

              emit_column_rows { emit_draw_column_row(bmp, width, clipped: false, see_through: see_through) }
              @emitter.emit_branch(:b, leave) if width > 1
              @emitter.place_label(clipped)
              emit_column_rows { emit_draw_column_row(bmp, width, clipped: true, see_through: see_through) } if width > 1
            end
            @emitter.place_label(done)
          end

          # The walk down the screen, one pass per row of the column that shows.
          def emit_column_rows
            @primitives.emit_row_loop(COLUMN_ROWS) do
              yield
              @emitter.emit(ASM.add_reg(COLUMN_POS, COLUMN_POS, COLUMN_STEP))
              @emitter.emit(ASM.add_imm(COLUMN_Y, COLUMN_Y, 1))
            end
          end

          # One row of the strip: work out which picture row we are on, read its colour, and
          # write it across. Every row this reaches is on the screen — that was settled before
          # the walk started.
          def emit_draw_column_row(bmp, width, clipped:, see_through:)
            skip = @emitter.gensym

            emit_read_column_pixel(bmp, skip, see_through)

            # ...to the screen at (x, y), and to the pixels beside it. Their addresses are a
            # fixed distance along from the first, so the row's address is built once.
            @emitter.emit_number(TMP, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(TMP, COLUMN_Y, TMP))
            @emitter.emit(ASM.add_reg(TMP, TMP, COLUMN_X))
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 1))
            @emitter.emit_number(SPARE, VRAM_START)
            @emitter.emit(ASM.add_reg(TMP, TMP, SPARE))
            width.times { |dx| emit_column_store(dx, clipped: clipped) }

            @emitter.place_label(skip)
          end

          # colour = picture[(pos >> 16) * width + slice], the slice already folded into
          # COLUMN_SRC. Leaves it in ACC, or jumps to +skip+ when the pixel is see-through.
          #
          # The row cannot run past the picture, so nothing holds it back. The step is the
          # picture's height shifted up over the row count, rounded down, and the last row
          # reaches at most one less than that count times it — which is strictly less than
          # the picture's height however the rounding falls.
          def emit_read_column_pixel(bmp, skip, see_through)
            @emitter.emit(ASM.lsr_imm(ACC, COLUMN_POS, COLUMN_FIXED))
            @emitter.emit_number(TMP, bmp.width * 2)
            @emitter.emit(ASM.mul(ACC, ACC, TMP))
            @emitter.emit(ASM.add_reg(ACC, COLUMN_SRC, ACC))
            @emitter.emit(ASM.load_halfword(ACC, ACC))

            # A see-through pixel carries a value no real color has, so it means "leave this
            # one alone" and nothing is written — which is what lets a scaled sprite in a
            # first-person view keep its shape instead of standing in a black box. A picture
            # whose walk lands only on pixels has nothing to ask (+see_through+ false).
            return unless see_through

            @emitter.emit_number(TMP, bmp.transparent)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
          end

          # One pixel of the strip. In the clipped copy of the rows its own column is tested,
          # since only part of the strip is on the screen.
          def emit_column_store(offset, clipped:)
            return @emitter.emit(ASM.store_halfword_offset(ACC, TMP, offset * 2)) unless clipped

            past = @emitter.gensym
            @emitter.emit(ASM.add_imm(SPARE, COLUMN_X, offset))
            @emitter.emit(ASM.cmp_imm(SPARE, @framebuffer.clip_left))
            @emitter.emit_branch(:bcond, past, cond: :lt)
            @emitter.emit(ASM.cmp_imm(SPARE, @framebuffer.clip_right))
            @emitter.emit_branch(:bcond, past, cond: :ge)
            @emitter.emit(ASM.store_halfword_offset(ACC, TMP, offset * 2))
            @emitter.place_label(past)
          end

          def emit_draw_rect_at(node)
            return @buffered.emit_draw_rect_at_buffered(node) if @lowering.mode == :buffered

            x_const = @primitives.const_int(node.x)
            y_const = @primitives.const_int(node.y)
            width = @primitives.const_int(node.w)
            height = @primitives.const_int(node.h)
            return if width && width < 1   # a rect with no width draws nothing
            return if height && height < 1 # ...or no height

            # Every edge settled while building: clip it here, in Ruby, once, and fire
            # the fill straight at plain addresses — nothing for the console to check.
            # A bar or column at a fixed place and size costs exactly what it always did.
            return emit_draw_rect_at_fixed(x_const, y_const, width, height, node.color) if x_const && y_const && width && height

            emit_draw_rect_at_computed(node, width, height)
          end

          # A rect whose x, y, width and height are all known while building.
          def emit_draw_rect_at_fixed(x, y, width, height, color)
            left = [x, @framebuffer.clip_left].max
            right = [x + width, @framebuffer.clip_right].min
            return if right <= left

            top = [y, @framebuffer.clip_top].max
            bottom = [y + height, @framebuffer.clip_bottom].min
            return if bottom <= top

            scratch = @framebuffer.emit_color_fill_word(color)
            control = @framebuffer.fill_control_for_column(nil, right - left)
            (top...bottom).each do |row|
              row_addr = VRAM_START + ((row * SCREEN_WIDTH) + left) * 2
              @framebuffer.emit_dma_fill_row(scratch, row_addr, control)
            end
          end

          # A rect with at least one edge the game works out as it runs, so the clip has
          # to happen at run time.
          #
          # x and width settle to one on-screen span before any row fires — a rect has
          # one x for its whole height, the same reason draw_column_at settles its
          # column once instead of testing it every row. Every row then checks its own
          # y against the area, because a run-time y or height means a run-time set of
          # rows survives: an unclipped row is what wrapped a rect onto its neighbor.
          def emit_draw_rect_at_computed(node, width, height)
            scratch = @framebuffer.emit_color_fill_word(node.color)

            x_reg = 2
            y_reg = 3
            rows_left = 6
            @framebuffer.eval_rect_position(node, x_reg: x_reg, y_reg: y_reg, rows_reg: rows_left,
                                                   width_reg: CONTROL_REG)

            skip = @emitter.gensym

            # right = x + width, unclipped, worked out before x itself is touched.
            if width
              @primitives.emit_add_const(ACC, x_reg, width, TMP)
            else
              @emitter.emit(ASM.add_reg(ACC, x_reg, CONTROL_REG)) # CONTROL_REG still holds the raw width here
            end

            # right := min(right, clip_right)
            keep_right = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, @framebuffer.clip_right))
            @emitter.emit_branch(:bcond, keep_right, cond: :le)
            @emitter.emit_number(ACC, @framebuffer.clip_right)
            @emitter.place_label(keep_right)

            # x_reg := max(x_reg, clip_left)
            keep_left = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(x_reg, @framebuffer.clip_left))
            @emitter.emit_branch(:bcond, keep_left, cond: :ge)
            @emitter.emit_number(x_reg, @framebuffer.clip_left)
            @emitter.place_label(keep_left)

            # width := right - x_reg. Nothing left of the row to draw at all bails the
            # whole rect, the same way a width of zero already did — a rect the game
            # shrank to nothing, or slid entirely off the area, draws nothing either way.
            @emitter.emit(ASM.sub_reg(TMP, ACC, x_reg))
            @emitter.emit(ASM.cmp_imm(TMP, 0))
            @emitter.emit_branch(:bcond, skip, cond: :le)
            @emitter.emit(ASM.mov_reg(CONTROL_REG, TMP))
            @emitter.emit_number(ACC, @framebuffer.dma_fill_control_halfwords(0))
            @emitter.emit(ASM.orr_reg(CONTROL_REG, CONTROL_REG, ACC)) # ...now it is a control word

            if height
              height.times { |dy| emit_mode3_rect_row(dy, x_reg, y_reg, scratch) }
            else
              @primitives.emit_row_loop(rows_left) do
                emit_mode3_rect_row(0, x_reg, y_reg, scratch)
                @emitter.emit(ASM.add_imm(y_reg, y_reg, 1)) # ...and on to the next row down
              end
            end
            @emitter.place_label(skip)
          end

          # The register a computed width, and then the fill's control word built from
          # it, lives in for the whole rect.
          CONTROL_REG = 7

          # One row of a run-time-positioned rect: skip it outright if its y falls
          # outside the area (a row above or below it draws nothing, not a row wrapped
          # onto its neighbor), else work out where it lands in video memory and fire
          # the fill. +dy+ is how far below the rect's y this row is; the fill's control
          # word always lives in CONTROL_REG by the time this runs.
          def emit_mode3_rect_row(dy, x_reg, y_reg, scratch)
            row_skip = @emitter.gensym

            # r4 = y + dy, checked against the area before it becomes an address.
            if dy.zero?
              @emitter.emit(ASM.mov_reg(4, y_reg))
            else
              @emitter.emit(ASM.add_imm(4, y_reg, dy))
            end
            @emitter.emit(ASM.cmp_imm(4, @framebuffer.clip_top))
            @emitter.emit_branch(:bcond, row_skip, cond: :lt)
            @emitter.emit(ASM.cmp_imm(4, @framebuffer.clip_bottom))
            @emitter.emit_branch(:bcond, row_skip, cond: :ge)

            @emitter.emit_number(5, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(4, 5, 4))           # r4 = width * (y + dy)
            @emitter.emit(ASM.add_reg(4, 4, x_reg))   # + x
            @emitter.emit(ASM.lsl_imm(4, 4, 1))       # * 2 bytes per pixel
            @emitter.emit_number(5, VRAM_START)
            @emitter.emit(ASM.add_reg(4, 4, 5))       # + VRAM base

            # To the address just worked out.
            @primitives.emit_start_copy_engine(from: scratch, to: Primitives::InRegister.new(4), control: Primitives::InRegister.new(CONTROL_REG))

            @emitter.place_label(row_skip)
          end

          # Draw a defined bitmap at a runtime (x, y). An opaque bitmap streams from
          # ROM by DMA; one with transparency is drawn pixel-by-pixel so its
          # transparent pixels can be skipped. Either way the draw is clipped to the
          # screen at run time — a bitmap pushed partway off an edge draws only its
          # visible part, with nothing written past the framebuffer.
          def emit_blit(node)
            bmp = @layout.bitmaps.fetch(node.name) do
              raise LoweringError, "blit of undefined image #{node.name.inspect}"
            end
            emit_blit_of(node, bmp)
          end

          def emit_blit_of(node, bmp)
            return @buffered.emit_blit_buffered(node, bmp) if @lowering.mode == :buffered

            bmp.transparent ? emit_blit_transparent(node, bmp) : emit_blit_opaque(node, bmp)
          end

          # Opaque bitmap: stream each row straight from the cartridge into VRAM by
          # DMA — a run-time-positioned rectangle copy from a ROM buffer onto the
          # screen. The shared row engine below does the clipping.
          def emit_blit_opaque(node, bmp)
            emit_rect_row_dma(node.x, node.y, bmp.width, bmp.height, node.name, vram: :dest)
          end

          # Draw a tiled background. In tile mode the console draws the whole layer
          # from data in video memory, so it's uploaded once (emit_background_hardware).
          # In bitmap mode there's no tile hardware, so each cell is stamped with the
          # blit path instead — correct, just a copy per cell.
          def emit_background(node)
            return emit_background_blits(node) unless @layout.tiled
            # A background a scene owns goes up as that scene takes over (see
            # #emit_scene_scenery and IR::SceneHandover), not where it is written.
            return if scene_handover.on_arrival?(node)
            # ...and one in a routine no run calls is on no screen (Stacking.scenery_reached): it
            # has no layer, and its line never runs.
            return unless @layout.screen.declared_background(node)

            @background_drawing.emit_background_hardware(node)
            emit_enable_late_layer(node)
            emit_bar_beside(node)
          end

          BAR_SHOWN_EARLY = :__bar_shown_early # Note that the bar shown early is up

          # A status bar shown before its own line runs (IR::SceneHandover#bar_shown_early) goes up beside every
          # background put up until it has gone up once, as Backends::SceneryWrites#emit_bar_beside puts it up on
          # the other cartridges, which the Advance's lowering does not mix in: the bar's own line notes it is up
          # (BAR_SHOWN_EARLY, cleared as the backgrounds' pictures go in, BackgroundDrawing#emit_boot_backgrounds,
          # and set again as a screen's change puts the bar back, #emit_always_up), and any other background puts
          # it up unless the note is set. +node+ is the background put up, or nil for a scene's own scenery as it
          # takes over.
          def emit_bar_beside(node)
            bar = scene_handover.bar_shown_early
            return unless bar
            return @primitives.store_word_immediate(1, @primitives.var_addr(BAR_SHOWN_EARLY)) if node.equal?(bar)
            return if node&.bar?

            up = @emitter.gensym
            @primitives.load_var(ACC, BAR_SHOWN_EARLY)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, up, cond: :ne)
            emit_background(bar)
            @emitter.place_label(up)
          end

          # Bitmap-mode background: no tile hardware, so stamp each non-empty cell with
          # the shared blit path — a positioned copy of the tile image onto the screen. A tile's
          # see-through pixels are the tile's own rule, which a blit does not know, so they are
          # marked first (Image#with_tile_see_through_marked).
          def emit_background_blits(node)
            tiles = node.tiles
            tile_w = node.tile_w
            tile_h = node.tile_h
            node.map.each_with_index do |row, r|
              row.each_with_index do |index, c|
                next if index.nil?

                picture = @layout.bitmaps.fetch(tiles[index]) do
                  raise LoweringError, "blit of undefined image #{tiles[index].inspect}"
                end
                stamp = Build.blit(tiles[index], c * tile_w, r * tile_h)
                marked = picture.with_tile_see_through_marked
                if @lowering.mode == :buffered && @buffered.stamp_by_pairs?(stamp, marked)
                  @buffered.emit_stamp_tile_buffered(stamp, marked)
                else
                  emit_blit_of(stamp, marked)
                end
              end
            end
          end

          # Draw whichever pose a run-time index selects. The image can't be chosen at
          # build time, so this expands to one guarded blit per pose — exactly one of
          # which draws — the same shape as a run-time digit. Each guard reuses the
          # shared blit path, so a pose honors clipping and transparency like any image.
          def emit_blit_pose(node)
            node.poses.each_with_index do |name, k|
              @lowering.statement(Build.if_(Build.binop(:==, node.index, Build.int(k)),
                                       Build.blit(name, node.x, node.y)))
            end
          end

          def backing_region_unsupported_in_buffered!
            raise LoweringError,
                  "A sprite's save and restore cannot run on the tear-free screen (`tear_free: true`). Its " \
                  "backing store holds direct colors, and that screen stores colors as color-table indices. " \
                  "To use sprites, use the direct-color screen: drop `tear_free:`."
          end

          # Save the screen patch under a moving object into its RAM backing store:
          # read the screen (VRAM) INTO the buffer. Same row engine as a blit, run in
          # the other direction.
          def emit_save_region(node)
            backing_region_unsupported_in_buffered! if @lowering.mode == :buffered
            info = backing_info(node.buffer)
            emit_rect_row_dma(node.x, node.y, info.width, info.height, info.base, vram: :src)
          end

          # Put a saved patch back on the screen: stream the RAM buffer INTO VRAM, just
          # like a blit but sourced from the backing store instead of a ROM image.
          def emit_restore_region(node)
            backing_region_unsupported_in_buffered! if @lowering.mode == :buffered
            info = backing_info(node.buffer)
            emit_rect_row_dma(node.x, node.y, info.width, info.height, info.base, vram: :dest)
          end

          # Copy the rows of a run-time-positioned width×height rectangle between the
          # screen (VRAM) and a row-major linear buffer, one 16-bit DMA per row,
          # clipping each row to the screen. This is the shared engine under blitting
          # an image and under a sprite's save/restore of what it covers.
          #
          # +vram:+ picks the direction. `:dest` streams the buffer onto the screen —
          # a blit, or a sprite putting back the pixels it had covered. `:src` reads
          # the screen into the buffer — a sprite capturing what it is about to cover.
          # Everything else about a row is identical either way, which is the whole
          # reason this is one method.
          #
          # +base+ names where the linear buffer lives: a Symbol names a ROM blob (its
          # address is patched in once the data region is placed); an Integer is a
          # fixed address in RAM (a sprite's reserved backing store). The buffer is
          # addressed row-major (row*width + column), so a clipped row drops the same
          # columns on both ends — which is exactly what lets a capture and a later
          # restore at the same spot round-trip a sprite hanging off an edge.
          #
          # Clipping is at run time because x/y are runtime values. A row off the top
          # or bottom is skipped whole; a row crossing a side edge is trimmed to its
          # on-screen span (the buffer end skips the clipped columns, the screen end
          # starts at the first visible column, the count is just the visible width) —
          # without the trim a row past the right edge would wrap onto the next line.
          #
          # r6 holds the buffer base and r7/r8 hold x/y across the whole copy; the
          # rest (r2–r5, r9–r11) are per-row scratch.
          #
          # ## One row, clipped
          #
          #   screen row:    0 ..................................... shown_columns
          #   buffer row:        [x ............ x+width)          (here it hangs off the left)
          #   copied:            [visible_left .. visible_right)
          #                      |_ visible_width _|
          #
          # A row is a start in the buffer (r5), a start on the screen (r3) and a count (r4).
          # Writing those three into the copy engine's registers, the count last with its enable
          # bit set, starts the copy; the processor waits until it is done (GBATEK, "DMA
          # Transfers").
          def emit_rect_row_dma(x_node, y_node, width, height, base, vram:)
            buf_reg = 6
            x_reg = 7
            y_reg = 8
            @lowering.value(x_node)
            @emitter.emit(ASM.mov_reg(x_reg, ACC))
            @lowering.value(y_node)
            @emitter.emit(ASM.mov_reg(y_reg, ACC))
            case base
            when Symbol  then @emitter.emit_load_data_address(buf_reg, base)    # r6 = ROM blob address
            when Integer then @emitter.emit_number(buf_reg, base)  # r6 = RAM buffer address
            else raise LoweringError, "rect DMA base must be a blob name or a RAM address, got #{base.inspect}"
            end

            height.times do |row|
              skip = @emitter.gensym

              # screen_y = y + row; drop the whole row if it's above or below screen.
              @primitives.emit_add_const(9, y_reg, row, 2)          # r9 = screen_y (r2 is the helper's scratch)
              @emitter.emit(ASM.cmp_imm(9, 0))
              @emitter.emit_branch(:bcond, skip, cond: :lt)
              @emitter.emit(ASM.cmp_imm(9, @layout.shown_rows))
              @emitter.emit_branch(:bcond, skip, cond: :ge)

              # visible_left = max(x, 0)  -> r10
              @emitter.emit(ASM.mov_reg(10, x_reg))
              @emitter.emit(ASM.cmp_imm(x_reg, 0))
              keep_left = @emitter.gensym
              @emitter.emit_branch(:bcond, keep_left, cond: :ge)
              @emitter.emit_number(10, 0)
              @emitter.place_label(keep_left)

              # visible_right = min(x + width, the shown width)  -> r11
              @primitives.emit_add_const(11, x_reg, width, 2)
              @emitter.emit(ASM.cmp_imm(11, @layout.shown_columns))
              keep_right = @emitter.gensym
              @emitter.emit_branch(:bcond, keep_right, cond: :le)
              @emitter.emit_number(11, @layout.shown_columns)
              @emitter.place_label(keep_right)

              # visible_width = visible_right - visible_left  -> r4; if <= 0 the row
              # is entirely off to one side, so skip it.
              @emitter.emit(ASM.sub_reg(4, 11, 10))
              @emitter.emit(ASM.cmp_imm(4, 0))
              @emitter.emit_branch(:bcond, skip, cond: :le)

              # buffer span address = base + (row*width + left_skip) * 2  -> r5
              @emitter.emit(ASM.sub_reg(5, 10, x_reg))           # left_skip = visible_left - x
              @primitives.emit_add_const(5, 5, row * width, 2)      # + this row's start in the buffer
              @emitter.emit(ASM.lsl_imm(5, 5, 1))                # * 2 bytes/pixel
              @emitter.emit(ASM.add_reg(5, buf_reg, 5))

              # screen span address = VRAM + (screen_y*SCREEN_WIDTH + visible_left) * 2 -> r3
              @emitter.emit_number(2, SCREEN_WIDTH)
              @emitter.emit(ASM.mul(3, 9, 2))                    # r3 = screen_y * width
              @emitter.emit(ASM.add_reg(3, 3, 10))               # + visible_left
              @emitter.emit(ASM.lsl_imm(3, 3, 1))
              @emitter.emit_number(2, VRAM_START)
              @emitter.emit(ASM.add_reg(3, 3, 2))

              # control = visible_width | DMA_ENABLE (16-bit, source+dest increment). The low
              # bits of the control word are the count of halfwords and the enable bit is what
              # makes the engine start once the word is written.
              @emitter.emit(ASM.orr_imm(4, 4, DMA_ENABLE))

              # Direction decides which span is the source: :dest sends the buffer
              # (r5) to the screen (r3); :src reads the screen (r3) into the buffer (r5).
              sad, dad = vram == :dest ? [5, 3] : [3, 5]
              @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(sad), to: Primitives::InRegister.new(dad), control: Primitives::InRegister.new(4))

              @emitter.place_label(skip)
            end
          end

          # Transparent bitmap: the art is known at build time, so unroll it. Emit a
          # store only for each NON-transparent pixel — with its color baked in, at
          # the run-time-computed destination — and simply skip transparent ones, so
          # the background shows through.
          #
          # Each store is guarded by a run-time screen-bounds check (x/y are runtime
          # values), so a lit pixel pushed off an edge is dropped rather than written
          # off the framebuffer — the same per-pixel clipping the interpreter does.
          # The row's off-top/off-bottom test is hoisted out of the pixel loop.
          #
          # r2/r3 hold x/y across the blit; r4/r6 are the per-row screen_y and row
          # base; r7/r8 are per-pixel scratch.
          #
          # ## What is written
          #
          # The picture's art is read now, while the game is built, so none of it is read as the
          # game runs. For each row there is a guard on the row, then for each lit pixel a guard on
          # its column and a store of its colour:
          #
          #   row 0:  [row guard] [px 0: guard, store] [px 3: guard, store] ...   (px 1, 2 see-through)
          #   row 1:  [row guard] ...
          #
          # A store to video memory is the pixel itself, so a see-through pixel costs nothing: no
          # code is written for it and the screen keeps what it showed.
          def emit_blit_transparent(node, bmp)
            width = bmp.width
            colors = bmp.pixels.unpack("v*")

            x_reg = 2
            y_reg = 3
            @lowering.value(node.x)
            @emitter.emit(ASM.mov_reg(x_reg, ACC))
            @lowering.value(node.y)
            @emitter.emit(ASM.mov_reg(y_reg, ACC))

            bmp.height.times do |row|
              lit = width.times.reject { |col| colors[(row * width) + col] == bmp.transparent }
              next if lit.empty? # a fully transparent row draws nothing

              skip_row = @emitter.gensym
              @primitives.emit_add_const(4, y_reg, row, 5)          # r4 = screen_y
              @emitter.emit(ASM.cmp_imm(4, 0))
              @emitter.emit_branch(:bcond, skip_row, cond: :lt)
              @emitter.emit(ASM.cmp_imm(4, @layout.shown_rows))
              @emitter.emit_branch(:bcond, skip_row, cond: :ge)
              @emitter.emit_number(5, SCREEN_WIDTH)
              @emitter.emit(ASM.mul(6, 4, 5))                    # r6 = screen_y * width (row base, in pixels)

              lit.each do |col|
                color = colors[(row * width) + col]
                skip_px = @emitter.gensym

                @primitives.emit_add_const(7, x_reg, col, 8)        # r7 = screen_x
                @emitter.emit(ASM.cmp_imm(7, 0))
                @emitter.emit_branch(:bcond, skip_px, cond: :lt)
                @emitter.emit(ASM.cmp_imm(7, @layout.shown_columns))
                @emitter.emit_branch(:bcond, skip_px, cond: :ge)

                @emitter.emit(ASM.add_reg(7, 6, 7))              # r7 = row_base + screen_x (pixels from the start)
                @emitter.emit(ASM.lsl_imm(7, 7, 1))              # * 2 bytes/pixel
                @emitter.emit_number(8, VRAM_START)
                @emitter.emit(ASM.add_reg(7, 7, 8))              # VRAM address
                @emitter.emit_number(8, color)
                @emitter.emit(ASM.store_halfword(8, 7))          # the store is the pixel

                @emitter.place_label(skip_px)
              end
              @emitter.place_label(skip_row)
            end
          end

          # Draw a line of text with the built-in bitmap font. The color loads once,
          # then every set pixel of every glyph is a single halfword store at its
          # fixed VRAM address; off-screen pixels are dropped. Positions are constant.
          def emit_draw_text(node)
            return @buffered.emit_draw_text_buffered(node) if @lowering.mode == :buffered

            x, y = @primitives.constant_ints!(node, x: node.x, y: node.y)
            @framebuffer.emit_text_color(node, ACC) { |color| Graphics::Color.resolve(color) }

            points = @framebuffer.text_points(node, x, y)
            return emit_text_points_call(points) if points.length >= Framebuffer::TEXT_POINTS_LINE

            points.each do |point|
              @emitter.emit_number(TMP, VRAM_START + (point * 2))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
            end
          end

          # A line in a table: the colour already in r0, then the table and how many it holds.
          def emit_text_points_call(points)
            @emitter.emit_load_data_address(TMP, @framebuffer.text_points_blob(points))
            @emitter.emit_number(SPARE, points.length)
            @text_points_used = true
            emit_call_cold_routine(TEXT_POINTS)
          end

          TEXT_POINTS = Messages::MadeNames.make(:text_points_routine)

          # The routine that stamps a table of pixels: r0 the colour, r1 the table, r2 how many.
          # Only ever entered by a call, and made only for a game with such a line.
          def emit_text_points_routine
            return unless @text_points_used

            pixel = @emitter.gensym
            @emitter.emit(ASM.loop_forever) # fall-through guard
            @emitter.place_label(TEXT_POINTS)
            @emitter.emit_number(12, VRAM_START)
            @emitter.place_label(pixel)
            @emitter.emit(ASM.load_halfword(3, 1))
            @emitter.emit(ASM.add_imm(1, 1, 2))
            @emitter.emit(ASM.lsl_imm(3, 3, 1))              # two bytes a pixel
            @emitter.emit(ASM.add_reg(3, 3, 12))
            @emitter.emit(ASM.store_halfword(0, 3))
            @emitter.emit(ASM.subs_imm(2, 2, 1))
            @emitter.emit_branch(:bcond, pixel, cond: :ne)
            @emitter.emit(ASM.return)
            @emitter.place_label(DerivedNames.routine_end(TEXT_POINTS))
          end
          # Draw the run-time digit held in +value+ (0..9). A font can't be indexed by a
          # run-time value the way an array is, so there are two ways to render it, and
          # the cheaper one is picked here.
          #
          # Data-driven (used for a column that sits fully on-screen with a font no wider
          # than a byte): the ten digit glyphs are embedded once as ROM data, and at run
          # time a small loop looks up the chosen glyph and stamps its set pixels — the
          # same idea as blitting an image. It costs one shared loop plus a few dozen
          # bytes of glyph data, instead of baking every pixel of all ten digits into the
          # code. Each screen mode plots a pixel differently — direct color writes a
          # color, the tear-free screen splices a palette index — but the glyph-walking
          # loop is the same one (emit_digit_glyph_loop).
          #
          # Fan-out (the fallback — a column crossing a screen edge, or a font with wide,
          # ragged, or missing digits): expand to ten mutually exclusive guards, one per
          # digit, exactly one of which draws. Each is a draw_text that clips per pixel
          # and honors the screen mode.
          def emit_draw_digit(node)
            font = node.fonts.get(node.font)
            x = @primitives.const_int(node.x)
            y = @primitives.const_int(node.y)
            digit_w = @framebuffer.uniform_digit_width(font)
            if x && y && digit_w && @framebuffer.digit_cell_on_screen?(x, y, digit_w, font.height)
              if @lowering.mode == :buffered
                @buffered.emit_draw_digit_data_buffered(node, font, digit_w, x, y)
              else
                emit_draw_digit_data(node, font, digit_w, x, y)
              end
            else
              emit_draw_digit_unrolled(node)
            end
          end

          # The fan-out fallback: ten guarded draw_texts, exactly one of which matches
          # the value and draws. Built as a sub-tree and emitted through the shared
          # statement paths, so it honors the current screen mode via draw_text.
          #
          # Each guard is hung from the digit it stands for, though it is never one of its
          # children: a draw_text finds its font by climbing to the top of its tree, and a
          # piece standing on its own would find only the fonts that ship, never the game's.
          def emit_draw_digit_unrolled(node)
            10.times do |k|
              guard = Build.if_(Build.binop(:==, node.value, Build.int(k)),
                                Build.draw_text(k.to_s, node.x, node.y, node.color, font: node.font))
              guard.parent = node
              @lowering.statement(guard)
            end
          end

          # Render one run-time digit from an embedded glyph table (direct color): call
          # the shared glyph-walking routine for this font (see #emit_digit_routines)
          # rather than laying its loop out again at every digit place. The digit is
          # already in r0 from evaluating node.value; x, y and color follow as plain
          # arguments in r1-r3, the same way a func's own arguments would (except a
          # func takes none — this is the one internal routine that does).
          def emit_draw_digit_data(node, font, width, x, y)
            color = Graphics::Color.resolve(node.color)
            @lowering.value(node.value)             # r0 = the digit (0..9)
            @emitter.emit_number(1, x)
            @emitter.emit_number(2, y)
            @emitter.emit_number(3, color)
            emit_call_cold_routine(digit_routine_label(node.font, font, width))
          end

          # The shared routine's label for a font, reserved the first time a digit in
          # that font is drawn and emitted once, later, by #emit_digit_routines. Every
          # other draw_number/draw_digit in the same font reuses the same label — this
          # is the memoization that turns "one copy of the loop per call site" into
          # "one copy of the loop per font actually used this way".
          def digit_routine_label(font_name, font, width)
            @digit_routines ||= {}
            @digit_routines[font_name] ||= begin
              @pending_digit_routines ||= []
              @pending_digit_routines << [font_name, font, width]
              Messages::MadeNames.make(:digit_routine, font: font_name)
            end
          end

          # Emit every shared digit routine this program actually used, once each, after
          # the program's own code (see GBA#lower) — a fall-through guard, a label, a
          # body, a return, the same shape Functions#emit_one_function gives a func,
          # because like a func this is only ever reached by a call.
          #
          # x, y and the fill color arrive as arguments (r1, r2, r3) rather than being
          # baked into the routine, which is what lets one routine serve every call
          # site. They move into r10-r12 first, because the glyph table lookup that
          # follows needs r1-r3 back as scratch.
          def emit_digit_routines
            return unless @pending_digit_routines

            @pending_digit_routines.each do |font_name, font, width|
              @emitter.emit(ASM.loop_forever) # fall-through guard: only ever entered by the call above
              @emitter.place_label(Messages::MadeNames.make(:digit_routine, font: font_name))
              @emitter.emit(ASM.push(14))
              @emitter.emit(ASM.mov_reg(10, 1)) # r10 = x, held across the routine
              @emitter.emit(ASM.mov_reg(11, 2)) # r11 = y
              @emitter.emit(ASM.mov_reg(12, 3)) # r12 = the fill color
              @framebuffer.emit_digit_glyph_loop(font_name, font, width) do |phase|
                case phase
                when :hold then @emitter.emit(ASM.mov_reg(8, 12)) # r8 = the fill color, held
                when :plot then emit_plot_digit_pixel(10, 11)
                end
              end
              @emitter.emit(ASM.pop(15))
              # Where it ends, so a profile of the finished game can say how much of a frame
              # went into drawing digits. A routine the lowering makes has no other record of
              # its span — func_ranges only knows routines somebody wrote.
              @emitter.place_label(DerivedNames.routine_end(Messages::MadeNames.make(:digit_routine, font: font_name)))
            end
          end

          # Stamp the current glyph pixel: screen = VRAM + ((y+row)*W + (x+col))*2, in
          # the held color (r8). x_reg/y_reg hold the cell's origin — arguments to the
          # shared routine, not constants baked in here — and r5/r4 are the live
          # row/col. Uses r0–r3 as scratch and leaves the loop registers alone.
          def emit_plot_digit_pixel(x_reg, y_reg)
            @emitter.emit(ASM.add_reg(0, y_reg, 5))        # r0 = screen_y = y + row
            @emitter.emit_number(1, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(2, 0, 1))                # r2 = screen_y * width
            @emitter.emit(ASM.add_reg(0, x_reg, 4))        # r0 = screen_x = x + col
            @emitter.emit(ASM.add_reg(2, 2, 0))            # r2 = screen_y*width + screen_x
            @emitter.emit(ASM.lsl_imm(2, 2, 1))            # * 2 bytes per pixel
            @emitter.emit_number(1, VRAM_START)
            @emitter.emit(ASM.add_reg(2, 2, 1))            # r2 = the pixel's VRAM address
            @emitter.emit(ASM.store_halfword(8, 2))        # write the color
          end

        end
      end
    end
  end
end
