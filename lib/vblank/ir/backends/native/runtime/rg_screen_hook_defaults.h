/*
 * What each of rg_screen.c's hooks does when no runtime feature of the game takes it: what the
 * screen does with no feature at all. Included at the end of rg_screen.c, after the game's features
 * (rg_runtime_features.h), each of which marks the hooks it took with RG_HOOK_<NAME>_TAKEN.
 */

#ifndef RG_HOOK_SCREEN_SET_TAKEN
static void rg_hook_screen_set(void) {}
#endif

#ifndef RG_HOOK_SCREEN_CROSSED_TAKEN
static void rg_hook_screen_crossed(int32_t new_kind) { (void)new_kind; }
#endif

#ifndef RG_HOOK_FRAME_ENDED_TAKEN
static void rg_hook_frame_ended(void) {}
#endif

#ifndef RG_HOOK_REPAINT_REQUESTED_TAKEN
static void rg_hook_repaint_requested(void) {}
#endif

#ifndef RG_HOOK_REBUILD_CHECKED_TAKEN
static void rg_hook_rebuild_checked(void) {}
#endif

#ifndef RG_HOOK_REPAINT_BEGAN_TAKEN
static void rg_hook_repaint_began(void) {}
#endif

#ifndef RG_HOOK_PAINT_LEVEL_TAKEN
static void rg_hook_paint_level(int32_t level) { (void)level; }
#endif

#ifndef RG_HOOK_REPAINT_ENDING_TAKEN
static void rg_hook_repaint_ending(void) {}
#endif

#ifndef RG_HOOK_STAMP_SCENERY_TAKEN
static void rg_hook_stamp_scenery(void) {}
#endif

#ifndef RG_HOOK_SCENERY_UP_TAKEN
static int32_t rg_hook_scenery_up(void) { return 0; }
#endif

#ifndef RG_HOOK_LAYER_HOLDS_SCENERY_TAKEN
static int32_t rg_hook_layer_holds_scenery(int32_t layer) {
  (void)layer;
  return 0;
}
#endif

#ifndef RG_HOOK_SCENE_TAKE_DOWN_TAKEN
static int32_t rg_hook_scene_take_down(int32_t brings_scenery) {
  (void)brings_scenery;
  return 0;
}
#endif

/* Must be inline: only the tiled feature asks it, and the compiler counts an unasked inline
 * function as no fault. */
#ifndef RG_HOOK_SCENERY_BLOCK_SIZE_TAKEN
static inline int32_t rg_hook_scenery_block_size(void) { return 1; }
#endif

#ifndef RG_HOOK_PAINT_KEPT_SPRITE_TAKEN
static int32_t rg_hook_paint_kept_sprite(const placed_object *placed) {
  (void)placed;
  return 0;
}
#endif

#ifndef RG_HOOK_SHOWN_PLAIN_TAKEN
static int32_t rg_hook_shown_plain(void) { return 1; }
#endif

#ifndef RG_HOOK_SHOWN_COLUMNS_TAKEN
static const int64_t *rg_hook_shown_columns(void) { return NULL; }
#endif

#ifndef RG_HOOK_SHOWN_ROW_TAKEN
static int64_t rg_hook_shown_row(int64_t y) { return y; }
#endif
