# frozen_string_literal: true

require "digest"
require "zlib"

module VBlank
  module Playthroughs
    # A TAPE WRITTEN OUT FOR ANOTHER EMULATOR, so a run can be shown in one people already use. The
    # tape stays the master: it holds named moments and plays on every console and computer build,
    # and these hold a list of frames for one exact cartridge.
    #
    # WHAT EACH ONE ASSUMES, since one frame of difference ruins a run. Frame 1 is the first frame
    # after power-on, with no BIOS screen first, so the emulator is set to skip the BIOS or has none.
    # The cartridge is the exact one the export was given. Save memory is empty, so a tape that
    # starts from a save or after a lead-in is refused rather than written out to play another game.
    #
    # A tape of passes is first played on the cartridge, to find which frames its passes fell on
    # (Tape#in_frames_on).
    module TapeExport
      # A Game Boy Advance's buttons as a line of a BizHawk movie, in the order its log gives them.
      BIZHAWK_BUTTONS = { up: "U", down: "D", left: "L", right: "R", start: "S", select: "s", b: "B", a: "A", l: "l", r: "r" }.freeze
      BIZHAWK_LOG_KEY = "LogKey:#Up|Down|Left|Right|Start|Select|B|A|L|R|Power|"
      SUBTITLE_FRAMES = 120
      SUBTITLE_COLOR = "FFFFFFFF"

      module_function

      # The file `Tools > Scripting` in mGBA 0.10 or later loads. It starts the game again from
      # power-on and holds the tape's buttons a frame at a time. mGBA says a frame is done and then
      # takes the buttons for the next, so the first frame's are set as it starts. +pictures_in+ is
      # a folder for it to write the screen at each moment into, as a PNG named for the moment.
      def mgba_script(tape, pictures_in: nil)
        runs = holds_of(tape).map { |hold| "{#{hold.frames}, #{Playthrough.key_mask(hold.buttons)}}" }
        moments = tape.moments.map { |name, frame| "[#{frame}] = #{name.to_s.inspect}" }
        <<~LUA
          -- #{tape.recorded_on_label}, written out by VBlank from a tape of #{tape.frames} frames.
          -- Load the game, then this file in Tools > Scripting. It plays from power-on. It assumes
          -- that exact cartridge, no BIOS screen (Emulation > Skip BIOS intro, or no BIOS) and empty
          -- save memory. It holds the buttons, so nothing else can press them while it plays.
          local runs = {
            #{runs.join(",\n  ")}
          }
          local moments = { #{moments.join(', ')} }
          local folder = #{pictures_in ? pictures_in.to_s.inspect : 'nil'}
          local run, left, frame

          local function hold_this_run()
            emu:setKeys(run <= #runs and runs[run][2] or 0)
          end

          local function start()
            run, left, frame = 1, runs[1][1], 0
            hold_this_run()
          end

          callbacks:add("reset", start)
          callbacks:add("frame", function()
            frame = frame + 1
            if folder and moments[frame] then
              emu:screenshot(folder .. "/" .. moments[frame] .. ".png")
            end
            if run > #runs then return end
            left = left - 1
            if left == 0 then
              run = run + 1
              left = run <= #runs and runs[run][1] or 0
              hold_this_run()
              if run > #runs then console:log("The tape has ended, on frame " .. frame .. ".") end
            end
          end)
          emu:reset()
        LUA
      end

      # A BizHawk movie: a zip of plain text, with each moment as a subtitle.
      def bizhawk_movie(tape, cartridge)
        zip_of("Header.txt" => bizhawk_header(tape, cartridge), "Input Log.txt" => bizhawk_input_log(tape),
               "Comments.txt" => "Written out by VBlank from a tape of #{tape.recorded_on_label}.\n",
               "Subtitles.txt" => bizhawk_subtitles(tape), "SyncSettings.json" => "{}\n")
      end

      def bizhawk_header(tape, cartridge)
        <<~TEXT
          MovieVersion BizHawk v2.0.0
          Author VBlank
          Platform GBA
          GameName #{tape.title}
          SHA1 #{Digest::SHA1.hexdigest(cartridge.buffer).upcase}
          Core mGBA
          rerecordCount 0
        TEXT
      end

      def bizhawk_input_log(tape)
        lines = holds_of(tape).map { |hold| "#{bizhawk_line(hold.buttons)}\n" * hold.frames }
        "[Input]\n#{BIZHAWK_LOG_KEY}\n#{lines.join}[/Input]\n"
      end

      def bizhawk_line(buttons) = "|#{BIZHAWK_BUTTONS.map { |button, mark| buttons.include?(button) ? mark : '.' }.join}.|"

      def bizhawk_subtitles(tape)
        tape.moments.map { |name, frame| "subtitle #{frame} 8 8 #{SUBTITLE_FRAMES} #{SUBTITLE_COLOR} #{name}\n" }.join
      end

      def holds_of(tape) = tape.steps.select { |step| step.frames.positive? }

      # +files+ as a zip with nothing compressed, which every zip reader takes. Ruby has no zip of
      # its own, and these are a few plain files.
      def zip_of(files)
        body = "".b
        directory = "".b
        files.each do |name, text|
          entry = zip_entry_fields(name, text)
          at = body.bytesize
          body << [0x04034B50].pack("V") << entry << name.b << text.b
          directory << [0x02014B50, 20].pack("Vv") << entry << [0, 0, 0, 0, at].pack("vvvVV") << name.b
        end
        ending = [0x06054B50, 0, 0, files.size, files.size, directory.bytesize, body.bytesize, 0].pack("VvvvvVVv")
        body + directory + ending
      end

      # What a zip says of a file twice over: the version, no flags, stored, no time, the checksum,
      # the sizes and the length of the name.
      def zip_entry_fields(name, text)
        size = text.bytesize
        [20, 0, 0, 0, 0, Zlib.crc32(text), size, size, name.bytesize, 0].pack("vvvvvVVVvv")
      end
    end
  end
end
