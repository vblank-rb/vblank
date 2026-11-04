# ruby-ps1-emulator

A headless PlayStation for checking programs from Ruby. It plays a PS-X EXE one frame at a time in
[Beetle PSX](https://github.com/libretro/beetle-psx-libretro) (Mednafen's PlayStation) and reads
back what a test needs to know:

- the picture shown, read from video RAM where the graphics chip is told to show it, as 15-bit
  colours (red in the low five bits);
- main RAM (2 megabytes), video RAM (1024 × 512 pixels), the scratchpad (1K) and the graphics chip's
  display settings;
- the processor's registers.

```ruby
require "ruby_ps1_emulator"

core = RubyPS1Emulator::Core.new("game.exe")
core.set_buttons(%i[right cross])
60.times { core.run_frame }
core.ram_read32(0x80100000)
core.colors.first # the top-left pixel: red in the low five bits, then green, then blue
core.destroy
```

## The core

Beetle PSX is built as a libretro core with `core/beetle-vblank-probe.patch`, without its
recompiler. Its libretro front end hands over only main RAM without the patch. The patch names the
other memories, and starts an EXE at power-on when the console runs OpenBIOS (OpenBIOS never reaches
the place in Sony's BIOS where Beetle hooks its EXE loader in). `rake compile_core` downloads one
archive of Beetle PSX at the revision `CoreBuild` names, applies the patch and builds it into
`core/build/` (tar, patch, make and a C compiler). Set `VBLANK_PS1_CORE` to use a core built
somewhere else.

No BIOS from Sony is needed: with none in its system folder, Beetle PSX runs OpenBIOS (MIT), which
is built into it. Beetle PSX is GPL-2.0, and `core/LICENSE.md` says what that covers here. This gem
is a tool for testing, and VBlank never ships it: it is not in VBlank's gemspec.

The binding is pure Ruby over Fiddle: there is no C extension to compile. Each `Core` loads a copy
of the library of its own, so two of them in one process are two consoles.
