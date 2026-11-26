# frozen_string_literal: true

require "json"
require_relative "../../../live/window_menu"
require_relative "../../../live/menu"

module VBlank
  module IR
    module Backends
      class JS
        # The window menu as JavaScript data, for the page's copy of it (runtime/rg_page_menu.js),
        # from Live::WindowMenu, as the desktop build's MenuData is. A page has no window
        # size of its own, so that line is left out. +menu+ false is a game that has no menu, and +states+
        # false one with no Save or Load (a shell's parts). The Keys heading lists the console's
        # buttons (Live::WindowMenu.headings).
        #
        # A page cannot close its own tab, so Quit stops the game and leaves its last picture up.
        # +stopped+ is what the page then writes over that picture to say so (rg_page.js,
        # present_stopped): STOPPED_LINES in the game's own font, as the pixels to light, each line
        # in the middle of the block.
        module MenuData
          STOPPED_LINES = ["Stopped.", "Reload to play again."].freeze
          STOPPED_LINE_GAP = 3 # Pixels between the lines
          TEXT_KINDS = %i[draw_text draw_digit].freeze
          # The box over the picture that shows what the page could not use of the settings it kept in
          # the browser's storage, as Live::Menu shows it for a settings file (Menu#show_problems).
          PROBLEMS_TITLE = "Stored settings"
          PROBLEMS_INTRO = "The page cannot use some of its stored settings. It uses the rest, and the game plays as usual."

          StoppedWords = Data.define(:width, :height, :points)

          module_function

          # +program+ gives the console, whose buttons the Keys heading lists, and the font the
          # stopped words are in (#game_font).
          def source(program, menu: true, states: true)
            return "const RG_PAGE_MENU = null;\n" unless menu

            console = program.described_console
            font = game_font(program, console.framed_screen_size[0])
            "const RG_PAGE_MENU = #{JSON.generate(description(states, console.buttons, font))};\n"
          end

          def description(states, buttons, font)
            window_menu = Live::WindowMenu
            shown = window_menu.headings(states: states, buttons: buttons)
            { headings: shown.map { |heading| heading_of(heading) },
              buttons: window_menu::BUTTON_NAMES, hotkeys: window_menu::HOTKEY_NAMES,
              colors: window_menu::COLORS.transform_values { |(red, green, blue, opacity)| "rgba(#{red},#{green},#{blue},#{opacity / 255.0})" },
              variable_rows: window_menu::VARIABLE_ROWS, filter_most: window_menu::FILTER_MOST,
              problems: { title: PROBLEMS_TITLE, intro: PROBLEMS_INTRO, close: Live::Menu::CLOSE_CAPTION },
              stopped: stopped_words(font).to_h }
          end

          # The font the game first writes words or a number in, where it has every letter of
          # STOPPED_LINES and they fit across the screen; otherwise the framework's default font.
          # A font of digits alone, for a score, has no letters to write them in.
          def game_font(program, screen_width)
            fallback = Graphics::Fonts.default
            fonts = program.walk.select { |node| TEXT_KINDS.include?(node.kind) }.map { |node| node.fonts.get(node.font) }
            fonts.uniq.find { |font| writes_stopped_lines?(font, screen_width) } || fallback
          end

          def writes_stopped_lines?(font, screen_width)
            STOPPED_LINES.all? { |line| font.missing_characters(line.delete(" ")).empty? && font.text_width(line) <= screen_width }
          end

          def stopped_words(font)
            width = STOPPED_LINES.map { |line| font.text_width(line) }.max
            points = STOPPED_LINES.each_with_index.flat_map do |line, row|
              left = (width - font.text_width(line)) / 2
              top = row * (font.height + STOPPED_LINE_GAP)
              font.enum_for(:each_pixel, line).flat_map { |x, y| [left + x, top + y] }
            end
            StoppedWords.new(width: width, height: (STOPPED_LINES.length * (font.height + STOPPED_LINE_GAP)) - STOPPED_LINE_GAP, points: points)
          end

          # Quit shows no key: a window quits on Escape, but on a page Escape closes the menu, and a
          # browser leaves fullscreen on it, so a page that quit on it would stop a game whose player
          # only wanted the screen back.
          def heading_of(heading)
            lines = heading.lines.reject { |line| line.setting == :scale }.map do |line|
              shortcut = line.does == :quit ? nil : line.shortcut
              { label: line.label, kind: line.kind, does: line.does, setting: line.setting, least: line.range&.min, most: line.range&.max,
                step: line.step, written: line.written, shortcut: shortcut, place: line.place, action: line.request&.action }
            end
            { name: heading.name, lines: lines, states: heading.states? }
          end
        end
      end
    end
  end
end
