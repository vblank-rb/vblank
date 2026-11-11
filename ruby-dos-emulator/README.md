# ruby-dos-emulator

A headless DOS machine for checking programs from Ruby. It runs an `.EXE` or a `.COM` one frame at a
time in [DOSBox](https://github.com/libretro/dosbox-svn) (libretro's dosbox-svn core) and reads
back what a test needs to know:

- the picture shown, as 24-bit colours;
- the first megabyte of the PC's memory, the video card's memory, its palette and its mode;
- the sound made, as pairs of 16-bit samples;
- keys pressed and let go, as the keyboard port sees them.

```ruby
require "ruby_dos_emulator"

core = RubyDOSEmulator::Core.new("GAME.EXE")
core.press(%i[left ctrl])
60.times { core.run_frame }
core.peek(0x1234, 16)   # bytes of the first megabyte, by linear address
core.picture.pixels     # 0xRRGGBB, row by row
core.chained_pixels     # palette indices in mode 13h, one byte a pixel
core.destroy
```

## The machine

The machine is a DOSBox configuration (`Core#configuration`): a VGA card, an AdLib, a Sound Blaster at
220h on IRQ 5 and DMA 1, a 486 and a fixed number of processor cycles for each millisecond. A fixed
speed means a program runs the same on every run and every machine. The program's folder is drive C:.

## The core

DOSBox is built as a libretro core with `core/dosbox-vblank-probe.patch`. The patch does four things:

- it hands over the memories (system RAM, video RAM, the palette and the card's mode);
- it carries the frontend's half in C (the `vblank_*` functions), because the core runs the machine
  on a stack of its own and calls its frontend from there, where Ruby cannot be called;
- it shuts the machine properly when a `Core` is destroyed, so the PC's memory is freed;
- it makes the build work on a Mac without SDL, and exports only libretro's functions and the probe's.

The frontend asks the core for its "external" timing: the machine keeps no time by the host's clock,
and every `run_frame` ends when the video card has finished one picture. So a frame is one vertical
retrace, the same on every run.

`rake compile_core` downloads the core and libretro-common, each at the commit `CoreBuild` names,
applies the patch and builds it into `core/build/` (tar, patch, make and a C++ compiler). Set
`VBLANK_DOS_CORE` to use a core built somewhere else. The build is tested on macOS; the Linux build
takes the same steps and has not been run.

The core is GPL-2.0, and `core/LICENSE.md` says what that covers here. This gem is a tool for
testing, and VBlank never ships it: it is not in VBlank's gemspec.

The binding is pure Ruby over Fiddle: there is no C extension to compile. Each `Core` loads a copy of
the library of its own (see `CoreCopy`), and `destroy` shuts the machine and unloads it again, so a
process that opens many machines does not grow.
