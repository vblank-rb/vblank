/*
 * The state image (rg_state.h): written by visiting every field, and read by visiting every field
 * again with the image's numbers to hand.
 */
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include "rg_console.h"
#include "rg_runtime.h"
#include "rg_state.h"

/* The save-state file's version and this build (Computer::StateFile, written beside game.c). A
 * file of the runtime read on its own, as the editor's checker reads it, has neither. */
#ifndef RG_STATE_VERSION
#define RG_STATE_VERSION 1
#define RG_GAME_CONSOLE ""
#define RG_GAME_BUILD ""
#endif

/* An image's field, as read: its name, its numbers, and whether a part has taken it yet. */
typedef struct {
  char *name;
  int32_t count;
  int64_t *values;
  int taken;
} read_field;

static FILE *writing_to;     /* where the image is going, while it is written */
static read_field *fields;   /* the image being read, while it is */
static int32_t field_count;

static void visit_all(void) {
  rg_game_visit_state();
  rg_runtime_visit_state();
  rg_save_visit_state();
  rg_screen_visit_state();
  rg_sound_visit_state();
}

static int reading;

int rg_state_reading(void) { return reading; }

void rg_state_write(FILE *out) {
  fprintf(out, "vblank-state %d\nbuild %s %s\n", RG_STATE_VERSION, RG_GAME_CONSOLE, RG_GAME_BUILD);
  writing_to = out;
  visit_all();
  writing_to = NULL;
  fflush(out);
}

/* --- reading --- */

static void forget_image(void) {
  for (int32_t i = 0; i < field_count; i++) {
    free(fields[i].name);
    free(fields[i].values);
  }
  free(fields);
  fields = NULL;
  field_count = 0;
}

static void *room_for(size_t bytes) {
  void *room = malloc(bytes ? bytes : 1);
  if (!room) rg_fault("There is no room to read the state.");
  return room;
}

/* Whether +text+ is nothing but spaces from here to its end. */
static int only_spaces(const char *text) {
  while (*text == ' ') text++;
  return *text == '\0';
}

static int field_read_already(const char *name) {
  for (int32_t i = 0; i < field_count; i++)
    if (strcmp(fields[i].name, name) == 0) return 1;
  return 0;
}

/* One line, from +line+ to +end+: "name<TAB>count n1 n2 ...", exactly +count+ numbers, added to the
 * fields. Gives back 0 for a line that is not one, or that names a field already read. The line is
 * copied out first, so the numbers are read from it alone and never run on into the next line. */
static int read_line(const char *line, const char *end) {
  size_t length = (size_t)(end - line);
  char *copy = room_for(length + 1);
  memcpy(copy, line, length);
  copy[length] = '\0';
  char *tab = strchr(copy, '\t');
  int read = 0;
  if (tab) {
    *tab = '\0';
    char *at;
    long count = strtol(tab + 1, &at, 10);
    if (at != tab + 1 && count >= 0 && count <= INT32_MAX && !field_read_already(copy)) {
      int64_t *values = room_for(sizeof(int64_t) * (size_t)count);
      int32_t got = 0;
      int run_well_formed = 1;
      while (got < count) {
        char *from = at;
        int64_t number = strtoll(from, &at, 10);
        if (at == from) break;
        int64_t times = 1;
        if (*at == '*') { /* a run: "times*number" */
          times = number;
          from = at + 1;
          number = strtoll(from, &at, 10);
          if (at == from || *from == ' ' || times < 1 || times > count - got) {
            run_well_formed = 0;
            break;
          }
        }
        for (int64_t i = 0; i < times; i++) values[got++] = number;
      }
      if (run_well_formed && got == count && only_spaces(at)) {
        read_field *grown = realloc(fields, sizeof(read_field) * (size_t)(field_count + 1));
        if (!grown) rg_fault("There is no room to read the state.");
        fields = grown;
        fields[field_count++] = (read_field){room_for(strlen(copy) + 1), (int32_t)count, values, 0};
        strcpy(fields[field_count - 1].name, copy);
        read = 1;
      } else {
        free(values);
      }
    }
  }
  free(copy);
  return read;
}

/* The file's two first lines (Computer::StateFile): its version, then the build that wrote it. The
 * words for why they are not this build's, or NULL when they are, in which case +rest+ is where the
 * image starts. Changes nothing, so a window can ask before it reads. */
static const char *header_problem(const char *text, const char **rest) {
  static char problem[400];
  int version = 0, used = 0;
  if (sscanf(text, "vblank-state %d\n%n", &version, &used) != 1 || used == 0)
    return "This is not a save state: it does not start with \"vblank-state\". Load a state that this game wrote.";
  if (version != RG_STATE_VERSION) {
    snprintf(problem, sizeof problem,
             "This state is version %d of the save-state format, and this build reads version %d. Load a state that this build "
             "wrote.", version, RG_STATE_VERSION);
    return problem;
  }
  text += used;
  char console[32] = "", build[80] = "";
  used = 0;
  if (sscanf(text, "build %31s %79s\n%n", console, build, &used) != 2 || used == 0)
    return "This state is damaged: its second line does not name the build that saved it. Load a state that this game wrote.";
  if (strcmp(console, RG_GAME_CONSOLE) != 0 || strcmp(build, RG_GAME_BUILD) != 0) {
    snprintf(problem, sizeof problem,
             "This state is for another build of the game: build %.8s for the %s saved it, and this is build %.8s for the %s. "
             "Load a state that this build saved.", build, console, RG_GAME_BUILD, RG_GAME_CONSOLE);
    return problem;
  }
  *rest = text + used;
  return NULL;
}

const char *rg_state_header_problem(const char *text) {
  const char *rest;
  return header_problem(text, &rest);
}

/* Each refused in plain words when it is not this build's. Gives back where the image starts. */
static const char *refuse_other_build(const char *text) {
  const char *rest = NULL;
  const char *problem = header_problem(text, &rest);
  if (problem) rg_fault("%s", problem);
  return rest;
}

void rg_state_read(const char *text) {
  forget_image();
  text = refuse_other_build(text);
  for (const char *line = text; *line;) {
    const char *end = strchr(line, '\n');
    if (!end) end = line + strlen(line);
    if (end > line && !read_line(line, end)) {
      forget_image();
      rg_fault("This state is damaged: a line is not a name, a tab, a count and numbers. Load a state that this game wrote.");
    }
    line = *end ? end + 1 : end;
  }
  reading = 1;
  visit_all();
  reading = 0;
  for (int32_t i = 0; i < field_count; i++) {
    if (!fields[i].taken)
      rg_fault("This state is for another game: it holds \"%s\", and this game has none. Load a state that this game wrote.", fields[i].name);
  }
  forget_image();
}

/* The image's field +name+, holding +count+ numbers. */
static read_field *field_named(const char *name, int32_t count) {
  for (int32_t i = 0; i < field_count; i++) {
    if (strcmp(fields[i].name, name) != 0) continue;
    if (fields[i].count != count)
      rg_fault("This state is for another game: it holds %d numbers for \"%s\", and this game keeps %d. Load a state that this "
               "game wrote.", (int)fields[i].count, name, (int)count);
    fields[i].taken = 1;
    return &fields[i];
  }
  rg_fault("This state is for another game: it has no \"%s\". Load a state that this game wrote.", name);
}

/* --- the fields --- */

/* A run of RG_STATE_SHORTEST_RUN or more of one number is written "times*number" (rg_state.h). */
static void write_field(const char *name, const int64_t *values, int32_t count) {
  fprintf(writing_to, "%s\t%d", name, (int)count);
  for (int32_t i = 0; i < count;) {
    int32_t run = 1;
    while (i + run < count && values[i + run] == values[i]) run++;
    if (run >= RG_STATE_SHORTEST_RUN) {
      fprintf(writing_to, " %d*%" PRId64, (int)run, values[i]);
      i += run;
    } else {
      fprintf(writing_to, " %" PRId64, values[i]);
      i++;
    }
  }
  fputc('\n', writing_to);
}

void rg_state_numbers(const char *name, int64_t *values, int32_t count) {
  if (writing_to) {
    write_field(name, values, count);
    return;
  }
  read_field *field = field_named(name, count);
  memcpy(values, field->values, sizeof(int64_t) * (size_t)count);
}

int32_t rg_state_number(const char *name, int32_t value) {
  int64_t held = value;
  rg_state_numbers(name, &held, 1);
  return (int32_t)held;
}

/* Where the oldest item is and how many there are, then every slot, used or not: the ring as it
 * stands, so the game's next push and shift land where they would have. */
void rg_state_list(const char *name, rg_list *list) {
  int32_t count = list->capacity + 2;
  int64_t *values = malloc(sizeof(int64_t) * (size_t)count);
  if (!values) rg_fault("there is no room to write the state");
  values[0] = list->front;
  values[1] = list->length;
  for (int32_t i = 0; i < list->capacity; i++) values[i + 2] = list->items[i];
  rg_state_numbers(name, values, count);
  if (values[0] < 0 || values[0] >= (list->capacity > 0 ? list->capacity : 1) || values[1] < 0 || values[1] > list->capacity)
    rg_fault("This state is damaged: the list \"%s\" has a place outside its %d slots. Load a state that this game wrote.", name,
             (int)list->capacity);
  list->front = (int32_t)values[0];
  list->length = (int32_t)values[1];
  for (int32_t i = 0; i < list->capacity; i++) list->items[i] = rg_list_fit(list, (int32_t)values[i + 2]);
  free(values);
}
