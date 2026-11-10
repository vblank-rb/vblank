# DOS — what every verb does there

DOS is a console a game can name (`VBlank.game "NAME", consoles: %i[gba dos]`). The build makes an
`.EXE` for a PC in real mode, and a PC with VGA, an AdLib and a Sound Blaster plays it (DOSBox in
the tests). **This page is written by hand for now.** When the answers table `Console::DOSAnswers`
exists, `tools/console_answers.rb` writes this page from it and replaces this text, as it does for
every other console. Until then, this is the design the table is built from.

## The machine

| Question | Decision |
|---|---|
| Processor | 16-bit real mode, an MZ `.EXE`, needing a 386. 32-bit registers and arithmetic through the operand-size prefix (`0x66`), so `IR::Int32` maps onto native 32-bit operations. No DOS extender. |
| Memory | Conventional memory (640 KB). Code and data in segments; pictures and big lists in far segments of their own. A game too big is refused at build time in plain words. |
| Video, plain | VGA mode 13h: 320 × 200, 256 colours. The frame buffer is at `A000:0000`. The palette goes through ports `0x3C8` and `0x3C9`, 6 bits a channel. |
| Variants | `variants: { dos: :mode_x }` is 320 × 240 at 256 colours (unchained). `variants: { dos: :vesa_640x480 }` is 640 × 480 at 256 colours, through VESA banks. |
| Frame | One frame is one vertical retrace (port `0x3DA`, bit 3): about 70 Hz in mode 13h and Mode X, 60 Hz at 640 × 480. |
| Sprites | There is no sprite hardware. The processor draws sprites into a back buffer, copied to video memory in the retrace. The description states the limits. |
| AdLib | The OPL2 at ports `0x388` and `0x389`, nine FM voices: music and effects. |
| Sound Blaster | The DSP at `0x220`, IRQ 5, DMA 1 (`BLASTER=A220 I5 D1`): recordings, 8-bit mono. A machine set up another way is told in plain words when the game starts. |
| Keys | A keyboard interrupt handler (IRQ 1, port `0x60`) keeps the held keys. Arrows are the d-pad, Ctrl is A, Alt is B, Enter is Start, Right Shift is Select, Z and X are L and R. There is no joystick. |
| Saves | A file beside the program. |
| Emulator | A DOSBox libretro core (DOSBox Pure) in `ruby-dos-emulator/`, built by `rake compile_dos_core`. |

The player chooses nothing but the window size, as on every console.
