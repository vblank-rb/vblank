/*
 * A shell on a computer (rg_shell.h has what one is). The flow is Live::Shell's, and rg_shell.js is
 * this written again for a page, function for function:
 *
 * - the pack kept in the game's folder, if it passes the check, is the pack;
 * - otherwise the menu part plays until the player picks a line. LOAD ROM asks for a file through
 *   the system's file dialog; it must be a release the game reads (its size, then its SHA-1), and
 *   the release's unpacking part plays handed the bytes that were checked, as fast as the computer goes, drawing its
 *   progress bar. The bytes it made, after the header for the file's SHA-1, are the pack, written to
 *   the folder. SETTINGS plays the menu again with the window's menu open.
 *
 * Every sentence is the build's (rg_shell_facts), filled in here by rg_words_fill.
 *
 * A part is run as a program of its own (--part RESULT): it plays in a window like any game, and
 * where a game would halt it writes where its variables and lists stand into RESULT and ends.
 */
#include "rg_shell.h"

#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rg_console_bios.h"
#include "rg_refusal.h"
#include "rg_runtime.h"

/* --- the refusals, as Original::Releases makes them --- */

/* Whether a file called +named+ of +size+ bytes is no release this game could read: 1 with the
 * sentence in +out+, or 0. */
static int rg_shell_size_refusal(const char *named, int32_t size, char *out) {
  const rg_shell_description *shell = rg_shell_facts;
  for (int i = 0; i < shell->release_count; i++) {
    if (shell->releases[i].size < 0 || shell->releases[i].size == size) return 0;
  }
  char size_text[16];
  snprintf(size_text, sizeof size_text, "%d", (int)size);
  const char *names[] = {"named", "size"};
  const char *values[] = {named, size_text};
  rg_words_fill(out, RG_WORDS_ROOM, shell->wrong_size_words, 2, names, values);
  return 1;
}

/* Whether a copy called +named+ whose SHA-1 is +sha1+ is refused: 1 with the sentence in +out+, or 0
 * when it is a release the game reads, with +release+ the one it is. */
static int rg_shell_digest_refusal(const char *named, const char *sha1, const rg_shell_release **release, char *out) {
  const rg_shell_description *shell = rg_shell_facts;
  const rg_shell_release *known = NULL;
  for (int i = 0; i < shell->release_count; i++) {
    if (strcmp(shell->releases[i].sha1, sha1) == 0) known = &shell->releases[i];
  }
  if (known && known->read) {
    *release = known;
    return 0;
  }
  const char *names[] = {"named", "sha1"};
  const char *values[] = {named, sha1};
  rg_words_fill(out, RG_WORDS_ROOM, known ? known->unread_words : shell->unknown_words, 2, names, values);
  return 1;
}

/* --- telling the player --- */

/* A refusal, printed, and shown in a box unless +quiet+ (a test's run). */
static void tell(const char *words, int quiet) {
  fprintf(stderr, "%s\n", words);
  if (!quiet) SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_WARNING, rg_shell_facts->title, words, NULL);
}

/* --- the folder and the pack --- */

static char *pack_file_in(const char *folder) {
  char *path = NULL;
  size_t length = strlen(folder);
  const char *between = length && (folder[length - 1] == '/' || folder[length - 1] == '\\') ? "" : "/";
  if (SDL_asprintf(&path, "%s%s%s", folder, between, rg_shell_facts->pack_file) < 0) return NULL;
  return path;
}

/* Written beside the pack and then moved into place, so a pack is never left half written. */
static int write_pack(const char *path, const uint8_t *bytes, size_t size) {
  char *writing = NULL;
  if (SDL_asprintf(&writing, "%s.writing", path) < 0) return 0;
  int ok = SDL_SaveFile(writing, bytes, size) && SDL_RenamePath(writing, path);
  SDL_free(writing);
  return ok;
}

/* The pack for a copy whose SHA-1 is +sha1+, holding the +count+ bytes the unpacking +made+, or NULL;
 * its size in +size+. */
static uint8_t *rg_shell_pack_for(const char *sha1, const uint8_t *made, size_t count, size_t *size) {
  const rg_shell_description *shell = rg_shell_facts;
  size_t before = (size_t)shell->pack_before_sha1_size, after = (size_t)shell->pack_after_sha1_size;
  uint8_t *pack = SDL_malloc(before + 20 + after + count);
  if (!pack) return NULL;
  memcpy(pack, shell->pack_before_sha1, before);
  for (size_t i = 0; i < 20; i++) {
    unsigned byte = 0;
    sscanf(sha1 + 2 * i, "%2x", &byte);
    pack[before + i] = (uint8_t)byte;
  }
  memcpy(pack + before + 20, shell->pack_after_sha1, after);
  memcpy(pack + before + 20 + after, made, count);
  *size = before + 20 + after + count;
  return pack;
}

/* --- parts --- */

/* The file of the part called +name+, under parts/ beside this program. */
static char *part_file(const char *name) {
  char *path = NULL;
  const char *base = SDL_GetBasePath();
#ifdef _WIN32
  const char *ending = ".exe";
#else
  const char *ending = "";
#endif
  if (SDL_asprintf(&path, "%sparts/%s%s", base ? base : "", name, ending) < 0) return NULL;
  return path;
}

/* Runs the part called +name+ to its end: with the copy for its start file where it has one, played
 * from the script of buttons in +keys+ where a test names one, and its answer written to +result+;
 * +fast+ for an unpacking, and +menu_open+ to open the window's menu as it starts. Whether it ended
 * well. */
static int run_part(const char *name, const char *copy, const char *keys, const char *result, int fast, int menu_open) {
  char *exe = part_file(name);
  if (!exe) return 0;
  const char *args[12];
  int count = 0;
  args[count++] = exe;
  args[count++] = "--part";
  args[count++] = result;
  if (copy) {
    args[count++] = "--data-pack";
    args[count++] = copy;
  }
  if (fast) args[count++] = "--part-fast";
  if (menu_open) args[count++] = "--open-menu";
  if (keys) {
    args[count++] = "--scripted-keys";
    args[count++] = "100000";
  }
  args[count] = NULL;

  SDL_PropertiesID properties = SDL_CreateProperties();
  SDL_SetPointerProperty(properties, SDL_PROP_PROCESS_CREATE_ARGS_POINTER, (void *)args);
  SDL_IOStream *script = keys ? SDL_IOFromFile(keys, "rb") : NULL;
  if (script) {
    SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, SDL_PROCESS_STDIO_REDIRECT);
    SDL_SetPointerProperty(properties, SDL_PROP_PROCESS_CREATE_STDIN_POINTER, script);
  } else {
    SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, SDL_PROCESS_STDIO_NULL);
  }
  SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, SDL_PROCESS_STDIO_NULL);
  SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, SDL_PROCESS_STDIO_INHERITED);
  SDL_Process *process = SDL_CreateProcessWithProperties(properties);
  SDL_DestroyProperties(properties);
  int ok = 0;
  if (process) {
    int status = 1;
    ok = SDL_WaitProcess(process, true, &status) && status == 0;
    SDL_DestroyProcess(process);
  } else {
    fprintf(stderr, "%s: the part %s cannot be started (%s)\n", rg_shell_facts->title, exe, SDL_GetError());
  }
  if (script) SDL_CloseIO(script);
  SDL_free(exe);
  return ok;
}

/* The number a variable holds in a part's answer: 1 with it in +value+, or 0 when it is not there. */
static int result_variable(const char *text, const char *name, int32_t *value) {
  char line[256];
  snprintf(line, sizeof line, "var %s ", name);
  for (const char *at = text; at && *at; at = strchr(at, '\n') ? strchr(at, '\n') + 1 : NULL) {
    if (strncmp(at, line, strlen(line)) == 0) {
      *value = (int32_t)strtol(at + strlen(line), NULL, 10);
      return 1;
    }
  }
  return 0;
}

/* A list in a part's answer: "list NAME COUNT" and then its items, one to a line. The bytes it
 * holds, one each (the low eight bits of an item), or NULL; the count in +count+. */
static uint8_t *result_list(const char *text, const char *name, size_t *count) {
  char line[256];
  snprintf(line, sizeof line, "list %s ", name);
  for (const char *at = text; at && *at; at = strchr(at, '\n') ? strchr(at, '\n') + 1 : NULL) {
    if (strncmp(at, line, strlen(line)) != 0) continue;
    char *after = NULL;
    long items = strtol(at + strlen(line), &after, 10);
    uint8_t *bytes = SDL_malloc(items > 0 ? (size_t)items : 1);
    if (!bytes) return NULL;
    for (long i = 0; i < items; i++) bytes[i] = (uint8_t)(strtol(after, &after, 10) & 0xFF);
    *count = (size_t)items;
    return bytes;
  }
  return NULL;
}

/* --- the file dialog --- */

typedef struct {
  int done;
  char *path;
} picked_file;

static void file_picked(void *user, const char *const *files, int filter) {
  (void)filter;
  picked_file *picked = user;
  if (files && files[0]) picked->path = SDL_strdup(files[0]);
  picked->done = 1;
}

/* The file the player picks in the system's dialog, or NULL for none. SDL calls back from the
 * main thread's event loop, so the events are pumped here until it has. */
static char *pick_copy(void) {
  picked_file picked = {0, NULL};
  SDL_ShowOpenFileDialog(file_picked, &picked, NULL, NULL, 0, NULL, false);
  while (!picked.done) {
    SDL_PumpEvents();
    SDL_Delay(10);
  }
  return picked.path;
}

/* --- the flow --- */

/* The last part of +path+, what the player calls the file. */
static const char *file_name_of(const char *path) {
  const char *name = path;
  for (const char *c = path; *c; c++) {
    if (*c == '/' || *c == '\\') name = c + 1;
  }
  return name;
}

/* Whether the pack kept at +path+ passes the check: 1, or 0, the player told why when a file is there. */
static int kept_pack_passes(const char *path) {
  const rg_shell_description *shell = rg_shell_facts;
  size_t size = 0;
  uint8_t *bytes = SDL_LoadFile(path, &size);
  if (!bytes) return 0;
  char refusal[RG_WORDS_ROOM];
  int refused = rg_start_file_refusal(bytes, (int32_t)size, shell->pack_rules, &shell->pack_words, refusal, sizeof refusal);
  SDL_free(bytes);
  if (!refused) return 1;
  char words[RG_WORDS_ROOM];
  const char *names[] = {"path", "refusal"};
  const char *values[] = {path, refusal};
  rg_words_fill(words, sizeof words, shell->kept_pack_refused_words, 2, names, values);
  tell(words, 0);
  return 0;
}

/* The pack made from the copy at +copy+ (a path, called +named+), read once, checked, and unpacked
 * by its release's part; written to +pack_path+. 1 when it is written, else 0, the player told why. */
static int make_pack(const char *copy, const char *named, const char *pack_path, const char *result, int quiet) {
  const rg_shell_description *shell = rg_shell_facts;
  size_t size = 0;
  uint8_t *copy_bytes = SDL_LoadFile(copy, &size);
  char words[RG_WORDS_ROOM];
  if (!copy_bytes) {
    const char *names[] = {"named", "why"};
    const char *values[] = {named, SDL_GetError()};
    rg_words_fill(words, sizeof words, shell->unreadable_words, 2, names, values);
    tell(words, quiet);
    return 0;
  }
  const rg_shell_release *release = NULL;
  char sha1[41];
  if (rg_shell_size_refusal(named, (int32_t)size, words)) {
    tell(words, quiet);
    SDL_free(copy_bytes);
    return 0;
  }
  rg_sha1_hex(copy_bytes, size, sha1);
  if (rg_shell_digest_refusal(named, sha1, &release, words)) {
    tell(words, quiet);
    SDL_free(copy_bytes);
    return 0;
  }

  /* The unpacking is handed the bytes that were checked, written beside the pack where only this
   * program writes, never the player's file again: that file could change between the two reads,
   * and the unpacking checks only a copy's size. (The unpacking checking the SHA-1 itself would put a
   * SHA-1 into every runtime's check of a start file, for this one use.) */
  char *checked = NULL;
  int handed = SDL_asprintf(&checked, "%s.copy", pack_path) >= 0 && SDL_SaveFile(checked, copy_bytes, size);
  SDL_free(copy_bytes);
  int unpacked = handed && run_part(release->part, checked, NULL, result, 1, 0);
  if (checked) SDL_RemovePath(checked);
  SDL_free(checked);
  if (!unpacked) return 0;
  size_t answer_size = 0;
  char *answer = SDL_LoadFile(result, &answer_size);
  if (!answer) return 0;
  int32_t finished = 0, fault = 0;
  size_t count = 0;
  uint8_t *made = result_list(answer, shell->bytes_list, &count);
  int stopped_early = !result_variable(answer, shell->finished_variable, &finished) ||
                      !result_variable(answer, shell->fault_kind_variable, &fault) || finished != 1 || fault != 0 || !made;
  SDL_free(answer);
  if (stopped_early) {
    char fault_text[16];
    snprintf(fault_text, sizeof fault_text, "%d", (int)fault);
    const char *names[] = {"named", "fault"};
    const char *values[] = {named, fault_text};
    rg_words_fill(words, sizeof words, shell->unpacking_stopped_words, 2, names, values);
    tell(words, quiet);
    SDL_free(made);
    return 0;
  }

  size_t pack_size = 0;
  uint8_t *pack = rg_shell_pack_for(sha1, made, count, &pack_size);
  SDL_free(made);
  if (!pack) return 0;
  int ok = write_pack(pack_path, pack, pack_size);
  SDL_free(pack);
  return ok;
}

char *rg_shell_pack_path(const rg_shell_asked *asked) {
  const rg_shell_description *shell = rg_shell_facts;
  char *folder = asked->pack_folder ? SDL_strdup(asked->pack_folder) : SDL_GetPrefPath("vblank", shell->folder);
  if (!folder) return NULL;
  SDL_CreateDirectory(folder);
  char *pack_path = pack_file_in(folder);
  char *result = NULL;
  SDL_free(folder);
  if (!pack_path || SDL_asprintf(&result, "%s.answer", pack_path) < 0) {
    SDL_free(pack_path);
    return NULL;
  }

  int quiet = asked->copy != NULL;
  if (kept_pack_passes(pack_path)) {
    SDL_free(result);
    return pack_path;
  }
  /* SETTINGS plays the menu again with the window's menu open, where the settings are. */
  int settings_open = 0;
  for (;;) {
    int32_t choice = 0;
    size_t answer_size = 0;
    const char *keys = settings_open && asked->settings_keys ? asked->settings_keys : asked->menu_keys;
    int played = run_part(shell->menu_part, NULL, keys, result, 0, settings_open);
    char *answer = played ? SDL_LoadFile(result, &answer_size) : NULL;
    if (!answer || !result_variable(answer, shell->choice_variable, &choice)) {
      SDL_free(answer);
      break; /* the player closed the menu */
    }
    SDL_free(answer);
    settings_open = choice == shell->settings;
    if (choice != shell->load_rom) continue;

    char *picked = asked->copy ? SDL_strdup(asked->copy) : pick_copy();
    if (!picked) continue;
    int made = make_pack(picked, file_name_of(picked), pack_path, result, quiet);
    SDL_free(picked);
    if (made) {
      SDL_free(result);
      return pack_path;
    }
    if (asked->copy) exit(2); /* a test names one copy; asking again would ask for it for ever */
  }
  SDL_free(result);
  SDL_free(pack_path);
  return NULL;
}
