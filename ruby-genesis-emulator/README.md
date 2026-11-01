# ruby-genesis-emulator

A headless Sega Genesis (Mega Drive) for checking cartridges from Ruby. It plays a cartridge one
frame at a time in [Genesis Plus GX](https://github.com/libretro/Genesis-Plus-GX) and reads back
what a test needs to know:

- the picture of the last frame, at the console's own size (320×224 for most games), as 9-bit
  colours;
- work RAM (64K, read in the order the 68000 sees it), video RAM (64K), the colour memory (64
  colours), the vertical scroll memory (40 words) and the video chip's registers;
- the 68000's registers.

```ruby
require "ruby_genesis_emulator"

core = RubyGenesisEmulator::Core.new("game.gen")
core.set_buttons(%i[right a])
60.times { core.run_frame }
core.wram_read16(0xFF0100)
core.colors.first # the top-left pixel: red in the low three bits, then green, then blue
core.destroy
```

## The core

Genesis Plus GX is built as a libretro core with `core/gpgx-vblank-probe.patch`. Its libretro
front end hands over only work RAM without it. The patch names the other memories.
`rake compile_core` downloads one archive of Genesis Plus GX at the revision `CoreBuild` names, applies
the patch and builds it into `core/build/` (tar, patch, make and a C compiler). Set
`VBLANK_GENESIS_CORE` to use a core built somewhere else.

Genesis Plus GX's licence bars commercial use, and `core/LICENSE.md` says what that covers here. This
gem is a tool for testing, and VBlank never ships it: it is not in VBlank's gemspec.

The binding is pure Ruby over Fiddle: there is no C extension to compile. Each `Core` loads a copy
of the library of its own, so two of them in one process are two consoles.
