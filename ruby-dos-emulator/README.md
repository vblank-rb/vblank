# ruby-dos-emulator

A headless DOS machine for checking programs from Ruby. It runs an `.EXE` or a `.COM` one frame at a
time in [DOSBox Pure](https://github.com/schellingb/dosbox-pure) (DOSBox as a libretro core) and reads
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

DOSBox Pure is built as a libretro core with `core/dosbox-vblank-probe.patch`. The patch does two
things. It hands over the memories (system RAM, video RAM, the palette and the card's mode), and it
carries the frontend's half in C (the `vblank_*` functions), because DOSBox Pure calls its frontend
from the thread it emulates on, and Ruby stops when a callback of its own is run by a thread it did not
start. `rake compile_core` downloads one archive of DOSBox Pure at the release `CoreBuild` names,
applies the patch and builds it into `core/build/` (tar, patch, make and a C++ compiler). Set
`VBLANK_DOS_CORE` to use a core built somewhere else.

DOSBox Pure is GPL-2.0, and `core/LICENSE.md` says what that covers here. This gem is a tool for
testing, and VBlank never ships it: it is not in VBlank's gemspec.

The binding is pure Ruby over Fiddle: there is no C extension to compile. Each `Core` loads a copy of
the library of its own and never reuses one (see `CoreCopy`): a machine cannot be started again in a
library that has run one. The library stays mapped after `destroy`, so a process that opens many
machines grows by about 40 MB each. A test run that opens many puts them in several processes.
