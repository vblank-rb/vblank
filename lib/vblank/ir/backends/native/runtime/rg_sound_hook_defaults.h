/*
 * What each of rg_sound.c's hooks does when no runtime feature of the game takes it: what the sound
 * does with no tune and no recording. Included at the end of rg_sound.c, after the game's sound
 * features (rg_sound_features.h), each of which marks the hooks it took with RG_HOOK_<NAME>_TAKEN.
 */

#ifndef RG_HOOK_SOUND_FRAME_TAKEN
static void rg_hook_sound_frame(void) {}
#endif

#ifndef RG_HOOK_SOUND_FRAME_ENDED_TAKEN
static void rg_hook_sound_frame_ended(void) {}
#endif

#ifndef RG_HOOK_VOICE_TAKEN_BY_GAME_TAKEN
static void rg_hook_voice_taken_by_game(int32_t voice) { (void)voice; }
#endif

/* No slice at all: the render has nothing to add to the voices. */
#ifndef RG_HOOK_MIXED_SLICE_TAKEN
static int32_t rg_hook_mixed_slice(const int32_t **samples) {
  *samples = NULL;
  return 0;
}
#endif

/* No slice, so nothing to take down. */
#ifndef RG_HOOK_MIXED_SAMPLE_SHIFT_TAKEN
static int32_t rg_hook_mixed_sample_shift(void) { return 0; }
#endif

/* No recordings: no voice of the chip's plays one. */
#ifndef RG_HOOK_RECORDINGS_TOLD_TAKEN
static inline void rg_hook_recordings_told(void) {}
#endif

#ifndef RG_HOOK_VISIT_SOUND_STATE_TAKEN
static void rg_hook_visit_sound_state(void) {}
#endif

/* A game with no recordings prints nothing of the mix. */
#ifndef RG_HOOK_MOMENT_PRINTED_TAKEN
static void rg_hook_moment_printed(void) {}
#endif
