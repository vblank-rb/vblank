/*
 * The window menu (rg_window_menu.h), written again from Live::Menu, line for line: change one and
 * change the other, or test_native_window_menu.rb says where they part.
 */
#include "rg_window_menu.h"

#include <stdio.h>
#include <string.h>
#include "rg_menu_font.h"
#include "rg_window.h"

/* Where the menu is: open or not, the heading whose lines show, the line chosen under it (-1
 * while the bar is), and whether Quit was chosen. */
static int menu_open, quit_chosen, heading, row = -1;
static int picture_width, picture_height;
static int most_scale = RG_WINDOW_SCALE_MOST;

/* The window of the game's variables: the letters typed into it, and the first of the lines they
 * find that it shows. Whether it is open is rg_window.c's (RG_PANEL_VARIABLES). */
#define FILTER_ROOM 64
static char filter[FILTER_ROOM];
static int variables_scroll;

static int clamped(int value, int least, int most) { return value < least ? least : value > most ? most : value; }

void rg_window_menu_reset(int width, int height) {
  menu_open = quit_chosen = heading = 0;
  row = -1;
  picture_width = width;
  picture_height = height;
  most_scale = rg_menu_scale_most;
  filter[0] = '\0';
  variables_scroll = 0;
  rg_window_show_panel(RG_PANEL_VARIABLES, 0);
}

void rg_window_menu_set_most_scale(int most) {
  most_scale = clamped(most, rg_menu_scale_least, rg_menu_scale_most);
}

int rg_window_menu_is_open(void) { return menu_open; }
int rg_window_menu_quit_chosen(void) { return quit_chosen; }

void rg_window_menu_toggle(void) {
  menu_open = !menu_open;
  heading = 0;
  row = -1;
  rg_window_capture_cancel();
}

static const rg_menu_heading *open_lines(void) { return &rg_menu_headings[heading]; }

/* How far a slider goes: the window's size no further than the screen has room for. */
static void limits(const rg_menu_line *line, int *least, int *most) {
  *least = line->least;
  *most = line->most;
  if (line->setting != RG_MENU_SCALE) return;
  if (*least < rg_menu_scale_least) *least = rg_menu_scale_least;
  if (*most > most_scale) *most = most_scale;
}

/* A setting as the menu shows it: rg_window.c's, with the window's size no bigger than fits. */
static int setting_value(rg_menu_setting setting) {
  switch (setting) {
  case RG_MENU_FAST_FORWARD_SPEED:
    return rg_window_fast_speed();
  case RG_MENU_SCALE:
    return clamped(rg_window_scale(), rg_menu_scale_least, most_scale);
  case RG_MENU_FULLSCREEN:
    return rg_window_fullscreen();
  case RG_MENU_VOLUME:
    return rg_window_volume();
  case RG_MENU_MUTED:
    return rg_window_muted();
  case RG_MENU_FRAME_RATE:
    return rg_window_shows_frame_rate();
  case RG_MENU_FRAME_TIME:
    return rg_window_shows_frame_time();
  case RG_MENU_NO_SETTING:
    break;
  }
  return 0;
}

static void set_setting(rg_menu_setting setting, int value) {
  switch (setting) {
  case RG_MENU_FAST_FORWARD_SPEED:
    rg_window_set_fast_speed(value);
    break;
  case RG_MENU_SCALE:
    rg_window_set_scale(value);
    break;
  case RG_MENU_FULLSCREEN:
    rg_window_set_fullscreen(value);
    break;
  case RG_MENU_VOLUME:
    rg_window_set_volume(value);
    break;
  case RG_MENU_MUTED:
    rg_window_set_mute(value);
    break;
  case RG_MENU_FRAME_RATE:
    rg_window_set_show_frame_rate(value);
    break;
  case RG_MENU_FRAME_TIME:
    rg_window_set_show_frame_time(value);
    break;
  case RG_MENU_NO_SETTING:
    break;
  }
}

static void press_on_bar(rg_menu_key key);

static void move_heading(rg_menu_key key) {
  heading = (heading + (key == RG_MENU_RIGHT ? 1 : -1) + rg_menu_heading_count) % rg_menu_heading_count;
  row = -1;
}

static void slide(const rg_menu_line *line, int direction) {
  int least, most;
  limits(line, &least, &most);
  int value = setting_value(line->setting) + direction * line->step;
  set_setting(line->setting, clamped(value, least, most));
}

static void enter(const rg_menu_line *line) {
  switch (line->kind) {
  case RG_MENU_CHECK:
    set_setting(line->setting, !setting_value(line->setting));
    break;
  case RG_MENU_ACTION:
    if (line->does == RG_MENU_RESUME) menu_open = 0;
    if (line->does == RG_MENU_QUIT) quit_chosen = 1;
    if (line->does == RG_MENU_RESET_KEYS) {
      rg_window_reset_keys();
      rg_window_reset_pad();
    }
    if (line->does == RG_MENU_RESET_HOTKEYS) rg_window_reset_hotkeys();
    /* The window of variables opened or shut, and the menu closed so the game plays under it. */
    if (line->does == RG_MENU_VARIABLES) {
      rg_window_show_panel(RG_PANEL_VARIABLES, !rg_window_menu_variables_open());
      menu_open = 0;
    }
    break;
  case RG_MENU_BUTTON:
    rg_window_capture_for_button(line->place);
    break;
  case RG_MENU_HOTKEY:
    rg_window_capture_key_for_hotkey(line->place);
    break;
  case RG_MENU_STATE:
    rg_window_ask_state(line->saves, line->place);
    menu_open = 0;
    break;
  case RG_MENU_SLIDER:
    break;
  }
}

/* Which line of keys is being chosen: its place among its kind, or -1. */
static int capture_place(const rg_menu_line *line) {
  return rg_window_capturing() && open_lines()->lines + row == line ? line->place : -1;
}

/* What a line of keys says at its right: what it is on now, or that it is being chosen. */
static void control_text(const rg_menu_line *line, char *text, size_t room) {
  if (capture_place(line) >= 0) {
    snprintf(text, room, "%s", rg_window_capture_prompt());
  } else if (line->kind == RG_MENU_HOTKEY) {
    snprintf(text, room, "%s", rg_window_key_name(rg_window_hotkey_key(line->place)));
  } else {
    rg_window_button_text(line->place, text, room);
  }
}

void rg_window_menu_press(rg_menu_key key) {
  if (key == RG_MENU_CLOSE) {
    rg_window_menu_toggle();
    return;
  }
  if (row < 0) {
    press_on_bar(key);
    return;
  }
  const rg_menu_heading *lines = open_lines();
  const rg_menu_line *line = &lines->lines[row];
  switch (key) {
  case RG_MENU_UP:
    row -= 1;
    break;
  case RG_MENU_DOWN:
    row = (row + 1) % lines->line_count;
    break;
  case RG_MENU_LEFT:
  case RG_MENU_RIGHT:
    if (line->kind == RG_MENU_SLIDER) slide(line, key == RG_MENU_RIGHT ? 1 : -1);
    else move_heading(key);
    break;
  case RG_MENU_ENTER:
    enter(line);
    break;
  case RG_MENU_CLOSE:
    break;
  }
}

int rg_window_menu_variables_open(void) { return rg_window_panel_shown(RG_PANEL_VARIABLES); }

static int variables_take_keys(void) { return rg_window_menu_variables_open() && !menu_open; }

int rg_window_menu_press_on_variables(rg_menu_key key) {
  if (!variables_take_keys()) return 0;
  switch (key) {
  case RG_MENU_UP:
    if (variables_scroll > 0) variables_scroll--;
    return 1;
  case RG_MENU_DOWN:
    variables_scroll++; /* held to the last line when it is drawn */
    return 1;
  case RG_MENU_CLOSE:
    rg_window_show_panel(RG_PANEL_VARIABLES, 0);
    return 1;
  case RG_MENU_LEFT:
  case RG_MENU_RIGHT:
  case RG_MENU_ENTER:
    break;
  }
  return 0;
}

/* The letter key +key+ types (Live::WindowMenu.typed_letter, by SDL's scancodes): A to Z, 1 to 9
 * and 0, and the minus key for an underscore; 0 for a key that types none. */
static char typed_letter(int key) {
  if (key >= 4 && key <= 29) return (char)('a' + (key - 4));
  if (key >= 30 && key <= 39) return (char)('0' + (key - 30 + 1) % 10);
  return key == 45 ? '_' : '\0';
}

#define BACKSPACE_KEY 42

int rg_window_menu_type_key(int key) {
  if (!variables_take_keys()) return 0;
  size_t length = strlen(filter);
  if (key == BACKSPACE_KEY) {
    if (length > 0) filter[length - 1] = '\0';
  } else {
    char letter = typed_letter(key);
    if (!letter) return 0;
    if ((int)length < rg_menu_filter_most && length + 1 < FILTER_ROOM) {
      filter[length] = letter;
      filter[length + 1] = '\0';
    }
  }
  variables_scroll = 0;
  return 1;
}

static void press_on_bar(rg_menu_key key) {
  switch (key) {
  case RG_MENU_LEFT:
  case RG_MENU_RIGHT:
    move_heading(key);
    break;
  case RG_MENU_DOWN:
  case RG_MENU_ENTER:
    row = 0;
    break;
  case RG_MENU_UP:
  case RG_MENU_CLOSE:
    break;
  }
}

/* --- drawing --- */

static rg_menu_drawing *out;
static double density;
static int heading_left;

static int pixels(int points) { return rg_menu_rounded((double)points * density); }

/* Ruby's division of whole numbers, which rounds down rather than towards nought. */
static int halved(int value) { return value >= 0 ? value / 2 : -((-value + 1) / 2); }

/* A box to draw, added to what rg_window_menu_draw gives. */
static void add_box(int x, int y, int width, int height, int radius, const uint8_t color[4]) {
  if (out->part_count == RG_MENU_PARTS_MOST) return;
  rg_menu_part *part = &out->parts[out->part_count++];
  memset(part, 0, sizeof *part);
  part->is_box = 1;
  part->x = x;
  part->y = y;
  part->width = width;
  part->height = height;
  part->radius = radius;
  memcpy(part->color, color, 4);
}

/* Words to draw, the top left of their line at +x+, +y+, added to what rg_window_menu_draw gives. */
static void add_words(const char *text, int x, int y, const uint8_t color[4]) {
  if (out->part_count == RG_MENU_PARTS_MOST) return;
  rg_menu_part *part = &out->parts[out->part_count++];
  memset(part, 0, sizeof *part);
  snprintf(part->text, sizeof part->text, "%s", text);
  memcpy(part->color, color, 4);
  part->first_letter = out->letter_count;
  part->letter_count =
    rg_menu_font_layout(text, x, y, density, &out->letters[out->letter_count], RG_MENU_LETTERS_MOST - out->letter_count);
  out->letter_count += part->letter_count;
}

static int width_of(const char *text) { return rg_menu_font_width(text, density); }

/* +text+ with its line in the middle of a row +height+ pixels high from +top+. */
static void add_words_in_row(const char *text, int x, int top, int height, const uint8_t color[4]) {
  add_words(text, x, top + halved(height - rg_menu_font_line_height(density)), color);
}

/* The bar along the top, its headings, and the open one marked. Gives how tall it is. */
static int draw_bar(int width) {
  int bar = pixels(rg_menu_size.bar);
  add_box(0, 0, width, bar, 0, rg_menu_color.bar);
  int x = pixels(rg_menu_size.pad);
  for (int index = 0; index < rg_menu_heading_count; index++) {
    const char *name = rg_menu_headings[index].name;
    int wide = width_of(name);
    if (index == heading) {
      heading_left = x - pixels(rg_menu_size.heading_pad);
      add_box(heading_left, 0, wide + 2 * pixels(rg_menu_size.heading_pad), bar, 0, row < 0 ? rg_menu_color.chosen : rg_menu_color.open);
    }
    add_words_in_row(name, x, 0, bar, rg_menu_color.text);
    x += wide + pixels(rg_menu_size.heading_gap);
  }
  return bar;
}

/* What a state line shows at its right: its key, or when its slot's state was taken. */
static const char *state_line_words(const rg_menu_line *line) {
  return line->shortcut ? line->shortcut : rg_window_state_slot_text(line->place);
}

/* How much room the right of a line takes: a slider, a shortcut, or a check mark. */
static int right_width(const rg_menu_line *line) {
  switch (line->kind) {
  case RG_MENU_SLIDER:
    return pixels(rg_menu_size.slider);
  case RG_MENU_CHECK:
    return pixels(rg_menu_size.check);
  case RG_MENU_BUTTON:
  case RG_MENU_HOTKEY: {
    char text[192];
    control_text(line, text, sizeof text);
    return width_of(text);
  }
  case RG_MENU_STATE:
    return width_of(state_line_words(line));
  case RG_MENU_ACTION:
    break;
  }
  return line->shortcut ? width_of(line->shortcut) : 0;
}

static void slider_text(const rg_menu_line *line, int value, char *text, size_t room) {
  switch (line->written) {
  case RG_MENU_TIMES:
    snprintf(text, room, "%dx", value);
    break;
  case RG_MENU_PERCENT:
    snprintf(text, room, "%d%%", value);
    break;
  case RG_MENU_WINDOW:
    snprintf(text, room, "%dx  (%d \xC3\x97 %d)", value, picture_width * value, picture_height * value);
    break;
  case RG_MENU_NOT_WRITTEN:
    text[0] = '\0';
    break;
  }
}

/* A slider as Dear ImGui draws one: a frame, a grab as far along it as the number is, and the
 * number written in the middle. */
static void draw_slider(const rg_menu_line *line, int x, int y, int wide, int high) {
  add_box(x, y, wide, high, pixels(rg_menu_size.frame_corner), rg_menu_color.frame);
  int inset = pixels(2);
  int least, most;
  limits(line, &least, &most);
  int value = setting_value(line->setting);
  int travel = wide - pixels(rg_menu_size.grab) - 2 * inset;
  int along = most > least ? travel * (value - least) / (most - least) : 0;
  add_box(x + inset + along, y + inset, pixels(rg_menu_size.grab), high - 2 * inset, pixels(2), rg_menu_color.grab);
  char text[64];
  slider_text(line, value, text, sizeof text);
  add_words_in_row(text, x + halved(wide - width_of(text)), y, high, rg_menu_color.text);
}

static void draw_line(const rg_menu_line *line, int x, int y, int inner, int row_height) {
  add_words_in_row(line->label, x, y, row_height, rg_menu_color.text);
  int right = x + inner;
  switch (line->kind) {
  case RG_MENU_ACTION:
    if (line->shortcut) add_words_in_row(line->shortcut, right - width_of(line->shortcut), y, row_height, rg_menu_color.dim);
    break;
  case RG_MENU_CHECK:
    if (setting_value(line->setting)) add_words_in_row("\xE2\x9C\x93", right - width_of("\xE2\x9C\x93"), y, row_height, rg_menu_color.text);
    break;
  case RG_MENU_SLIDER:
    draw_slider(line, right - pixels(rg_menu_size.slider), y + pixels(2), pixels(rg_menu_size.slider), row_height - pixels(4));
    break;
  case RG_MENU_BUTTON:
  case RG_MENU_HOTKEY: {
    char text[192];
    control_text(line, text, sizeof text);
    add_words_in_row(text, right - width_of(text), y, row_height, capture_place(line) >= 0 ? rg_menu_color.fast : rg_menu_color.dim);
    break;
  }
  case RG_MENU_STATE: {
    const char *text = state_line_words(line);
    add_words_in_row(text, right - width_of(text), y, row_height, rg_menu_color.dim);
    break;
  }
  }
}

/* The open heading's lines, in a box under it with a border a point wide. */
static void draw_lines(int top) {
  const rg_menu_heading *lines = open_lines();
  int pad = pixels(rg_menu_size.pad);
  int row_height = pixels(rg_menu_size.row);
  int inner = pixels(rg_menu_size.least_width);
  int separated = 0;
  int widest = 0;
  for (int i = 0; i < lines->line_count; i++) {
    const rg_menu_line *line = &lines->lines[i];
    int wide = width_of(line->label) + pixels(rg_menu_size.label_gap) + right_width(line);
    if (i == 0 || wide > widest) widest = wide;
    if (line->line_before) separated++;
  }
  if (widest > inner) inner = widest;
  const char *notice = rg_window_notice();
  if (notice[0] && width_of(notice) > inner) inner = width_of(notice);
  int wide = inner + 2 * pad;
  int high = lines->line_count * row_height + 2 * pad + separated * pixels(rg_menu_size.line_before) + (notice[0] ? row_height : 0);
  int border = pixels(1);
  add_box(heading_left, top, wide, high, pixels(rg_menu_size.corner), rg_menu_color.border);
  add_box(heading_left + border, top + border, wide - 2 * border, high - 2 * border, pixels(rg_menu_size.corner) - border,
          rg_menu_color.box);
  int y = top + pad;
  for (int index = 0; index < lines->line_count; index++) {
    const rg_menu_line *line = &lines->lines[index];
    if (line->line_before) {
      add_box(heading_left + pad, y + halved(pixels(rg_menu_size.line_before)), inner, border, 0, rg_menu_color.border);
      y += pixels(rg_menu_size.line_before);
    }
    if (index == row) add_box(heading_left + halved(pad), y, wide - pad, row_height, pixels(rg_menu_size.frame_corner), rg_menu_color.chosen);
    draw_line(line, heading_left + pad, y, inner, row_height);
    y += row_height;
  }
  if (notice[0]) add_words_in_row(notice, heading_left + pad, y, row_height, rg_menu_color.paused);
}

/* What the window is doing, in a see-through box in the top right corner, under the bar when the
 * menu is open. */
static void draw_status(int width, int top, int held, int fast_forward, const char *frame_rate, const char *frame_work) {
  char said[3][64];
  const uint8_t *colors[3];
  int count = 0;
  if (frame_rate) {
    snprintf(said[count], sizeof said[count], "%s fps", frame_rate);
    colors[count++] = rg_menu_color.text;
  }
  if (frame_work) {
    snprintf(said[count], sizeof said[count], "%s ms of work a frame", frame_work);
    colors[count++] = rg_menu_color.text;
  }
  if (held) {
    snprintf(said[count], sizeof said[count], "PAUSED");
    colors[count++] = rg_menu_color.paused;
  } else if (fast_forward) {
    snprintf(said[count], sizeof said[count], "FAST FORWARD %dx", fast_forward);
    colors[count++] = rg_menu_color.fast;
  }
  if (count == 0) return;

  int pad = pixels(rg_menu_size.status_pad);
  int line = pixels(rg_menu_size.status_line);
  int widest = 0;
  for (int i = 0; i < count; i++) {
    int wide = width_of(said[i]);
    if (i == 0 || wide > widest) widest = wide;
  }
  int wide = widest + 2 * pad;
  int x = width - wide - pixels(rg_menu_size.status_gap);
  int y = top + pixels(rg_menu_size.status_gap);
  add_box(x, y, wide, count * line + 2 * pad, pixels(rg_menu_size.corner), rg_menu_color.status);
  for (int i = 0; i < count; i++) add_words(said[i], x + pad, y + pad + i * line, colors[i]);
}

/* Whether +name+ has the letters typed, in any case: the letters are typed small. */
static int found_by_filter(const char *name) {
  char small[64];
  size_t i = 0;
  for (; name[i] && i + 1 < sizeof small; i++) small[i] = name[i] >= 'A' && name[i] <= 'Z' ? (char)(name[i] - 'A' + 'a') : name[i];
  small[i] = '\0';
  return strstr(small, filter) != NULL;
}

/* Which of the lines found are shown, or that none are, and how many there was no room to read. */
static void variables_footer(int count, int dropped, char *text, size_t room) {
  if (count == 0) {
    snprintf(text, room, "%s", filter[0] ? "No name has these letters" : "No variables");
  } else {
    int last = variables_scroll + rg_menu_variable_rows < count ? variables_scroll + rg_menu_variable_rows : count;
    snprintf(text, room, "%d to %d of %d", variables_scroll + 1, last, count);
  }
  if (dropped > 0) {
    size_t used = strlen(text);
    snprintf(text + used, room - used, ", and %d more not shown", dropped);
  }
}

/* THE WINDOW OF THE GAME'S VARIABLES, in the top left corner, under the bar when the menu is open:
 * its title, the letters typed or what to type, a heading of Name and Value, a line for each
 * variable the letters find from the one scrolled to, and which lines those are. It is as wide as
 * its widest name needs, never narrower than variables_width, and always the same height, so it
 * stands still as the list changes. */
static void draw_variables(int top) {
  int pad = pixels(rg_menu_size.pad);
  int row_height = pixels(rg_menu_size.row);
  int rows = rg_menu_variable_rows;
  int count = rg_window_watch_count();
  int found = 0;
  for (int i = 0; i < count; i++) found += found_by_filter(rg_window_watch_name(i));
  int most_scroll = found - rows > 0 ? found - rows : 0;
  variables_scroll = clamped(variables_scroll, 0, most_scroll);
  int value_room = width_of(rg_menu_widest_value);
  int inner = pixels(rg_menu_size.variables_width);
  for (int i = 0; i < count; i++) {
    int wide = width_of(rg_window_watch_name(i)) + pixels(rg_menu_size.label_gap) + value_room;
    if (wide > inner) inner = wide;
  }
  int wide = inner + 2 * pad;
  int high = (rows + 4) * row_height + 2 * pad;
  int x = pixels(rg_menu_size.status_gap);
  int y = top + pixels(rg_menu_size.status_gap);
  int border = pixels(1);
  add_box(x, y, wide, high, pixels(rg_menu_size.corner), rg_menu_color.border);
  add_box(x + border, y + border, wide - 2 * border, high - 2 * border, pixels(rg_menu_size.corner) - border, rg_menu_color.box);
  int left = x + pad;
  int right = left + inner;
  int line = y + pad;
  add_words_in_row("Game variables", left, line, row_height, rg_menu_color.text);
  line += row_height;
  if (filter[0]) add_words_in_row(filter, left, line, row_height, rg_menu_color.text);
  else add_words_in_row("Type letters to find a name", left, line, row_height, rg_menu_color.dim);
  line += row_height;
  add_words_in_row("Name", left, line, row_height, rg_menu_color.dim);
  add_words_in_row("Value", right - width_of("Value"), line, row_height, rg_menu_color.dim);
  line += row_height;
  add_box(left, line, inner, border, 0, rg_menu_color.border);
  int seen = 0;
  for (int i = 0; i < count; i++) {
    const char *name = rg_window_watch_name(i);
    if (!found_by_filter(name)) continue;
    int place = seen++;
    if (place < variables_scroll || place >= variables_scroll + rows) continue;
    char value[16];
    snprintf(value, sizeof value, "%d", (int)rg_window_watch_value(i));
    add_words_in_row(name, left, line, row_height, rg_menu_color.text);
    add_words_in_row(value, right - width_of(value), line, row_height, rg_menu_color.text);
    line += row_height;
  }
  char footer[96];
  variables_footer(found, rg_window_watch_dropped(), footer, sizeof footer);
  add_words_in_row(footer, left, y + pad + (rows + 3) * row_height, row_height, rg_menu_color.dim);
}

void rg_window_menu_draw(rg_menu_drawing *drawing, int width, int height, double pixels_a_point, int held, int fast_forward,
                         const char *frame_rate, const char *frame_work) {
  out = drawing;
  out->part_count = 0;
  out->letter_count = 0;
  density = pixels_a_point;
  (void)height;
  int top = menu_open ? pixels(rg_menu_size.bar) : 0;
  if (rg_window_menu_variables_open()) draw_variables(top);
  if (menu_open) {
    draw_bar(width);
    draw_lines(top);
  }
  draw_status(width, top, held, fast_forward, frame_rate, frame_work);
}
