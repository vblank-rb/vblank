/*
 * What each of rg_screen.c's hooks does when no runtime feature of the game takes it: what the
 * screen does with no feature at all. Included at the end of rg_screen.c, after the game's features
 * (rg_runtime_features.h), each of which marks the hooks it took with RG_HOOK_<NAME>_TAKEN.
 */

#ifndef RG_HOOK_SCREEN_SET_TAKEN
static void rg_hook_screen_set(void) {}
#endif

#ifndef RG_HOOK_PAINT_SCENERY_TAKEN
static int32_t rg_hook_paint_scenery(int32_t background) {
  (void)background;
  return 0;
}
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
