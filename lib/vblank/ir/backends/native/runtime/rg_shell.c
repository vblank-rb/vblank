/*
 * A shell on a computer (rg_shell.h says what one is). The flow is Live::Shell's:
 *
 * - the pack kept in the game's folder, if this shell reads it, is the pack;
 * - otherwise the menu part plays until the player picks a line. LOAD ROM asks for a file through
 *   the system's file dialog; it must be a release the game reads (its size, then its SHA-1, in the
 *   words Original::Releases gives), and the release's unpacking part plays handed the file, as fast
 *   as the computer goes, drawing its progress bar. The bytes it made, after the header for the
 *   file's SHA-1, are the pack, written to the folder.
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
#include "rg_runtime.h"

#define WORDS_ROOM 2048

/* --- the words, the same as Original::Releases --- */

/* Why a file of +size+ bytes called +named+ is no release this game could read, or 0. */
static int size_refusal(const char *named, int32_t size, char *words) {
  const rg_shell_description *shell = rg_shell_facts;
  for (int i = 0; i < shell->release_count; i++) {
    if (shell->releases[i].size < 0 || shell->releases[i].size == size) return 0;
  }
  char sizes[256] = "";
  int32_t listed[64];
  int listed_count = 0;
  for (int i = 0; i < shell->release_count; i++) {
    if (!shell->releases[i].readable) continue;
    int seen = 0;
    for (int j = 0; j < listed_count; j++) seen |= listed[j] == shell->releases[i].size;
    if (seen || listed_count == 64) continue;
    listed[listed_count++] = shell->releases[i].size;
    size_t used = strlen(sizes);
    snprintf(sizes + used, sizeof sizes - used, "%s%d", used ? " or " : "", (int)shell->releases[i].size);
  }
  snprintf(words, WORDS_ROOM, "%s is %d bytes. A copy of %s is %s bytes. Name a complete copy of %s.", named, (int)size,
           shell->releases_title, sizes, shell->releases_title);
  return 1;
}

static void readable_words(char *out, size_t room) {
  const rg_shell_description *shell = rg_shell_facts;
  out[0] = '\0';
  for (int i = 0; i < shell->release_count; i++) {
    if (!shell->releases[i].readable) continue;
    size_t used = strlen(out);
    snprintf(out + used, room - used, "%s%s (SHA-1 %s)", used ? ", " : "", shell->releases[i].name, shell->releases[i].sha1);
  }
}

/* Why a copy called +named+ whose SHA-1 is +sha1+ is refused, or 0 when it is a release the game
 * reads, with +release+ the one it is. */
static int digest_refusal(const char *named, const char *sha1, const rg_shell_release **release, char *words) {
  const rg_shell_description *shell = rg_shell_facts;
  const rg_shell_release *known = NULL;
  for (int i = 0; i < shell->release_count; i++) {
    if (strcmp(shell->releases[i].sha1, sha1) == 0) known = &shell->releases[i];
  }
  if (known && known->readable) {
    *release = known;
    return 0;
  }
  char readable[1024];
  readable_words(readable, sizeof readable);
  if (known) {
    snprintf(words, WORDS_ROOM, "%s is the %s release of %s. This game does not read that release. It reads %s. Name a copy of one of these.",
             named, known->name, shell->releases_title, readable);
  } else {
    snprintf(words, WORDS_ROOM,
             "%s is not a release of %s that this game knows. Its SHA-1 is %s. A changed or damaged copy has a different "
             "SHA-1. This game reads %s. Name a copy of one of these.",
             named, shell->releases_title, sha1, readable);
  }
  return 1;
}

/* --- saying a refusal --- */

static void say(const char *words, int quiet) {
  fprintf(stderr, "%s\n", words);
  if (!quiet) SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_WARNING, rg_shell_facts->title, words, NULL);
}

/* --- the folder and the pack --- */

static char *pack_file_in(const char *folder) {
  char *path = NULL;
  size_t length = strlen(folder);
  const char *between = length && (folder[length - 1] == '/' || folder[length - 1] == '\\') ? "" : "/";
  if (SDL_asprintf(&path, "%s%sdata.pack", folder, between) < 0) return NULL;
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
 * from the script of buttons in +keys+ where a test names one, and its answer written to +result+.
 * Whether it ended well. */
static int run_part(const char *name, const char *copy, const char *keys, const char *result, int fast) {
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

/* The number a variable holds in a part's answer, or 0 and not found. */
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

/* The pack kept at +path+ when this shell reads it, else NULL, saying why when a file is there. */
static int kept_pack_is_read(const char *path) {
  const rg_shell_description *shell = rg_shell_facts;
  size_t size = 0;
  uint8_t *bytes = SDL_LoadFile(path, &size);
  if (!bytes) return 0;
  char words[WORDS_ROOM];
  char refusal[512];
  int refused = rg_start_file_refusal(bytes, (int32_t)size, shell->called, shell->pack_rules, refusal, sizeof refusal);
  SDL_free(bytes);
  if (!refused) return 1;
  snprintf(words, sizeof words, "%s: %s Load your copy of %s again to make it.", path, refusal, shell->title);
  say(words, 0);
  return 0;
}

/* The pack made from the copy at +copy+ (a path, called +named+), unpacked by its release's part,
 * written to +pack_path+. 1 when it is written, else 0 with the words said. */
static int make_pack(const char *copy, const char *named, const char *pack_path, const char *result, int quiet) {
  const rg_shell_description *shell = rg_shell_facts;
  size_t size = 0;
  uint8_t *copy_bytes = SDL_LoadFile(copy, &size);
  char words[WORDS_ROOM];
  if (!copy_bytes) {
    snprintf(words, sizeof words, "%s cannot be read (%s).", named, SDL_GetError());
    say(words, quiet);
    return 0;
  }
  const rg_shell_release *release = NULL;
  char sha1[41];
  if (size_refusal(named, (int32_t)size, words)) {
    say(words, quiet);
    SDL_free(copy_bytes);
    return 0;
  }
  rg_sha1_hex(copy_bytes, size, sha1);
  SDL_free(copy_bytes);
  if (digest_refusal(named, sha1, &release, words)) {
    say(words, quiet);
    return 0;
  }

  if (!run_part(release->part, copy, NULL, result, 1)) return 0;
  size_t answer_size = 0;
  char *answer = SDL_LoadFile(result, &answer_size);
  if (!answer) return 0;
  int32_t finished = 0, fault = 0;
  size_t count = 0;
  uint8_t *made = result_list(answer, shell->bytes_list, &count);
  int stopped_early = !result_variable(answer, shell->finished_variable, &finished) ||
                      !result_variable(answer, shell->fault_variable, &fault) || finished != 1 || fault != 0 || !made;
  SDL_free(answer);
  if (stopped_early) {
    snprintf(words, sizeof words,
             "%s is a copy this game reads, and its unpacking stopped part way (fault %d). This is a fault in the game. Tell its makers.",
             named, (int)fault);
    say(words, quiet);
    SDL_free(made);
    return 0;
  }

  size_t pack_size = (size_t)shell->before_size + 20 + (size_t)shell->after_size + count;
  uint8_t *pack = SDL_malloc(pack_size);
  if (!pack) {
    SDL_free(made);
    return 0;
  }
  memcpy(pack, shell->before, (size_t)shell->before_size);
  for (int i = 0; i < 20; i++) {
    unsigned byte = 0;
    sscanf(sha1 + 2 * i, "%2x", &byte);
    pack[shell->before_size + i] = (uint8_t)byte;
  }
  memcpy(pack + shell->before_size + 20, shell->after, (size_t)shell->after_size);
  memcpy(pack + shell->before_size + 20 + shell->after_size, made, count);
  SDL_free(made);
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
  if (kept_pack_is_read(pack_path)) {
    SDL_free(result);
    return pack_path;
  }
  for (;;) {
    int32_t choice = 0;
    size_t answer_size = 0;
    int played = run_part(shell->menu_part, NULL, asked->menu_keys, result, 0);
    char *answer = played ? SDL_LoadFile(result, &answer_size) : NULL;
    if (!answer || !result_variable(answer, shell->choice_variable, &choice)) {
      SDL_free(answer);
      break; /* the player closed the menu */
    }
    SDL_free(answer);
    if (choice != shell->load_rom_choice) continue;

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
