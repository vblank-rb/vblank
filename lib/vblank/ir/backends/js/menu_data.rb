# frozen_string_literal: true

require "json"
require "vblank/live/window_menu"

module VBlank
  module IR
    module Backends
      class JS
        # THE WINDOW MENU AS JAVASCRIPT DATA, for the page's copy of it (runtime/rg_page_menu.js),
        # from Live::WindowMenu, as the desktop build's MenuData is. A page has no window
        # size of its own, so that line is left out. +menu+ false is a game that has no menu.
        module MenuData
          module_function

          def source(menu: true)
            "const RG_PAGE_MENU = #{JSON.generate(menu ? description : nil)};\n"
          end

          def description
            window_menu = Live::WindowMenu
            { headings: window_menu::HEADINGS.map { |heading| heading_of(heading) },
              buttons: window_menu::BUTTON_NAMES, hotkeys: window_menu::HOTKEY_NAMES,
              colors: window_menu::COLORS.transform_values { |(red, green, blue, opacity)| "rgba(#{red},#{green},#{blue},#{opacity / 255.0})" } }
          end

          def heading_of(heading)
            lines = heading.lines.reject { |line| line.setting == :scale }.map do |line|
              { label: line.label, kind: line.kind, does: line.does, setting: line.setting, least: line.range&.min, most: line.range&.max,
                step: line.step, written: line.written, shortcut: line.shortcut, place: line.place }
            end
            { name: heading.name, lines: lines }
          end
        end
      end
    end
  end
end
