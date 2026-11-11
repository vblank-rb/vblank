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
 * ONE WINDOW, FROM THE MENU TO THE GAME. A part is a program of its own (rg_shell.h says why), and
 * a window cannot be handed from one program to another. So this program, which becomes the game,
 * opens its window before any of this runs and keeps it, and a part has none: it is started with
 * --part RESULT, sends each picture it draws down its standard output, is sent the buttons held for
 * each frame on its standard input, and where a game would halt writes where its variables and
 * lists stand into RESULT and ends (rg_sdl.c has both ends: its rg_shell_window shows a part, and
 * its --part plays one). The file chooser and the box a refusal is told in are that window's own,
 * and the last picture a part drew stays up until the next thing is drawn, so nothing closes or
 * opens between the menu, the chooser, the unpacking and the game.
 */
#include "rg_shell.h"

#include <SDL3/SDL.h>
#ifndef _WIN32
#include <signal.h>
#endif
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

/* --- a copy that is a folder, as Original::Releases#match_folder takes one --- */

/* Whether a release the game reads is several files, so LOAD ROM asks for a folder. */
static int copy_is_folder(void) {
  const rg_shell_description *shell = rg_shell_facts;
  for (int i = 0; i < shell->release_count; i++) {
    if (shell->releases[i].read && shell->releases[i].files) return 1;
  }
  return 0;
}

static int is_folder(const char *path) {
  SDL_PathInfo info;
  return SDL_GetPathInfo(path, &info) && info.type == SDL_PATHTYPE_DIRECTORY;
}

/* +folder+ and +name+ joined, freed with SDL_free, or NULL. */
static char *path_in_folder(const char *folder, const char *name) {
  char *path = NULL;
  size_t length = strlen(folder);
  const char *between = length && (folder[length - 1] == '/' || folder[length - 1] == '\\') ? "" : "/";
  if (SDL_asprintf(&path, "%s%s%s", folder, between, name) < 0) return NULL;
  return path;
}

/* The name in +names+ that is +file_name+ without regard to case, or NULL. */
static const char *file_in(char **names, int count, const char *file_name) {
  for (int i = 0; i < count; i++) {
    if (SDL_strcasecmp(names[i], file_name) == 0) return names[i];
  }
  return NULL;
}

/* The first release the game reads whose every file is among +names+, or NULL. */
static const rg_shell_release *release_in_folder(char **names, int count) {
  const rg_shell_description *shell = rg_shell_facts;
  for (int i = 0; i < shell->release_count; i++) {
    const rg_shell_release *release = &shell->releases[i];
    if (!release->read || !release->files) continue;
    int whole = 1;
    for (int f = 0; f < release->file_count && whole; f++) whole = file_in(names, count, release->files[f].name) != NULL;
    if (whole) return release;
  }
  return NULL;
}

/* +text+ added to the end of +out+ (room RG_WORDS_ROOM), after +join+ unless +out+ is empty. */
static void add_joined(char *out, const char *join, const char *text) {
  if (*out) SDL_strlcat(out, join, RG_WORDS_ROOM);
  SDL_strlcat(out, text, RG_WORDS_ROOM);
}

/* Why the folder +named+, holding +names+, is refused when it holds no release whole, into +out+. */
static void lacking_refusal(const char *named, char **names, int count, char *out) {
  const rg_shell_description *shell = rg_shell_facts;
  if (*shell->folder_words) {
    const char *keys[] = {"named"};
    const char *values[] = {named};
    rg_words_fill(out, RG_WORDS_ROOM, shell->folder_words, 1, keys, values);
    return;
  }
  char lacking[RG_WORDS_ROOM] = "";
  for (int i = 0; i < shell->release_count; i++) {
    const rg_shell_release *release = &shell->releases[i];
    if (!release->read || !release->files) continue;
    char missing[RG_WORDS_ROOM] = "";
    for (int f = 0; f < release->file_count; f++) {
      if (!file_in(names, count, release->files[f].name)) add_joined(missing, shell->missing_join, release->files[f].name);
    }
    char part[RG_WORDS_ROOM];
    const char *keys[] = {"release", "missing"};
    const char *values[] = {release->name, missing};
    rg_words_fill(part, sizeof part, shell->release_lacks_words, 2, keys, values);
    add_joined(lacking, shell->lacking_join, part);
  }
  const char *keys[] = {"named", "lacking"};
  const char *values[] = {named, lacking};
  rg_words_fill(out, RG_WORDS_ROOM, shell->lacking_words, 2, keys, values);
}

/* The folder's own files as SDL_EnumerateDirectory walks it: its top level only, never a folder
 * inside it, which SDL_GlobDirectory would walk whole. */
typedef struct {
  char **names;
  int count;
  int room;
} rg_folder_files;

static SDL_EnumerationResult add_folder_file(void *userdata, const char *folder, const char *name) {
  rg_folder_files *files = userdata;
  char *path = path_in_folder(folder, name);
  SDL_PathInfo info;
  int is_file = path && SDL_GetPathInfo(path, &info) && info.type == SDL_PATHTYPE_FILE;
  SDL_free(path);
  if (!is_file) return SDL_ENUM_CONTINUE;
  if (files->count == files->room) {
    int room = files->room ? files->room * 2 : 16;
    char **grown = SDL_realloc(files->names, (size_t)room * sizeof *grown);
    if (!grown) return SDL_ENUM_FAILURE;
    files->names = grown;
    files->room = room;
  }
  files->names[files->count++] = SDL_strdup(name);
  return SDL_ENUM_CONTINUE;
}

/* The names of the files in +folder+, or NULL; how many in +count+. Free each and then the list with
 * SDL_free. */
static char **list_files_in(const char *folder, int *count) {
  rg_folder_files files = {NULL, 0, 0};
  SDL_EnumerateDirectory(folder, add_folder_file, &files);
  *count = files.count;
  return files.names ? files.names : SDL_calloc(1, sizeof(char *));
}

static void free_names(char **names, int count) {
  for (int i = 0; names && i < count; i++) SDL_free(names[i]);
  SDL_free(names);
}

/* --- telling the player --- */

/* The window all of this is shown in, for as long as rg_shell_pack_path runs. */
static const rg_shell_window *shell_window;

/* A refusal, printed, and shown in a box on the window unless +quiet+ (a test's run). */
static void tell(const char *words, int quiet) {
  fprintf(stderr, "%s\n", words);
  if (!quiet) shell_window->tell(words);
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

/* What a part that stopped on a fault left to be told (rg_sdl.c's write_part_fault writes the words
 * beside its answer): told, in a box on the window unless +quiet+, and removed. */
static void tell_part_fault(const char *result, int quiet) {
  char *path = NULL;
  if (SDL_asprintf(&path, "%s.fault", result) < 0) return;
  char *words = SDL_LoadFile(path, NULL);
  if (words && *words) tell(words, quiet);
  SDL_free(words);
  SDL_RemovePath(path);
  SDL_free(path);
}

/* Runs the part called +name+ to its end, shown in the window: handed +start_file+ as its start
 * file (an unpacking's copy, the menu's line), played from the script of buttons in +keys+ where a
 * test names one, and its answer written to +result+; +fast+ for an unpacking. Whether it ended
 * well. The player closing the window ends the program, and the part with it. */
static int run_part(const char *name, const char *start_file, const char *keys, const char *result, int fast, int quiet) {
  char *exe = part_file(name);
  if (!exe) return 0;
  /* A part that is stopped writes no answer, so the answer of the part before it must not be left
   * there to be read as this one's. */
  SDL_RemovePath(result);
  const char *args[8];
  int count = 0;
  args[count++] = exe;
  args[count++] = "--part";
  args[count++] = result;
  if (start_file) {
    args[count++] = "--data-pack";
    args[count++] = start_file;
  }
  if (fast) args[count++] = "--part-fast";
  args[count] = NULL;

  /* Its pictures come up its standard output and its buttons go down its standard input, both
   * pipes of this program's; what it complains of goes where this program's complaints go. */
  SDL_PropertiesID properties = SDL_CreateProperties();
  SDL_SetPointerProperty(properties, SDL_PROP_PROCESS_CREATE_ARGS_POINTER, (void *)args);
  SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, SDL_PROCESS_STDIO_APP);
  SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, SDL_PROCESS_STDIO_APP);
  SDL_SetNumberProperty(properties, SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, SDL_PROCESS_STDIO_INHERITED);
  SDL_Process *process = SDL_CreateProcessWithProperties(properties);
  SDL_DestroyProperties(properties);
  int ok = 0;
  if (process) {
    ok = shell_window->show_part(process, fast, keys);
    SDL_DestroyProcess(process);
  } else {
    fprintf(stderr, "%s: the part %s cannot be started (%s)\n", rg_shell_facts->title, exe, SDL_GetError());
  }
  SDL_free(exe);
  if (!ok) tell_part_fault(result, quiet);
  /* A part writes its answer beside the file and moves it into place (rg_sdl.c's write_part_result);
   * one stopped as it wrote leaves the half it had written, which goes here. */
  char *writing = NULL;
  if (SDL_asprintf(&writing, "%s.writing", result) >= 0) SDL_RemovePath(writing);
  SDL_free(writing);
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

/* --- what a test picks in place of the file dialog --- */

/* A TEST'S PICKS (--shell-picks FILE): a line for each time LOAD ROM asks for the copy, in order.
 * A line holding a path is that file or folder picked; an empty line is the dialog closed with
 * nothing picked. +next+ is the line the next ask takes. */
typedef struct {
  char *lines; /* the file's text, each line's end made the end of a string as it is taken */
  char *next;  /* NULL once every line is taken */
} rg_shell_picks;

/* The next pick: 1 with it in +picked+ (freed with SDL_free; NULL for nothing picked), or 0 when
 * the test's picks have run out. */
static int take_pick(rg_shell_picks *picks, char **picked) {
  if (!picks->next || !*picks->next) return 0;
  char *line = picks->next;
  char *end = strchr(line, '\n');
  picks->next = end ? end + 1 : NULL;
  if (end) *end = '\0';
  size_t length = strlen(line);
  if (length && line[length - 1] == '\r') line[length - 1] = '\0';
  *picked = *line ? SDL_strdup(line) : NULL;
  return 1;
}

/* --- the flow --- */

/* The last part of +path+, what the player calls the file or the folder, a separator at its end
 * left out; freed with SDL_free. */
static char *file_name_of(const char *path) {
  char *trimmed = SDL_strdup(path);
  if (!trimmed) return NULL;
  size_t length = strlen(trimmed);
  while (length > 1 && (trimmed[length - 1] == '/' || trimmed[length - 1] == '\\')) trimmed[--length] = '\0';
  const char *name = trimmed;
  for (const char *c = trimmed; *c; c++) {
    if (*c == '/' || *c == '\\') name = c + 1;
  }
  char *copy = SDL_strdup(name);
  SDL_free(trimmed);
  return copy;
}

/* Whether the pack kept at +path+ passes the check: 1, or 0, the player told why when a file is there
 * (in a box unless +quiet+). */
static int kept_pack_passes(const char *path, int quiet) {
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
  tell(words, quiet);
  return 0;
}

/* The bytes of the file at +path+ (called +named+), or NULL with why in +words+. */
static uint8_t *read_picked(const char *path, const char *named, size_t *size, char *words) {
  uint8_t *bytes = SDL_LoadFile(path, size);
  if (bytes) return bytes;
  const char *names[] = {"named", "why"};
  const char *values[] = {named, SDL_GetError()};
  rg_words_fill(words, RG_WORDS_ROOM, rg_shell_facts->unreadable_words, 2, names, values);
  return NULL;
}

/* The copy at the file +path+ (called +named+), checked: its bytes, with the release it is in +release+
 * and its SHA-1 in +sha1+; or NULL with why in +words+. */
static uint8_t *copy_from_file(const char *path, const char *named, size_t *size, const rg_shell_release **release, char *sha1,
                               char *words) {
  const rg_shell_description *shell = rg_shell_facts;
  if (*shell->one_file_words) {
    const char *names[] = {"named"};
    const char *values[] = {named};
    rg_words_fill(words, RG_WORDS_ROOM, shell->one_file_words, 1, names, values);
    return NULL;
  }
  uint8_t *bytes = read_picked(path, named, size, words);
  if (!bytes) return NULL;
  if (!rg_shell_size_refusal(named, (int32_t)*size, words)) {
    rg_sha1_hex(bytes, *size, sha1);
    if (!rg_shell_digest_refusal(named, sha1, release, words)) return bytes;
  }
  SDL_free(bytes);
  return NULL;
}

/* The copy that is the folder +path+ (called +named+), of a release that is several files: each file
 * the release names found in it without regard to case and checked, and the files joined in the
 * release's order. Nothing else in the folder is read. Its bytes, with the release in +release+ and
 * its SHA-1 in +sha1+; or NULL with why in +words+. */
static uint8_t *copy_from_folder(const char *path, const char *named, size_t *size, const rg_shell_release **release, char *sha1,
                                 char *words) {
  int count = 0;
  char **names = list_files_in(path, &count);
  const rg_shell_release *found = release_in_folder(names, count);
  if (!found) {
    lacking_refusal(named, names, count, words);
    free_names(names, count);
    return NULL;
  }
  uint8_t *bytes = SDL_malloc(found->size > 0 ? (size_t)found->size : 1);
  size_t at = 0;
  for (int f = 0; bytes && f < found->file_count; f++) {
    const rg_shell_file *wanted = &found->files[f];
    char *file_path = path_in_folder(path, file_in(names, count, wanted->name));
    char *file_named = path_in_folder(named, wanted->name);
    size_t file_size = 0;
    uint8_t *file_bytes = file_path ? read_picked(file_path, file_named, &file_size, words) : NULL;
    char file_sha1[41] = "";
    if (file_bytes) rg_sha1_hex(file_bytes, file_size, file_sha1);
    int right = file_bytes && file_size == (size_t)wanted->size && strcmp(file_sha1, wanted->sha1) == 0;
    if (file_bytes && !right) {
      char want_size[16], got_size[16];
      snprintf(want_size, sizeof want_size, "%d", (int)wanted->size);
      snprintf(got_size, sizeof got_size, "%zu", file_size);
      const char *keys[] = {"named", "release", "want_size", "want_sha1", "size", "sha1"};
      const char *values[] = {file_named, found->name, want_size, wanted->sha1, got_size, file_sha1};
      rg_words_fill(words, RG_WORDS_ROOM, rg_shell_facts->wrong_file_words, 6, keys, values);
    }
    if (right) memcpy(bytes + at, file_bytes, file_size);
    at += file_size;
    SDL_free(file_bytes);
    SDL_free(file_path);
    SDL_free(file_named);
    if (!right) {
      SDL_free(bytes);
      bytes = NULL;
    }
  }
  free_names(names, count);
  if (!bytes) return NULL;
  *size = at;
  *release = found;
  SDL_strlcpy(sha1, found->sha1, 41);
  return bytes;
}

/* The pack made from the copy at +copy+ (a file, or a folder for a release that is several files,
 * called +named+), read once, checked, and unpacked by its release's part; written to +pack_path+. 1
 * when it is written, else 0, the player told why. */
static int make_pack(const char *copy, const char *named, const char *pack_path, const char *result, int quiet) {
  const rg_shell_description *shell = rg_shell_facts;
  size_t size = 0;
  char words[RG_WORDS_ROOM] = "";
  const rg_shell_release *release = NULL;
  char sha1[41];
  uint8_t *copy_bytes = is_folder(copy) ? copy_from_folder(copy, named, &size, &release, sha1, words)
                                        : copy_from_file(copy, named, &size, &release, sha1, words);
  if (!copy_bytes) {
    if (*words) tell(words, quiet);
    return 0;
  }

  /* The unpacking is handed the bytes that were checked, written beside the pack where only this
   * program writes, never the player's file again: that file could change between the two reads,
   * and the unpacking checks only a copy's size. (The unpacking checking the SHA-1 itself would put a
   * SHA-1 into every runtime's check of a start file, for this one use.) */
  char *checked = NULL;
  int handed = SDL_asprintf(&checked, "%s.copy", pack_path) >= 0 && SDL_SaveFile(checked, copy_bytes, size);
  SDL_free(copy_bytes);
  int unpacked = handed && run_part(release->part, checked, NULL, result, 1, quiet);
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

/* A file of this program's own beside the pack, at +path+ (from SDL_asprintf, or NULL), removed and
 * its name freed. */
static void forget_file(char *path) {
  if (path) SDL_RemovePath(path);
  SDL_free(path);
}

/* The pack's path while rg_shell_pack_path is making it, and the endings of the files it and its
 * parts write beside it on the way: the checked copy an unpacking is handed, the menu's start file,
 * a part's answer, the answer as it is being written, and the words of a part's fault. */
static const char *pack_being_made;
static const char *const WORKING_FILE_ENDINGS[] = {".copy", ".menu", ".answer", ".answer.writing", ".answer.fault"};

void rg_shell_remove_working_files(void) {
  if (!pack_being_made) return;
  for (size_t i = 0; i < sizeof WORKING_FILE_ENDINGS / sizeof WORKING_FILE_ENDINGS[0]; i++) {
    char *path = NULL;
    if (SDL_asprintf(&path, "%s%s", pack_being_made, WORKING_FILE_ENDINGS[i]) >= 0) forget_file(path);
  }
}

/* The copy LOAD ROM asks for, the +asks+th time it asks (from 1): 1 with its path in +picked+ (freed
 * with SDL_free; NULL when nothing was picked), or 0 when a test's picks have run out, which ends
 * the shell as the player closing the window does. A person picks in the system's dialog, on the
 * window; a test names the copy (--shell-copy) or each pick in turn (--shell-picks). A test that
 * asks for it gets the window as it stands when the dialog would open (--shell-pick-pictures). */
static int ask_for_copy(const rg_shell_asked *asked, rg_shell_picks *picks, int asks, char **picked) {
  if (asked->pick_pictures) {
    char *picture = NULL;
    if (SDL_asprintf(&picture, "%s.%d.bmp", asked->pick_pictures, asks) >= 0) shell_window->save_picture(picture);
    SDL_free(picture);
  }
  if (asked->copy) {
    *picked = SDL_strdup(asked->copy);
    return 1;
  }
  if (asked->picks) return take_pick(picks, picked);
  *picked = shell_window->pick_copy(copy_is_folder());
  return 1;
}

char *rg_shell_pack_path(const rg_shell_asked *asked, const rg_shell_window *window) {
  const rg_shell_description *shell = rg_shell_facts;
  shell_window = window;
#ifndef _WIN32
  /* A part that ends while this program is writing its buttons to it must not end this program
   * too, which is what a write to a closed pipe does unless the signal for it is ignored. A part
   * starts with it ignored as well, and ends itself when a picture it sends cannot be written. */
  signal(SIGPIPE, SIG_IGN);
#endif
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

  int quiet = asked->copy != NULL || asked->picks != NULL;
  if (kept_pack_passes(pack_path, quiet)) {
    SDL_free(result);
    return pack_path;
  }
  pack_being_made = pack_path;
  rg_shell_picks picks = {NULL, NULL};
  if (asked->picks) picks.next = picks.lines = SDL_LoadFile(asked->picks, NULL);
  /* SETTINGS opens the window's menu, where the settings are, and plays the menu again under it.
   * The menu is handed the line its cursor starts on as its start file, one byte, and its answer
   * says the line it was left on, so a menu played again comes back as it was left. */
  int settings_open = 0;
  int asks = 0;
  int32_t line = 0;
  char *menu_start = NULL;
  if (SDL_asprintf(&menu_start, "%s.menu", pack_path) < 0) menu_start = NULL;
  for (;;) {
    int32_t choice = 0;
    size_t answer_size = 0;
    const char *keys = settings_open && asked->settings_keys ? asked->settings_keys : asked->menu_keys;
    uint8_t start_line = (uint8_t)line;
    int played = menu_start && SDL_SaveFile(menu_start, &start_line, 1) && run_part(shell->menu_part, menu_start, keys, result, 0, quiet);
    char *answer = played ? SDL_LoadFile(result, &answer_size) : NULL;
    if (!answer || !result_variable(answer, shell->choice_variable, &choice)) {
      SDL_free(answer);
      break; /* the menu stopped with no line chosen */
    }
    result_variable(answer, shell->line_variable, &line);
    SDL_free(answer);
    settings_open = choice == shell->settings;
    if (settings_open) window->open_settings();
    if (choice != shell->load_rom) continue;

    char *picked = NULL;
    if (!ask_for_copy(asked, &picks, ++asks, &picked)) break;
    if (!picked) continue;
    char *named = file_name_of(picked);
    int made = named && make_pack(picked, named, pack_path, result, quiet);
    SDL_free(named);
    SDL_free(picked);
    if (made) {
      rg_shell_remove_working_files();
      pack_being_made = NULL;
      SDL_free(menu_start);
      SDL_free(picks.lines);
      SDL_free(result);
      return pack_path;
    }
    if (asked->copy) {
      /* A test names one copy; asking again would ask for it for ever. */
      rg_shell_remove_working_files();
      exit(2);
    }
  }
  rg_shell_remove_working_files();
  pack_being_made = NULL;
  SDL_free(menu_start);
  SDL_free(picks.lines);
  SDL_free(result);
  SDL_free(pack_path);
  return NULL;
}
