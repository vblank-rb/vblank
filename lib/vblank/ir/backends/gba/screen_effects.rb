# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # What happens to the whole picture rather than to anything in it: moving the window
        # onto it (the camera), fading it toward black or white, and tinting it toward a
        # colour. None of these redraws anything. Each tells the display to show what is
        # already there differently — slid, darkened, mixed — or, where the display cannot,
        # moves the colour table instead (see PaletteTint).
        #
        # The fade and the tint share their arithmetic with PaletteTint and LayerBlend, which
        # reach it through the backend (#fade_steps_value and friends are public for that reason).
        class ScreenEffects
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[camera fade tint pixelate].freeze

          def emit_statement(node)
            case node.kind
            when :camera then emit_camera(node)
            when :fade then emit_fade(node)
            when :tint then emit_tint(node)
            when :pixelate then emit_pixelate(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware

          def initialize(emitter:, primitives:, lowering:, palette_tint:, layer_blend:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @palette_tint = palette_tint
            @layer_blend = layer_blend
            @layout = nil
          end

          attr_writer :layout

          def placed_fade = @layout.screen.placed_fade

          # Move the visible window over the whole picture.
          #
          # The bitmap screen is drawn by the console's one scalable layer, and that
          # layer fetches its pixels starting from a reference point. Write a new
          # reference point and the whole picture slides, with no redrawing at all —
          # which is what makes a screen shake nearly free. The game keeps drawing
          # exactly what it drew before; only the window onto it moves.
          #
          # Two details the hardware needs. The reference point counts in a fixed-point
          # number with 8 fraction bits, so a whole number of pixels is that number
          # shifted up by 8. And the same layer carries a scale/rotate matrix that the
          # console powers on holding zeroes, which would shrink the picture away to
          # nothing; setting it to no-scale-no-rotate here keeps the pan a plain slide.
          # It is set beside the offset rather than at boot so a program that never
          # moves the camera emits not one extra byte.
          def emit_camera(node)
            raise LoweringError, CAMERA_NEEDS_BITMAP if @layout.modes.default_mode == :tiled

            # The window over the picture steps by a whole pixel of it for each pixel it shows, or by half
            # of one in a game of big pixels (Drawing#emit_bigger_pixels), where it is the game's pixels
            # the offsets count.
            step = FIXED_ONE / @layout.pixel_size
            @emitter.write_reg16(REG_BG2PA, step)
            @emitter.write_reg16(REG_BG2PB, 0)
            @emitter.write_reg16(REG_BG2PC, 0)
            @emitter.write_reg16(REG_BG2PD, step)
            emit_camera_axis(node.x, REG_BG2X, :x)
            emit_camera_axis(node.y, REG_BG2Y, :y)
            @primitives.store_word_immediate(1, @primitives.var_addr(CAMERA_MOVED)) if @layout.camera_at_flip
          end

          # A game whose every screen is tiled never reaches here: the builder moves its
          # backgrounds and sprites instead (Builder::Drawing#finalize_tiled_camera). What is left
          # is a game whose first screen is tiled and that paints a screen too.
          CAMERA_NEEDS_BITMAP =
            "This game moves the camera (`camera` or `shake_screen`). Its first screen is tiled, and " \
            "it has a painted (bitmap) screen too. The camera can move a game whose screens are all " \
            "tiled, or a game whose first screen is painted. To fix this, make every screen tiled, " \
            "or put the painted screen first."

          # A game's screen in a border starts at its corner, so the corner is taken off too (see
          # BorderSprites).
          #
          # On a tear-free screen the picture the pass draws is shown at the next page flip, and the
          # page on show now is the last pass's. A camera written into the display at once would move
          # that older picture a pass early, so there the place is kept until the flip shows the page
          # it belongs to (#emit_camera_shown_with_page). It is kept on a screen drawn straight to the
          # display too, so a tear-free screen that takes over later starts from where the camera is.
          def emit_camera_axis(value, reg, way)
            @lowering.value(value)                   # r0 = the offset in whole pixels
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 8))      # ...into the 8-fraction-bit format
            @layout.border&.emit_corner_off_reference(way)
            @primitives.store_var(ACC, CAMERA_AT_FLIP.fetch(reg)) if @layout.camera_at_flip
            @primitives.store_word_acc(reg) unless @lowering.mode == :buffered
          end

          # Where the camera stands for the page the flip shows next, by the register it goes to.
          CAMERA_AT_FLIP = { REG_BG2X => :__camera_x_at_flip, REG_BG2Y => :__camera_y_at_flip }.freeze
          # 1 once the game has moved the camera: until then the display keeps what was set up for it.
          CAMERA_MOVED = :__camera_moved

          # The camera's place, written into the display as the page drawn with it is shown, once the
          # game has placed it.
          def emit_camera_shown_with_page
            skip = @emitter.gensym
            @primitives.load_var(ACC, CAMERA_MOVED)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            CAMERA_AT_FLIP.each do |reg, var|
              @primitives.load_var(ACC, var)
              @primitives.store_word_acc(reg)
            end
            @emitter.place_label(skip)
          end

          # Blend the whole picture toward black or white.
          #
          # The console can do this as it draws: one register sets which layers to
          # blend and which way, another sets how far. Nothing is redrawn and no pixel
          # in memory changes, so a fade costs the same whatever is on screen and the
          # picture is still all there when it lifts. Every layer and the backdrop are
          # blended, so this works the same on a bitmap screen and a tiled one.
          #
          # "How far" counts in sixteenths, while the DSL talks in percent, so the
          # amount is scaled. A fixed amount is worked out here and written as a plain
          # number; an amount the game computes is scaled at run time, which is a
          # multiply and a divide once per call — nothing next to a frame.
          def emit_fade(node)
            if @layout.fading.palette_walk?(node)
              return emit_walked_fade_by_screen_up(node) if @palette_tint.tint_crosses_screens?

              return emit_palette_fade(node)
            end
            # A fade takes the tint's place, so no tint is left to put back on a change of screen.
            @palette_tint.emit_clear_remembered_tint if @palette_tint.tint_crosses_screens?

            # On a screen drawn through a color table the two effects are separate pieces
            # of hardware, so nothing puts a tint away by itself. The display still holds
            # one whole-picture effect at a time — that is the rule the DSL states and the
            # interpreter models — so a fade puts the colors back. Only a program that
            # tints such a screen emits this, and the check inside is one compare.
            if @palette_tint.moves_color_table? && @palette_tint.palette_screen?(node)
              @palette_tint.emit_lift_palette_tint(@layout.modes.mode_at(node))
            end
            return emit_fade_beside_see_through(node) if @layer_blend.see_through?

            emit_fade_registers(node)
          end

          # A fade that moves the colors rather than asking the display to blend — which
          # is how the games on this console fade, and the only way a see-through layer
          # survives one (IR::Fading says which fades those are and why).
          #
          # Moving every entry of the color table a fraction of the way to black and
          # moving the finished picture there come to the same picture, so this is the
          # tint walk with black or white as the color — rounded the way the display's own
          # fade rounds, so a fade in shows the picture on the same frame either way (see
          # PaletteTint::DARKEN). The blend registers are not written for this fade, so the
          # layer keeps the setup it was given at boot and there is nothing to hand back when
          # it lifts.
          #
          # What it may have to hand back is another fade's. The display holds one fade at a
          # time, so this one takes the place of whatever fade was in force — and in a game
          # with a see-through layer that can be a fade the display itself was doing: one
          # placed in the stack, or one left on from a painted screen that has no colors to
          # walk. That fade holds the blend the layer needs, and nothing but this statement
          # is going to lift it (see LayerBlend#emit_blend_back_from_display_fade).
          def emit_palette_fade(node, mode: @layout.modes.mode_at(node))
            @layer_blend.emit_blend_back_from_display_fade
            toward = node.toward == :black ? PaletteTint::DARKEN : Graphics::Color.resolve(node.toward)
            @palette_tint.emit_palette_tint(color: toward,
                                            amount: node.amount,
                                            fraction_bits: node.fraction_bits,
                                            mode: mode)
          end

          # A fade that walks the colors, in a game with more than one screen, is done the way
          # the screen up now does it, as a tint is (see #emit_tint_by_screen_up): a flash runs
          # from a routine of its own every frame, whichever scene is up. The plain bitmap
          # screen has no colors to walk, so there the display fades it, in sixteenths; every
          # other screen walks its tables. And it is kept, like a tint, so the next screen to
          # take over puts it back its own way (see #emit_kept_tint_on_entry).
          def emit_walked_fade_by_screen_up(node)
            toward = walked_fade_color(node)
            @palette_tint.emit_remember_tint(toward, node.amount, node.fraction_bits)
            emit_for_each_screen_kind do |mode|
              mode == IR::Modes::DIRECT ? emit_walked_fade_by_display : emit_palette_fade(node, mode: mode)
            end
          end

          # The color a walked fade is kept as: black's rounding marker, or white with the bit
          # that tells it from a tint toward white.
          def walked_fade_color(node)
            node.toward == :black ? PaletteTint::DARKEN : Graphics::Color.resolve(:white) | PaletteTint::BRIGHTEN
          end

          # The fade just kept in TINT_ASKED, done by the display on the plain bitmap screen:
          # toward black or white by the marker, as far as the walk's steps come to in
          # the display's sixteenths. A fade of nothing leaves the effect off rather than a fade
          # of nothing on, which is what a screen with a see-through layer looks for on arrival.
          def emit_walked_fade_by_display
            @primitives.load_var(KEPT, PaletteTint::TINT_ASKED)
            emit_display_fade_from_kept
          end

          # KEPT holds a kept fade (its color is DARKEN or carries BRIGHTEN): tell the display.
          def emit_display_fade_from_kept
            off = @emitter.gensym
            brighten = @emitter.gensym
            done = @emitter.gensym
            @palette_tint.emit_state_steps_in_sixteenths(KEPT) # a walk's steps, in the display's sixteenths
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, off, cond: :eq)
            @primitives.store_halfword_acc(REG_BLDY)
            emit_whole_screen_window
            @emitter.emit(ASM.lsr_imm(ACC, KEPT, @palette_tint.state_shift))
            @emitter.emit(ASM.tst_imm(ACC, PaletteTint::DARKEN))
            @emitter.emit_branch(:bcond, brighten, cond: :eq)
            @emitter.write_reg16(REG_BLDCNT, BLD_DARKEN | placed_fade.blend_target_bits(nil))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(brighten)
            @emitter.write_reg16(REG_BLDCNT, BLD_BRIGHTEN | placed_fade.blend_target_bits(nil))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(off)
            @emitter.write_reg16(REG_BLDCNT, 0)
            @emitter.place_label(done)
          end

          # Which layers the fade reaches and which way, then how far.
          def emit_fade_registers(node)
            emit_fade_window(node.reaches, node.area) if @layout.fading.rectangle_fades?
            emit_fade_control(node)

            if (steps = constant_fade_steps(node))
              @emitter.write_reg16(REG_BLDY, steps)
            else
              @lowering.value(display_steps_value(node))
              @primitives.store_halfword_acc(REG_BLDY)
            end
          end

          # A fade held to a rectangle is the display's own fade with its first window switched
          # on. The window is a rectangle the display is told about, and two registers set what
          # happens inside it and outside: which layers show (all of them, both sides, always
          # here) and whether the color effect — the darkening a fade is — applies. So holding a
          # fade inside a rectangle is the effect switched on inside and off outside, and
          # `outside:` is the other way round.
          #
          # The window is switched on for the whole of a game that holds a fade anywhere (see
          # Drawing#display_window_bits), so every fade in it sets where it reaches, a fade over
          # the whole screen included: the effect on both sides. The last fade set is the one
          # in force, as it always is. Four register writes, every one of a number settled at
          # build time.
          #
          # Right and bottom are one past the last column and row the window covers, which is how
          # the display counts them. The rectangle was clipped to the screen as the program was
          # built, so the display is never handed an edge past it. +reaches+ nil is the whole
          # screen, and then the rectangle does not matter and nothing is written for it.
          def emit_fade_window(reaches, area)
            # The window's edges are the console's pixels, and the game gave its own: each is shown
            # pixel_size of them across and down in a game of big pixels.
            edges = reaches ? area.map { |edge| edge * @layout.pixel_size } : nil
            @emitter.write_reg16(REG_WIN0H, edges ? (edges[0] << 8) | edges[2] : 0)
            @emitter.write_reg16(REG_WIN0V, edges ? (edges[1] << 8) | edges[3] : 0)
            inside, outside = fade_window_switches(reaches)
            @emitter.write_reg16(REG_WININ, inside)
            @emitter.write_reg16(REG_WINOUT, outside)
          end

          # What the window's two regions are told: every layer shows in both, and the darkening
          # applies on the side the fade reaches, or on both for a fade over the whole screen.
          def fade_window_switches(reaches)
            [reaches == :outside ? WIN_ALL_LAYERS : WIN_ALL_LAYERS | WIN_EFFECT,
             reaches == :inside ? WIN_ALL_LAYERS : WIN_ALL_LAYERS | WIN_EFFECT]
          end

          # The window as power-on leaves it in a game that holds a fade, and as a tint the
          # display mixes in leaves it: no rectangle, and the effect on everywhere. A tint is the
          # same color effect, so it has to set that it reaches the whole screen, or it would stop at
          # the rectangle the last fade was held to.
          def emit_whole_screen_window
            emit_fade_window(nil, nil) if @layout.fading.rectangle_fades?
          end

          def emit_fade_control(node)
            mode = node.toward == :white ? BLD_BRIGHTEN : BLD_DARKEN
            @emitter.write_reg16(REG_BLDCNT, mode | placed_fade.blend_target_bits(node.under))
            # Where this fade sits in the stack, for the window twins to read. Only a
            # program that has twins writes it (see ScreenLayout, which makes the PlacedFade).
            @primitives.store_word_immediate(placed_fade.fade_stack_index(node.under), @primitives.var_addr(EFFECT_LINE)) if placed_fade.any?
          end

          # How far the fade has come, in the sixteenths the hardware counts in, for an
          # amount the game works out as it runs.
          #
          # A class method because the estimate prices this conversion, and the conversion
          # is not in the tree to be found — the lowering builds it. Handed a number, it
          # answers the shape, which is what the estimate wants to price.
          def self.fade_steps_value(amount)
            Build.binop(:/, Build.binop(:*, amount, Build.int(Console::Hardware::BLD_MAX)), Build.int(100))
          end

          def fade_steps_value(amount) = ScreenEffects.fade_steps_value(amount)

          # Where the amount waits while the registers around it are written. Free within
          # a statement, like the other scratch registers.
          FADE_HELD = 2

          # A fade and a see-through layer are the same piece of display, so only one of
          # them can be in force. The blend unit is told which effect it is running in one
          # field of one register: mixing two layers together, or moving the whole picture
          # toward black. A fade writes that field, and the layer's blend is gone while it
          # holds it — the layer draws solid, and darkens with everything else, which is
          # what a fade out is supposed to look like.
          #
          # What must not happen is that it stays gone. A fade ends at zero — invisible,
          # but still a fade as far as the register is concerned — so without this a single
          # hit flash would leave the water solid for the rest of the game, with nothing on
          # screen or in the build to say why.
          #
          # So a fade of nothing hands the register back rather than writing a dead fade.
          # A zero the author wrote is settled here and costs not one instruction; an amount
          # the game works out is a compare and a branch, which is what a fade walked over
          # frames arrives as.
          def emit_fade_beside_see_through(node)
            if (steps = constant_fade_steps(node))
              return @layer_blend.emit_restore_layer_blend if steps.zero?

              return emit_fade_registers(node)
            end

            emit_fade_or_restore_blend(node)
          end

          def emit_fade_or_restore_blend(node)
            hand_back = @emitter.gensym
            done = @emitter.gensym
            @lowering.value(display_steps_value(node))
            @emitter.emit(ASM.mov_reg(FADE_HELD, ACC))
            @emitter.emit(ASM.cmp_imm(FADE_HELD, 0))
            @emitter.emit_branch(:bcond, hand_back, cond: :eq)
            emit_fade_control(node)
            @emitter.emit(ASM.mov_reg(ACC, FADE_HELD))
            @primitives.store_halfword_acc(REG_BLDY)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(hand_back)
            @layer_blend.emit_restore_layer_blend
            @emitter.place_label(done)
          end

          # How far a fade or a tint goes in those sixteenths, when its amount is written in
          # the program — whole or with a fraction (see IR::Fading) — and nil when the game
          # works it out.
          def constant_fade_steps(node)
            amount = @primitives.const_int(node.amount)
            amount && FadeSteps.steps(amount, fraction_bits: node.fraction_bits, walked: false)
          end

          # ...and the same for an amount the game works out, as a value to lower.
          def display_steps_value(node)
            FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: false)
          end

          # Mix a color into the whole picture, which is a different piece of the display
          # from the fade above and not a fade with a color argument.
          #
          # Two mechanisms, chosen by the screen — see PaletteTint for the other one, and
          # for why a screen that draws through a color table cannot use this one.
          #
          # The display can blend two layers together as it draws, weighing each one. So
          # the picture is blended against the BACKDROP — the color shown where nothing
          # was drawn — with the backdrop set to the tint. Turn the weights toward the
          # backdrop and the whole picture moves toward that color. Nothing is redrawn
          # and no pixel in memory changes, so this costs the same whatever is on screen
          # and the picture is all still there when the amount returns to 0.
          #
          # This works because on the direct-color screen the picture is one layer of
          # its own colors, so the backdrop is free to be anything and nothing else in
          # the picture reads it. The screens that draw through a shared color table —
          # the tiled one and the tear-free bitmap one — cannot do it this way, because
          # the backdrop is the first color of that table and the picture reads it. They
          # move the table instead, which is the branch at the top of this method.
          #
          # The weights are a pair that adds to sixteen: what is left of the picture,
          # and how much of the color has come in.
          def emit_tint(node)
            return emit_tint_by_screen_up(node) if @palette_tint.tint_crosses_screens?

            emit_tint_for_mode(node, @layout.modes.mode_at(node))
          end

          # The tint on the screen +mode+ draws on.
          def emit_tint_for_mode(node, mode)
            unless mode == IR::Modes::DIRECT
              # A tint takes the place of a fade as a fade does, so it hands back the blend a
              # fade the display was doing held (see #emit_palette_fade).
              @layer_blend.emit_blend_back_from_display_fade
              return @palette_tint.emit_palette_tint(color: Graphics::Color.resolve(node.color),
                                                     amount: node.amount,
                                                     fraction_bits: node.fraction_bits,
                                                     mode: mode)
            end

            @emitter.write_reg16(PALETTE_START, Graphics::Color.resolve(node.color)) # the backdrop IS the tint
            emit_whole_screen_window
            @emitter.write_reg16(REG_BLDCNT, TINT_BLEND)
            if (steps = constant_fade_steps(node))
              @emitter.write_reg16(REG_BLDALPHA, tint_weights(steps))
            else
              @lowering.value(display_steps_value(node))
              emit_blend_weights_from_acc
            end
          end

          # The picture's layer blended with the backdrop, which is how the plain bitmap screen
          # tints.
          TINT_BLEND = BLD_ALPHA | BLD_BG2 | (BLD_BACKDROP << BLD_SECOND_SHIFT)

          # A tint in a game with more than one screen is done the way the screen up now does
          # it, which a statement cannot know from where it is written: a flash runs from a
          # routine of its own every frame, whichever scene is up. So the tint is kept for the
          # next change of screen (see PaletteTint::TINT_ASKED), and then done one way or the
          # other by which screen the display is in.
          def emit_tint_by_screen_up(node)
            @palette_tint.emit_remember_tint(Graphics::Color.resolve(node.color), node.amount, node.fraction_bits)
            emit_for_each_screen_kind { |mode| emit_tint_for_mode(node, mode) }
          end

          # The block's code once for each kind of screen the game draws on, each run only while
          # the display is in that one: a compare against which screen is up, per kind.
          def emit_for_each_screen_kind
            done = @emitter.gensym
            @layout.modes.modes_in_use.each do |mode|
              other = @emitter.gensym
              @primitives.load_var(ACC, MODE_STATE)
              @emitter.emit(ASM.cmp_imm(ACC, MODE_MARKERS.fetch(mode)))
              @emitter.emit_branch(:bcond, other, cond: :ne)
              yield mode
              @emitter.emit_branch(:b, done)
              @emitter.place_label(other)
            end
            @emitter.place_label(done)
          end

          # Put the tint kept in TINT_ASKED BACK as the display changes to +mode+'s screen.
          # What the last screen left would be wrong here either way round: a walked table is
          # sent again as drawn, and the blend the plain bitmap screen tints with reads the
          # first color of a table, which a tiled screen has just filled with its own. With no
          # tint kept nothing is written, so a fade the display is holding stays on.
          def emit_kept_tint_on_entry(mode)
            return unless @palette_tint.tint_crosses_screens?
            return emit_blend_to_kept_tint if mode == IR::Modes::DIRECT

            @palette_tint.emit_walk_to_kept_tint(mode) do
              # The blend the plain bitmap screen tinted with would mix this screen's third
              # layer with its backdrop. A see-through layer's own blend is written as the
              # screen takes over — unless the display was fading the screen before, which
              # held it; the kept effect is walked into the colors now, so it hands it back.
              if @layer_blend.see_through?
                @layer_blend.emit_blend_back_from_display_fade
              else
                @emitter.write_reg16(REG_BLDCNT, 0)
              end
            end
          end

          # Where the kept tint waits while its color goes in: a change of screen runs between
          # statements, so nothing else is held there.
          KEPT = 2

          def emit_blend_to_kept_tint
            skip = @emitter.gensym
            fade = @emitter.gensym
            @primitives.load_var(KEPT, PaletteTint::TINT_ASKED)
            @emitter.emit(ASM.cmp_imm(KEPT, 0))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            # A kept fade is the display's fade on this screen, not a tint (see
            # #emit_walked_fade_by_screen_up).
            @emitter.emit(ASM.lsr_imm(ACC, KEPT, @palette_tint.state_shift))
            @emitter.emit(ASM.tst_imm(ACC, PaletteTint::DARKEN))
            @emitter.emit_branch(:bcond, fade, cond: :ne)
            @emitter.emit(ASM.tst_imm(ACC, PaletteTint::BRIGHTEN))
            @emitter.emit_branch(:bcond, fade, cond: :ne)
            emit_tint_from_kept
            @emitter.emit_branch(:b, skip)
            @emitter.place_label(fade)
            emit_display_fade_from_kept
            @emitter.place_label(skip)
          end

          # KEPT holds a kept tint: the backdrop becomes its color and the picture is mixed with it.
          def emit_tint_from_kept
            @emitter.emit(ASM.lsr_imm(ACC, KEPT, @palette_tint.state_shift))
            @primitives.store_halfword_acc(PALETTE_START) # the backdrop IS the tint
            emit_whole_screen_window # a tint set on another screen did not set where it reaches
            @emitter.write_reg16(REG_BLDCNT, TINT_BLEND)
            @palette_tint.emit_state_steps_in_sixteenths(KEPT) # a walk's steps, in the display's sixteenths
            emit_blend_weights_from_acc
          end

          # The weight pair as one halfword: how much of the picture survives in the low
          # byte, how much of the color comes in above it.
          def tint_weights(steps)
            (BLD_MAX - steps) | (steps << 8)
          end

          # The same pair, for an amount the game works out. r0 holds the steps.
          #
          # Shared by the two things that blend two layers together: a tint on the
          # direct-color screen, and a see-through layer. They mean different things by
          # the two sides — a color coming in, or what is behind showing through — and the
          # register does not care, so neither does this.
          def emit_blend_weights_from_acc
            @emitter.emit_number(TMP, BLD_MAX)
            @emitter.emit(ASM.sub_reg(TMP, TMP, ACC))              # r1 = what is left of the near side
            @emitter.emit(ASM.orr_reg_lsl(ACC, TMP, ACC, 8))       # ...with the far side's share above it
            @primitives.store_halfword_acc(REG_BLDALPHA)
          end

          # Show the picture in blocks of this many pixels each way.
          #
          # One register holds the size, and nothing else is written: which things are
          # drawn in blocks was settled as the cartridge was built (see Pixelation). The
          # register keeps four sizes — across and down for backgrounds, then across and
          # down for sprites — each in four bits and each one less than the pixels, so the
          # same number goes into all four places.
          #
          # A size written in the program is worked out here and stored as a plain number.
          # One the game works out is held to the sizes there are first, since the fields
          # are four bits wide and a number past them would spill into its neighbour.
          def emit_pixelate(node)
            # A block of the game's pixels is pixel_size of the console's across and down, so the size the
            # game gives is the display's times that: the biggest block is 16 over pixel_size.
            pixel_size = @layout.pixel_size
            largest = Blocks.largest_for(pixel_size)
            if (size = @primitives.const_int(node.size))
              field = (Blocks.size(size, largest) * pixel_size) - 1
              pair = field | (field << MOSAIC_DOWN_SHIFT)
              return @emitter.write_reg16(REG_MOSAIC, pair | (pair << MOSAIC_SPRITES_SHIFT))
            end

            @lowering.value(node.size)
            @emitter.emit(ASM.cmp_imm(ACC, 1))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 1))
            @emitter.emit(ASM.cmp_imm(ACC, largest))
            @emitter.emit(ASM.mov_imm_cond(:gt, ACC, largest))
            # Times pixel_size, a power of two (Console::Description::PIXEL_SIZES), so a shift.
            @emitter.emit(ASM.lsl_imm(ACC, ACC, pixel_size.bit_length - 1)) if pixel_size > 1
            @emitter.emit(ASM.sub_imm(ACC, ACC, 1))
            @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, MOSAIC_DOWN_SHIFT)) # across and down
            @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, MOSAIC_SPRITES_SHIFT)) # ...and the same pair again for sprites
            @primitives.store_halfword_acc(REG_MOSAIC)
          end

          # An amount past either end settles at that end rather than running off it, the
          # same as the interpreter does. Where the weights go into a register the display
          # itself clamps this is free, but a share worked out here can be more than all of
          # it — and that takes a picture somewhere no color goes.
          #
          # +most+ is the far end: the display's sixteen, or a walk's (see PaletteTint#walk_levels).
          def emit_clamp_blend_steps(most = BLD_MAX)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))
            @emitter.emit(ASM.cmp_imm(ACC, most))
            @emitter.emit(ASM.mov_imm_cond(:gt, ACC, most))
          end
        end
      end
    end
  end
end
