# frozen_string_literal: true

# FADES AND TINTS (Reference#exec_fade, #exec_tint and Framebuffer#faded): the display's own fade toward
# black or white, held to a rectangle or placed in the stack, a fade that walks the colours, and a tint
# toward a colour. Joined into the runtime's class after rg_screen.rb for a game that fades or tints.
# rg_fades.c says how, rule for rule; this is that file written again, method for method.
#
# The screen never asks it about a pixel. It asks once a read for the colour table the finished
# picture is read through (rg_fades_fade_filter), and once a thing painted for the table that thing is
# painted through (rg_fades_paint_fade_for); the screen's loops then read the tables.
#
# A TABLE here is a Hash that works a colour's answer out the first time it is asked and keeps it
# (Hash.new with a block), so a lookup in the screen's loop is a plain table[color]. A fade that
# animates changes every frame, and working out all 65536 colours a frame would cost more than the
# reading it saves. So a new fade, tint or screen means a new table; a table kept past a change
# would show the old fade.

RG_FADE_WHOLE_SCREEN = 0
RG_FADE_INSIDE = 1
RG_FADE_OUTSIDE = 2

# Backends::FadeSteps: a walk of the colors counts in 256ths, sixteen to a display's step.
RG_WALK_STEPS = 256
RG_WALK_PER_DISPLAY = 16

# A FADE PLACED IN THE STACK (Reference @fade_placed): whether one is in force, how far forward the
# layer it sits under is among the layers the game declared, which way it fades, and how far.
RgPlacedFade = Struct.new(:in_force, :layer_place, :toward_white, :steps)

def rg_fades_setup
  # What a display does to the finished picture: one effect at a time (Framebuffer#fade_to).
  @rg_fade_white = 0
  @rg_fade_steps = 0
  @rg_tint_mode = :none # :none, :toward or :color
  @rg_tint_white = 0
  @rg_tint_color = 0
  @rg_tint_steps = 0
  @rg_tint_by_display = false
  @rg_placed_fade = RgPlacedFade.new(false, RG_NO_LAYER, 0, 0)
  # Which part of the screen the display's fade reaches (Framebuffer#fade_steps_to's +reaches+):
  # RG_FADE_WHOLE_SCREEN, or RG_FADE_INSIDE or RG_FADE_OUTSIDE the rectangle [left, top, right,
  # bottom], the right and bottom one past the last pixel.
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  @rg_fade_area = [0, 0, 0, 0]
  # The filter handed to the screen, and the rows it holds when a fade is held to a rectangle. Its
  # table is made again when +stale+ (a fade, a tint or a screen changed since).
  @rg_fade_rows = Array.new(RG_SCREEN_HEIGHT) { [0, 0, false] }
  @rg_fade_filter = RgShownFilter.new(nil, true, @rg_fade_rows, false)
  @rg_fade_filter_stale = true
  # The table a placed fade paints through, and the direction and steps it was made for.
  @rg_placed_table = nil
  @rg_placed_table_white = nil
  @rg_placed_table_steps = nil
end

# Reference#fading?: is a fade in force that takes the display's blend? The display blends two layers
# together or moves the whole picture toward a color, one or the other, so while such a fade runs a
# see-through layer is solid. A fade that walks the colors sets no fade amount and is never found here.
# The copy of the scenery kept to put back under sprites is a picture of its own, which no fade was
# ever set on, so painting into it never finds one either. A fade placed in the stack is the game's and
# takes the blend whichever picture is being painted.
#
# The screen asks it when a thing in a see-through layer is about to be painted (rg_hook_blend_held_by_fade).
def rg_fades_blend_held_by_fade
  return @rg_placed_fade.steps > 0 if @rg_placed_fade.in_force

  !@rg_target.equal?(@rg_scenery) && @rg_fade_steps > 0
end

# --- effects over the finished picture (Framebuffer#faded) ---

# Framebuffer#walked_toward: a fade that walks the colors, in five bits a channel, each channel
# moved a truncated share of the way to black or white.
def rg_walked_toward(color, white, steps)
  return color if steps == 0

  # FadeSteps.dimmed_levels, on a display that dims
  level = steps >= RG_WALK_STEPS ? 0 : 15 - ((steps * 15) / RG_WALK_STEPS)
  out = 0
  3.times do |channel|
    c = (color >> (5 * channel)) & 0x1F
    c = if RG_CONSOLE_DIMS && white == 0 then ((2 * c * level) + 15) / 30
        else white != 0 ? c + (((31 - c) * steps) / RG_WALK_STEPS) : c - ((c * steps) / RG_WALK_STEPS)
        end
    out |= c << (5 * channel)
  end
  out
end

# Framebuffer#brightened_by_display: each channel widened to eight bits and given +steps+
# sixteenths of the headroom it has left there, then brought back to five bits.
def rg_brightened_by_display(color, steps)
  return color if steps == 0

  rg_brightened_channel(color & 0x1F, steps) | (rg_brightened_channel((color >> 5) & 0x1F, steps) << 5) |
    (rg_brightened_channel((color >> 10) & 0x1F, steps) << 10)
end

# One channel of rg_brightened_by_display, five bits in and five out.
def rg_brightened_channel(channel, steps)
  have = (channel << 3) | (channel >> 2)
  (have + (((255 - have) * steps) / 16)) >> 3
end

# Framebuffer#faded_by_display: the display's own fade toward black or white.
def rg_faded_by_display(color, white, steps)
  white != 0 ? rg_brightened_by_display(color, steps) : rg_darkened_by_display(color, steps)
end

# Framebuffer#mixed and #mixed_by_display: the two shares added, and only then the fraction
# dropped. The display mixes at eight bits a channel; a game writing tinted colors, at five.
#
# The channels are written out rather than looped over, as in rg_mixed_with_under.
def rg_mixed(color, toward, steps, by_display)
  return color if steps == 0

  keep = RG_WALK_STEPS - steps
  red = rg_mixed_channel(color & 0x1F, toward & 0x1F, keep, steps, by_display)
  green = rg_mixed_channel((color >> 5) & 0x1F, (toward >> 5) & 0x1F, keep, steps, by_display)
  blue = rg_mixed_channel((color >> 10) & 0x1F, (toward >> 10) & 0x1F, keep, steps, by_display)
  red | (green << 5) | (blue << 10)
end

# One channel of rg_mixed, five bits in and five out.
def rg_mixed_channel(have, want, keep, steps, by_display)
  return ((have * keep) + (want * steps)) / RG_WALK_STEPS unless by_display

  (((((have << 3) | (have >> 2)) * keep) + (((want << 3) | (want >> 2)) * steps)) / RG_WALK_STEPS) >> 3
end

# Framebuffer#faded, for a pixel the fade reaches (the screen asks only the pixels the filter's
# rows say it does reach, see rg_fades_fill_rows).
def rg_fades_color_through_fade(color)
  case @rg_tint_mode
  when :toward
    # On the plain bitmap screen the display does a walked fade, in sixteenths.
    return rg_faded_by_display(color, @rg_tint_white, @rg_tint_steps / RG_WALK_PER_DISPLAY) if @rg_tint_by_display

    return rg_walked_toward(color, @rg_tint_white, @rg_tint_steps)
  when :color
    # The display counts in sixteenths, every sixteenth 256th, so the steps between are dropped.
    steps = @rg_tint_by_display ? @rg_tint_steps - (@rg_tint_steps % RG_WALK_PER_DISPLAY) : @rg_tint_steps
    return rg_mixed(color, @rg_tint_color, steps, @rg_tint_by_display)
  end
  rg_faded_by_display(color, @rg_fade_white, @rg_fade_steps)
end

# Framebuffer#fade_reaches?, row by row: a pixel is changed when +inverted+ differs from
# from <= x < to. Inside the rectangle that is the rectangle's columns on its rows and nothing on the
# others; outside it is the opposite. Only used when the fade is not over the whole screen and no
# tint is in force: a tint reaches every pixel, whatever rectangle a fade before it was held to.
def rg_fades_fill_rows
  inverted = @rg_fade_side == RG_FADE_OUTSIDE
  left, top, right, bottom = @rg_fade_area
  RG_SCREEN_HEIGHT.times do |y|
    on_rows = y >= top && y < bottom
    row = @rg_fade_rows[y]
    row[0] = on_rows ? left : 0
    row[1] = on_rows ? right : 0
    row[2] = inverted
  end
end

# rg_hook_fade_filter. Nothing when no tint is in force and the fade is not out of nought steps: the
# picture is then read as it is stored, which keeps a cell's bit 15 that every fade drops. A tint in
# force always has a filter, even for a tint of nought steps (which changes no colour): the
# see-through cells it remixes are read through it (Framebuffer#shown_color).
def rg_fades_fade_filter
  return nil if @rg_tint_mode == :none && @rg_fade_steps == 0

  filter = @rg_fade_filter
  if @rg_fade_filter_stale
    filter.table = Hash.new { |table, color| table[color] = rg_fades_color_through_fade(color) }
    filter.everywhere = @rg_tint_mode != :none || @rg_fade_side == RG_FADE_WHOLE_SCREEN
    rg_fades_fill_rows unless filter.everywhere
    @rg_fade_filter_stale = false
  end
  # A cell a see-through layer was mixed into, under a tint, is mixed again from its two colors
  # tinted: a tint on a screen drawn through a color table moves the colors the display then mixes,
  # so it reaches each side before the two are added, and past a whole the order shows.
  filter.remix = @rg_tint_mode != :none && @rg_pixels.equal?(@rg_viewed)
  filter
end

# rg_hook_paint_fade_for. Reference#set_blend_for, the fade half, for the thing about to be painted:
# the placed fade in force reaches it unless that fade's layer is no further forward than
# +fade_place+, the furthest forward such a layer can be and still leave the thing as drawn
# (RG_BG_FADE_PLACE). That is RG_NO_LAYER for a thing every placed fade reaches, and for the backdrop,
# which is behind everything. A fade under a layer the game never declared reaches everything. A color
# painted through the table is Framebuffer#apply_placed_fade's; a fade of nought steps changes none,
# so it answers no table. The table is made again when the fade's direction or steps are not the ones
# it was made for.
def rg_fades_paint_fade_for(fade_place)
  placed = @rg_placed_fade
  under = placed.layer_place
  left_as_drawn = under != RG_NO_LAYER && fade_place != RG_NO_LAYER && fade_place >= under
  return nil if !placed.in_force || left_as_drawn || placed.steps == 0

  white = placed.toward_white
  steps = placed.steps
  if @rg_placed_table_white != white || @rg_placed_table_steps != steps
    @rg_placed_table = Hash.new { |table, color| table[color] = rg_faded_by_display(color, white, steps) }
    @rg_placed_table_white = white
    @rg_placed_table_steps = steps
  end
  @rg_placed_table
end

# Reference#exec_fade, through Framebuffer#fade_steps_to or, for a fade that walks the colors,
# #tint_steps_to. +placed+ is true for a fade placed in the stack under the layer at +layer_place+.
#
# Over the whole screen it is laid over the picture as the screen is read, so nothing drawn
# changes. Placed in the stack it is painted into the picture, so the picture is built again right
# here, and again by the fade that takes a placed one's place, which has to take it back out. A
# fade that takes the display's blend takes it from a see-through layer and hands it back as it
# lifts, so the picture is built again at each of those two moments as well.
def rg_fade_to(placed, layer_place, toward_white, steps, walked)
  took_the_blend = rg_fades_blend_held_by_fade
  was_placed = @rg_placed_fade.in_force
  @rg_placed_fade = RgPlacedFade.new(placed, layer_place, toward_white, steps)
  if walked != 0
    @rg_tint_mode = :toward
    @rg_tint_white = toward_white
    @rg_tint_steps = steps
    @rg_tint_by_display = rg_tint_mixed_by_display? # Reference#fade_by_tint
    @rg_fade_steps = 0
  else
    @rg_fade_white = toward_white
    @rg_fade_steps = placed ? 0 : steps
    @rg_tint_mode = :none
  end
  @rg_fade_filter_stale = true
  blend_changed_hands = rg_see_through_layers > 0 && rg_fades_blend_held_by_fade != took_the_blend
  rg_request_repaint if was_placed || placed || blend_changed_hands
end

def rg_screen_fade(toward_white, steps, walked)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  rg_fade_to(false, RG_NO_LAYER, toward_white, steps, walked)
end

def rg_screen_fade_in_area(reaches, left, top, right, bottom, toward_white, steps)
  @rg_fade_side = reaches
  @rg_fade_area = [left, top, right, bottom]
  rg_fade_to(false, RG_NO_LAYER, toward_white, steps, 0)
end

def rg_screen_fade_under(layer_place, toward_white, steps, walked)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  rg_fade_to(true, layer_place, toward_white, steps, walked)
end

# Reference#tint_by_display?: does the display mix a tint in as it draws, which only the plain
# bitmap screen does, on a console that blends? Every other screen has it mixed into a colour table.
def rg_tint_mixed_by_display? = rg_painted_screen? && @rg_pixels.equal?(@rg_viewed) && RG_CONSOLE_BLENDS

# rg_hook_screen_set (Reference#exec_screen): a tint in force is mixed this screen's way, so the
# table made for the screen before is made again.
def rg_fades_screen_set
  @rg_tint_by_display = rg_tint_mixed_by_display?
  @rg_fade_filter_stale = true
end

# Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever fade
# was in force, one placed in the stack included, and the picture is built again when a fade that
# held a see-through layer solid, or was painted into the picture, goes.
def rg_screen_tint(color, steps)
  took_the_blend = rg_fades_blend_held_by_fade
  was_placed = @rg_placed_fade.in_force
  @rg_placed_fade.in_force = false
  @rg_tint_mode = :color
  @rg_tint_color = color
  @rg_tint_steps = steps
  @rg_tint_by_display = rg_tint_mixed_by_display?
  @rg_fade_steps = 0
  @rg_fade_filter_stale = true
  blend_changed_hands = rg_see_through_layers > 0 && rg_fades_blend_held_by_fade != took_the_blend
  rg_request_repaint if was_placed || blend_changed_hands
end

RG_TINT_MODES = %i[none toward color].freeze # The tint's way, by its number in the state image

# "fades" (Computer::StateFields says what each holds).
RgFadesFields = Data.define(:fade_white, :fade_steps, :tint_mode, :tint_white, :tint_color, :tint_steps, :tint_by_display,
                           :placed_in_force, :placed_layer_place, :placed_toward_white, :placed_steps,
                           :fade_side, :area_left, :area_top, :area_right, :area_bottom)

# rg_hook_visit_state (rg_fades.c's rg_fades_visit_state).
def rg_fades_visit_state
  placed = @rg_placed_fade
  left, top, right, bottom = @rg_fade_area
  fields = rg_state_record("fades", RgFadesFields.new(
                                     fade_white: @rg_fade_white, fade_steps: @rg_fade_steps, tint_mode: RG_TINT_MODES.index(@rg_tint_mode),
                                     tint_white: @rg_tint_white, tint_color: @rg_tint_color, tint_steps: @rg_tint_steps,
                                     tint_by_display: rg_state_flag(@rg_tint_by_display),
                                     placed_in_force: rg_state_flag(placed.in_force), placed_layer_place: placed.layer_place,
                                     placed_toward_white: placed.toward_white, placed_steps: placed.steps,
                                     fade_side: @rg_fade_side, area_left: left, area_top: top, area_right: right, area_bottom: bottom
                                   ))
  unless fields.tint_mode.between?(0, RG_TINT_MODES.length - 1)
    rg_state_refuse_damaged("the screen names a tint it does not have")
  end
  @rg_fade_white = fields.fade_white
  @rg_fade_steps = fields.fade_steps
  @rg_tint_mode = RG_TINT_MODES[fields.tint_mode]
  @rg_tint_white = fields.tint_white
  @rg_tint_color = fields.tint_color
  @rg_tint_steps = fields.tint_steps
  @rg_tint_by_display = fields.tint_by_display != 0
  @rg_placed_fade = RgPlacedFade.new(fields.placed_in_force != 0, fields.placed_layer_place, fields.placed_toward_white,
                                     fields.placed_steps)
  @rg_fade_side = fields.fade_side
  @rg_fade_area = [fields.area_left, fields.area_top, fields.area_right, fields.area_bottom]
  @rg_fade_filter_stale = true
end

# Backends::FadeSteps.steps
def rg_fade_steps(amount, fraction_bits, walked)
  levels = walked != 0 ? RG_WALK_STEPS : 16
  if fraction_bits < 0
    sixteenths = rg_whole_sixteenths(amount)
    return walked != 0 ? sixteenths * RG_WALK_PER_DISPLAY : sixteenths
  end
  rg_clamp_wide((amount * levels) / (100 << fraction_bits), 0, levels)
end
