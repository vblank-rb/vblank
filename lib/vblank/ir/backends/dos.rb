# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # Raised when a program cannot be made into a DOS program: it reaches something DOS cannot do,
        # or something its build does not make yet, or it is too big for conventional memory. Said to
        # the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

module VBlank
  module IR
    module Backends
      # The game as a DOS program: the same program every other backend runs, lowered to the 386 in
      # real mode and written as an MZ .EXE, the file DOS loads from a disk and DOSBox runs from a
      # folder. It is checked in DOSBox (ruby-dos-emulator, a DOSBox Pure core that
      # `rake compile_dos_core` builds) against the interpreter, which stays the answer key.
      #
      # THE DESIGN, DECIDED BEFORE ANY CODE WAS WRITTEN. Each row is a decision the operator handed
      # over. Take it unless the code shows it is wrong; when one is wrong, change it, and say why in
      # a paragraph below the table.
      #
      #   Question          Decision
      #   ----------------  -----------------------------------------------------------------------
      #   Processor         16-bit REAL MODE, an MZ .EXE, needing a 386. 32-bit registers and
      #                     arithmetic come through the operand-size prefix (0x66), so IR::Int32 maps
      #                     onto native 32-bit operations. No DOS extender: DOS/4GW cannot be shipped.
      #   Memory            Conventional memory (640 KB). Code and data in segments; pictures and big
      #                     lists in far segments of their own. A game too big is refused at build
      #                     time in plain words, as other consoles refuse a full cartridge.
      #   Video (plain)     VGA mode 13h: 320 x 200, 256 colours, the frame buffer at A000:0000, the
      #                     palette through ports 3C8h/3C9h (6 bits a channel).
      #   Variants          :mode_x is 320 x 240, 256 colours, unchained (Abrash's Mode X).
      #                     :vesa_640x480 is 640 x 480, 256 colours, through VESA BIOS banks. A game
      #                     picks one as `variants: { dos: :mode_x }`, as `variants: { snes: :superfx }`
      #                     picks the Super Nintendo's chip.
      #   Frame             One frame is one vertical retrace (poll port 3DAh, bit 3): about 70 Hz in
      #                     13h and Mode X, 60 Hz at 640 x 480. The description's frame length says so.
      #   Sprites           There is no sprite hardware. The processor draws sprites into a back
      #                     buffer that is copied to video memory in the retrace. The description
      #                     states the limits, generous but finite.
      #   AdLib             The OPL2 at ports 388h/389h, nine FM voices: music and effects.
      #   Sound Blaster     The DSP at 220h, IRQ 5, DMA 1 (BLASTER=A220 I5 D1): recordings, 8-bit
      #                     mono, single-cycle or auto-init DMA. A machine set up otherwise is told in
      #                     plain words at start.
      #   Keys              A keyboard interrupt handler (IRQ 1, port 60h) keeps the held keys. Arrows
      #                     are the d-pad, Ctrl is A, Alt is B, Enter is Start, Right Shift is Select,
      #                     Z and X are L and R. No joystick.
      #   Saves             A file beside the program.
      #   Emulator          A DOSBox libretro core (DOSBox Pure), driven like the other consoles'
      #                     cores: mount a temporary folder as C:, run the .EXE, step frames, read
      #                     video memory and the shown picture, read memory and sound, press keys.
      #
      # WHAT IS DIFFERENT FROM THE PLAYSTATION'S AND THE GENESIS'S LOWERINGS: nothing about where the
      # lowering sits. It is a peer of those two: it walks the IR and emits machine code itself, through
      # a Ruby assembler (DOS::X86) and a writer for the file (the MZ .EXE), and shares what the other
      # cartridge lowerings decide before writing an instruction (LoweringPlan, BuildCache,
      # RoutineCuts, Sections). Never the C lowering through a cross-compiler.
      #
      # WHAT IS DIFFERENT, AND WHY IT MATTERS: a 16-bit real-mode program sees memory through 64 KB
      # segments, so a number held in a variable is two 16-bit halves to the eye but one 32-bit
      # register to the arithmetic. A game's variables live in one data segment; a list or picture too
      # big for what is left goes in a far segment of its own and is reached through ES.
      #
      # THE EMULATOR GEM IS PURE RUBY OVER FIDDLE, not a C extension: like the PlayStation's and the
      # Super Nintendo's, it drives a libretro core, and the only thing that needs building is the
      # core. (The first draft of the brief said "C extension"; the code beside it does not need one.)
      class DOS
      end
    end
  end
end
