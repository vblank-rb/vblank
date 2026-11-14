/*
 * The runtime with no window: what the tests run a game against.
 *
 *   ./game --headless FRAMES [options] < buttons   (the program a player runs)
 *   ./game FRAMES [options] < buttons              (a test build, which has no window)
 *
 * plays FRAMES frames and stops at the start of the next one, the way the interpreter's
 * run(program, frames: FRAMES) does. Each line of standard input is the buttons held during one
 * frame, as a number with a bit per button (bit 0 is a, in the order rg_runtime.h lists them);
 * a missing line holds nothing.
 *
 * At every frame boundary it prints "frame N", every variable as "var name value", every list as
 * "list name" and its items (see headless_dump_list), every sprite
 * the game last drew as "sprite" and four numbers (see print_sprites), what the mixer made and is
 * playing for a game that mixes recordings (see print_mix), and where the window sits over the
 * picture as "camera X Y", then "buttons?",
 * and only then reads that frame's line. So whoever is feeding it can answer from what the game
 * has done so far — a test that presses a button only once the game has reached somewhere — or
 * write every line up front and ignore the question. That is the order the interpreter asks its
 * own input script in, after the frame before has finished.
 *
 * At the end it prints "end", every variable and every sprite the same way, and the picture as
 * shown: "picture" and every pixel, row by row, as four hex digits — and then the same page as
 * it is stored ("stored"), with no window moved over it and no fade mixed in, how many times the
 * whole view was built again ("repaints"), and how many pages
 * the screen has ("pages", 2 for a tear-free one). A frame's moment carries only a check number
 * of its picture ("picture-crc"), or with --every-picture the whole picture, for a test that
 * compares every frame pixel by pixel. Without it a frame is a few lines rather than a hundred
 * and fifty thousand characters, which is what lets a long run be driven a frame at a time.
 *
 * The options are --every-picture, and the eight below.
 *
 * With --start-file FILE the game is handed FILE as it starts (rg_start_file_read): the data pack
 * of a game built with its pack left out, or the copy of the original its unpacking reads. A game
 * that reads such a file and is handed none stops at its first statement, with a sentence naming
 * the file it lacks.
 *
 * With --clock-at SECONDS TICKS SET the cartridge has a clock, which reads SECONDS from the start
 * of 1970 and TICKS of the console's 2^24 a second more at power-on, and was set when SET is 1
 * (rg_clock_starts_at). Without it the cartridge has no clock.
 *
 * With --held-from-power-on MASK the buttons in MASK (bits as on standard input) are down before
 * the game's first statement, as a button held through the whole run is in the interpreter; the
 * first frame's line still says what is held from then on.
 *
 * With --save FILE the game starts with the save memory FILE holds (rg_save.h: the bytes of a
 * .sav file, as many as the game has save memory), and when the run ends the save memory is
 * written back to FILE, whole, over what was there. No file there yet is a new cartridge. A game
 * with no save memory reads and writes nothing. And with --save-cut-after N the power goes off
 * N steps into the game's saving, which ends the run there, as it does in the interpreter.
 *
 * With --sound-out FILE the sound of every frame played is written to FILE as it is made: one
 * speaker's worth, RG_SOUND_RATE numbers a second, each two bytes with the low byte first. And
 * with --sound-voice N only voice N is in it, by the console's count of its voices (1 and 2 the
 * square voices, 3 the wave voice, 4 the noise voice), which is how a test hears one voice at a
 * time.
 *
 * With --picture-out FILE the picture of every moment is written to FILE, over the one before:
 * every pixel as shown and then every pixel as stored, row by row, each two bytes with the low
 * byte first, and for a game shown in a border then every pixel of the whole screen as the window
 * shows it (rg_screen_framed). It is there before "buttons?" is asked, so whoever is feeding the buttons can read
 * that frame's picture, and need not when it has no use for it. The end then prints its
 * picture as a check number too, since the picture itself is in the file. A picture is far more
 * than a pipe holds at once, and a reader that takes it a pipeful at a time waits its turn for
 * each; a file is read in one go.
 *
 * With --state-out FILE --state-out-after N the whole state (rg_state.h) is written to FILE at the
 * frame boundary after frame N, before the next frame begins. With --state-in FILE the state FILE
 * holds is read in at the first frame boundary, after the game's first pass and before its second
 * frame begins, so the run goes on from there: its frame 1 is the frame after the one the state was
 * written at.
 *
 * With --final-state FILE nobody watches the run (Native::FinalStateRun): it plays as fast as the
 * computer goes to its halt, or to the end of FRAMES, printing nothing of each frame and reading
 * no buttons, and makes no sound. At the end it writes FILE: every variable as "var name value",
 * a line each, then every list as "list", its name, a tab, its width in bytes and its count, a
 * line's end, and then its items oldest first, each in its width with the low byte first. What a
 * build plays this way is a port's unpacking, whose pack is one list of millions of bytes, which
 * as printed numbers would be several times its size. With --list-file NAME PATH as well, the
 * list called NAME is left out of FILE and its items alone, written the same way, are added to
 * the end of PATH: a build hands the file it wants the pack in, already holding the pack's
 * header, and the pack's bytes go straight there (Original::Unpacking#write_pack_as_c), never
 * through the reader. So that a stuck routine can be told from a
 * long one, it prints one "." on standard output at a frame boundary, at most every
 * DOT_EVERY_CLOCKS of the processor's time, and the reader stops a run that has printed none
 * for a while.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "rg_driver.h"
#include "rg_list.h"
#include "rg_runtime.h"
#include "rg_save.h"
#include "rg_screen.h"
#include "rg_sound.h"
#include "rg_state.h"

static long frames_to_play;
static long frame; /* frames started so far */
static int every_picture; /* print the picture at every frame, not only at the end */
static int asked;         /* say nothing between frames but what is asked (see answer_until_buttons) */
static const char *asked_name; /* the one variable or list being asked about just now */
static FILE *sound_out;   /* where each frame's sound is written, if anywhere */
static FILE *picture_out; /* where each moment's picture is written, if anywhere */
static const char *save_path; /* the file save memory is read from and written back to, if any */
static const char *state_out_path; /* where the state is written, if anywhere... */
static long state_out_after = -1;  /* ...at the boundary after this frame */
static char *state_in;             /* the state read in at the first boundary, until it is */
static const char *final_state_path; /* where a run nobody watches writes its variables and lists */
static FILE *final_state;            /* ...open while they are written */
static clock_t last_dot_clock;       /* when such a run last printed a "." to show it is not stuck */
static const char *list_file_name;   /* the list such a run adds to a file of its own... */
static const char *list_file_path;   /* ...and that file */

/* The whole of the file at +path+ as text, or NULL where it cannot be read. */
static char *read_text_file(const char *path) {
  FILE *file = fopen(path, "rb");
  if (!file) return NULL;
  char *text = NULL;
  size_t size = 0, room = 0;
  for (;;) {
    if (size + 1 >= room) {
      room = room ? room * 2 : 65536;
      char *grown = realloc(text, room);
      if (!grown) {
        free(text);
        fclose(file);
        return NULL;
      }
      text = grown;
    }
    size_t got = fread(text + size, 1, room - size - 1, file);
    size += got;
    if (got == 0) break;
  }
  fclose(file);
  text[size] = '\0';
  return text;
}

/* The state written or read at this frame boundary, as the options asked. */
static void state_at_boundary(void) {
  if (state_in) {
    rg_state_read(state_in);
    free(state_in);
    state_in = NULL;
  }
  if (!state_out_path || frame != state_out_after) return;
  FILE *out = fopen(state_out_path, "wb");
  if (!out) {
    fprintf(stderr, "the state could not be written to %s\n", state_out_path);
    exit(1);
  }
  rg_state_write(out);
  fclose(out);
}

/* Save memory as the file holds it, and whether that went well. No file is a new cartridge; a
 * file of any other size than the game's save memory is somebody else's save. */
static int read_save_file(void) {
  FILE *file = fopen(save_path, "rb");
  if (!file) return 1;
  size_t size = (size_t)rg_save_size();
  int whole = fread(rg_save_bytes(), 1, size, file) == size && fgetc(file) == EOF;
  fclose(file);
  return whole;
}

/* Puts the file at +from+ where +to+ is, in place of any file there. C's rename does that in one
 * step everywhere but on Windows, where it refuses while the old file is there; so the old file is
 * taken away and the rename tried once more. (The window's own save goes through SDL, whose
 * renaming replaces a file on every system.) */
static int put_file_in_place(const char *from, const char *to) {
  if (rename(from, to) == 0) return 1;
  remove(to);
  return rename(from, to) == 0;
}

/* Save memory written to its file: to a new file beside it, which then takes its place, so a
 * run stopped part way through leaves the old file whole. */
static void write_save_file(void) {
  size_t size = (size_t)rg_save_size();
  size_t room = strlen(save_path) + sizeof ".writing";
  char *writing = malloc(room);
  int written = 0;
  if (writing) {
    snprintf(writing, room, "%s.writing", save_path);
    FILE *file = fopen(writing, "wb");
    written = file && fwrite(rg_save_bytes(), 1, size, file) == size;
    if (file && fclose(file) != 0) written = 0;
    if (written && !put_file_in_place(writing, save_path)) written = 0;
    free(writing);
  }
  if (written) return;
  fprintf(stderr, "the save memory could not be written to %s\n", save_path);
  exit(1);
}

/* The sound of the frame that has just been played, written down: a sample of the left speaker,
 * then the right's at the same moment, and so on. A machine that keeps its numbers the other way
 * round would write them the other way round; every machine this is built for keeps the low byte
 * first. */
static void write_frame_sound(void) {
  int16_t left[RG_SOUND_FRAME_MOST], right[RG_SOUND_FRAME_MOST], both[2 * RG_SOUND_FRAME_MOST];
  int32_t count = rg_sound_render_frame(left, right);
  for (int32_t i = 0; i < count; i++) {
    both[2 * i] = left[i];
    both[(2 * i) + 1] = right[i];
  }
  if (!sound_out) return;
  fwrite(both, sizeof both[0], (size_t)(2 * count), sound_out);
  fflush(sound_out); /* a speaker reads it as the game plays */
}

/* A whole picture as one line: +word+ and then every pixel, row by row, as four hex digits. */
static void print_pixels(const char *word, const uint16_t *pixels) {
  printf("%s ", word);
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) printf("%04x", (unsigned)pixels[i]);
  fputc('\n', stdout);
}

/* The picture as it is +shown+, as one number: the CRC-32 of its pixels, each as two bytes with the
 * low byte first — the CRC zip files use, which Ruby's Zlib.crc32 works out from the same bytes.
 * Two pictures with the same number are, in practice, the same picture, so a test can check
 * every frame for eight hex digits apiece and ask for the whole picture only where they differ. */
static void print_picture_crc(const uint16_t *shown) {
  uint32_t crc = 0xFFFFFFFFu;
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) {
    for (int half = 0; half < 2; half++) {
      crc ^= (uint32_t)((shown[i] >> (8 * half)) & 0xFFu);
      for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  printf("picture-crc %08x\n", (unsigned)~crc);
}

/* This moment's picture written to the picture file, over the last moment's: as it is +shown+,
 * then as it is stored. Like the sound, it is written the way this machine keeps a number, and
 * every machine this is built for keeps the low byte first. */
static void write_picture(const uint16_t *shown) {
  size_t pixels = (size_t)RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT;
  rewind(picture_out);
  fwrite(shown, sizeof shown[0], pixels, picture_out);
  fwrite(rg_screen_stored(), sizeof shown[0], pixels, picture_out);
#if RG_SCREEN_BORDERED
  fwrite(rg_screen_framed(), sizeof shown[0], (size_t)RG_WHOLE_WIDTH * RG_WHOLE_HEIGHT, picture_out);
#endif
  fflush(picture_out);
}

/* Every sprite the game last put on screen, back to front, a line each: whose it is and which
 * picture it shows, both as the number of a name the game was built with, and where it is. */
static void print_sprites(void) {
  for (int32_t place = 0; place < rg_screen_drawn_count(); place++) {
    rg_drawn_sprite drawn = rg_screen_drawn_sprite(place);
    printf("sprite %d %d %d %d\n", (int)drawn.name, (int)drawn.picture, (int)drawn.x, (int)drawn.y);
  }
}

static void print_moment(const char *heading, int with_picture) {
  printf("%s\n", heading);
  rg_game_dump_state();
  print_sprites();
  rg_sound_print_moment(); /* a game's mix prints here, when it has one */
  printf("camera %d %d\n", (int)rg_screen_camera_x(), (int)rg_screen_camera_y());
  printf("motor %d\n", (int)rg_motor_on());
  const uint16_t *shown = rg_screen_shown();
  if (with_picture) {
    print_pixels("picture", shown);
  } else {
    print_picture_crc(shown);
  }
  if (picture_out) write_picture(shown);
}

static _Noreturn void finish(void) {
  print_moment("end", !picture_out);
  if (!picture_out) print_pixels("stored", rg_screen_stored());
  printf("repaints %d\npages %d\n", (int)rg_screen_repaints_painted(), rg_screen_two_pages() ? 2 : 1);
  fflush(stdout);
  if (sound_out) fclose(sound_out);
  if (picture_out) fclose(picture_out);
  if (save_path) write_save_file();
  exit(0);
}

/* A line of buttons, one number for each connected player, the first player's first
 * (IR::Buttons.masks), handed to +read+. */
static void read_players(const char *line, void (*read)(int32_t, const uint32_t *)) {
  uint32_t masks[RG_MOST_PLAYERS];
  int32_t count = 0;
  char *end;
  for (const char *at = line; count < RG_MOST_PLAYERS; at = end) {
    unsigned long mask = strtoul(at, &end, 10);
    if (end == at) break;
    masks[count++] = (uint32_t)mask;
  }
  read(count, masks);
}

/* The buttons for the frame that is starting: the next line of standard input. */
static void read_buttons(void) {
  char line[1024];
  read_players(fgets(line, sizeof line, stdin) ? line : "", rg_players_read);
}

/* ASKED: the game prints nothing of itself between frames, and says what it holds when asked. Printing
 * everything each frame is what a run read frame by frame wants, and for a game with long lists
 * reading that back is most of the run. So here each frame says only that it wants its buttons, and
 * until they come a line "? name" is answered with that variable or list, and "*" with all of them,
 * then a ".". */
static void answer_until_buttons(void) {
  char line[1024];
  printf("frame %ld\nbuttons?\n", frame);
  fflush(stdout);
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] != '?' && line[0] != '*') {
      read_players(line, rg_players_read);
      return;
    }
    line[strcspn(line, "\n")] = '\0';
    asked_name = line[0] == '?' ? line + 2 : NULL;
    rg_game_dump_state();
    asked_name = NULL;
    puts(".");
    fflush(stdout);
  }
  finish();
}

static void headless_wait_vblank(void) {
  state_at_boundary();
  if (asked) {
    if (frame >= frames_to_play) finish();
    rg_frame_begins();
    frame++;
    answer_until_buttons();
    return;
  }
  write_frame_sound();
  if (frame >= frames_to_play) finish();
  rg_frame_begins();
  frame++;
  char heading[32];
  snprintf(heading, sizeof heading, "frame %ld", frame);
  print_moment(heading, every_picture);
  puts("buttons?");
  fflush(stdout);
  read_buttons();
}

static void headless_halt(void) { finish(); }

/* Said on the error stream, and the run ends badly, which is how a test sees it. */
static void headless_fault(const char *format, va_list args) {
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  exit(RG_GAME_WENT_WRONG);
}

/* "var" first, so no name a game gives a variable can be read as one of the other lines: a game
 * may well call one `frame`, or `picture`. */
static void headless_dump_variable(const char *name, int32_t value) {
  if (asked_name && strcmp(name, asked_name) != 0) return;
  printf("var %s %d\n", name, (int)value);
}

/* "sound" first, for the same reason a variable's line starts with "var"; printed as it happens,
 * among the frames, so a test reading the log mid-run sees it up to the frame it is on. */
static void headless_sound_logged(const char *line) { printf("sound %s\n", line); }

/* "list", the game's name for it, a tab, and its items oldest first — the order the game reads
 * them in, which in a list the game shifts is not the order they sit in memory. A pool's fields
 * come this way too, a slot an item, under the names the build gave them. The tab ends the name,
 * since a pool's field may be called anything, spaces and all. */
static void headless_dump_list(const rg_list *list) {
  if (asked_name && strcmp(list->name, asked_name) != 0) return;
  printf("list %s\t", list->name);
  for (int32_t i = 0; i < list->length; i++) printf(i ? " %d" : "%d", (int)rg_list_load(list, rg_list_slot(list, i)));
  fputc('\n', stdout);
}

static const rg_driver headless = {headless_wait_vblank, headless_halt, headless_fault, headless_dump_variable,
                                   headless_sound_logged, headless_dump_list};

/* --- a run nobody watches (--final-state) --- */

/* How much of the processor's time goes by between two "."s at most: a tenth of a second. */
#define DOT_EVERY_CLOCKS (CLOCKS_PER_SEC / 10)

/* Every variable and list written to the final state's file, and the run ended. */
static _Noreturn void finish_final_state(void) {
  final_state = fopen(final_state_path, "wb");
  if (!final_state) {
    fprintf(stderr, "the final state could not be written to %s\n", final_state_path);
    exit(1);
  }
  rg_game_dump_state();
  if (fclose(final_state) != 0) {
    fprintf(stderr, "the final state could not be written to %s\n", final_state_path);
    exit(1);
  }
  exit(0);
}

static void final_state_wait_vblank(void) {
  if (frame >= frames_to_play) finish_final_state();
  rg_frame_begins();
  frame++;
  clock_t now = clock();
  if (now - last_dot_clock < DOT_EVERY_CLOCKS) return;
  last_dot_clock = now;
  fputc('.', stdout);
  fflush(stdout);
}

static void final_state_halt(void) { finish_final_state(); }

static void final_state_dump_variable(const char *name, int32_t value) { fprintf(final_state, "var %s %d\n", name, (int)value); }

static void final_state_sound_logged(const char *line) { (void)line; }

/* The items of +list+, oldest first, each in its width with the low byte first, written to +out+.
 * A list of bytes is already that in memory, so it goes as the one or two runs of its ring; a
 * wider one goes through a buffer of whole items, since a pack's list holds millions of them. */
static void write_list_items(const rg_list *list, FILE *out) {
  if (list->width == 1) {
    const int8_t *items = list->items;
    int32_t first_run = list->capacity - list->front;
    if (first_run > list->length) first_run = list->length;
    fwrite(items + list->front, 1, (size_t)first_run, out);
    fwrite(items, 1, (size_t)(list->length - first_run), out);
    return;
  }
  unsigned char buffer[4096];
  size_t width = (size_t)list->width, held = 0;
  for (int32_t i = 0; i < list->length; i++) {
    uint32_t item = (uint32_t)rg_list_load(list, rg_list_slot(list, i));
    for (size_t byte = 0; byte < width; byte++) buffer[held++] = (unsigned char)((item >> (8 * byte)) & 0xFFu);
    if (held + width > sizeof buffer) {
      fwrite(buffer, 1, held, out);
      held = 0;
    }
  }
  fwrite(buffer, 1, held, out);
}

/* The list --list-file names: its items added to the end of its file. */
static void append_list_file(const rg_list *list) {
  FILE *out = fopen(list_file_path, "ab");
  int failed = !out;
  if (out) {
    write_list_items(list, out);
    failed = ferror(out);
    if (fclose(out) != 0) failed = 1;
  }
  if (failed) {
    fprintf(stderr, "the list %s could not be written to %s\n", list->name, list_file_path);
    exit(1);
  }
}

static void final_state_dump_list(const rg_list *list) {
  if (list_file_name && strcmp(list->name, list_file_name) == 0) {
    append_list_file(list);
    return;
  }
  fprintf(final_state, "list %s\t%d %d\n", list->name, (int)list->width, (int)list->length);
  write_list_items(list, final_state);
}

static const rg_driver final_state_driver = {final_state_wait_vblank, final_state_halt, headless_fault, final_state_dump_variable,
                                             final_state_sound_logged, final_state_dump_list};

int rg_headless_main(int argc, char **argv) {
  if (argc < 2) {
    fputs("give the number of frames to play, and the buttons for each frame on standard input\n", stderr);
    return 2;
  }
  frames_to_play = strtol(argv[1], NULL, 10);
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--every-picture") == 0) {
      every_picture = 1;
    } else if (strcmp(argv[i], "--asked") == 0) {
      asked = 1;
    } else if (strcmp(argv[i], "--sound-out") == 0 && i + 1 < argc) {
      sound_out = fopen(argv[++i], "wb");
      if (!sound_out) {
        fprintf(stderr, "the sound could not be written to %s\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--picture-out") == 0 && i + 1 < argc) {
      picture_out = fopen(argv[++i], "wb");
      if (!picture_out) {
        fprintf(stderr, "the picture could not be written to %s\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--sound-voice") == 0 && i + 1 < argc) {
      rg_sound_hear_only((int32_t)strtol(argv[++i], NULL, 10));
    } else if (strcmp(argv[i], "--save") == 0 && i + 1 < argc) {
      i++;
      if (rg_save_size() == 0) continue; /* a game with no save memory keeps nothing there */
      save_path = argv[i];
      if (!read_save_file()) {
        fprintf(stderr, "the file at %s is not this game's save memory, which is %d bytes\n", save_path, (int)rg_save_size());
        return 2;
      }
    } else if (strcmp(argv[i], "--save-cut-after") == 0 && i + 1 < argc) {
      rg_save_cut_power_after(strtol(argv[++i], NULL, 10));
    } else if (strcmp(argv[i], "--held-from-power-on") == 0 && i + 1 < argc) {
      read_players(argv[++i], rg_players_held_from_power_on);
    } else if (strcmp(argv[i], "--clock-at") == 0 && i + 3 < argc) {
      int64_t seconds = strtoll(argv[++i], NULL, 10);
      int64_t ticks = strtoll(argv[++i], NULL, 10);
      rg_clock_starts_at(seconds, ticks, (int32_t)strtol(argv[++i], NULL, 10));
    } else if (strcmp(argv[i], "--state-out") == 0 && i + 1 < argc) {
      state_out_path = argv[++i];
    } else if (strcmp(argv[i], "--state-out-after") == 0 && i + 1 < argc) {
      state_out_after = strtol(argv[++i], NULL, 10);
    } else if (strcmp(argv[i], "--state-in") == 0 && i + 1 < argc) {
      state_in = read_text_file(argv[++i]);
      if (!state_in) {
        fprintf(stderr, "the state at %s could not be read\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--start-file") == 0 && i + 1 < argc) {
      if (!rg_start_file_read(argv[++i])) {
        fprintf(stderr, "the file at %s could not be read\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--final-state") == 0 && i + 1 < argc) {
      final_state_path = argv[++i];
    } else if (strcmp(argv[i], "--list-file") == 0 && i + 2 < argc) {
      list_file_name = argv[++i];
      list_file_path = argv[++i];
    }
  }
  if (final_state_path) {
    rg_active_driver = &final_state_driver;
    last_dot_clock = clock();
    rg_play_frames();
    finish_final_state();
  }
  rg_active_driver = &headless;
  rg_play_frames();
  finish();
}
