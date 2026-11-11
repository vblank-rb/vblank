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

require_relative "dos/x86"
require_relative "dos/screen"
require_relative "dos/memory"
require_relative "dos/runtime"
require_relative "dos/runtime/rows"
require_relative "dos/runtime/mode_x"
require_relative "dos/runtime/saving"
require_relative "dos/runtime/clock"
require_relative "dos/runtime/sprites"
require_relative "dos/runtime/view"
require_relative "dos/runtime/regions"
require_relative "dos/runtime/fades"
require_relative "dos/lowering/sprites"
require_relative "dos/lowering/clock"
require_relative "dos/lowering"
require_relative "dos/headless_run"
require_relative "dos/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a DOS program: the same program every other backend runs, lowered to the 386 in
      # real mode and written as an MZ .EXE, the file DOS loads from a disk and DOSBox runs from a
      # folder. It is checked in DOSBox (ruby-dos-emulator, a DOSBox core that
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
      #   Emulator          A DOSBox libretro core (dosbox-svn), driven like the other consoles'
      #                     cores: mount a temporary folder as C:, run the .EXE, step frames, read
      #                     video memory and the shown picture, read memory and sound, press keys.
      #
      # WHERE THE CODE PARTS FROM THE TABLE, AND WHY:
      #
      # - MODE X IS 60 HZ, NOT 70. The table said "about 70 Hz in 13h and Mode X". Mode 13h draws its 200 lines
      #   with the card's 400-line timing (each line twice, 449 lines of 800 dots). Mode X's 240 lines are
      #   drawn with 480-line timing (525 lines of 800 dots), as the 640 x 480 mode is: more lines a frame
      #   at the same dot clock, so fewer frames a second.
      #   Console::DOSHardware::LINES_A_FRAME has the numbers and the variants' descriptions use them.
      # - THE EMULATOR GEM IS PURE RUBY OVER FIDDLE, with a frontend written in C inside the core (see
      #   ruby-dos-emulator): the core runs the machine on a stack of its own and calls its frontend from
      #   there, which a Ruby callback cannot answer.
      # - A PROGRAM TELLS THE READER WHERE ITS DATA IS. DOS loads an EXE wherever it finds room, so the
      #   program's first act is to store its data segment at 0040:00F0, the 16 bytes the PC's designers
      #   kept for programs to share (Diagnostics::DOSMemory), and a variable's address is an offset in it.
      #
      # WHAT IS DIFFERENT FROM THE PLAYSTATION'S AND THE GENESIS'S LOWERINGS: nothing about where the
      # lowering sits. It is a peer of those two: it walks the IR and emits machine code itself, through
      # a Ruby assembler (DOS::X86) and a writer for the file (the MZ .EXE), and shares what the other
      # cartridge lowerings decide before writing an instruction (LoweringPlan, BuildCache). It has no use
      # for RoutineCuts or Sections, which fit routines into a cartridge's banks: a DOS program's code is
      # one segment, refused at build time when it is too big. Never the C lowering through a cross-compiler.
      #
      # WHAT IS DIFFERENT, AND WHY IT MATTERS: a 16-bit real-mode program sees memory through 64 KB
      # segments, so a number held in a variable is two 16-bit halves to the eye but one 32-bit
      # register to the arithmetic. A game's variables live in one data segment; a list or picture too
      # big for what is left goes in a far segment of its own and is reached through ES.
      class DOS
        # WHERE A RUNNING PROGRAM KEEPS WHAT A READER WANTS, which nothing in its bytes shows: every variable by
        # the game's name (its offset in the data segment), every list (none are made yet), where the runtime
        # keeps how the run stands (Runtime::Frame's names), and the program it was built from. +bytes+ gives
        # what the program comes to (ByteCounts).
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :bytes, :routines) do
          # Where the runtime counts the times the game has waited for the screen.
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)
        end

        # What the program comes to: +code+, the bytes the processor runs, and +data+, the bytes it only reads.
        ByteCounts = Data.define(:code, :data)

        # What the build found to say about what it decided (Cartridge::LoweredBuild): nothing yet.
        def findings = (@findings ||= [])

        # The most code a program can have: it is one segment, reached by a 16-bit offset.
        MOST_CODE_BYTES = Console::DOSHardware::SEGMENT_SIZE

        # +program+ as an MZ EXE (Cartridge::DOSEXE), carrying its Places. The code is first, the runtime
        # behind the game's, and the data segment starts on the first paragraph after it, in memory the loader
        # gives beyond the file (EXTRA_PARAGRAPHS), cleared by the program as it starts.
        def build(program, title: "VBLANK", cache: BuildCache.for(DOS, program))
          memory = Memory.new(Screen.of(program))
          sprites = Lowering::Sprites.count_in(program)
          walks = Lowering.walks_colors?(program)
          view = Lowering.shown_through_view?(program)
          second = sprites.positive? || view
          Runtime.reserve(memory, saves: SaveLayout.named_by?(program), clock: Lowering::Clock.used_by?(program),
                                  area: Lowering.area_used_by?(program), sprites: sprites,
                                  walks: walks, view: view)
          Lowering::Sprites.reserve(memory, program)
          lowering = Lowering.new(program, memory: memory, cache: cache)
          asm = X86.new
          asm.jmp("start")
          lowering.emit(asm)
          Runtime.emit(asm, memory, palette: lowering.palette, starts: lowering.starts, pictures: lowering.pictures?,
                                    saves: lowering.saves?, clock: lowering.clock?, area: lowering.area?,
                                    sprites: sprites.positive?, regions: lowering.regions?,
                                    walks: walks, view: view, columns: Lowering.draws_columns?(program))
          refuse_too_much_code!(asm.here)
          art_segment = (asm.here + 15) / 16
          art = lowering.art.ljust((lowering.art.bytesize + 15) / 16 * 16, "\0")
          refuse_too_much_art!(art.bytesize)
          data_segment = art_segment + (art.bytesize / 16)
          shown = DOS.picture_shown_after_data(memory.screen, second: second)
          after_pictures = shown + Runtime::Rows.picture_paragraphs(memory.screen)
          assembled = asm.assemble(art: art_segment, data: data_segment, back: data_segment + PICTURE_AFTER_DATA,
                                   shown: data_segment + shown, save: data_segment + after_pictures)
          places = Places.new(variables: lowering.variables, lists: {},
                              runtime: Runtime.places(memory, sprites: sprites.positive?, view: view),
                              source_program: program, code: asm.here,
                              bytes: ByteCounts.new(code: asm.here, data: art.bytesize), routines: [])
          Cartridge::DOSEXE.new(assembled.bytes.ljust(art_segment * 16, "\0") + art, title: title, entry: [0, 0],
                                stack: [data_segment, 0xFFFE], relocations: assembled.segment_words.map { |at| [0, at] },
                                extra_paragraphs: after_pictures + (lowering.saves? ? SAVE_PARAGRAPHS : 0),
                                built: places)
        end

        # A segment of 64K for the numbers and the stack, in memory the loader gives beyond the file.
        EXTRA_PARAGRAPHS = Console::DOSHardware::SEGMENT_SIZE / 16

        # THE PICTURE THE GAME DRAWS, in a segment of its own after that one: every pixel a pass draws goes
        # here, and the rows that changed are copied to the card as the retrace begins (Runtime, "THE
        # PICTURE"). A reader of the running program finds it this many paragraphs past the data segment.
        # It is a segment's worth, or for a screen of more pixels than that, as many as it has (Runtime::Rows).
        PICTURE_AFTER_DATA = EXTRA_PARAGRAPHS

        # A game with sprites, a camera or blocks has a second picture after the first: the one shown, the game's with
        # the sprites over it (Runtime::Sprites) as the view has it (Runtime::View). Where the picture the
        # player is shown is, in paragraphs past the data segment: the second where there is one (+second+),
        # the game's own where there is not.
        def self.picture_shown_after_data(screen, second:)
          PICTURE_AFTER_DATA + (second ? Runtime::Rows.picture_paragraphs(screen) : 0)
        end

        # The save memory of a game that saves, in a segment of its own after those (Runtime::Saving).
        SAVE_PARAGRAPHS = Runtime::Saving::SIZE / 16

        private

        def refuse_too_much_art!(bytes)
          return if bytes <= MOST_CODE_BYTES

          raise LoweringError, "This game's pictures are #{bytes} bytes, and a DOS program keeps them in one segment of " \
                               "#{MOST_CODE_BYTES}. To fix this, use fewer or smaller pictures."
        end

        def refuse_too_much_code!(bytes)
          return if bytes <= MOST_CODE_BYTES

          raise LoweringError, "This game's code is #{bytes} bytes, and a DOS program keeps its code in one segment of " \
                               "#{MOST_CODE_BYTES}. To fix this, make the game smaller."
        end
      end
    end
  end
end
