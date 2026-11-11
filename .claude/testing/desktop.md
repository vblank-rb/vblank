# The native desktop window

What only the windowed desktop build does, and how each part is tested.

**Input.** Keys are pressed through SDL (`--scripted-keys`, in `test_native_desktop.rb`, under
`SDL=1`): each is a real key event, onto the gamepad the keyboard is, round the window's frame
loop. Feeding buttons to the windowless program skips all of that, so a fault in how the window
reads a key shows only there.

**Retina.** SDL's stand-in display has one pixel to a point, so a fault only at a screen's own
scale (the menu drawn at half size, its text cut off) passes there. One test in
`test_native_desktop.rb` opens a real window on a Mac for that. A check of what the menu draws
looks for its text (near-white pixels), never only for something lit — an empty box is lit too.

**The save file.** Tested on a few-line game that keeps a count: the file holds the bytes the
interpreter's save memory does, is read before the game starts, is written while it runs, and
lands in a folder named for the game among the player's files. `--save-file PATH` keeps the save
there instead, which keeps a test (or a person trying something) out of real saves. When the
window writes the file is plain counting in `runtime/rg_save.c`, tested with no window
(`test_native_save_file.rb`). Small made-up programs that save go in `test_native_saves.rb`.

**The player's BIOS** (for the console's start-up, never in the repository) is found by
`runtime/rg_console_bios.h` and `Live::ConsoleBIOS`, both held to `test/console_bios_cases.rb`
with made-up files and a made-up accepted checksum (`known_sha1:`), so no test needs a BIOS.

**The console's start-up** is the BIOS's own code, run by a small emulator of what it touches
(`runtime/rg_bios_boot.c`) before an Advance game's first frame. `test_native_bios_boot.rb` holds
its processor to small programs assembled with `GBA::ASM`, and the whole start-up to mGBA frame by
frame, every pixel and every sample of the console's own mix (`Core#mixed_sound_start`); the window
plays it only in a player's run, or a scripted one given `--start-up` (`test_native_desktop.rb`).
The tests that need the BIOS read the file `VBLANK_GBA_BIOS` names and skip without one. When the
emulator and mGBA part ways, `bios_boot_harness.c trace` prints every instruction with its cycle
count, to step beside mGBA's `Core#step` and `#registers` and find the first one that differs.

**How evenly it shows its pictures** cannot be seen by a test, and a stutter is exactly that. A
build started with `--frame-times` says at its end, on the error stream, what paced its frames
(the monitor or the console's clock), how far apart pictures were handed to the display, which
gaps were more than two milliseconds from the middle one, and whether sound was thrown away or
ran dry. A stutter is a clump of uneven gaps every few seconds; scattered single ones are the
computer being busy. `--refresh-rate 144` makes it choose its pacing as for that monitor; only
the choice is pretended, so `--refresh-rate 120` on a 60Hz monitor shows each picture for two
refreshes and plays at half speed. The pacing rule and the limit behind a hidden window are plain
arithmetic in `runtime/rg_pacing.h`, tested as that (`test_native_pacing.rb`).

**A shell has one window, from its first screen to its game.** The game's program opens it and
keeps it. The menu and each unpacking are programs of their own with no window: started with
`--part RESULT`, each sends its pictures down its standard output and the menu is sent the buttons
held on its standard input (`runtime/rg_shell.c` says why; `show_shell_part` and `play_part_for_shell`
in `runtime/rg_sdl.c` are the two ends). The file dialog and the box a refusal is told in are that
window's own. `test_native_shell.rb` stands in for the person:

- `--shell-picks FILE` is what the dialog gives each time LOAD ROM asks, a line each: a path, or an
  empty line for a dialog closed with nothing picked. The shell ends when the lines run out.
  `--shell-copy PATH` names one copy for every ask, and a copy refused ends the program.
- `--shell-pick-pictures NAME` saves the window as it stands each time the dialog would open
  (`NAME.1.bmp`, `NAME.2.bmp`), which is where a test sees the chosen line shown as chosen.
- `VBLANK_WINDOW_LOG=FILE` in the environment gets a line for every window a desktop program
  opens. A part is handed the shell's environment, so one line is one window for all of them.
- `--shell-menu-keys` and `--shell-settings-keys` are scripts the menu is played from, read from
  the start each time the menu plays.
- `--shell-told FILE` gets a line for everything the shell puts in a box for the player, in order.
  A file that is not there is a run that told nothing: how a test holds that a pack an older build
  kept is no box. The box is drawn by the window and nothing waits for it, in a test as for a person.

The real dialog cannot be clicked by a test: that it is a sheet on the window is looked at by a
person.

**A shell's unpacking plays on a thread of its own** (`play_part_on_thread` in `runtime/rg_sdl.c`),
so pictures keep coming while the routine works. `test_native_shell.rb` plays a whole shell with
`--frame-times`, on a port whose routine works about a second with no write and no wait
(`ShellTests#busy_port`), and counts the pictures in the report; and it closes the window part way
(a TERM signal), which ends the unpacking and leaves nothing in the pack's folder.

**An editor's complaints about the runtime's C are not the build's.** An editor's C checker reads
`lib/vblank/ir/backends/native/runtime/` on its own. Every native build writes a
`compile_flags.txt` above that folder with the build's own flags and header folders
(`Native::Zig.checker_flags`), so the checker holds the code to what the build does and finds
SDL's headers; the test harnesses (`test/lowering/native/vblank/ir/backends/native/*_harness.c`) get one too.
After a header is edited the checker can keep reading it at old positions and report nonsense
("invalid suffix on integer constant" on a line naming a defined number). Ask the compiler before
believing it:
`rake test:lowering:native TEST=test/lowering/native/vblank/ir/backends/native/test_native_checker_flags.rb`.
