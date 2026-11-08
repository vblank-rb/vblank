# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN on a console that only draws tiles.
          #
          # The Advance has screens that are a picture in memory, a colour for every pixel, which a
          # game paints into (`screen :bitmap`). A Super Nintendo has no such thing: everything it
          # shows is tiles. So a painted screen here is one background of 896 tiles, 32 across and 28
          # down, each shown once, so that together they are the screen: a pixel of the picture is a
          # pixel of one of them. Mode 3 (BGMODE) gives its first layer tiles of eight bits a pixel,
          # so every pixel is any of the 256 colours of the colour memory (SNES::PaintedArt picks
          # them while the game is built). Each tile is 64 bytes, so the 896 of them take 56K of the
          # console's 64K of video RAM (word addresses, as the console counts them):
          #
          #   $0000-$6FFF  the screen's tiles, in the order they are shown, row by row
          #   $7000-$77FF  the layer's map, 32 cells across and 64 down: which tile each cell shows
          #   $7860-$787F  the CLEAR TILE, every pixel the colour the screen was last cleared to
          #   $7880-$78BF  the SEE-THROUGH TILE, every pixel nought, never written (Boot leaves it so)
          #
          # A game with text at places known when it is built shows that text on a second layer
          # instead (TextLayer), whose map takes the rows of this map past the 32nd and whose tiles
          # the rest of video RAM past the see-through tile; such a game has no camera.
          #
          # The map's rows past the picture's 28 show the see-through tile, so a view moved down or
          # up past the picture (`camera`) shows the backdrop there, colour 0 of the colour memory,
          # which is black and fades with the picture (Tint) as the interpreter's backdrop does. The
          # map is 32 cells across, as wide as the screen, so a view moved across wraps round; the
          # console's first WINDOW hides the layer outside the columns where the picture is
          # (rt_paint_camera), and the backdrop shows there.
          #
          # THE GAME PAINTS INTO A COPY in work RAM — $7F:0000 to $7F:DFFF of its upper bank, laid out
          # the same way — and the tiles it changed go to video RAM after the pass (rt_paint_upload).
          # On a cartridge with a Super FX the copy is the chip's RAM instead (ChipPaint).
          #
          # A CLEAR WRITES NOTHING. Copying the whole screen is 57344 bytes, fourteen blanks' worth,
          # and a game that clears every pass would pay that every pass. Instead the clear moves the
          # screen on a GENERATION, and a tile last painted in an older generation is the clear
          # colour throughout, whatever the copy holds there (the Game Boy Color's painted screen does
          # the same). Such a tile is shown by pointing its cell of the map at the clear tile, two
          # bytes instead of 64. The first paint of a tile in a generation fills it with the clear
          # colour first and points its cell back at its own tile (rt_paint_ready). So each tile
          # keeps the generation it was last made ready in (GENERATIONS, a byte a tile), and work RAM
          # keeps the whole map as it is to be once the pass is shown (MAP_COPY).
          #
          # WHAT A PASS SENDS. The tiles painted in the pass, where they are in this generation: for
          # each row of tiles the copy keeps the leftmost and rightmost tile painted since the last
          # blank (DIRTY), and as the pass ends (rt_paint_prepare) each row's tiles of this generation
          # between them are put on a list of RUNS, side by side in video RAM and in the copy, a copy
          # each. Then, if they changed, the clear tile, the map and the colours of a fade or tint.
          #
          # ON A PLAIN CARTRIDGE A PASS THAT CLEARS PAINTS ONLY WHAT CHANGED (PaintLog): its paintings
          # are written down as it asks for them, and as it ends only the tiles that come out
          # different from what the copy holds are painted and sent, and only the cells of the map
          # that changed. A pass that draws what the last one drew sends nothing. A pass that has
          # not cleared paints at once, as here.
          #
          # THE COPY TO VIDEO RAM IS SPREAD OVER BLANKS, WITH THE SCREEN ON (Blank says how): the
          # runs go one at a time, each when the blank has room and time for it. The map, the clear
          # tile and the colours go last, all in one blank: until then a tile that was the clear
          # colour still shows the clear tile, so a tile sent early is not seen early, and the
          # colours never show with the last pass's tiles. A tile painted in both passes shows as it
          # arrives; a pass that changes more than a blank holds of such tiles still shows them
          # coming in down the screen.
          #
          # A TILE KEEPS ITS PIXELS IN PLANES. A pixel's colour is a place in the colour memory, eight
          # bits; a tile keeps the first bit of each of its 64 pixels together, a row of eight pixels
          # to a byte, leftmost pixel in the top bit, then the second bit of each, and so on. Its 64
          # bytes are the rows' planes 0 and 1 side by side (row 0's plane 0, row 0's plane 1, row
          # 1's...), then planes 2 and 3, then 4 and 5, then 6 and 7. So painting one pixel touches
          # eight bytes, but painting eight pixels of a row of one tile touches the same eight bytes:
          # everything here paints a row of a tile at a time, a MASK of which of its eight pixels.
          #
          #   rt_paint_start    at power-on: Mode 3, the map, the colours, the whole screen to paint in
          #   rt_paint_area     what follows paints only inside a rectangle (`inside`)
          #   rt_paint_camera   the view moved over the picture (`camera`)
          #   rt_paint_clear    the screen, or the rectangle, in one colour
          #   rt_paint_fill     a rectangle in one colour
          #   rt_paint_blit     a picture (SNES::PaintedArt's) at a place
          #   rt_paint_blit_one_of  one of a list of pictures, by number
          #   rt_paint_blit_inked   text whose colour is picked as the game runs, in an ink whose
          #                         colour changes rather than its tiles
          #   rt_paint_save     the patch of the screen under a sprite, kept
          #   rt_paint_restore  the patch put back
          #   rt_paint_prepare  as a pass ends: the runs of tiles to send
          #   rt_paint_upload   in the blank: the runs, then the map, the clear tile and the colours
          module Paint
            COLUMNS = 32
            ROWS = 28
            TILES = COLUMNS * ROWS
            TILE_BYTES = 64
            WIDTH = COLUMNS * 8
            HEIGHT = ROWS * 8
            COPY = 0x7F0000
            COPY_BYTES = TILES * TILE_BYTES
            MAP = 0x7000
            MAP_BYTES = TILES * 2
            # Work RAM's first byte, where the work RAM port counts from.
            WORK_RAM = 0x7E0000

            # THE CLEAR TILE is tile 963, at $7860, past the map, where no tile of the screen is. A
            # cell of the map is a word: the tile's number in its low ten bits, and above them its
            # colours' group, its priority and whether it is drawn flipped across or down. The cell
            # that shows the clear tile is drawn flipped both ways, which a tile of one colour does
            # not show, so that both of its bytes are $C3 — and so the whole map can be pointed at
            # it by the copying engine sending one byte over and over (DMA_FIXED_SOURCE).
            CLEAR_TILE = 963
            CLEAR_TILE_AT = CLEAR_TILE * TILE_BYTES / 2
            CLEAR_CELL = 0xC3C3
            # The cell that shows the see-through tile, the tile after the clear tile.
            SEE_THROUGH_CELL = CLEAR_TILE + 1
            # The map's rows: the picture's, then the see-through ones to its foot.
            MAP_ROWS = 64
            # BG1SC's size bits for a map 32 cells across and 64 down.
            MAP_32_BY_64 = 0x02
            # Where the camera puts the view: how far it is scrolled across, how far down (one less,
            # for the screen's first row, see rt_paint_start), the window's left and right columns
            # as WH0 and WH1 take them (a byte each, the left lowest), whether they changed since
            # the last blank sent them, and the place the game gave, 32 bits each way, for a reader
            # of the run (SNES::HeadlessRun).
            CAMERA = "rt paint camera"
            CAMERA_ACROSS = 0
            CAMERA_DOWN = 2
            CAMERA_WINDOW = 4
            CAMERA_CHANGED = 6
            CAMERA_X = 8
            CAMERA_Y = 12
            CAMERA_BYTES = 16
            # The window when the picture shows across the whole screen, and when none of it does
            # (its left past its right: no columns).
            WHOLE_WINDOW = 0xFF00
            NO_WINDOW = 0x00FF

            # Where painting is held to (`inside`): its left, top, right and bottom, right and bottom
            # just past it; then AREA_PART, nought when that is the whole screen, as it nearly
            # always is, so a painting compared with the last pass's (PaintLog) compares one word
            # for its area and not four. Kept and given back as AREA_WORDS words.
            AREA = "rt paint area"
            AREA_PART = 8
            AREA_WORDS = 5
            # AREA_PART when the area is less than the whole screen: a bit above any kind of
            # painting, so it goes in with the kind (PaintLog).
            PART_OF_SCREEN = 0x100
            # For each row of tiles, the leftmost and rightmost tile changed since the last blank: a
            # word each. A row with none has its leftmost past its rightmost (NONE_LEFT, 0).
            DIRTY = "rt paint dirty"
            NONE_LEFT = COLUMNS
            # For each tile column, which of its pixels the painting at hand may touch: worked out
            # once a picture or a patch (rt_paint_column_masks), not for every row of it.
            COLUMN_MASKS = "rt paint column masks"
            # The screen's generation, from 0 to one short of NO_GENERATION, and each tile's, a byte
            # each: the generation the tile was made ready in. Coming round, every tile is put in
            # NO_GENERATION, which the screen is never in, so no tile is taken for the new one.
            GENERATION = "rt paint generation"
            GENERATIONS = "rt paint generations"
            NO_GENERATION = 0xFF
            # The colour the screen was last cleared to (its place), its four words of planes as a
            # tile's row keeps them (rt_paint_planes), and the clear tile made of them, in work RAM.
            CLEAR_PLACE = "rt paint clear place"
            CLEAR_PLANES = "rt paint clear planes"
            CLEAR_TILE_COPY = "rt paint clear tile"
            # The map as the pass leaves it: a word for each of the screen's cells.
            MAP_COPY = "rt paint map"
            # Whether the map, or the clear tile, changed since the last blank sent them.
            MAP_CHANGED = "rt paint map changed"
            CLEAR_CHANGED = "rt paint clear changed"
            # The runs of tiles to send, each its first tile and how many, a word each: from the
            # start, the runs of tiles not on the screen now, to RUNS_END; and from the end back to
            # IN_PLACE_START, the runs of tiles that are (see SHOWN_IN). A run is a tile or more,
            # so there are never more runs than tiles.
            RUNS = "rt paint runs"
            RUNS_END = "rt paint runs end"
            IN_PLACE_START = "rt paint in place start"
            MOST_RUNS = TILES
            # WHICH TILES ARE ON THE SCREEN NOW: for each tile, the generation it was last sent in
            # (written as a pass is prepared), and the generation the screen shows (SHOWN_GENERATION,
            # a word: nothing, past any byte, at power-on). A tile whose two match has its cell
            # pointing at its own slot of video RAM in the map on the screen, so whatever is copied
            # into that slot is seen as it arrives; such tiles go last, with the map. Each pass is
            # shown before the next is prepared, so the generation shown is the one the last pass
            # was prepared in. Readying and clearing leave these alone, so a pass that clears twice,
            # or as the generations come round, still knows. When a byte's generations come round
            # to one a tile was last sent in long ago, that tile is taken to be on the screen when
            # it is not: it goes last when it need not, which is only later.
            SHOWN_IN = "rt paint shown in"
            SHOWN_GENERATION = "rt paint shown generation"
            NOTHING_SHOWN = 0xFFFF

            # The most inks a game paints text in (rt_paint_blit_inked), and for each the generation it
            # was last set in, a word.
            MOST_INKS = 64
            INK_GENERATIONS = "rt paint ink generations"
            # How many times the whole screen has been cleared, a word that comes round: what an
            # ink's generation counts. Not the tiles' generation, which a deferred clear (PaintLog)
            # leaves as it was while the screen still shows the last pass.
            CLEARS = "rt paint clears"

            # The direct page the routines work on.
            Scratch = Data.define(:left, :right, :top, :bottom, :area, :y, :row, :count, :chunk, :last,
                                  :shift, :mask, :not_mask, :planes, :left_planes, :right_planes,
                                  :pointer, :height, :across, :first_x, :temp, :column, :tile, :mark_row,
                                  :mark_count, :run) do
              def area_left = area
              def area_top = area + 2
              def area_right = area + 4
              def area_bottom = area + 6
            end

            R = Ractor.make_shareable(->(n) { Memory.register(n) })

            module_function

            # On a cartridge with a Super FX (+chip+) the copy is the chip's RAM, so work RAM keeps
            # none, and what the painted screen keeps beside it goes with the rest of work RAM's far
            # places; on a plain one it goes in the last bank, after the copy.
            # +turns+ keeps room for a second picture to swap with (PaintTurns).
            def reserve(memory, chip: false, text_layer: false, turns: false)
              memory.reserve_last_bank("rt paint copy", COPY_BYTES) unless chip
              # Far from the chip's own memory when the chip paints, else in the last bank.
              far = ->(name, bytes) { chip ? memory.reserve_far(name, bytes) : memory.reserve_last_bank(name, bytes) }
              chip ? memory.name_place(GENERATIONS, ChipPaint::GENERATIONS) : far.call(GENERATIONS, TILES)
              far.call(MAP_COPY, MAP_BYTES)
              far.call(CLEAR_TILE_COPY, TILE_BYTES)
              far.call(RUNS, MOST_RUNS * 4)
              far.call(SHOWN_IN, TILES)
              memory.reserve_far(INK_GENERATIONS, MOST_INKS * 2)
              memory.reserve(AREA, AREA_WORDS * 2)
              memory.reserve(DIRTY, ROWS * 4)
              memory.reserve(COLUMN_MASKS, COLUMNS * 2)
              memory.reserve(GENERATION, 2)
              memory.reserve(CLEARS, 2)
              memory.reserve(CLEAR_PLACE, 2)
              memory.reserve(CLEAR_PLANES, 8)
              memory.reserve(MAP_CHANGED, 2)
              memory.reserve(CLEAR_CHANGED, 2)
              memory.reserve(RUNS_END, 2)
              memory.reserve(IN_PLACE_START, 2)
              memory.reserve(SHOWN_GENERATION, 2)
              memory.reserve(CAMERA, CAMERA_BYTES)
              PaintLog.reserve(memory, turns: turns) unless chip
              TextLayer.reserve(memory) if text_layer && !chip
            end

            def scratch(memory)
              Scratch.new(left: memory.scratch(2), right: memory.scratch(2), top: memory.scratch(2),
                          bottom: memory.scratch(2), area: memory.scratch(8), y: memory.scratch(2),
                          row: memory.scratch(2), count: memory.scratch(2), chunk: memory.scratch(2),
                          last: memory.scratch(2), shift: memory.scratch(2), mask: memory.scratch(2),
                          not_mask: memory.scratch(2), planes: memory.scratch(8), left_planes: memory.scratch(10),
                          right_planes: memory.scratch(10), pointer: memory.scratch(4), height: memory.scratch(2),
                          across: memory.scratch(2), first_x: memory.scratch(2), temp: memory.scratch(4),
                          column: memory.scratch(2), tile: memory.scratch(2), mark_row: memory.scratch(2),
                          mark_count: memory.scratch(2), run: memory.scratch(2))
            end

            # +chip+ for a cartridge with a Super FX: see ChipPaint, which says what changes there.
            def emit(asm, memory, s, chip: false, columns: false)
              bank = chip ? ChipPaint::COPY >> 16 : COPY >> 16
              logged = !chip
              emit_start(asm, memory, logged)
              emit_area(asm, memory, s)
              emit_camera(asm, memory, s)
              emit_helpers(asm, memory, s, bank, logged)
              PaintLog.emit(asm, memory, s, bank) if logged
              emit_clear(asm, memory, s, logged)
              chip ? ChipFill.emit_console(asm, memory, s) : emit_fill(asm, memory, s, bank, logged)
              emit_column(asm, memory) if columns
              emit_blit(asm, memory, s, bank, logged, chip: chip)
              emit_patches(asm, memory, s, bank, logged)
              emit_prepare(asm, memory, s, logged)
              emit_upload(asm, memory, s, bank, logged)
              emit_send_run(asm, memory, bank)
              emit_send_runs(asm, memory, s)
              emit_tables(asm)
            end

            # --- power-on ---

            def emit_start(asm, memory, logged)
              h = Console::SNESHardware
              # A game with a text layer has no camera, and its map's rows past the picture's are
              # the text layer's map (TextLayer).
              layer = TextLayer.kept?(memory)
              asm.label("rt_paint_start")
              asm.sep(0x20)
              asm.lda(0x03) # mode 3: the first layer's tiles eight bits a pixel
              asm.sta(asm.abs(h::BGMODE))
              asm.stz(asm.abs(h::BG12NBA)) # its tiles from $0000
              asm.lda(((MAP >> 10) << 2) | (layer ? 0 : MAP_32_BY_64)) # its map at $7000, 32 cells across and 64 down (32)
              asm.sta(asm.abs(h::BG1SC))
              # The first window hides the layer outside its columns (W12SEL: the window on, its
              # outside the part hidden; TMW: on the main screen), every column at power-on.
              asm.stz(asm.abs(h::WH0))
              asm.lda(0xFF)
              asm.sta(asm.abs(h::WH1))
              asm.lda(0x03)
              asm.sta(asm.abs(h::W12SEL))
              asm.lda(0x01)
              asm.sta(asm.abs(h::TMW))
              asm.lda(layer ? 0x03 : 0x01) # the first layer alone on the main screen, or with the text layer
              asm.sta(asm.abs(h::TM))
              # The screen's first row is the console's line 1 (see Runtime::Picture's scroll), so the
              # layer is scrolled up one: -1 is $3FF in the register's ten bits.
              asm.lda(0xFF)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.lda(0x03)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.rep(0x20)
              # The map: every cell of the picture shows the clear tile, black at power-on, as the
              # screen starts, and every cell past it the see-through tile.
              asm.lda(MAP)
              asm.sta(asm.abs(h::VMADDL))
              asm.ldx(0)
              asm.label("rt_paint_start_cell")
              asm.lda(CLEAR_CELL)
              asm.cpx(TILES)
              asm.bcc("rt_paint_start_cell_shown")
              asm.lda(SEE_THROUGH_CELL)
              asm.label("rt_paint_start_cell_shown")
              asm.sta(asm.abs(h::VMDATAL))
              asm.inx
              asm.cpx(COLUMNS * (layer ? COLUMNS : MAP_ROWS))
              asm.bne("rt_paint_start_cell")
              asm.jsr(asm.abs("rt_paint_layer_start")) if layer
              # The colours, all 256.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm("art colors"), asm.bank_of("art colors"), 512)
              # ...and where they change as the game runs (an ink's, rt_paint_blit_inked), there too.
              asm.jsl(asm.long("rt_colors_start")) if memory.reserved?(Tint::COLORS_NOW)
              # Paint anywhere, and nothing changed yet. The screen starts cleared to place 0, black,
              # in generation 0, which no tile is in yet; the copy, the clear tile in video RAM and the
              # clear colour's planes start all nought, as Boot leaves them.
              asm.jsl(asm.long("rt_paint_anywhere"))
              emit_no_generation_everywhere(asm, memory, "rt_paint_start")
              emit_fill_work_ram(asm, memory[SHOWN_IN], TILES, "rt_paint_no_generation")
              emit_fill_work_ram(asm, memory[MAP_COPY], MAP_BYTES, "rt_paint_clear_cell")
              [GENERATION, CLEARS, CLEAR_PLACE, MAP_CHANGED, CLEAR_CHANGED, RUNS_END].each do |name|
                asm.stz(asm.abs(memory[name]))
              end
              asm.lda(NOTHING_SHOWN)
              asm.sta(asm.abs(memory[SHOWN_GENERATION]))
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              asm.stz(asm.abs(memory[CAMERA] + CAMERA_ACROSS))
              asm.lda(0x03FF)
              asm.sta(asm.abs(memory[CAMERA] + CAMERA_DOWN))
              asm.lda(WHOLE_WINDOW)
              asm.sta(asm.abs(memory[CAMERA] + CAMERA_WINDOW))
              [CAMERA_CHANGED, CAMERA_X, CAMERA_X + 2, CAMERA_Y, CAMERA_Y + 2].each do |at|
                asm.stz(asm.abs(memory[CAMERA] + at))
              end
              asm.ldx(0)
              asm.label("rt_paint_start_row")
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(memory[DIRTY]))
              asm.stz(asm.abs_x(memory[DIRTY] + 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_start_row")
              PaintLog.emit_start(asm, memory) if logged
              asm.rtl
            end

            # Every tile put in NO_GENERATION. In work RAM the copying engine does it
            # (#emit_fill_work_ram); in a Super FX's RAM (ChipPaint), which the engine's work RAM port
            # cannot reach, a loop of 16-bit stores does, two tiles a store. +prefix+ makes its labels
            # its own. A changes; X is left at the end.
            def emit_no_generation_everywhere(asm, memory, prefix)
              address = memory[GENERATIONS]
              return emit_fill_work_ram(asm, address, TILES, "rt_paint_no_generation") if address >= WORK_RAM

              asm.ldx(0)
              asm.lda((NO_GENERATION << 8) | NO_GENERATION)
              asm.label("#{prefix}_no_generation")
              asm.sta(asm.long_x(address))
              asm.inx
              asm.inx
              asm.cpx(TILES)
              asm.bne("#{prefix}_no_generation")
            end

            # +bytes+ of work RAM from +address+ (24 bits) all the byte at +label+, by the copying
            # engine's channel 0 sending that one byte (DMA_FIXED_SOURCE) to the work RAM port,
            # which moves on by itself. The port counts work RAM's 128K from nought, $7E:0000, in 17
            # bits. The engine moves a byte in one of the processor's slow cycles, where a loop of
            # 16-bit stores takes eight of them a byte.
            def emit_fill_work_ram(asm, address, bytes, label)
              h = Console::SNESHardware
              offset = address - WORK_RAM
              asm.lda(offset & 0xFFFF)
              asm.sta(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.lda(offset >> 16)
              asm.sta(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT | h::DMA_FIXED_SOURCE, h::WMDATA, asm.imm(label),
                               asm.bank_of(label), bytes)
            end

            # --- the area ---

            # rt_paint_area(x, y, w, h): painting held to the rectangle, as far as it is on the
            # screen. rt_paint_anywhere: the whole screen. The lowering keeps the area there was
            # before an `inside` on the stack and puts it back after (Lowering::Paint).
            def emit_area(asm, memory, s)
              area = memory[AREA]
              asm.label("rt_paint_area")
              # The right and bottom: the left and top plus the width and height.
              [[R.call(0), R.call(2), R.call(4)], [R.call(1), R.call(3), R.call(5)]].each do |at, size, out|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(asm.direct(size))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(at + 2))
                asm.adc(asm.direct(size + 2))
                asm.sta(asm.direct(out + 2))
              end
              asm.stz(asm.direct(s.temp))
              asm.lda(WIDTH)
              asm.sta(asm.direct(s.temp + 2))
              emit_clamp(asm, "area", R.call(0), s.temp, s.temp + 2, s.left)
              emit_clamp(asm, "area", R.call(4), s.temp, s.temp + 2, s.right)
              asm.lda(HEIGHT)
              asm.sta(asm.direct(s.temp + 2))
              emit_clamp(asm, "area", R.call(1), s.temp, s.temp + 2, s.top)
              emit_clamp(asm, "area", R.call(5), s.temp, s.temp + 2, s.bottom)
              [s.left, s.top, s.right, s.bottom].each_with_index do |from, i|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(area + (i * 2)))
              end
              asm.lda(PART_OF_SCREEN)
              asm.sta(asm.abs(area + AREA_PART))
              [[s.left, 0], [s.top, 0], [s.right, WIDTH], [s.bottom, HEIGHT]].each do |at, whole|
                asm.lda(asm.direct(at))
                asm.cmp(whole)
                asm.bne("rt_paint_area_part")
              end
              asm.stz(asm.abs(area + AREA_PART))
              asm.label("rt_paint_area_part")
              asm.rtl

              asm.label("rt_paint_anywhere")
              asm.stz(asm.abs(area + AREA_PART))
              asm.stz(asm.abs(area))
              asm.stz(asm.abs(area + 2))
              asm.lda(WIDTH)
              asm.sta(asm.abs(area + 4))
              asm.lda(HEIGHT)
              asm.sta(asm.abs(area + 6))
              asm.rtl
            end

            # +out+ = the 32-bit number at +at+ held between the words at +low+ and +high+ (two small
            # numbers, nought or more).
            def emit_clamp(asm, routine, at, low, high, out)
              tag = "rt paint clamp #{routine} #{out}"
              asm.lda(asm.direct(at + 2))
              asm.bmi("#{tag} low")
              asm.bne("#{tag} high")
              asm.lda(asm.direct(at))
              asm.cmp(asm.direct(low))
              asm.bcc("#{tag} low")
              asm.cmp(asm.direct(high))
              asm.bcs("#{tag} high")
              asm.bra("#{tag} keep")
              asm.label("#{tag} low")
              asm.lda(asm.direct(low))
              asm.bra("#{tag} keep")
              asm.label("#{tag} high")
              asm.lda(asm.direct(high))
              asm.label("#{tag} keep")
              asm.sta(asm.direct(out))
            end

            # --- the camera ---

            # rt_paint_camera(x, y): screen (0, 0) shows what was painted at (x, y) from the next
            # blank on, and the backdrop past the picture's edges. A view the picture's width or
            # more across, or its height or more down, shows nothing of it, so the place is held to
            # those first and the rest is worked in 16 bits:
            #
            #   across: the layer scrolled across by x; the window keeps the columns from -x (or 0)
            #           to 255 - x (or 255), the ones the picture is in, and hides the rest — all of
            #           them when x is 256 or -256, the window's left then past its right
            #   down:   the layer scrolled down by y, one less for the screen's first row; the map's
            #           rows past the picture show the see-through tile, 288 rows of them, enough for
            #           a view from 224 above the picture to 224 below it
            def emit_camera(asm, memory, s)
              camera = memory[CAMERA]
              asm.label("rt_paint_camera")
              [[R.call(0), CAMERA_X], [R.call(1), CAMERA_Y]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(camera + to))
                asm.lda(asm.direct(from + 2))
                asm.sta(asm.abs(camera + to + 2))
              end
              emit_clamp_signed(asm, R.call(0), WIDTH, s.left)
              emit_clamp_signed(asm, R.call(1), HEIGHT, s.top)
              asm.lda(asm.direct(s.left))
              asm.sta(asm.abs(camera + CAMERA_ACROSS))
              asm.lda(asm.direct(s.top))
              asm.dec
              asm.sta(asm.abs(camera + CAMERA_DOWN))
              # The window's left: -x for a view moved left, else the first column.
              asm.lda(asm.direct(s.left))
              asm.bpl("rt_paint_camera_from_first")
              asm.eor(0xFFFF)
              asm.inc
              asm.bra("rt_paint_camera_left")
              asm.label("rt_paint_camera_from_first")
              asm.lda(0)
              asm.label("rt_paint_camera_left")
              asm.cmp(WIDTH)
              asm.bcs("rt_paint_camera_none")
              asm.sta(asm.direct(s.temp))
              # ...and its right: 255 - x for a view moved right, else the last column.
              asm.lda(WIDTH - 1)
              asm.sec
              asm.sbc(asm.direct(s.left))
              asm.bit(asm.direct(s.left))
              asm.bpl("rt_paint_camera_right")
              asm.lda(WIDTH - 1)
              asm.label("rt_paint_camera_right")
              asm.cmp(0)
              asm.bmi("rt_paint_camera_none")
              asm.xba
              asm.ora(asm.direct(s.temp))
              asm.bra("rt_paint_camera_window")
              asm.label("rt_paint_camera_none")
              asm.lda(NO_WINDOW)
              asm.label("rt_paint_camera_window")
              asm.sta(asm.abs(camera + CAMERA_WINDOW))
              asm.lda(1)
              asm.sta(asm.abs(camera + CAMERA_CHANGED))
              asm.rtl
            end

            # +out+ = the 32-bit number at +at+ held between -+limit+ and +limit+, as 16 bits.
            def emit_clamp_signed(asm, at, limit, out)
              tag = "rt paint clamp signed #{at}"
              asm.lda(asm.direct(at + 2))
              asm.bmi("#{tag} below")
              asm.bne("#{tag} high")
              asm.lda(asm.direct(at))
              asm.cmp(limit + 1)
              asm.bcc("#{tag} keep")
              asm.label("#{tag} high")
              asm.lda(limit)
              asm.bra("#{tag} keep")
              asm.label("#{tag} below")
              asm.cmp(0xFFFF)
              asm.bne("#{tag} low")
              asm.lda(asm.direct(at))
              asm.cmp(0x10000 - limit)
              asm.bcs("#{tag} keep")
              asm.label("#{tag} low")
              asm.lda(0x10000 - limit)
              asm.label("#{tag} keep")
              asm.sta(asm.direct(out))
            end

            # --- what several routines share ---

            def emit_helpers(asm, memory, s, bank, logged)
              area = memory[AREA]

              # rt_paint_take_area (JSR): the area onto the direct page.
              asm.label("rt_paint_take_area")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.direct(s.area + (i * 2)))
              end
              asm.rts

              emit_mark_now(asm, memory, s, bank) unless logged
              emit_planes(asm, s)
              emit_row_start(asm, s)
              emit_column_mask_helpers(asm, memory, s)
            end

            # On a Super FX cartridge each painting is done as it is asked for (PaintLog keeps a
            # plain cartridge's): rt_paint_mark makes its tiles ready first, and rt_paint_ready is
            # what the chip's own painting (ChipColumns) does too.
            def emit_mark_now(asm, memory, s, bank)
              dirty = memory[DIRTY]

              # rt_paint_mark (JSR): rows of pixels +top+ up to +bottom+, tiles +chunk+ to +last+
              # across, marked changed, and each of those tiles made ready to paint in this generation.
              asm.label("rt_paint_mark")
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.mark_row))
              asm.label("rt_paint_mark_row")
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.direct(s.chunk))
              asm.cmp(asm.abs_x(dirty))
              asm.bcs("rt_paint_mark_left_kept")
              asm.sta(asm.abs_x(dirty))
              asm.label("rt_paint_mark_left_kept")
              asm.lda(asm.direct(s.last))
              asm.cmp(asm.abs_x(dirty + 2))
              asm.bcc("rt_paint_mark_right_kept")
              asm.sta(asm.abs_x(dirty + 2))
              asm.label("rt_paint_mark_right_kept")
              # The row's tiles, each of an older generation made ready.
              asm.lda(asm.direct(s.mark_row))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.inc
              asm.sta(asm.direct(s.mark_count))
              asm.label("rt_paint_mark_tile")
              asm.ldx(asm.direct(s.tile))
              asm.lda(asm.long_x(memory[GENERATIONS]))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[GENERATION]))
              asm.beq("rt_paint_mark_ready")
              asm.jsr(asm.abs("rt_paint_ready"))
              asm.label("rt_paint_mark_ready")
              asm.inc(asm.direct(s.tile))
              asm.dec(asm.direct(s.mark_count))
              asm.bne("rt_paint_mark_tile")
              asm.lda(asm.direct(s.mark_row))
              asm.cmp(asm.direct(s.temp))
              asm.beq("rt_paint_mark_done")
              asm.inc
              asm.sta(asm.direct(s.mark_row))
              asm.bra("rt_paint_mark_row")
              asm.label("rt_paint_mark_done")
              asm.rts

              # rt_paint_ready (JSR): tile +tile+, of an older generation and so the clear colour
              # throughout, made so in the copy — eight rows of the clear colour's four words of
              # planes — and put in this generation, its cell of the map pointed back at it.
              asm.label("rt_paint_ready")
              asm.ldx(asm.direct(s.tile))
              asm.sep(0x20)
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.long_x(memory[GENERATIONS]))
              asm.rep(0x20)
              asm.txa
              asm.asl
              asm.tax
              asm.lda(asm.direct(s.tile))
              asm.sta(asm.long_x(memory[MAP_COPY]))
              6.times { asm.asl }
              asm.tax
              4.times do |pair|
                asm.lda(asm.abs(memory[CLEAR_PLANES] + (pair * 2)))
                8.times { |row| asm.sta(asm.long_x((bank << 16) + (pair * 16) + (row * 2))) }
              end
              asm.lda(1)
              asm.sta(asm.abs(memory[MAP_CHANGED]))
              asm.rts
            end

            # rt_paint_planes (JSR): the colour at the place in A as four words, a pair of planes
            # each, into +planes+: $FF in a byte for a bit set.
            def emit_planes(asm, s)
              asm.label("rt_paint_planes")
              asm.sta(asm.direct(s.column))
              4.times do |pair|
                asm.stz(asm.direct(s.planes + (pair * 2)))
                2.times do |half|
                  skip = "rt_paint_planes_#{pair}_#{half}"
                  asm.lda(asm.direct(s.column))
                  asm.and_a(1 << ((pair * 2) + half))
                  asm.beq(skip)
                  asm.lda(half.zero? ? 0x00FF : 0xFF00)
                  asm.tsb(asm.direct(s.planes + (pair * 2)))
                  asm.label(skip)
                end
              end
              asm.rts
            end

            # rt_paint_row_start (JSR): A = where row +y+ of pixels starts in the copy, in its first
            # row of tiles: its row of tiles × 2048, and two bytes for each row of pixels down it.
            def emit_row_start(asm, s)
              asm.label("rt_paint_row_start")
              asm.lda(asm.direct(s.y))
              asm.and_a(0x00F8)
              asm.xba
              asm.sta(asm.direct(s.row))
              asm.lda(asm.direct(s.y))
              asm.and_a(0x0007)
              asm.asl
              asm.ora(asm.direct(s.row))
              asm.sta(asm.direct(s.row))
              asm.rts
            end

            def emit_column_mask_helpers(asm, memory, s)
              # rt_paint_column_mask (JSR): A = the pixels of the tile whose left edge is at A that
              # are between +left+ and +right+ (a byte, top bit leftmost), in both bytes of the word.
              # Uses X, and the tables are read with long addresses, whatever the data bank is.
              asm.label("rt_paint_column_mask")
              asm.sta(asm.direct(s.column))
              asm.lda(asm.direct(s.right))
              asm.sec
              asm.sbc(asm.direct(s.column))
              asm.bmi("rt_paint_column_mask_none")
              asm.beq("rt_paint_column_mask_none")
              asm.cmp(8)
              asm.bcc("rt_paint_column_mask_to")
              asm.lda(8)
              asm.label("rt_paint_column_mask_to")
              asm.asl
              asm.tax
              asm.lda(asm.direct(s.left))
              asm.sec
              asm.sbc(asm.direct(s.column))
              asm.bpl("rt_paint_column_mask_from")
              asm.lda(0)
              asm.label("rt_paint_column_mask_from")
              asm.cmp(8)
              asm.bcs("rt_paint_column_mask_none")
              asm.asl
              asm.pha
              asm.lda(asm.long_x("rt_paint_up_to"))
              asm.plx
              asm.and_a(asm.long_x("rt_paint_from_left"))
              asm.rts
              asm.label("rt_paint_column_mask_none")
              asm.lda(0)
              asm.rts

              # rt_paint_column_masks (JSR): each column +tile+ to +mark_count+ (0 to 31, the first no
              # further on than the last) its rt_paint_column_mask, into COLUMN_MASKS.
              asm.label("rt_paint_column_masks")
              asm.lda(asm.direct(s.tile))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              asm.pha
              asm.lda(asm.direct(s.tile))
              asm.asl
              asm.tax
              asm.pla
              asm.sta(asm.long_x(memory[COLUMN_MASKS]))
              asm.lda(asm.direct(s.tile))
              asm.cmp(asm.direct(s.mark_count))
              asm.inc(asm.direct(s.tile)) # INC leaves the carry as the comparison set it
              asm.bcc("rt_paint_column_masks")
              asm.rts
            end

            # --- clearing ---

            # rt_paint_clear(place): the screen in the colour at +place+, by moving on a generation
            # (see the top). Held to an area, the area alone, painted as a rectangle.
            def emit_clear(asm, memory, s, logged)
              dirty = memory[DIRTY]
              asm.label("rt_paint_clear")
              asm.jsr(asm.abs("rt_paint_take_area"))
              asm.lda(asm.direct(s.area_left))
              asm.ora(asm.direct(s.area_top))
              asm.bne("rt_paint_clear_area")
              asm.lda(asm.direct(s.area_right))
              asm.cmp(WIDTH)
              asm.bne("rt_paint_clear_area")
              asm.lda(asm.direct(s.area_bottom))
              asm.cmp(HEIGHT)
              asm.beq("rt_paint_clear_whole")
              asm.label("rt_paint_clear_area")
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(R.call(4)))
              [[s.area_left, nil, R.call(0)], [s.area_top, nil, R.call(1)],
               [s.area_right, s.area_left, R.call(2)], [s.area_bottom, s.area_top, R.call(3)]].each do |from, less, out|
                asm.lda(asm.direct(from))
                if less
                  asm.sec
                  asm.sbc(asm.direct(less))
                end
                asm.sta(asm.direct(out))
                asm.stz(asm.direct(out + 2))
              end
              asm.brl("rt_paint_fill")

              # The whole screen. A colour other than the last clear's makes the clear tile again:
              # its planes, kept for making tiles ready, and its 64 bytes, for the blank to send.
              asm.label("rt_paint_clear_whole")
              asm.inc(asm.abs(memory[CLEARS]))
              PaintLog.emit_clear_deferred(asm, memory) if logged
              asm.jsr(asm.abs("rt_paint_layer_clear_all")) if TextLayer.kept?(memory)
              asm.lda(asm.direct(R.call(0)))
              asm.cmp(asm.abs(memory[CLEAR_PLACE]))
              asm.branch_long(:beq, "rt_paint_clear_same_colour")
              asm.sta(asm.abs(memory[CLEAR_PLACE]))
              asm.jsr(asm.abs("rt_paint_planes"))
              4.times do |pair|
                asm.lda(asm.direct(s.planes + (pair * 2)))
                asm.sta(asm.abs(memory[CLEAR_PLANES] + (pair * 2)))
                8.times { |row| asm.sta(asm.long(memory[CLEAR_TILE_COPY] + (pair * 16) + (row * 2))) }
              end
              asm.lda(1)
              asm.sta(asm.abs(memory[CLEAR_CHANGED]))
              asm.jsr(asm.abs("rt_paint_seed")) if logged # a fresh tile's key, from the place in R0
              asm.label("rt_paint_clear_same_colour")
              if logged
                # Nothing written down is to be painted now (PaintLog).
                asm.jsr(asm.abs("rt_paint_next_generation"))
                PaintLog.emit_clear(asm, memory)
              else
                emit_next_generation(asm, memory, logged)
                # Every cell shows the clear tile, and nothing painted before is to be sent.
                emit_fill_work_ram(asm, memory[MAP_COPY], MAP_BYTES, "rt_paint_clear_cell")
                asm.lda(1)
                asm.sta(asm.abs(memory[MAP_CHANGED]))
              end
              emit_dirty_rows_from(asm, memory, logged, "rt_paint_clear_rows_done")
              asm.label("rt_paint_clear_rows")
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              emit_dirty_rows_until(asm, memory, logged, "rt_paint_clear_rows")
              asm.label("rt_paint_clear_rows_done")
              PaintLog.emit_no_rows(asm, memory, DIRTY) if logged
              asm.rtl
              return unless logged

              # rt_paint_next_generation (JSR): the clear made, as a clear or once deferred
              # (PaintLog): the next generation, and the cells of the tiles the last one readied to
              # go back to the clear tile, unless painted again.
              asm.label("rt_paint_next_generation")
              emit_next_generation(asm, memory, logged)
              PaintLog.emit_next_generation(asm, memory)
              asm.rts
            end

            # The next generation; coming round, every tile put in none first.
            # A screen that takes turns (PaintTurns) may show an older generation than the newest, so
            # the next is one past the newest, and coming round, the other picture is gone too.
            def emit_next_generation(asm, memory, logged)
              turns = logged && PaintTurns.kept?(memory)
              asm.lda(asm.abs(memory[turns ? PaintTurns::NEWEST_GENERATION : GENERATION]))
              asm.inc
              asm.cmp(NO_GENERATION)
              asm.bcc("rt_paint_clear_generation")
              emit_no_generation_everywhere(asm, memory, "rt_paint_clear")
              emit_fill_work_ram(asm, memory[PaintLog::PAINTED_IN], TILES, "rt_paint_no_generation") if logged
              asm.stz(asm.abs(memory[PaintTurns::OTHER_VALID])) if turns
              asm.lda(0)
              asm.label("rt_paint_clear_generation")
              asm.sta(asm.abs(memory[GENERATION]))
              asm.sta(asm.abs(memory[PaintTurns::NEWEST_GENERATION])) if turns
            end

            # --- a picture's column, stretched ---

            # rt_paint_column(pointer, step, start, rows, x, y, width): a column of a picture walked
            # down the screen. +pointer+ is where the column's places are, a byte each. +step+ is how
            # far down the picture a row of the screen goes, in 65536ths, and +start+ where the first
            # row stands. Rows that land on one colour are one rectangle, so a wall stretched
            # up close, which holds each colour for many rows, costs a few rectangles and not a
            # rectangle for every row. A place of 0xFF is see-through.
            def emit_column(asm, memory)
              # A painted screen's scratch fills the direct page, so all but the pointer are in work RAM.
              pointer = R.call(7)
              kept = %i[step at x y width].to_h { |what| [what, memory.reserve("rt paint column #{what}", 4)] }
              rows = memory.reserve("rt paint column rows", 2)
              shown = memory.reserve("rt paint column shown", 2)
              run = memory.reserve("rt paint column run", 2)
              asm.label("rt_paint_column")
              2.times do |half|
                asm.lda(asm.direct(R.call(0) + (half * 2)))
                asm.sta(asm.direct(pointer + (half * 2)))
              end
              { step: 1, at: 2, x: 4, y: 5, width: 6 }.each do |what, register|
                2.times do |half|
                  asm.lda(asm.direct(R.call(register) + (half * 2)))
                  asm.sta(asm.abs(kept.fetch(what) + (half * 2)))
                end
              end
              asm.lda(asm.direct(R.call(3)))
              asm.sta(asm.abs(rows))
              asm.ldy(asm.abs(kept.fetch(:at) + 2))
              asm.lda(asm.ind_long_y(pointer))
              asm.and_a(0x00FF)
              asm.sta(asm.abs(shown))
              asm.label("rt_paint_column_run")
              asm.lda(1)
              asm.sta(asm.abs(run))
              asm.label("rt_paint_column_same")
              asm.dec(asm.abs(rows))
              asm.beq("rt_paint_column_paint")
              asm.clc
              asm.lda(asm.abs(kept.fetch(:at)))
              asm.adc(asm.abs(kept.fetch(:step)))
              asm.sta(asm.abs(kept.fetch(:at)))
              asm.lda(asm.abs(kept.fetch(:at) + 2))
              asm.adc(asm.abs(kept.fetch(:step) + 2))
              asm.sta(asm.abs(kept.fetch(:at) + 2))
              asm.tay
              asm.lda(asm.ind_long_y(pointer))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(shown))
              asm.bne("rt_paint_column_paint")
              asm.inc(asm.abs(run))
              asm.bra("rt_paint_column_same")
              asm.label("rt_paint_column_paint")
              asm.pha # the place the next run is in
              asm.lda(asm.abs(shown))
              asm.cmp(0x00FF)
              asm.beq("rt_paint_column_left_alone")
              asm.sta(asm.direct(R.call(4)))
              asm.stz(asm.direct(R.call(4) + 2))
              { x: 0, y: 1, width: 2 }.each do |what, register|
                2.times do |half|
                  asm.lda(asm.abs(kept.fetch(what) + (half * 2)))
                  asm.sta(asm.direct(R.call(register) + (half * 2)))
                end
              end
              asm.lda(asm.abs(run))
              asm.sta(asm.direct(R.call(3)))
              asm.stz(asm.direct(R.call(3) + 2))
              asm.jsl(asm.long("rt_paint_fill"))
              asm.label("rt_paint_column_left_alone")
              asm.clc
              asm.lda(asm.abs(kept.fetch(:y)))
              asm.adc(asm.abs(run))
              asm.sta(asm.abs(kept.fetch(:y)))
              asm.pla
              asm.sta(asm.abs(shown))
              asm.lda(asm.abs(rows))
              asm.bne("rt_paint_column_run")
              asm.rtl
            end

            # --- rectangles ---

            # rt_paint_fill(x, y, w, h, place): the rectangle, as far as it is inside the area, in
            # the colour at +place+. Each row of it is a tile's row at the left edge (some of its
            # pixels), the tiles' rows between (all eight), and a tile's row at the right edge.
            def emit_fill(asm, memory, s, bank, logged)
              asm.label("rt_paint_fill")
              emit_op_begin(asm, memory, PaintLog::KIND_FILL, 20, "rt_paint_fill_now") if logged
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[R.call(0), R.call(2), R.call(5)], [R.call(1), R.call(3), R.call(6)]].each do |at, size, out|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(asm.direct(size))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(at + 2))
                asm.adc(asm.direct(size + 2))
                asm.sta(asm.direct(out + 2))
              end
              emit_clamp(asm, "fill", R.call(0), s.area_left, s.area_right, s.left)
              emit_clamp(asm, "fill", R.call(5), s.area_left, s.area_right, s.right)
              emit_clamp(asm, "fill", R.call(1), s.area_top, s.area_bottom, s.top)
              emit_clamp(asm, "fill", R.call(6), s.area_top, s.area_bottom, s.bottom)
              asm.lda(asm.direct(s.left))
              asm.cmp(asm.direct(s.right))
              asm.branch_long(:bcs, "rt_paint_fill_none")
              asm.lda(asm.direct(s.top))
              asm.cmp(asm.direct(s.bottom))
              asm.bcc("rt_paint_fill_some")
              asm.label("rt_paint_fill_none")
              asm.rtl
              asm.label("rt_paint_fill_some")
              # The colour's place as four words, a pair of planes each.
              asm.lda(asm.direct(R.call(4)))
              asm.jsr(asm.abs("rt_paint_planes"))
              # The tiles across: the first and the last, and the pixels of each edge.
              asm.lda(asm.direct(s.left))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.right))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.last))
              asm.lda(asm.direct(s.chunk))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              emit_masked_planes(asm, s, s.left_planes)
              asm.lda(asm.direct(s.last))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              emit_masked_planes(asm, s, s.right_planes)
              emit_mark_or_log(asm, memory, logged, "rt_paint_fill_paint")
              emit_into_copy(asm, bank)
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.y))
              asm.label("rt_paint_fill_row")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.chunk))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              asm.jsr(asm.abs("rt_paint_fill_left"))
              asm.lda(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.beq("rt_paint_fill_row_done")
              asm.dec
              asm.sta(asm.direct(s.count))
              asm.beq("rt_paint_fill_right")
              asm.label("rt_paint_fill_middle")
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES)
              asm.tax
              4.times do |pair|
                asm.lda(asm.direct(s.planes + (pair * 2)))
                asm.sta(asm.abs_x(pair * 16))
              end
              asm.dec(asm.direct(s.count))
              asm.bne("rt_paint_fill_middle")
              asm.label("rt_paint_fill_right")
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES)
              asm.tax
              asm.jsr(asm.abs("rt_paint_fill_right_tile"))
              asm.label("rt_paint_fill_row_done")
              asm.inc(asm.direct(s.y))
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.bottom))
              asm.branch_long(:bcc, "rt_paint_fill_row")
              asm.plb
              asm.rtl

              # One tile's row at X, through a mask's planes (+planes+: the mask's opposite, then the
              # four pairs of planes held to the mask).
              [["rt_paint_fill_left", s.left_planes], ["rt_paint_fill_right_tile", s.right_planes]].each do |label, planes|
                asm.label(label)
                4.times do |pair|
                  asm.lda(asm.abs_x(pair * 16))
                  asm.and_a(asm.direct(planes))
                  asm.ora(asm.direct(planes + 2 + (pair * 2)))
                  asm.sta(asm.abs_x(pair * 16))
                end
                asm.rts
              end
            end

            # A painting's start, on a plain cartridge: passed over if it is the last pass's (a clear
            # deferred), else its kind and the +bytes+ of working numbers it is known by
            # (PaintLog::HASHED_NUMBERS), for PaintLog to hash and write down. Painting it again
            # starts at +now+.
            def emit_op_begin(asm, memory, kind, bytes, now)
              PaintLog.emit_same_as_last_pass(asm, memory, kind, bytes, "#{now}_last_pass")
              asm.lda(kind)
              asm.ldx(bytes)
              asm.jsr(asm.abs("rt_paint_op_begin"))
              asm.label(now)
            end

            # Where a painting covers its tiles. On a Super FX cartridge they are made ready and it
            # paints. On a plain one, asked by the game after a clear, it is written down (PaintLog)
            # and paints nothing yet; painted again from the log, it goes straight on to +paint+;
            # asked before any clear in the pass, its tiles are made ready and it paints at once.
            def emit_mark_or_log(asm, memory, logged, paint)
              unless logged
                asm.jsr(asm.abs("rt_paint_mark"))
                return
              end

              asm.lda(asm.abs(memory[PaintLog::REPLAYING]))
              asm.bne(paint)
              asm.lda(asm.abs(memory[PaintLog::LOGGING]))
              asm.beq("#{paint}_at_once")
              asm.jsr(asm.abs("rt_paint_mark"))
              asm.jsr(asm.abs("rt_paint_log_append"))
              asm.rtl
              asm.label("#{paint}_at_once")
              asm.jsr(asm.abs("rt_paint_mark_now"))
              asm.label(paint)
            end

            # The mask in A (in both bytes) made into +out+: its opposite, then the four pairs of the
            # colour's planes held to it.
            def emit_masked_planes(asm, s, out)
              asm.sta(asm.direct(s.mask))
              asm.eor(0xFFFF)
              asm.sta(asm.direct(out))
              4.times do |pair|
                asm.lda(asm.direct(s.planes + (pair * 2)))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(out + 2 + (pair * 2)))
              end
            end

            # The data bank switched to the copy's, +bank+, the one it was kept on the stack: from here an
            # address of 16 bits is a byte of the copy. The direct page is in bank 0 whatever the data
            # bank, so the routines' numbers are where they were.
            def emit_into_copy(asm, bank)
              asm.phb
              asm.sep(0x20)
              asm.lda(bank)
              asm.pha
              asm.plb
              asm.rep(0x20)
            end

            # --- pictures ---

            # rt_paint_blit_inked(list, showing, x, y, ink): text whose colour is picked as the game
            # runs (Lowering::Paint#emit_draw_text), from the list of its three pictures — in the
            # colour shown, in the colour picked, and in its INK, a place of the colour list no other
            # colour is painted in.
            #
            # The ink's picture is painted when the ink can stand for the colour wanted: the ink
            # holds it already, or nothing has painted in the ink since the screen was last cleared
            # whole, and then the ink is set to it. Every pixel of the ink on the screen then is this
            # text's, painted since that clear (a tile of an older generation shows the clear tile),
            # so changing the ink's colour changes no pixel the interpreter would keep. Text painted
            # the same each pass in a colour that changes is then the same tiles, which are neither
            # painted nor sent again (PaintLog): only the colour list changes, with the map in the
            # pass's last blank (Tint). A second colour wanted of the ink before the next clear is
            # painted in its own colour's picture, as is any colour when the count of clears comes
            # round to the one the ink was last set at.
            #
            # INK_GENERATIONS keeps, for each ink, one more than the count of clears (CLEARS) it was
            # last set at: nought, at power-on, is none. (+temp+ is the colour wanted, +temp+ + 2 its place's byte.)
            def emit_blit_inked(asm, memory, s)
              now = memory[Tint::COLORS_NOW]
              state = memory[Tint::STATE]
              asm.label("rt_paint_blit_inked")
              asm.lda(asm.direct(R.call(4)))
              3.times { asm.asl }
              asm.tax
              asm.lda(asm.direct(R.call(1)))
              asm.ora(asm.direct(R.call(1) + 2))
              asm.beq("rt_paint_blit_inked_shown")
              asm.lda(asm.long_x("paint inks", 4))
              asm.bra("rt_paint_blit_inked_wanted")
              asm.label("rt_paint_blit_inked_shown")
              asm.lda(asm.long_x("paint inks", 2))
              asm.label("rt_paint_blit_inked_wanted")
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.long_x("paint inks"))
              asm.sta(asm.direct(s.temp + 2))
              asm.lda(asm.direct(R.call(4)))
              asm.asl
              asm.tax
              asm.lda(asm.abs(memory[CLEARS]))
              asm.inc
              asm.cmp(asm.long_x(memory[INK_GENERATIONS]))
              asm.beq("rt_paint_blit_inked_set")
              asm.sta(asm.long_x(memory[INK_GENERATIONS]))
              asm.ldx(asm.direct(s.temp + 2))
              asm.lda(asm.direct(s.temp))
              asm.cmp(asm.long_x(now))
              asm.beq("rt_paint_blit_inked_ink")
              # The ink's colour changed: in the colours a fade moves from, and, with no fade in
              # force, in the copy the blank sends, as Tint's rt_colors_hold changes a colour.
              asm.sta(asm.long_x(now))
              asm.ldy(asm.abs(state + Tint::STEPS_AT))
              asm.bne("rt_paint_blit_inked_faded")
              asm.sta(asm.long_x(memory[Tint::SHADOW]))
              asm.lda(asm.abs(state + Tint::CHANGED))
              asm.bne("rt_paint_blit_inked_ink")
              asm.lda(Tint::TO_SEND)
              asm.bra("rt_paint_blit_inked_noted")
              asm.label("rt_paint_blit_inked_faded")
              asm.lda(Tint::TO_WORK_OUT)
              asm.label("rt_paint_blit_inked_noted")
              asm.sta(asm.abs(state + Tint::CHANGED))
              asm.bra("rt_paint_blit_inked_ink")
              # Set in this generation already: the ink stands for the colour only if it holds it.
              asm.label("rt_paint_blit_inked_set")
              asm.ldx(asm.direct(s.temp + 2))
              asm.lda(asm.direct(s.temp))
              asm.cmp(asm.long_x(now))
              asm.bne("rt_paint_blit_one_of") # +showing+ picks the picture in the colour
              asm.label("rt_paint_blit_inked_ink")
              asm.lda(2) # the third picture, the ink's
              asm.sta(asm.direct(R.call(1)))
              asm.stz(asm.direct(R.call(1) + 2))
            end

            # rt_paint_blit_one_of(list, which, x, y): the picture numbered +which+ in the list of
            # pictures numbered +list+ (the table "paint picture lists": each a count, then the
            # pictures' numbers), or none for a number outside it. rt_paint_blit(picture, x, y).
            #
            # A picture placed more than 2048 pixels off the screen's left or top, or past its right
            # or bottom, paints nothing, so everything below works in 16 bits; no picture is that big.
            # On a Super FX cartridge (+chip+) the Super FX paints it, from the tiles across on
            # (ChipBlit).
            def emit_blit(asm, memory, s, bank, logged, chip: false)
              emit_blit_inked(asm, memory, s) if memory.reserved?(Tint::COLORS_NOW)
              asm.label("rt_paint_blit_one_of")
              asm.lda(asm.direct(R.call(0)))
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.long_x("paint picture lists"))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint picture lists", 2))
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(asm.direct(R.call(1) + 2))
              asm.branch_long(:bne, "rt_paint_blit_none")
              asm.lda(asm.direct(R.call(1)))
              asm.cmp(asm.ind_long(s.pointer))
              asm.branch_long(:bcs, "rt_paint_blit_none")
              asm.inc
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(R.call(0)))
              [[2, 1], [3, 2]].each do |from, to|
                asm.lda(asm.direct(R.call(from)))
                asm.sta(asm.direct(R.call(to)))
                asm.lda(asm.direct(R.call(from) + 2))
                asm.sta(asm.direct(R.call(to) + 2))
              end

              asm.label("rt_paint_blit")
              # A picture's number and its place: the place is held near the screen (below), where
              # its low word holds it all, and the low word is all that is hashed.
              emit_op_begin(asm, memory, PaintLog::KIND_BLIT, 12, "rt_paint_blit_now") if logged
              # Near enough the screen to paint anything at all.
              [[R.call(1), WIDTH], [R.call(2), HEIGHT]].each do |at, edge|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(2048)
                asm.tax
                asm.lda(asm.direct(at + 2))
                asm.adc(0)
                asm.branch_long(:bne, "rt_paint_blit_none")
                asm.cpx(2048 + edge)
                asm.branch_long(:bcs, "rt_paint_blit_none")
              end
              # The picture: where its rows' places are, its columns and its height.
              asm.lda(asm.direct(R.call(0)))
              3.times { asm.asl }
              asm.tax
              asm.lda(asm.long_x("paint pictures"))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint pictures", 2))
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(asm.long_x("paint pictures", 4))
              asm.sta(asm.direct(s.across))
              asm.lda(asm.long_x("paint pictures", 6))
              asm.sta(asm.direct(s.height))
              # Which of each row's runs of columns: the one for the place across modulo eight, where
              # the picture's table of runs shows it starts in a row (SNES::PaintedArt#run_starts,
              # sixteen bytes a picture), in +run+.
              asm.lda(asm.direct(R.call(0)))
              4.times { asm.asl }
              asm.sta(asm.direct(s.run))
              asm.lda(asm.direct(R.call(1)))
              asm.and_a(7)
              asm.asl
              asm.clc
              asm.adc(asm.direct(s.run))
              asm.tax
              asm.lda(asm.long_x("paint picture runs"))
              asm.sta(asm.direct(s.run))
              asm.jsr(asm.abs("rt_paint_take_area"))
              # The rows painted: the picture's, inside the area.
              asm.lda(asm.direct(R.call(2)))
              asm.bmi("rt_paint_blit_top_area")
              asm.cmp(asm.direct(s.area_top))
              asm.bcs("rt_paint_blit_top")
              asm.label("rt_paint_blit_top_area")
              asm.lda(asm.direct(s.area_top))
              asm.label("rt_paint_blit_top")
              asm.sta(asm.direct(s.top))
              asm.lda(asm.direct(R.call(2)))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.branch_long(:bmi, "rt_paint_blit_none")
              asm.cmp(asm.direct(s.area_bottom))
              asm.bcc("rt_paint_blit_bottom")
              asm.lda(asm.direct(s.area_bottom))
              asm.label("rt_paint_blit_bottom")
              asm.sta(asm.direct(s.bottom))
              asm.cmp(asm.direct(s.top))
              asm.branch_long(:beq, "rt_paint_blit_none")
              asm.bcs("rt_paint_blit_some")
              asm.label("rt_paint_blit_none")
              asm.rtl
              asm.label("rt_paint_blit_some")
              # The tiles across: the picture's first, at its place across divided by eight (rounded
              # down, so -3 is the tile left of the screen), and its columns from there, held to the
              # area's.
              asm.lda(asm.direct(R.call(1)))
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sta(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dec # the last: the columns, from the first
              asm.sta(asm.direct(s.last))
              asm.lda(asm.direct(s.area_right))
              asm.dec
              3.times { asm.lsr }
              asm.cmp(asm.direct(s.last))
              asm.bpl("rt_paint_blit_last")
              asm.sta(asm.direct(s.last))
              asm.label("rt_paint_blit_last")
              asm.lda(asm.direct(s.area_left))
              3.times { asm.lsr }
              asm.cmp(asm.direct(s.first_x))
              asm.bpl("rt_paint_blit_first")
              asm.lda(asm.direct(s.first_x))
              asm.label("rt_paint_blit_first")
              asm.sta(asm.direct(s.chunk))
              asm.cmp(asm.direct(s.last))
              asm.beq("rt_paint_blit_across")
              asm.branch_long(:bpl, "rt_paint_blit_none")
              asm.label("rt_paint_blit_across")
              return ChipBlit.emit_console(asm, memory, s) if chip

              emit_mark_or_log(asm, memory, logged, "rt_paint_blit_paint")
              [[s.area_left, s.left], [s.area_right, s.right]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.direct(to))
              end
              emit_blit_whole_tiles_check(asm, s)
              # Held to the area, each tile column's pixels it allows (whole tiles need none).
              asm.lda(asm.direct(s.planes))
              asm.bne("rt_paint_blit_masks_unneeded")
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.last))
              asm.sta(asm.direct(s.mark_count))
              asm.jsr(asm.abs("rt_paint_column_masks"))
              asm.label("rt_paint_blit_masks_unneeded")
              emit_into_copy(asm, bank)
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.y))
              asm.lda(asm.direct(s.planes))
              asm.branch_long(:bne, "rt_paint_blit_whole")
              asm.label("rt_paint_blit_row")
              # The row of the picture: its place, from the picture's table of rows, and its run.
              asm.lda(asm.direct(s.y))
              asm.sec
              asm.sbc(asm.direct(R.call(2)))
              asm.asl
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.pointer))
              asm.clc
              asm.adc(asm.direct(s.run)) # a row is in one bank, so this never carries
              asm.sta(asm.direct(s.temp))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.temp + 2))
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_blit_tile")
              # The tile's eight pixels the area allows, and of them the ones the picture draws: its
              # column, ten bytes for each tile from the picture's first.
              asm.lda(asm.direct(s.count))
              asm.asl
              asm.tax
              asm.lda(asm.long_x(memory[COLUMN_MASKS]))
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.count))
              asm.sec
              asm.sbc(asm.direct(s.first_x))
              asm.asl
              asm.sta(asm.direct(s.right_planes))
              asm.asl
              asm.asl
              asm.clc
              asm.adc(asm.direct(s.right_planes))
              asm.tay
              asm.lda(asm.ind_long_y(s.temp))
              asm.and_a(asm.direct(s.not_mask))
              asm.beq("rt_paint_blit_next_tile")
              asm.sta(asm.direct(s.mask))
              asm.eor(0xFFFF)
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.count))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              # Each pair of planes into the tile's row: a word of the column, held to the mask.
              4.times do |pair|
                asm.iny
                asm.iny
                asm.lda(asm.ind_long_y(s.temp))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(s.left_planes))
                asm.lda(asm.abs_x(pair * 16))
                asm.and_a(asm.direct(s.not_mask))
                asm.ora(asm.direct(s.left_planes))
                asm.sta(asm.abs_x(pair * 16))
              end
              asm.label("rt_paint_blit_next_tile")
              asm.lda(asm.direct(s.count))
              asm.cmp(asm.direct(s.last))
              asm.beq("rt_paint_blit_row_done")
              asm.inc(asm.direct(s.count))
              asm.brl("rt_paint_blit_tile")
              asm.label("rt_paint_blit_row_done")
              asm.inc(asm.direct(s.y))
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.bottom))
              asm.bcs("rt_paint_blit_done")
              asm.brl("rt_paint_blit_row")
              asm.label("rt_paint_blit_done")
              asm.plb
              asm.rtl
              emit_blit_whole_tiles(asm, s)
            end

            # +planes+ not nought when the area takes in every pixel of the tiles +chunk+ to +last+:
            # its left at or before the first's, its right at or past the last's. A picture painted
            # so needs no tile's pixels held to the area, and each of its rows starts the same way
            # (#emit_blit_whole_tiles_row): +mark_count+ the first tile's column of the picture, ten
            # bytes a tile, +column+ the first tile's place in a row of tiles, +tile+ how many.
            def emit_blit_whole_tiles_check(asm, s)
              asm.stz(asm.direct(s.planes))
              asm.lda(asm.direct(s.chunk))
              3.times { asm.asl }
              asm.cmp(asm.direct(s.left))
              asm.bcc("rt_paint_blit_held")
              asm.lda(asm.direct(s.last))
              asm.inc
              3.times { asm.asl }
              asm.sta(asm.direct(s.mask))
              asm.lda(asm.direct(s.right))
              asm.cmp(asm.direct(s.mask))
              asm.bcc("rt_paint_blit_held")
              asm.inc(asm.direct(s.planes))
              asm.lda(asm.direct(s.chunk))
              asm.sec
              asm.sbc(asm.direct(s.first_x))
              asm.asl
              asm.sta(asm.direct(s.mask))
              asm.asl
              asm.asl
              asm.clc
              asm.adc(asm.direct(s.mask))
              asm.sta(asm.direct(s.mark_count))
              asm.lda(asm.direct(s.chunk))
              6.times { asm.asl }
              asm.sta(asm.direct(s.column))
              asm.lda(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.inc
              asm.sta(asm.direct(s.tile))
              asm.label("rt_paint_blit_held")
            end

            # rt_paint_blit_whole: the rows of a picture whose tiles the area takes in whole
            # (#emit_blit_whole_tiles_check), from +y+ down to +bottom+, the data bank the copy's. A
            # picture's planes are nought wherever it does not draw, so each pair of planes goes in
            # as the tile's row with the picture's pixels taken out and the picture's put in: two
            # instructions fewer than holding them to a mask. Each row goes on from the last
            # rather than being worked out again: the next of the picture's rows (four bytes on in
            # its table, at +first_x+), and two bytes on in the copy, or on to the next row of
            # tiles after a tile's eighth. Y walks the picture's columns, ten bytes a tile, and X
            # the tiles, 64 bytes each. (+height+ is the rows left.)
            def emit_blit_whole_tiles(asm, s)
              asm.label("rt_paint_blit_whole")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.bottom))
              asm.sec
              asm.sbc(asm.direct(s.y))
              asm.sta(asm.direct(s.height))
              asm.lda(asm.direct(s.y))
              asm.sec
              asm.sbc(asm.direct(R.call(2)))
              asm.asl
              asm.asl
              asm.sta(asm.direct(s.first_x))
              asm.label("rt_paint_blit_whole_row")
              asm.ldy(asm.direct(s.first_x))
              asm.lda(asm.ind_long_y(s.pointer))
              asm.clc
              asm.adc(asm.direct(s.run)) # a row is in one bank, so this never carries
              asm.sta(asm.direct(s.temp))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.temp + 2))
              asm.iny
              asm.iny
              asm.sty(asm.direct(s.first_x))
              asm.ldy(asm.direct(s.mark_count))
              asm.lda(asm.direct(s.column))
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              asm.lda(asm.direct(s.tile))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_blit_whole_tile")
              asm.lda(asm.ind_long_y(s.temp)) # the mask
              asm.beq("rt_paint_blit_whole_none")
              asm.eor(0xFFFF)
              asm.sta(asm.direct(s.not_mask))
              4.times do |pair|
                asm.iny
                asm.iny
                asm.lda(asm.abs_x(pair * 16))
                asm.and_a(asm.direct(s.not_mask))
                asm.ora(asm.ind_long_y(s.temp))
                asm.sta(asm.abs_x(pair * 16))
              end
              asm.iny
              asm.iny
              asm.bra("rt_paint_blit_whole_next")
              asm.label("rt_paint_blit_whole_none")
              asm.tya
              asm.clc
              asm.adc(10)
              asm.tay
              asm.label("rt_paint_blit_whole_next")
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES)
              asm.tax
              asm.dec(asm.direct(s.count))
              asm.bne("rt_paint_blit_whole_tile")
              # The next row in the copy: two bytes on, or past a tile's eighth row (its offset
              # 16) on to the next row of tiles, 2048 bytes from the first.
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(2)
              asm.bit(0x0010)
              asm.beq("rt_paint_blit_whole_same_tiles")
              asm.clc
              asm.adc(COLUMNS * TILE_BYTES - 16)
              asm.label("rt_paint_blit_whole_same_tiles")
              asm.sta(asm.direct(s.row))
              asm.dec(asm.direct(s.height))
              asm.branch_long(:bne, "rt_paint_blit_whole_row")
              asm.plb
              asm.rtl
            end

            # --- a sprite's patch ---

            # rt_paint_save(buffer, x, y, w, h): the patch of the screen at (x, y), w by h, kept at
            # +buffer+ (24 bits; Lowering::Paint sizes it, #patch_bytes): a word saying it was kept,
            # then for each row of the patch each tile's row it touches, eight bytes. A row or a tile
            # off the screen is not kept, and is off the screen again when the patch is put back.
            # rt_paint_restore(buffer, x, y, w, h): the patch put back at the place it was kept from,
            # inside the area, its own pixels alone — nothing if none was kept.
            def emit_patches(asm, memory, s, bank, logged)
              asm.label("rt_paint_save")
              asm.jsr(asm.abs("rt_paint_patch_start"))
              asm.branch_long(:bcc, "rt_paint_save_some")
              asm.rtl
              asm.label("rt_paint_save_some")
              asm.lda(1)
              asm.sta(asm.ind_long(s.pointer))
              # The tiles it reads, as far as they are on the screen, made ready: one of an older
              # generation is the clear colour, whatever the copy holds there.
              asm.lda(asm.direct(s.y))
              asm.bpl("rt_paint_save_top")
              asm.lda(0)
              asm.label("rt_paint_save_top")
              asm.sta(asm.direct(s.top))
              asm.lda(asm.direct(s.y))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.bmi("rt_paint_save_marked")
              asm.cmp(HEIGHT)
              asm.bcc("rt_paint_save_bottom")
              asm.lda(HEIGHT)
              asm.label("rt_paint_save_bottom")
              asm.sta(asm.direct(s.bottom))
              asm.cmp(asm.direct(s.top))
              asm.beq("rt_paint_save_marked")
              asm.bcc("rt_paint_save_marked")
              asm.lda(asm.direct(s.first_x))
              asm.bpl("rt_paint_save_first")
              asm.lda(0)
              asm.label("rt_paint_save_first")
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dec
              asm.bmi("rt_paint_save_marked")
              asm.cmp(COLUMNS)
              asm.bcc("rt_paint_save_last")
              asm.lda(COLUMNS - 1)
              asm.label("rt_paint_save_last")
              asm.sta(asm.direct(s.last))
              asm.cmp(asm.direct(s.chunk))
              asm.bcc("rt_paint_save_marked")
              if logged # keeping a patch paints nothing, so its tiles' keys stay (PaintLog)
                asm.stz(asm.abs(memory[PaintLog::OP_HASH]))
                asm.stz(asm.abs(memory[PaintLog::OP_HASH] + 2))
              end
              asm.jsr(asm.abs(logged ? "rt_paint_mark_any" : "rt_paint_mark"))
              asm.label("rt_paint_save_marked")
              asm.jsr(asm.abs("rt_paint_flush_logged")) if logged # the copy as the screen is now
              emit_into_copy(asm, bank)
              asm.ldy(2)
              asm.label("rt_paint_save_row")
              asm.lda(asm.direct(s.y))
              asm.cmp(HEIGHT) # nought to the screen's height, unsigned
              asm.branch_long(:bcs, "rt_paint_save_row_off")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.first_x))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.across))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_save_tile")
              asm.lda(asm.direct(s.chunk))
              asm.cmp(COLUMNS)
              asm.branch_long(:bcs, "rt_paint_save_tile_off")
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              4.times do |pair|
                asm.lda(asm.abs_x(pair * 16))
                asm.sta(asm.ind_long_y(s.pointer))
                asm.iny
                asm.iny
              end
              asm.bra("rt_paint_save_tile_next")
              asm.label("rt_paint_save_tile_off")
              4.times do
                asm.iny
                asm.iny
              end
              asm.label("rt_paint_save_tile_next")
              asm.inc(asm.direct(s.chunk))
              asm.dec(asm.direct(s.count))
              asm.branch_long(:bne, "rt_paint_save_tile")
              asm.bra("rt_paint_save_row_next")
              asm.label("rt_paint_save_row_off")
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.temp + 2)) # a row of the patch's bytes
              asm.tay
              asm.label("rt_paint_save_row_next")
              asm.inc(asm.direct(s.y))
              asm.dec(asm.direct(s.height))
              asm.branch_long(:bne, "rt_paint_save_row")
              asm.plb
              asm.rtl

              asm.label("rt_paint_restore")
              asm.jsr(asm.abs("rt_paint_patch_start"))
              asm.branch_long(:bcc, "rt_paint_restore_kept")
              asm.label("rt_paint_restore_none")
              asm.rtl
              asm.label("rt_paint_restore_kept")
              asm.lda(asm.ind_long(s.pointer))
              asm.branch_long(:beq, "rt_paint_restore_none")
              # The columns put back: the patch's, inside the area.
              asm.jsr(asm.abs("rt_paint_take_area"))
              asm.lda(asm.direct(R.call(1)))
              asm.branch_long(:bmi, "rt_paint_restore_left_area")
              asm.cmp(asm.direct(s.area_left))
              asm.branch_long(:bcs, "rt_paint_restore_left")
              asm.label("rt_paint_restore_left_area")
              asm.lda(asm.direct(s.area_left))
              asm.label("rt_paint_restore_left")
              asm.sta(asm.direct(s.left))
              asm.lda(asm.direct(R.call(1)))
              asm.clc
              asm.adc(asm.direct(R.call(3)))
              asm.branch_long(:bmi, "rt_paint_restore_none")
              asm.cmp(asm.direct(s.area_right))
              asm.branch_long(:bcc, "rt_paint_restore_right")
              asm.lda(asm.direct(s.area_right))
              asm.label("rt_paint_restore_right")
              asm.sta(asm.direct(s.right))
              # The rows: every one of the patch's inside the area, marked changed with the tiles.
              asm.lda(asm.direct(R.call(2)))
              asm.branch_long(:bmi, "rt_paint_restore_top_area")
              asm.cmp(asm.direct(s.area_top))
              asm.branch_long(:bcs, "rt_paint_restore_top")
              asm.label("rt_paint_restore_top_area")
              asm.lda(asm.direct(s.area_top))
              asm.label("rt_paint_restore_top")
              asm.sta(asm.direct(s.top))
              asm.lda(asm.direct(R.call(2)))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.branch_long(:bmi, "rt_paint_restore_none")
              asm.cmp(asm.direct(s.area_bottom))
              asm.branch_long(:bcc, "rt_paint_restore_bottom")
              asm.lda(asm.direct(s.area_bottom))
              asm.label("rt_paint_restore_bottom")
              asm.sta(asm.direct(s.bottom))
              asm.cmp(asm.direct(s.top))
              asm.branch_long(:beq, "rt_paint_restore_none")
              asm.branch_long(:bcc, "rt_paint_restore_none")
              asm.lda(asm.direct(s.left))
              asm.cmp(asm.direct(s.right))
              asm.branch_long(:bcs, "rt_paint_restore_none")
              asm.lda(asm.direct(s.first_x))
              asm.pha
              asm.lda(asm.direct(s.left))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.right))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.last))
              if logged
                # What a patch puts back is whatever was under it, which no hash of its numbers
                # gives, so each one put back is a hash of its own: its tiles never match an older
                # key. What is written down is painted first, and then the patch, now.
                asm.inc(asm.abs(memory[PaintLog::RESTORES]))
                asm.lda(asm.abs(memory[PaintLog::RESTORES]))
                asm.sta(asm.abs(memory[PaintLog::OP_HASH]))
                asm.lda(PaintLog::RESTORE_HASH)
                asm.sta(asm.abs(memory[PaintLog::OP_HASH] + 2))
              end
              asm.jsr(asm.abs(logged ? "rt_paint_mark_any" : "rt_paint_mark"))
              asm.jsr(asm.abs("rt_paint_flush_logged")) if logged
              asm.pla
              asm.sta(asm.direct(s.first_x))
              # The masks of the patch's columns on the screen, from its first (or the screen's)
              # to its last (or the screen's).
              asm.bpl("rt_paint_restore_masks_from")
              asm.lda(0)
              asm.label("rt_paint_restore_masks_from")
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dec
              asm.cmp(COLUMNS)
              asm.bcc("rt_paint_restore_masks_to")
              asm.lda(COLUMNS - 1)
              asm.label("rt_paint_restore_masks_to")
              asm.sta(asm.direct(s.mark_count))
              asm.jsr(asm.abs("rt_paint_column_masks"))
              emit_into_copy(asm, bank)
              # Each row of the patch, from its first; the ones outside the area are passed over.
              asm.ldy(2)
              asm.label("rt_paint_restore_row")
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.top))
              asm.branch_long(:bmi, "rt_paint_restore_row_off")
              asm.cmp(asm.direct(s.bottom))
              asm.branch_long(:bpl, "rt_paint_restore_row_off")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.first_x))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.across))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_restore_tile")
              asm.lda(asm.direct(s.chunk))
              asm.cmp(COLUMNS)
              asm.branch_long(:bcs, "rt_paint_restore_tile_off")
              asm.asl
              asm.tax
              asm.lda(asm.long_x(memory[COLUMN_MASKS]))
              asm.sta(asm.direct(s.mask))
              asm.eor(0xFFFF)
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.chunk))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              4.times do |pair|
                asm.lda(asm.ind_long_y(s.pointer))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(s.left_planes))
                asm.lda(asm.abs_x(pair * 16))
                asm.and_a(asm.direct(s.not_mask))
                asm.ora(asm.direct(s.left_planes))
                asm.sta(asm.abs_x(pair * 16))
                asm.iny
                asm.iny
              end
              asm.bra("rt_paint_restore_tile_next")
              asm.label("rt_paint_restore_tile_off")
              4.times do
                asm.iny
                asm.iny
              end
              asm.label("rt_paint_restore_tile_next")
              asm.inc(asm.direct(s.chunk))
              asm.dec(asm.direct(s.count))
              asm.branch_long(:bne, "rt_paint_restore_tile")
              asm.bra("rt_paint_restore_row_next")
              asm.label("rt_paint_restore_row_off")
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.temp + 2))
              asm.tay
              asm.label("rt_paint_restore_row_next")
              asm.inc(asm.direct(s.y))
              asm.dec(asm.direct(s.height))
              asm.branch_long(:bne, "rt_paint_restore_row")
              asm.plb
              asm.rtl

              # rt_paint_patch_start (JSR): the buffer's place, and the patch's first row, its height,
              # its first tile across and how many tiles across it touches (+first_x+, +across+), and
              # the bytes of a row of it; the carry set for a patch too far off the screen to touch it.
              asm.label("rt_paint_patch_start")
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.direct(R.call(0) + 2))
              asm.sta(asm.direct(s.pointer + 2))
              [[R.call(1), WIDTH], [R.call(2), HEIGHT]].each do |at, edge|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(2048)
                asm.tax
                asm.lda(asm.direct(at + 2))
                asm.adc(0)
                asm.bne("rt_paint_patch_far")
                asm.cpx(2048 + edge)
                asm.bcs("rt_paint_patch_far")
              end
              asm.lda(asm.direct(R.call(2)))
              asm.sta(asm.direct(s.y))
              asm.lda(asm.direct(R.call(4)))
              asm.sta(asm.direct(s.height))
              asm.beq("rt_paint_patch_far")
              asm.lda(asm.direct(R.call(1)))
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sta(asm.direct(s.first_x))
              asm.lda(asm.direct(R.call(1)))
              asm.clc
              asm.adc(asm.direct(R.call(3)))
              asm.dec
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sec
              asm.sbc(asm.direct(s.first_x))
              asm.inc
              asm.sta(asm.direct(s.across))
              3.times { asm.asl } # ... × 8 bytes: a row of the patch
              asm.sta(asm.direct(s.temp + 2))
              asm.clc
              asm.rts
              asm.label("rt_paint_patch_far")
              asm.sec
              asm.rts
            end

            # The bytes a patch of +width+ by +height+ keeps: the word saying it was kept, and eight
            # bytes for each tile's row it can touch, wherever it is placed across.
            def patch_bytes(width, height) = 2 + (height * (((width + 7) / 8) + 1) * 8)

            # --- the end of a pass ---

            # rt_paint_prepare (JSL, as a pass ends, before its wait): each row's tiles changed and
            # in this generation put on the runs to send, a run for each stretch of them side by
            # side — of tiles on the screen now, or of tiles that are not (SHOWN_IN), each on its own
            # list. A tile of an older generation between them is not sent: its cell shows the
            # clear tile. The rows are marked unchanged again, and this generation is the one shown.
            #
            # A PASS THAT FITS IN ONE BLANK, as near as the rows changed show (#emit_measure), is not
            # split on a Super FX cartridge: every run goes on the list that is sent last, with the
            # map, so the whole pass arrives in one blank, in as few runs as it has. Only a bigger
            # pass is split, its tiles on the screen held back to go with the map. On a plain
            # cartridge (PaintLog) the rows changed show little of what is sent, as most of the tiles
            # in them are sent already, so a pass is always split, which is right for any pass:
            # the tiles not on the screen only go in a blank before the map, unseen until it does.
            # (+mask+ is the kind of the run started, +not_mask+ the tile's: 0 not on the screen, 1
            # on, or held back with the map; +temp+ 1 for a pass that is not split.)
            def emit_prepare(asm, memory, s, logged)
              dirty = memory[DIRTY]
              asm.label("rt_paint_prepare")
              if logged
                # A clear still deferred (PaintLog): a pass that matched the whole of the last
                # pass's log is the screen as it is, and nothing is painted or sent; one that
                # stopped short of it is made, and goes on as any other.
                asm.lda(asm.abs(memory[PaintLog::DEFERRED_CLEAR]))
                asm.beq("rt_paint_prepare_cleared")
                asm.lda(asm.abs(memory[PaintLog::LOG_END]))
                asm.cmp(asm.abs(memory[PaintLog::LAST_PASS_END]))
                asm.beq("rt_paint_prepare_same")
                if PaintTurns.kept?(memory)
                  # Short of the last pass's log, it may be the whole of the other picture's.
                  asm.jsr(asm.abs("rt_paint_try_other_at_end"))
                  asm.bne("rt_paint_prepare_same")
                end
                asm.jsr(asm.abs("rt_paint_apply_deferred_clear"))
                asm.bra("rt_paint_prepare_cleared")
                asm.label("rt_paint_prepare_same")
                emit_show_other_picture_or_clear(asm, memory) if PaintTurns.kept?(memory)
                asm.stz(asm.abs(memory[PaintLog::DEFERRED_CLEAR]))
                asm.stz(asm.abs(memory[PaintLog::LOGGING]))
                asm.stz(asm.abs(memory[RUNS_END]))
                asm.lda(MOST_RUNS * 4)
                asm.sta(asm.abs(memory[IN_PLACE_START]))
                asm.rtl
                asm.label("rt_paint_prepare_cleared")
              end
              asm.stz(asm.abs(memory[RUNS_END]))
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              asm.stz(asm.direct(s.temp))
              if logged
                # What the pass wrote down, painted into the copy and put on the runs as it is
                # (PaintLog); the next pass paints at once until it clears.
                asm.lda(asm.abs(memory[PaintLog::LOGGING]))
                asm.beq("rt_paint_prepare_split")
                asm.jsr(asm.abs("rt_paint_flush_sending"))
                asm.jsr(asm.abs("rt_paint_shared_checked")) if PaintTurns.kept?(memory)
                asm.stz(asm.abs(memory[PaintLog::LOGGING]))
                asm.brl("rt_paint_prepare_sent")
              else
                emit_measure(asm, memory, s)
              end
              asm.label("rt_paint_prepare_split")
              emit_dirty_rows_from(asm, memory, logged, "rt_paint_prepare_rows_done")
              asm.txa
              3.times { asm.asl }
              asm.sta(asm.direct(s.row)) # the row's first tile
              asm.label("rt_paint_prepare_row")
              asm.lda(asm.abs_x(dirty + 2))
              asm.cmp(asm.abs_x(dirty))
              asm.branch_long(:bcc, "rt_paint_prepare_next_row")
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.last))
              asm.lda(asm.abs_x(dirty))
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.tile))
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.phx
              asm.lda(0xFFFF) # no run started
              asm.sta(asm.direct(s.chunk))
              asm.label("rt_paint_prepare_tile")
              asm.ldx(asm.direct(s.tile))
              logged ? emit_prepare_kind_logged(asm, memory, s) : emit_prepare_kind(asm, memory, s)
              # A run of the other kind is ended first.
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_prepare_start")
              asm.lda(asm.direct(s.not_mask))
              asm.cmp(asm.direct(s.mask))
              asm.beq("rt_paint_prepare_next_tile")
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.label("rt_paint_prepare_start")
              asm.lda(asm.direct(s.tile))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.not_mask))
              asm.sta(asm.direct(s.mask))
              asm.bra("rt_paint_prepare_next_tile")
              asm.label("rt_paint_prepare_older")
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_prepare_next_tile") # no run to end
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.label("rt_paint_prepare_next_tile")
              asm.lda(asm.direct(s.tile))
              asm.cmp(asm.direct(s.last))
              asm.inc(asm.direct(s.tile)) # INC leaves the carry as the comparison set it
              asm.branch_long(:bcc, "rt_paint_prepare_tile")
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.plx
              asm.label("rt_paint_prepare_next_row")
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(COLUMNS)
              asm.sta(asm.direct(s.row))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              emit_dirty_rows_until(asm, memory, logged, "rt_paint_prepare_row")
              asm.label("rt_paint_prepare_rows_done")
              if logged
                PaintLog.emit_no_rows(asm, memory, DIRTY)
                asm.label("rt_paint_prepare_sent")
              end
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.abs(memory[SHOWN_GENERATION]))
              asm.jsr(asm.abs("rt_paint_map_runs")) if logged # after the tiles, which ask the map as it is shown
              asm.rtl

              # rt_paint_run_end (JSR): the run started at +chunk+, if one is, ended before +tile+
              # and put on its list: the runs of tiles not on the screen from the start, the others
              # from the end back. A run that starts where the last one put on its list ends — the
              # next row's, after a row changed to its end — is that run made longer: the tiles are
              # side by side in video RAM and in the copy, and one copy costs a blank less of its
              # time than two.
              asm.label("rt_paint_run_end")
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_run_end_none")
              asm.lda(asm.direct(s.mask))
              asm.bne("rt_paint_run_end_in_place")
              asm.ldx(asm.abs(memory[RUNS_END]))
              asm.beq("rt_paint_run_end_new")
              asm.dex
              asm.dex
              asm.dex
              asm.dex
              emit_run_joined(asm, memory, s, "rt_paint_run_end_new")
              asm.label("rt_paint_run_end_new")
              asm.ldx(asm.abs(memory[RUNS_END]))
              asm.txa
              asm.clc
              asm.adc(4)
              asm.sta(asm.abs(memory[RUNS_END]))
              asm.bra("rt_paint_run_end_put")
              asm.label("rt_paint_run_end_in_place")
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.cpx(MOST_RUNS * 4)
              asm.bcs("rt_paint_run_end_new_in_place")
              emit_run_joined(asm, memory, s, "rt_paint_run_end_new_in_place")
              asm.label("rt_paint_run_end_new_in_place")
              asm.lda(asm.abs(memory[IN_PLACE_START]))
              asm.sec
              asm.sbc(4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              asm.tax
              asm.label("rt_paint_run_end_put")
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.long_x(memory[RUNS]))
              asm.lda(asm.direct(s.tile))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.sta(asm.long_x(memory[RUNS] + 2))
              asm.lda(0xFFFF)
              asm.sta(asm.direct(s.chunk))
              asm.label("rt_paint_run_end_none")
              asm.rts
            end

            # In rt_paint_prepare, a deferred pass that matched the whole of the log it was compared
            # with: when that was the other picture's (PaintTurns), it takes its turn if it can,
            # and is otherwise made as any other pass, from rt_paint_prepare_cleared. A pass that
            # matched the last pass's goes on past.
            def emit_show_other_picture_or_clear(asm, memory)
              t = PaintTurns
              asm.lda(asm.abs(memory[t::MATCHING_OTHER]))
              asm.beq("rt_paint_prepare_last_pass")
              asm.lda(asm.abs(memory[t::OTHER_VALID]))
              asm.beq("rt_paint_prepare_no_turn")
              asm.lda(asm.abs(memory[t::OTHER_CLEAR]))
              asm.cmp(asm.abs(memory[CLEAR_PLACE]))
              asm.bne("rt_paint_prepare_no_turn")
              asm.jsr(asm.abs("rt_paint_turn"))
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.abs(memory[SHOWN_GENERATION]))
              asm.bra("rt_paint_prepare_last_pass")
              asm.label("rt_paint_prepare_no_turn")
              asm.jsr(asm.abs("rt_paint_apply_deferred_clear"))
              asm.brl("rt_paint_prepare_cleared")
              asm.label("rt_paint_prepare_last_pass")
            end

            # In rt_paint_run_end, X the run last put on the list: if it ends where the run at +chunk+
            # starts, it takes the run's tiles too, and the routine returns; else on to +apart+.
            def emit_run_joined(asm, memory, s, apart)
              asm.lda(asm.long_x(memory[RUNS]))
              asm.clc
              asm.adc(asm.long_x(memory[RUNS] + 2))
              asm.cmp(asm.direct(s.chunk))
              asm.bne(apart)
              asm.lda(asm.direct(s.tile))
              asm.sec
              asm.sbc(asm.long_x(memory[RUNS]))
              asm.sta(asm.long_x(memory[RUNS] + 2))
              asm.lda(0xFFFF)
              asm.sta(asm.direct(s.chunk))
              asm.rts
            end

            # The pass's bytes at most, on a Super FX cartridge: each changed row's tiles from its
            # leftmost to its rightmost and a run's setting up, then what goes with the map. +temp+ 1
            # if it fits in a blank.
            def emit_measure(asm, memory, s)
              dirty = memory[DIRTY]
              asm.stz(asm.direct(s.count))
              asm.ldx(0)
              asm.label("rt_paint_prepare_measure")
              asm.lda(asm.abs_x(dirty + 2))
              asm.sec
              asm.sbc(asm.abs_x(dirty))
              asm.bcc("rt_paint_prepare_measured_row") # a row with none
              asm.inc
              6.times { asm.asl }
              asm.clc
              asm.adc(RUN_SETTING_UP)
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.sta(asm.direct(s.count))
              asm.cmp(Blank::BLANK_BYTES + 1)
              asm.bcs("rt_paint_prepare_split") # too big already
              asm.label("rt_paint_prepare_measured_row")
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_prepare_measure")
              emit_count_with_map(asm, memory, s.count, "rt_paint_prepare_count", false)
              asm.lda(asm.direct(s.count))
              asm.cmp(Blank::BLANK_BYTES + 1)
              asm.bcs("rt_paint_prepare_split")
              asm.inc(asm.direct(s.temp)) # all of it with the map
            end

            # The tile X of the pass, +tile+ (rt_paint_prepare): to +older+ when it is not sent, or
            # +not_mask+ its kind. Here a tile of this generation is sent, and it is on the screen if
            # it was sent in the generation the screen shows (SHOWN_IN).
            def emit_prepare_kind(asm, memory, s)
              asm.lda(asm.long_x(memory[GENERATIONS]))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[GENERATION]))
              asm.branch_long(:bne, "rt_paint_prepare_older")
              asm.lda(asm.direct(s.temp))
              asm.bne("rt_paint_prepare_kind")
              asm.lda(asm.long_x(memory[SHOWN_IN]))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[SHOWN_GENERATION]))
              asm.bne("rt_paint_prepare_off_screen")
              asm.lda(1)
              asm.bra("rt_paint_prepare_kind")
              asm.label("rt_paint_prepare_off_screen")
              asm.lda(0)
              asm.label("rt_paint_prepare_kind")
              asm.sta(asm.direct(s.not_mask))
              asm.sep(0x20)
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.long_x(memory[SHOWN_IN]))
              asm.rep(0x20)
            end

            # The same on a plain cartridge (PaintLog): a tile is sent when its copy changed since its
            # slot was last sent, whatever its generation, and it is on the screen if the map video
            # RAM holds now (MAP_COPY, before rt_paint_map_runs changes it) points at it.
            # (A tile whose slot of video RAM already holds what the copy does is not sent either:
            # PaintLog's rt_paint_slot_behind.)
            def emit_prepare_kind_logged(asm, memory, s)
              asm.lda(asm.long_x(memory[PaintLog::UNSENT]))
              asm.and_a(0x00FF)
              asm.branch_long(:beq, "rt_paint_prepare_older")
              asm.sep(0x20)
              asm.lda(0)
              asm.sta(asm.long_x(memory[PaintLog::UNSENT]))
              asm.rep(0x20)
              asm.txa
              asm.asl
              asm.asl
              asm.tax
              asm.jsr(asm.abs("rt_paint_slot_behind"))
              asm.branch_long(:beq, "rt_paint_prepare_older") # its slot holds it already
              asm.lda(asm.direct(s.tile))
              asm.asl
              asm.tax
              asm.lda(asm.long_x(memory[MAP_COPY]))
              asm.cmp(asm.direct(s.tile))
              asm.beq("rt_paint_prepare_on_screen")
              asm.lda(0)
              asm.bra("rt_paint_prepare_kind")
              asm.label("rt_paint_prepare_on_screen")
              asm.lda(1)
              asm.label("rt_paint_prepare_kind")
              asm.sta(asm.direct(s.not_mask))
            end

            # X at the first row of DIRTY to look at, four bytes a row, or on to +none+ if there is
            # none: every row on a Super FX cartridge, and on a plain one the rows painted since the
            # last pass (PaintLog keeps which).
            def emit_dirty_rows_from(asm, memory, logged, none)
              unless logged
                asm.ldx(0)
                return
              end

              rows = memory[PaintLog::ROWS_OF.fetch(DIRTY)]
              asm.ldx(asm.abs(rows))
              asm.cpx(asm.abs(rows + 2))
              asm.branch_long(:bcs, none)
            end

            # Back to +again+ while X is short of the last row to look at, and its one.
            def emit_dirty_rows_until(asm, memory, logged, again)
              asm.cpx(logged ? asm.abs(memory[PaintLog::ROWS_OF.fetch(DIRTY)] + 2) : ROWS * 4)
              asm.branch_long(:bcc, again)
            end

            # +sum+ (a word of the direct page) and the bytes that go with the map in the blank: the
            # clear tile and the colours if they changed, and the map, whole on a Super FX cartridge
            # when it changed and its runs of changed cells on a plain one (PaintLog).
            def emit_count_with_map(asm, memory, sum, tag, logged)
              tint_changed = memory[Tint::STATE] + Tint::CHANGED
              flagged = [[memory[CLEAR_CHANGED], TILE_BYTES], [tint_changed, 512]]
              flagged.unshift([memory[MAP_CHANGED], MAP_BYTES]) unless logged
              flagged.each do |flag, bytes|
                skip = "#{tag}_#{bytes}"
                asm.lda(asm.abs(flag))
                asm.beq(skip)
                asm.lda(asm.direct(sum))
                asm.clc
                asm.adc(bytes)
                asm.sta(asm.direct(sum))
                asm.label(skip)
              end
              return unless logged

              runs = [PaintLog::MAP_RUN_BYTES]
              runs << TextLayer::CHANGED_BYTES if TextLayer.kept?(memory)
              runs.each do |name|
                asm.lda(asm.abs(memory[name]))
                asm.clc
                asm.adc(asm.direct(sum))
                asm.sta(asm.direct(sum))
              end
            end

            # --- the blank ---

            # rt_paint_upload (JSR, in the blank, the screen on — or off, before the first pass is
            # shown): the runs of tiles not on the screen, as many at a time as each blank has room
            # for (rt_paint_send_runs); then, all in one blank so they show together, the tiles on
            # the screen now (SHOWN_IN), the clear tile, the map and the colours of a fade or tint,
            # those of them that changed. More than a blank holds of those, the tiles go first, as
            # the others did, and the rest in the blank after.
            def emit_upload(asm, memory, s, bank, logged)
              h = Console::SNESHardware
              asm.label("rt_paint_upload")
              asm.lda(asm.abs(memory[RUNS_END]))
              asm.sta(asm.direct(s.last))
              asm.ldx(0)
              asm.jsr(asm.abs("rt_paint_send_runs"))

              # +height+ is the bytes of the clear tile, the map and the colours; +chunk+ those and
              # the tiles on the screen, each run counted RUN_SETTING_UP more for setting it going.
              asm.label("rt_paint_upload_last")
              asm.stz(asm.abs(memory[RUNS_END]))
              asm.stz(asm.direct(s.height))
              emit_count_with_map(asm, memory, s.height, "rt_paint_upload_count", logged)
              asm.lda(asm.direct(s.height))
              asm.sta(asm.direct(s.chunk))
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.label("rt_paint_upload_count_in_place")
              asm.cpx(MOST_RUNS * 4)
              asm.bcs("rt_paint_upload_counted")
              emit_add_run_bytes(asm, memory, s)
              asm.bra("rt_paint_upload_count_in_place")
              asm.label("rt_paint_upload_counted")
              # Nothing to copy, the camera alone moved: a line of the blank for its registers.
              asm.lda(asm.direct(s.chunk))
              asm.bne("rt_paint_upload_copies")
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_CHANGED))
              asm.branch_long(:beq, "rt_paint_upload_done")
              asm.jsr(asm.abs("rt_blank_time"))
              asm.brl("rt_paint_upload_camera")
              asm.label("rt_paint_upload_copies")
              asm.cmp(Blank::BLANK_BYTES + 1)
              asm.bcs("rt_paint_upload_apart")
              asm.jsr(asm.abs("rt_blank_room"))
              asm.jsr(asm.abs("rt_paint_send_ready"))
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.label("rt_paint_upload_in_place")
              asm.cpx(MOST_RUNS * 4)
              asm.bcs("rt_paint_upload_rest")
              asm.jsr(asm.abs("rt_paint_send_run"))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_upload_in_place")
              asm.label("rt_paint_upload_apart")
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.direct(s.last))
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.jsr(asm.abs("rt_paint_send_runs"))
              asm.lda(asm.direct(s.height))
              asm.jsr(asm.abs("rt_blank_room"))
              asm.label("rt_paint_upload_rest")
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              whole = [[CLEAR_CHANGED, CLEAR_TILE_COPY, CLEAR_TILE_AT, TILE_BYTES]]
              whole << [MAP_CHANGED, MAP_COPY, MAP, MAP_BYTES] unless logged
              PaintLog.emit_map_runs_upload(asm, memory) if logged
              asm.jsr(asm.abs("rt_paint_layer_upload")) if TextLayer.kept?(memory)
              whole.each do |flag, from, to, bytes|
                skip = "rt_paint_upload_#{to}_sent"
                asm.lda(asm.abs(memory[flag]))
                asm.beq(skip)
                asm.stz(asm.abs(memory[flag]))
                asm.lda(to)
                asm.sta(asm.abs(h::VMADDL))
                asm.lda(bytes)
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
                asm.lda(memory[from] & 0xFFFF)
                asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
                asm.sep(0x20)
                asm.lda(memory[from] >> 16)
                emit_copy_to_video_ram(asm)
                asm.label(skip)
              end
              asm.jsr(asm.abs("rt_tint_upload"))
              # The camera: the layer's scroll, each register written twice, its low byte and then
              # its high, and the window's columns.
              asm.label("rt_paint_upload_camera")
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_CHANGED))
              asm.beq("rt_paint_upload_done")
              asm.stz(asm.abs(memory[CAMERA] + CAMERA_CHANGED))
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_ACROSS))
              Picture.emit_scroll_register(asm, h::BG1HOFS)
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_DOWN))
              Picture.emit_scroll_register(asm, h::BG1VOFS)
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_WINDOW))
              asm.sep(0x20)
              asm.sta(asm.abs(h::WH0))
              asm.xba
              asm.sta(asm.abs(h::WH1))
              asm.rep(0x20)
              asm.label("rt_paint_upload_done")
              asm.rts
            end

            # rt_paint_send_runs (JSR): the runs of RUNS from X up to +last+, as many at a time as
            # the blank has time for (Blank's rt_blank_left), each counted RUN_SETTING_UP more; when
            # not even the next fits, as many of its tiles as do, and the rest in the next blank.
            # One check of the blank for each handful of runs rather than for each run, which costs
            # as much as copying a tile. The handful then goes on that one check, so each run is
            # counted for the time it takes to pick it too (RUN_PICKING), which a handful of many
            # small runs makes lines of. After a handful the line is asked again, and the rest of
            # the blank filled.
            # (+tile+ is where the handful starts, +mark_count+ where it ends, +chunk+ the room,
            # +count+ the handful's bytes.)
            def emit_send_runs(asm, memory, s)
              asm.label("rt_paint_send_runs")
              asm.stx(asm.direct(s.tile))
              asm.cpx(asm.direct(s.last))
              asm.branch_long(:bcs, "rt_paint_send_runs_done")
              asm.jsr(asm.abs("rt_blank_left"))
              asm.sta(asm.direct(s.chunk))
              asm.stz(asm.direct(s.count))
              asm.label("rt_paint_send_runs_scan")
              asm.cpx(asm.direct(s.last))
              asm.bcs("rt_paint_send_runs_scanned")
              asm.lda(asm.long_x(memory[RUNS] + 2))
              6.times { asm.asl }
              asm.clc
              asm.adc(RUN_SETTING_UP + RUN_PICKING)
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.cmp(asm.direct(s.chunk))
              asm.beq("rt_paint_send_runs_take")
              asm.bcs("rt_paint_send_runs_scanned")
              asm.label("rt_paint_send_runs_take")
              asm.sta(asm.direct(s.count))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_send_runs_scan")
              asm.label("rt_paint_send_runs_scanned")
              asm.stx(asm.direct(s.mark_count))
              asm.ldx(asm.direct(s.tile))
              asm.lda(asm.direct(s.count))
              asm.bne("rt_paint_send_runs_go")
              # Not even the next run fits: as many of its tiles as do go now, and the run starts
              # past them, so the blank is filled rather than left with room unused.
              asm.lda(asm.direct(s.chunk))
              asm.sec
              asm.sbc(RUN_SETTING_UP + RUN_PICKING)
              asm.bcc("rt_paint_send_runs_full")
              6.times { asm.lsr }
              asm.beq("rt_paint_send_runs_full")
              asm.sta(asm.direct(s.y)) # the tiles that fit
              asm.jsr(asm.abs("rt_paint_send_ready"))
              asm.lda(asm.long_x(memory[RUNS] + 2))
              asm.pha
              asm.lda(asm.direct(s.y))
              asm.sta(asm.long_x(memory[RUNS] + 2))
              asm.jsr(asm.abs("rt_paint_send_run"))
              asm.pla
              asm.sec
              asm.sbc(asm.direct(s.y))
              asm.sta(asm.long_x(memory[RUNS] + 2))
              asm.lda(asm.long_x(memory[RUNS]))
              asm.clc
              asm.adc(asm.direct(s.y))
              asm.sta(asm.long_x(memory[RUNS]))
              asm.label("rt_paint_send_runs_full")
              asm.jsr(asm.abs("rt_blank_next"))
              asm.brl("rt_paint_send_runs")
              asm.label("rt_paint_send_runs_go")
              asm.jsr(asm.abs("rt_paint_send_ready"))
              asm.label("rt_paint_send_runs_one")
              asm.cpx(asm.direct(s.mark_count))
              asm.branch_long(:bcs, "rt_paint_send_runs")
              asm.jsr(asm.abs("rt_paint_send_run"))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_send_runs_one")
              asm.label("rt_paint_send_runs_done")
              asm.rts
            end

            # rt_paint_send_ready (JSR): the copying engine's channel 0 set to copy from the copy in
            # +bank+ to video RAM's two ports, what every run shares, so each run (rt_paint_send_run)
            # sets only its own place and length. Set again after anything else could copy, as
            # after a wait for the next blank.
            # rt_paint_send_run (JSR): the run at X of RUNS copied to video RAM, its tiles to their
            # own slots. Keeps X.
            def emit_send_run(asm, memory, bank)
              h = Console::SNESHardware
              asm.label("rt_paint_send_ready")
              asm.sep(0x20)
              asm.lda(bank)
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_TWO_PORTS)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::VMDATAL & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.rep(0x20)
              asm.rts

              asm.label("rt_paint_send_run")
              asm.lda(asm.long_x(memory[RUNS] + 2))
              6.times { asm.asl }
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.lda(asm.long_x(memory[RUNS]))
              5.times { asm.asl } # the first tile's word in video RAM
              asm.sta(asm.abs(h::VMADDL))
              asm.asl # ...and its byte in the copy
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.rts
            end

            # What setting a run going costs the blank, counted as bytes copied: a little over half a
            # line (Blank::BYTES_A_LINE), for the hundred or so cycles of code that start its copy
            # (rt_paint_send_run sets only what differs from run to run, which keeps it inside that
            # even for many runs of a tile each).
            RUN_SETTING_UP = 96
            # What picking a run for a handful costs the blank (rt_paint_send_runs), counted the same
            # way: under a third of a line, for the sixty or so cycles of looking at it.
            RUN_PICKING = 48

            # The run at X of RUNS added to +chunk+, as its bytes and RUN_SETTING_UP; X on to the next.
            def emit_add_run_bytes(asm, memory, s)
              asm.lda(asm.long_x(memory[RUNS] + 2))
              6.times { asm.asl }
              asm.clc
              asm.adc(RUN_SETTING_UP)
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.chunk))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
            end

            # The copying engine's channel 0 sending to video RAM's two ports, from the bank in A (8
            # bits wide), the address and count already set; A back to 16 bits.
            def emit_copy_to_video_ram(asm)
              h = Console::SNESHardware
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_TWO_PORTS)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::VMDATAL & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
            end

            # The masks of a tile's row from a pixel to its right end (rt_paint_from_left, nine: from
            # pixel 0 to past pixel 7) and from its left end up to a pixel (rt_paint_up_to, nine); and
            # the bytes the copying engine fills work RAM with: a generation no tile is in, and either
            # byte of a cell showing the clear tile.
            def emit_tables(asm)
              asm.label("rt_paint_from_left")
              asm.data_words(*(0..8).map { |from| (0xFF >> from) * 0x0101 })
              asm.label("rt_paint_up_to")
              asm.data_words(*(0..8).map { |to| ((0xFF00 >> to) & 0xFF) * 0x0101 })
              asm.label("rt_paint_no_generation")
              asm.data_bytes(NO_GENERATION)
              asm.label("rt_paint_clear_cell")
              asm.data_bytes(CLEAR_CELL & 0xFF)
            end
          end
        end
      end
    end
  end
end
