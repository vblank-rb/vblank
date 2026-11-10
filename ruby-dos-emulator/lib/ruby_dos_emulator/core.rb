# frozen_string_literal: true

require "fiddle"
require "fileutils"
require "tmpdir"

module RubyDOSEmulator
  # ONE DOS MACHINE, PLAYED A FRAME AT A TIME with nobody watching: a program (an .EXE or a .COM)
  # run by DOSBox Pure (a libretro core, see CoreLibrary) with the program's own folder as drive C:,
  # its keys pressed from Ruby, and everything a test wants to read back handed over as plain bytes:
  # the first megabyte of memory, the video card's memory and palette and mode, the picture shown
  # and the sound made.
  #
  #   core = RubyDOSEmulator::Core.new("GAME.EXE")
  #   core.press(%i[left ctrl])
  #   core.run_frame
  #   core.peek(0x1234, 0x10)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE MACHINE PER LIBRARY: it keeps the whole PC in the library's own globals.
  # So each Core loads a copy of the library of its own (CoreCopy), and two Cores in one process are
  # two machines that cannot see each other.
  #
  # THE MACHINE IS SET BY A DOSBOX CONFIGURATION FILE (#configuration), which is the "game" the core
  # is loaded with: DOSBox Pure treats a .conf as plain DOSBox does. It says a Sound Blaster at 220h
  # on IRQ 5 and DMA 1, an AdLib's OPL2, a VGA card with the memory a VESA mode wants, a 486, and a
  # FIXED number of processor cycles for every millisecond, so a program runs the same on every run
  # and on every machine, whatever the host's speed. Then it mounts the program's folder and runs it.
  #
  # THE PICTURE is what DOSBox shows (#picture), as the core hands it over after each frame: 24-bit
  # colours, the palette already applied. #vga_memory and #palette are the card's own, for a check
  # that wants what the program wrote rather than what was shown.
  #
  # THE FRONTEND IS IN THE CORE, NOT IN RUBY. DOSBox Pure emulates on a thread of its own and calls
  # its frontend (the settings it asks for, the picture, the sound, the keys) from there, and Ruby
  # stops with a bug report when a callback of its own is run by a thread it did not start. So the
  # probe patch carries the frontend's half too (the vblank_* functions): it keeps the last picture,
  # the sound made and the keys held, and this class hands the core their addresses and reads them.
  class Core
    # libretro's name for system RAM, and the probe patch's own (core/dosbox-vblank-probe.patch).
    SYSTEM_RAM = 2
    VIDEO_RAM = 0x8001
    PALETTE = 0x8002
    VGA_STATE = 0x8003

    # DOSBox's speed: processor cycles in each millisecond. 30000 is about a fast 486.
    CYCLES = 30_000

    # libretro's key numbers (RETROK_*) for the keys a DOS game is played with, by name.
    KEYS = { up: 273, down: 274, right: 275, left: 276, ctrl: 306, alt: 308, enter: 13, shift: 303,
             z: 122, x: 120, space: 32, escape: 27, left_shift: 304, left_ctrl: 306, right_ctrl: 305 }.freeze

    # A frame as the core handed it over: its size and its pixels as 0xRRGGBB, row by row.
    Picture = Data.define(:width, :height, :pixels)

    attr_reader :frames, :sample_rate, :fps

    # THE START GATE: a byte at 0040:00F2, in the 16 bytes the PC keeps free for programs to talk to each
    # other. A program started as `GAME.EXE HOLD` is meant to set it and wait for it to be cleared, so a
    # reader can see its first pass from the start: DOSBox runs the program during its own start-up, and
    # without the gate the first passes are over before a test can look. #release_gate lets it go.
    START_GATE_AT = 0x4F2

    # +program+ is the path of an .EXE or a .COM; its folder is drive C: (a copy of it, so a program
    # that saves a file never changes what is on disk; read it back with #drive_file). With +hold+ the
    # program is started with the word HOLD after its name (see START_GATE_AT).
    def initialize(program, hold: false)
      @hold = hold
      @dir = Dir.mktmpdir("ruby-dos-emulator")
      @drive = File.join(@dir, "c")
      FileUtils.mkdir_p(@drive)
      FileUtils.cp_r(File.join(File.dirname(File.expand_path(program)), "."), @drive)
      @frames = 0
      @held = []
      @kept = [] # what the core holds a pointer to, kept from the garbage collector
      load_library
      hand_over_callbacks
      @call[:retro_init].call
      load_program(File.basename(program))
      read_timing
    end

    # The keys held down, by name (KEYS), from the next frame on.
    def press(keys)
      unknown = keys - KEYS.keys
      raise ArgumentError, "a DOS keyboard has no #{unknown.join(', ')} key here" unless unknown.empty?

      codes = keys.map { |key| KEYS.fetch(key) }
      (@held - codes).each { |code| @call[:vblank_key_event].call(0, code) }
      (codes - @held).each { |code| @call[:vblank_key_event].call(1, code) }
      @held = codes
    end

    # Plays one frame: one picture's time, about a seventieth of a second in mode 13h. The machine is left
    # parked between two frames (see the probe patch's vblank_finish_frame), so everything read after it is
    # what the program has done by then, whatever the host's speed. #picture is the frame before that one:
    # DOSBox hands over a frame's picture a frame after it emulates it, so read the screen from
    # #chained_pixels and #palette to see what the memory holds now.
    def run_frame
      @call[:retro_run].call
      @call[:vblank_finish_frame].call
      @frames += 1
      self
    end

    # Whether the program has reached its gate and is waiting there (see START_GATE_AT).
    def gate_closed? = peek(START_GATE_AT, 1).getbyte(0) == 1

    # Lets a program held at its start go on.
    def release_gate = poke(START_GATE_AT, "\0")

    # --- the picture ---

    # The last picture the core handed over (a Picture), or nil before the first.
    def picture
      width = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pixels = @call[:vblank_picture].call(width, width + 4)
      return nil if pixels.null?

      wide, high = width.to_str(8).unpack("L<2")
      Picture.new(width: wide, height: high, pixels: pixels.to_str(wide * high * 4).unpack("V*").map { |pixel| pixel & 0xFF_FFFF })
    end

    # --- the memories ---

    # +count+ bytes of the PC's first megabyte, from linear address +address+ (segment * 16 + offset).
    def peek(address, count) = live(SYSTEM_RAM, 0x10_0000)[address, count]

    # Writes +bytes+ into the PC's first megabyte at linear address +address+, as a program's own store would.
    def poke(address, bytes) = (live(SYSTEM_RAM, 0x10_0000)[address, bytes.bytesize] = bytes)

    # The video card's memory as DOSBox keeps it: four planes interleaved (byte 4n + plane). A mode
    # that is unchained (Mode X) reads that as it is. Mode 13h is chained, and DOSBox spreads its
    # pixels over the planes four at a time, 16 bytes apart (see #chained_pixels).
    def vga_memory = memory(VIDEO_RAM)

    # The first +count+ pixels of a chained mode (mode 13h) as one palette index each, in screen order.
    # Pixel n is at byte ((n >> 2) << 4) + (n & 3) of the card's memory: the card's address n goes to
    # plane (n & 3), at plane address (n >> 2), and a plane's byte is 4 bytes in DOSBox's memory.
    def chained_pixels(count = 64_000)
      memory = vga_memory
      Array.new((count + 3) / 4) { |group| memory.byteslice(group * 16, 4) }.join.byteslice(0, count)
    end

    # The 256 colours of the card's palette as [red, green, blue], each of 6 bits as the card keeps them.
    def palette = memory(PALETTE).unpack("C*").each_slice(3).to_a

    # The card's state: its mode number (DOSBox's own numbering), and the width and height it draws.
    def vga_state
      mode, width, height, address_add = memory(VGA_STATE).unpack("L<4")
      { mode: mode, width: width, height: height, address_add: address_add }
    end

    # --- the sound ---

    # The sound made since this was last asked: pairs of signed 16-bit samples as [left, right], at
    # #sample_rate a second.
    def take_audio
      room = 1 << 20
      buffer = Fiddle::Pointer.malloc(room * 2, Fiddle::RUBY_FREE)
      held = @call[:vblank_take_sound].call(buffer, room)
      buffer.to_str([held, room].min * 2).unpack("s<*").each_slice(2).to_a
    end

    # --- the files ---

    # What a program saved on drive C: (its name in capitals, as DOS keeps it), or nil.
    def drive_file(name)
      found = Dir.children(@drive).find { |child| child.casecmp?(name) }
      found && File.binread(File.join(@drive, found))
    end

    # Unloads the program, shuts the core and lets go of its library.
    def destroy
      return unless @call

      @call[:retro_unload_game].call
      @call[:retro_deinit].call
      @call = nil
      FileUtils.rm_rf(@dir)
    end

    private

    def memory(id)
      size = @call[:retro_get_memory_size].call(id)
      return "".b if size.zero?

      Fiddle::Pointer.new(@call[:retro_get_memory_data].call(id).to_i)[0, size]
    end

    def live(id, size) = Fiddle::Pointer.new(@call[:retro_get_memory_data].call(id).to_i, size)

    FUNCTIONS = {
      retro_set_environment: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_video_refresh: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_audio_sample: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_audio_sample_batch: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_input_poll: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_input_state: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_init: [[], Fiddle::TYPE_VOID],
      retro_deinit: [[], Fiddle::TYPE_VOID],
      retro_load_game: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_BOOL],
      retro_unload_game: [[], Fiddle::TYPE_VOID],
      retro_run: [[], Fiddle::TYPE_VOID],
      retro_get_system_av_info: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_get_memory_data: [[Fiddle::TYPE_UINT], Fiddle::TYPE_VOIDP],
      retro_get_memory_size: [[Fiddle::TYPE_UINT], Fiddle::TYPE_SIZE_T],
      vblank_finish_frame: [[], Fiddle::TYPE_VOID],
      vblank_set_directory: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      vblank_key_event: [[Fiddle::TYPE_INT, Fiddle::TYPE_UINT], Fiddle::TYPE_VOID],
      vblank_picture: [[Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP],
      vblank_take_sound: [[Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_SIZE_T]
    }.freeze

    # The core's own frontend functions the setters are handed (see the comment atop this class).
    FRONTEND = { retro_set_environment: :vblank_environment, retro_set_video_refresh: :vblank_video_refresh,
                 retro_set_audio_sample: :vblank_audio_sample, retro_set_audio_sample_batch: :vblank_audio_batch,
                 retro_set_input_poll: :vblank_input_poll, retro_set_input_state: :vblank_input_state }.freeze

    def load_library
      copy = CoreCopy.make
      @handle = Fiddle::Handle.new(copy.path, Fiddle::Handle::RTLD_NOW)
      @handle.disable_close # the library stays mapped anyway (see CoreCopy), so it is never asked to close
      copy.delete
      @call = FUNCTIONS.to_h do |name, (args, result)|
        [name, Fiddle::Function.new(@handle[name.to_s], args, result)]
      end
    end

    def hand_over_callbacks
      FRONTEND.each { |setter, function| @call.fetch(setter).call(Fiddle::Pointer.new(@handle[function.to_s])) }
      @call[:vblank_set_directory].call(kept_string(@dir))
    end

    def kept_string(text) = kept_bytes("#{text}\0".b)

    def kept_bytes(bytes)
      pointer = Fiddle::Pointer.malloc([bytes.bytesize, 1].max, Fiddle::RUBY_FREE)
      pointer[0, bytes.bytesize] = bytes
      @kept << pointer
      pointer
    end

    # The DOSBox configuration this machine is made from (see the comment atop this class).
    def configuration(program)
      <<~CONF
        [dosbox]
        machine=svga_s3
        memsize=4
        [render]
        aspect=false
        [cpu]
        core=normal
        cputype=486
        cycles=fixed #{CYCLES}
        [mixer]
        rate=44100
        [sblaster]
        sbtype=sb2
        sbbase=220
        irq=5
        dma=1
        oplmode=opl2
        [autoexec]
        @echo off
        mount c "#{@drive}"
        c:
        #{program}#{' HOLD' if @hold}
      CONF
    end

    # libretro's retro_game_info: the path, the bytes and their count, and nothing for meta.
    def load_program(program)
      path = File.join(@dir, "machine.conf")
      File.write(path, configuration(program))
      info = kept_bytes([kept_string(path).to_i, 0, 0, 0].pack("J4"))
      raise ArgumentError, "DOSBox would not load #{program}" unless @call[:retro_load_game].call(info)
    end

    # retro_system_av_info: four numbers for the picture's size, its aspect ratio, then the frame rate
    # and the sound's rate, both doubles.
    def read_timing
      info = Fiddle::Pointer.malloc(40, Fiddle::RUBY_FREE)
      @call[:retro_get_system_av_info].call(info)
      @fps, @sample_rate = info.to_str(40).unpack("x24E2")
    end
  end
end
