/*
 * A PORT BUILT AS A SHELL, ON A COMPUTER (Original::Shell has what a shell is; rg_shell.c is the
 * flow, and rg_shell.js the same written again for a page, function for function). The program
 * holds none of the original's data. It is built with its parts in a folder beside it: the game
 * itself, and under parts/ the menu and one unpacking for each release of the original the game
 * reads. Each part is a whole desktop program of its own, since the native lowering names every
 * global of one program for the runtime and two programs cannot share one executable. A part has
 * no window: the game's program shows what each part draws in its own (rg_shell_window).
 *
 * rg_shell_facts is Original::ShellFacts, what every runtime of a shell is made from
 * (Native::ShellData writes it), every sentence a file is refused in among them, each with {name}
 * where rg_words_fill puts what only the running program knows. A build that is no shell has none
 * (NULL), and nothing here runs.
 */
#ifndef RG_SHELL_H
#define RG_SHELL_H

#include <stddef.h>
#include <stdint.h>

#include "rg_refusal.h"

/* One file of a release that is several files (Original::ReleaseFile). */
typedef struct {
  const char *name; /* as the original's disks spell it; a folder's may differ in case */
  const char *sha1;
  int32_t size;
} rg_shell_file;

typedef struct {
  const char *name;
  const char *sha1;         /* 40 lowercase hex digits */
  int32_t size;             /* in bytes, or -1 where it is not known */
  int read;                 /* whether the game reads this release */
  const char *part;         /* the file under parts/ that unpacks it, "" for a release not read */
  const char *unread_words; /* {named}: a copy of a release not read; "" for one that is */
  const rg_shell_file *files; /* a release that is several files: its files, in its order; NULL for one file */
  int file_count;
} rg_shell_release;

typedef struct {
  const char *title;
  const char *folder;    /* the game's folder among the files the computer keeps for each program */
  const char *pack_file; /* the pack's name in it */
  const rg_shell_release *releases;
  int release_count;
  const char *wrong_size_words; /* {named} and {size}: a file no release is the size of */
  const char *unknown_words;    /* {named} and {sha1}: a file that is no release the game knows */
  const char *one_file_words;   /* {named}: one file, where every release read is a folder; "" otherwise */
  const char *folder_words;     /* {named}: a folder, where no release read is one; "" otherwise */
  const char *lacking_words;    /* {named} and {lacking}: a folder that holds no release whole */
  const char *release_lacks_words; /* {release} and {missing}: one release's part of {lacking} */
  const char *wrong_file_words; /* {named}, {release}, {want_size}, {want_sha1}, {size}, {sha1} */
  const char *lacking_join;     /* between releases in {lacking} */
  const char *missing_join;     /* between file names in {missing} */
  const uint8_t *pack_before_sha1; /* the pack's header before the copy's SHA-1 */
  int pack_before_sha1_size;
  const uint8_t *pack_after_sha1; /* ...and after it */
  int pack_after_sha1_size;
  const int32_t *pack_rules; /* the check of a kept pack, as rg_start_file_refusal takes it */
  rg_start_file_words pack_words;
  const char *menu_part;       /* the file under parts/ that plays the menu */
  const char *choice_variable; /* the menu's variable, and what each number in it means */
  int load_rom;
  int settings;
  const char *line_variable; /* the menu's variable for the line under the cursor, handed back as its start file */
  const char *bytes_list; /* the unpacking's list of the pack's bytes, and its two variables */
  const char *finished_variable;
  const char *fault_kind_variable;
  const char *kept_pack_refused_words; /* {path} and {refusal}: for the error stream, never the player */
  const char *unpacking_stopped_words; /* {named} and {fault} */
  const char *unreadable_words;        /* {named} and {why} */
} rg_shell_description;

extern const rg_shell_description *const rg_shell_facts;

/* What a test names in place of what a person does (--shell-copy, --shell-picks, --shell-menu-keys,
 * --shell-settings-keys, --shell-pick-pictures), and where the pack is kept where the player has
 * not chosen (--pack-folder). All NULL for a player's run. */
typedef struct {
  const char *pack_folder;
  const char *copy;          /* the file picked, in place of the file dialog; one refused ends the program */
  const char *picks;         /* a file of what the dialog gives each time it is asked, a line each: a path, or
                              * an empty line for nothing picked; the shell ends when they run out */
  const char *menu_keys;     /* a script of buttons the menu is played with each time it plays, in place of a person */
  const char *settings_keys; /* ...and the one once SETTINGS has opened the window's menu */
  const char *pick_pictures; /* the window saved each time the copy is asked for, as it stands then:
                              * this name with ".1.bmp" for the first time, ".2.bmp" for the second */
  const char *told;          /* a file that gets a line for everything the shell puts in a box for the
                              * player, in order: a test's way to see what was told, and that nothing was */
} rg_shell_asked;

/* THE WINDOW A SHELL IS SHOWN IN, which the program that owns it hands over (rg_sdl.c): one window
 * from the menu to the game. Each of these keeps reading the window's events while it waits, and
 * the player closing the window ends the program from inside any of them.
 *
 * SDL's types are named here and not included: this header is also read where there is no SDL. */
struct SDL_Process;
typedef struct {
  /* Shows +part+, a part started with its standard input and output as pipes, until it ends: each
   * picture it sends is drawn, and it is sent the buttons held for each frame (from the script in
   * +keys+ where a test names one). +fast+ is an unpacking, which is sent no buttons. Whether the
   * part ended well. Its last picture stays up after. */
  int (*show_part)(struct SDL_Process *part, int fast, const char *keys);
  /* The file the player picks in the system's dialog, or the folder when +folder+, the dialog the
   * window's own; NULL for none. Freed with SDL_free. */
  char *(*pick_copy)(int folder);
  /* +words+ in a box the window draws over its picture until the player closes it. It comes back
   * at once: nothing waits for the box, and the menu plays on under it. */
  void (*tell)(const char *words);
  /* The window's menu, where the settings are, opened over the picture. */
  void (*open_settings)(void);
  /* The window as it stands, saved as a BMP at +path+: a test's way to see it. */
  void (*save_picture)(const char *path);
} rg_shell_window;

/* The path of a data pack this shell reads, made from the player's copy if it was not kept yet, all
 * of it shown in +window+; NULL when the player stopped. Frees with SDL_free. A test that names a
 * copy this shell refuses ends the program here, printing why. */
char *rg_shell_pack_path(const rg_shell_asked *asked, const rg_shell_window *window);

/* The files rg_shell_pack_path and its parts write beside the pack while they work, removed: the
 * window calls this when the player closes it part way, after ending the part that was playing,
 * so the copy the player picked is not left in the game's folder. Does nothing at any other time. */
void rg_shell_remove_working_files(void);

#endif
