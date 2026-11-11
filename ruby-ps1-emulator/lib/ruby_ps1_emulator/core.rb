# frozen_string_literal: true

require "fiddle"
require "fileutils"
require "tmpdir"

module RubyPS1Emulator
  # ONE PLAYSTATION, PLAYED A FRAME AT A TIME with nobody watching: a program (a PS-X EXE) loaded into
  # Beetle PSX (a libretro core, see CoreLibrary), its buttons set from Ruby, and everything a test wants
  # to read back handed over as plain bytes — main RAM, video RAM and the picture shown in it, the
  # graphics chip's display settings, the scratchpad and the processor's registers — and where the
  # processor's time went, by address, and how long the graphics chip spent drawing, for a profiler.
  #
  #   core = RubyPS1Emulator::Core.new("game.exe")
  #   core.set_buttons(%i[right cross])
  #   core.run_frame
  #   core.ram_read32(0x80010000)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE CONSOLE PER LIBRARY: it keeps the whole machine in the library's own
  # globals. So each Core loads a copy of the library of its own (KeptCopy), and two Cores in one
  # process are two consoles that cannot see each other.
  #
  # NO BIOS FROM SONY, unless one is handed over. The core is told a system folder with no BIOS in it,
  # so it starts OpenBIOS, the free BIOS built into it. Beetle loads a PS-X EXE by letting the BIOS
  # start and then copying the program into RAM and jumping to it, where the BIOS would have started
  # the disc. OpenBIOS never reaches the place Beetle does that from, so the probe patch starts the
  # program at power-on instead, with no BIOS run at all.
  #
  # A BIOS FROM SONY is the player's own, dumped from their console, and is named when the core is made
  # (+bios+). The core finds a BIOS by its file name in the system folder, so a link to the player's
  # file is put there under the name the core asks for (BIOS_NAME): a link and never a copy, gone with
  # the folder. Then the BIOS runs first, sets its kernel up in RAM as it does on a console, and Beetle
  # starts the program from inside it, so the program finds the console as a BIOS leaves it and not as
  # power-on does.
  #
  # THE PICTURE is read from video RAM, at the place and the size the graphics chip is told to show,
  # never from the picture the core hands its front end (which it crops and widens for a television).
  # So a pixel here is exactly the 15 bits the program drew: red in the low five, then green, then blue.
  class Core
    # libretro's name for main RAM, and the probe patch's own (core/beetle-vblank-probe.patch).
    SYSTEM_RAM = 2
    VIDEO_RAM = 0x8001
    GPU_STATE = 0x8002
    SCRATCHPAD = 0x8003
    CPU_REGISTERS = 0x8004
    PROCESSOR_TIME = 0x8007
    GPU_BUSY = 0x8008

    RAM_SIZE = 0x20_0000
    SCRATCHPAD_SIZE = 0x400
    VRAM_WIDTH = 1024
    VRAM_HEIGHT = 512

    # libretro's joypad: the number it asks about each button by. The PlayStation's pad as the core lays
    # it out: its "B" is cross, its "A" circle, its "Y" square and its "X" triangle.
    BUTTONS = { cross: 0, square: 1, select: 2, start: 3, up: 4, down: 5, left: 6, right: 7,
                circle: 8, triangle: 9, l1: 10, r1: 11, l2: 12, r2: 13 }.freeze

    # The graphics chip's settings in the order the probe patch hands them over.
    GPU_STATE_NAMES = %i[display_mode display_off display_x display_y horizontal_start horizontal_end
                         vertical_start vertical_end clip_left clip_top clip_right clip_bottom offset_x offset_y
                         upscale_shift scanline].freeze

    # The processor's registers in the order the probe patch hands them over.
    REGISTER_NAMES = (%i[zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra] +
                      %i[lo hi pc]).freeze

    # The widths the display mode's low two bits choose, and the one bit 6 chooses over them.
    WIDTHS = [256, 320, 512, 640].freeze
    WIDTH_368 = 1 << 6

    # libretro's environment calls that matter here.
    GET_CAN_DUPE = 3
    GET_SYSTEM_DIRECTORY = 9
    SET_PIXEL_FORMAT = 10
    GET_VARIABLE_UPDATE = 17
    GET_LOG_INTERFACE = 27
    GET_SAVE_DIRECTORY = 31

    JOYPAD = 1
    JOYPAD_MASK = 256

    # The name Beetle looks for a North American console's BIOS under in its system folder, the region
    # it takes a PS-X EXE to be for. It takes a file of that name whichever console it was dumped from.
    BIOS_NAME = "scph5501.bin"

    attr_reader :frames

    # How many pairs of sound samples the console has made since power-on. The sound chip makes 44100 a
    # second, one every 768 cycles of the processor, so this is a clock: how long the frames played took.
    attr_reader :sound_frames

    # +exe_path+ is the program. +save_dir+ is where the core is told to keep files; a core made without
    # one keeps them in a folder of its own that is gone with it.
    #
    # +bios+ is the path of a BIOS file to start the console under, the player's own (see "A BIOS FROM
    # SONY" above). Without one the console has OpenBIOS.
    def initialize(exe_path, save_dir: nil, bios: nil)
      raise ArgumentError, "there is no BIOS file at #{bios}" if bios && !File.file?(bios)

      @dir = Dir.mktmpdir("ruby-ps1-emulator")
      @save_dir = save_dir || @dir
      File.symlink(File.expand_path(bios), File.join(@dir, BIOS_NAME)) if bios
      @buttons = Array.new(2) { [] }
      @frames = 0
      @sound_frames = 0
      @kept = [] # what the core holds a pointer to, kept from the garbage collector
      load_library
      @quiet_log = quiet_log
      hand_over_callbacks
      @call[:retro_init].call
      load_program(exe_path)
    end

    # The buttons down on controller +port+ (0 for the first), by name (BUTTONS).
    def set_buttons(buttons, port: 0)
      unknown = buttons - BUTTONS.keys
      raise ArgumentError, "a PlayStation pad has no #{unknown.join(', ')} button" unless unknown.empty?

      @buttons[port] = buttons.map { |button| BUTTONS.fetch(button) }
    end

    # Plays one frame.
    def run_frame
      @call[:retro_run].call
      @frames += 1
      self
    end

    # --- the picture ---

    # The graphics chip's display and drawing settings by name (GPU_STATE_NAMES).
    def gpu_state
      values = memory(GPU_STATE).unpack("l<*")
      GPU_STATE_NAMES.zip(values).to_h
    end

    # The size of the picture the chip shows: its width from the display mode, its height 240 lines (or
    # 480 when interlaced, bit 5 with bit 2).
    def width
      mode = gpu_state.fetch(:display_mode)
      mode.anybits?(WIDTH_368) ? 368 : WIDTHS.fetch(mode & 3)
    end

    def height = gpu_state.fetch(:display_mode).allbits?(0x24) ? 480 : 240

    # The picture shown: #width × #height 15-bit colours, row by row, read from video RAM where the chip
    # is told the picture starts. A row that runs past video RAM's right edge goes round to its left,
    # as the chip's own reading does.
    def colors
      state = gpu_state
      colors_at(state.fetch(:display_x), state.fetch(:display_y), width, height)
    end

    # The +width+ × +height+ pixels of video RAM whose top left is (+left+, +top+), row by row, each the
    # 15 bits the chip shows (its top bit, the mask bit, dropped). Only those rows are read, in place: a
    # row that runs past video RAM's right edge goes round to its left, and one past the bottom to the
    # top, as the chip's own reading does.
    def colors_at(left, top, width, height)
      video = live(VIDEO_RAM, VRAM_WIDTH * VRAM_HEIGHT * 2)
      left %= VRAM_WIDTH
      before_edge = [width, VRAM_WIDTH - left].min
      Array.new(height) do |row|
        line = ((top + row) % VRAM_HEIGHT) * VRAM_WIDTH * 2
        bytes = video[line + (left * 2), before_edge * 2]
        bytes += video[line, (width - before_edge) * 2] if width > before_edge
        bytes.unpack("v*").map { |color| color & 0x7FFF }
      end.flatten
    end

    # --- the memories ---

    # All 2 megabytes of main RAM, from 80000000h.
    def ram = memory(SYSTEM_RAM)

    # Video RAM: 1024 × 512 pixels of 16 bits, row by row, low byte first.
    def vram = memory(VIDEO_RAM)

    # The scratchpad: 1K at 1F800000h.
    def scratchpad = memory(SCRATCHPAD)

    # The processor's registers by name (REGISTER_NAMES): the 32 general ones, LO, HI and the
    # program counter.
    def registers = REGISTER_NAMES.zip(memory(CPU_REGISTERS).unpack("L<*")).to_h

    # --- the time ---

    # WHERE THE PROCESSOR'S TIME WENT since this was last asked: each address an instruction started
    # at (as 8xxxxxxxh, where a program runs), and the processor's cycles from its fetch to the next
    # instruction's, whatever it stood still for included (a copy that stops it, a wait on the
    # graphics chip). Code outside main RAM, the BIOS's, is all counted at 80000000h, where no
    # program runs. The first ask starts the count and
    # answers nothing.
    def take_processor_time
      bytes = memory(PROCESSOR_TIME)
      bytes.unpack("L<Q<" * (bytes.bytesize / 12)).each_slice(2).to_h
    end

    # HOW LONG THE GRAPHICS CHIP HAS SPENT DRAWING since power-on, in the processor's cycles. The chip
    # draws while the processor goes on, so this is time of its own: a frame whose chip was busy for
    # most of it is a frame the chip, not the processor, made long, once the processor waits for it.
    def gpu_busy_cycles = memory(GPU_BUSY).unpack1("Q<")

    # Main RAM read in place, at +address+ (only its low 21 bits matter, so 80010000h, A0010000h and
    # 00010000h are the same byte), low byte first as the console keeps a number.
    def ram_read8(address) = ram_bytes(address, 1).getbyte(0)
    def ram_read16(address) = ram_bytes(address, 2).unpack1("v")
    def ram_read32(address) = ram_bytes(address, 4).unpack1("V")
    def ram_bytes(address, count) = live(SYSTEM_RAM, RAM_SIZE)[address & (RAM_SIZE - 1), count]
    def ram_write32(address, value) = (live(SYSTEM_RAM, RAM_SIZE)[address & (RAM_SIZE - 1), 4] = [value & 0xFFFF_FFFF].pack("V"))

    # The scratchpad read and written in place, +offset+ bytes from its start (1F800000h).
    def scratchpad_bytes(offset, count) = live(SCRATCHPAD, SCRATCHPAD_SIZE)[offset & (SCRATCHPAD_SIZE - 1), count]
    def scratchpad_write32(offset, value) = (live(SCRATCHPAD, SCRATCHPAD_SIZE)[offset & (SCRATCHPAD_SIZE - 1), 4] = [value & 0xFFFF_FFFF].pack("V"))

    # Unloads the program, shuts the core and lets go of its library.
    def destroy
      return unless @call

      @call[:retro_unload_game].call
      @call[:retro_deinit].call
      @handle.close
      @copy.give_back
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
      retro_set_controller_port_device: [[Fiddle::TYPE_UINT, Fiddle::TYPE_UINT], Fiddle::TYPE_VOID],
      retro_get_memory_data: [[Fiddle::TYPE_UINT], Fiddle::TYPE_VOIDP],
      retro_get_memory_size: [[Fiddle::TYPE_UINT], Fiddle::TYPE_SIZE_T]
    }.freeze

    def load_library
      @copy = KeptCopy.take
      @handle = Fiddle::Handle.new(@copy.path, Fiddle::Handle::RTLD_NOW)
      @call = FUNCTIONS.to_h do |name, (args, result)|
        [name, Fiddle::Function.new(@handle[name.to_s], args, result)]
      end
      refuse_unpatched_core!
    end

    def refuse_unpatched_core!
      return if @call[:retro_get_memory_size].call(GPU_STATE).positive?

      raise LoadError, "#{CoreLibrary.path} is a Beetle PSX core built without this gem's probe patch, so it " \
                       "cannot hand over the console's memories. Build it with `rake compile_core` in " \
                       "ruby-ps1-emulator/."
    end

    def hand_over_callbacks
      @callbacks = {
        retro_set_environment: closure(Fiddle::TYPE_BOOL, [Fiddle::TYPE_UINT, Fiddle::TYPE_VOIDP]) { |cmd, data| environment(cmd, data) },
        retro_set_video_refresh: closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT, Fiddle::TYPE_UINT,
                                                             Fiddle::TYPE_SIZE_T]) { nil },
        retro_set_audio_sample: closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_INT16_T, Fiddle::TYPE_INT16_T]) { nil },
        retro_set_audio_sample_batch: closure(Fiddle::TYPE_SIZE_T, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]) do |_data, frames|
          @sound_frames += frames
          frames
        end,
        retro_set_input_poll: closure(Fiddle::TYPE_VOID, []) { nil },
        retro_set_input_state: closure(Fiddle::TYPE_INT16_T, [Fiddle::TYPE_UINT, Fiddle::TYPE_UINT, Fiddle::TYPE_UINT,
                                                              Fiddle::TYPE_UINT]) do |port, device, _index, id|
          button_state(port, device, id)
        end
      }
      @callbacks.each { |setter, callback| @call.fetch(setter).call(callback) }
    end

    # What the core says as it works (which BIOS it found, which pads are plugged in) goes to a log the
    # frontend hands it, or to the terminal when there is none. This one hears it and says nothing: the
    # function takes a level, a format and the format's numbers, and only the first two are named here,
    # which is all a caller of a C function that takes any number of them needs.
    def quiet_log = closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP]) { nil }

    def closure(result, args, &block) = Fiddle::Closure::BlockCaller.new(result, args, &block)

    # What the core asks of the controller: one button, or all of them as bits when it asks for the mask.
    def button_state(port, device, id)
      return 0 unless device == JOYPAD

      down = @buttons.fetch(port, [])
      return down.sum { |button| 1 << button } if id == JOYPAD_MASK

      down.include?(id) ? 1 : 0
    end

    # What the core asks of its frontend. Anything not answered here is answered "no", which a core
    # takes as the frontend not having it, and uses its own settings. Any pixel format is taken, since
    # the picture is read from video RAM and never from what the core hands over.
    def environment(cmd, data)
      case cmd & 0xFFFF
      when GET_CAN_DUPE then write_bool(data, true)
      when SET_PIXEL_FORMAT then true
      when GET_SYSTEM_DIRECTORY then write_pointer(data, kept_string(@dir))
      when GET_SAVE_DIRECTORY then write_pointer(data, kept_string(@save_dir))
      when GET_VARIABLE_UPDATE then write_bool(data, false)
      when GET_LOG_INTERFACE then write_pointer(data, @quiet_log)
      else false
      end
    rescue StandardError
      false
    end

    def write_bool(data, value)
      Fiddle::Pointer.new(data.to_i, 1)[0, 1] = value ? "\1" : "\0"
      true
    end

    def write_pointer(data, pointer)
      Fiddle::Pointer.new(data.to_i, 8)[0, 8] = [pointer.to_i].pack("J")
      true
    end

    # A C string the core may hold on to for as long as this core lives.
    def kept_string(text) = kept_bytes("#{text}\0".b)

    # +bytes+ copied into memory of their own that does not move, kept as long as the core lives.
    def kept_bytes(bytes)
      pointer = Fiddle::Pointer.malloc([bytes.bytesize, 1].max, Fiddle::RUBY_FREE)
      pointer[0, bytes.bytesize] = bytes
      @kept << pointer
      pointer
    end

    # libretro's retro_game_info: the path, the bytes and their count, and nothing for meta.
    def load_program(exe_path)
      bytes = File.binread(exe_path)
      path = kept_string(File.expand_path(exe_path))
      data = kept_bytes(bytes)
      info = kept_bytes([path.to_i, data.to_i, bytes.bytesize, 0].pack("J4"))
      raise ArgumentError, "Beetle PSX would not load #{exe_path}" unless @call[:retro_load_game].call(info)

      @call[:retro_set_controller_port_device].call(0, JOYPAD)
    end
  end
end
