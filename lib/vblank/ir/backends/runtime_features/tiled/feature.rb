# frozen_string_literal: true

# `background` and `status_bar`: scenery drawn from tiles. Its maps, scroll, turn, bends and boxes,
# the order a stack of layers puts it in, and a scene's scenery coming down.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :tiled,
  needed_by: %i[background],
  hooks: %i[setup screen_crossed frame_ended repaint_requested rebuild_checked repaint_began paint_level
            repaint_ending stamp_scenery scenery_up layer_holds_scenery scene_take_down visit_state]
)
