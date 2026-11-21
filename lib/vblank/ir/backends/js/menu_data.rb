# frozen_string_literal: true

require "json"
require_relative "../../../live/window_menu"

module VBlank
  module IR
    module Backends
      class JS
        # THE WINDOW MENU AS JAVASCRIPT DATA, for the page's copy of it (runtime/rg_page_menu.js),
        # from Live::WindowMenu, as the desktop build's MenuData is. A page has no window
        # size of its own, so that line is left out. +menu+ false is a game that has no menu, and +states+
        # false one with no Save or Load (a shell's parts). +buttons+ are the console's, which the
        # Keys heading lists (Live::WindowMenu.headings).
        module MenuData
          module_function

          def source(menu: true, states: true, buttons: Console::ADVANCE.buttons)
            "const RG_PAGE_MENU = #{JSON.generate(menu ? description(states, buttons) : nil)};\n"
          end

          def description(states, buttons)
            window_menu = Live::WindowMenu
            # The page has no window of the game's variables yet, so no Developer heading.
            shown = window_menu.headings(states: states, buttons: buttons, developer: false)
            { headings: shown.map { |heading| heading_of(heading) },
              buttons: window_menu::BUTTON_NAMES, hotkeys: window_menu::HOTKEY_NAMES,
              colors: window_menu::COLORS.transform_values { |(red, green, blue, opacity)| "rgba(#{red},#{green},#{blue},#{opacity / 255.0})" } }
          end

          def heading_of(heading)
            lines = heading.lines.reject { |line| line.setting == :scale }.map do |line|
              { label: line.label, kind: line.kind, does: line.does, setting: line.setting, least: line.range&.min, most: line.range&.max,
                step: line.step, written: line.written, shortcut: line.shortcut, place: line.place, action: line.request&.action }
            end
            { name: heading.name, lines: lines, states: heading.states? }
          end
        end
      end
    end
  end
end
