# frozen_string_literal: true

require "cgi/escape"
require "erb"

module VBlank
  module IR
    module Backends
      class JS
        # The page a game plays in: one HTML file holding the game and its runtime, with nothing
        # to fetch unless its data was built separate (JS#build_page), so it opens from a disk as
        # well as from a server. The picture is a <canvas> the
        # size of the console's screen, enlarged without smoothing so a pixel stays a square; the
        # keyboard and any controller are the gamepad (runtime/rg_page.js says which is which).
        #
        # The page is a template, page.html.erb unless the build names another (`vblank build
        # --format=web --template file`). A template is ERB, and it is handed these, each a piece of
        # finished HTML:
        #
        #   game        the canvas and the script: the one piece a page must have
        #   title       the game's name, as text
        #   style       the default look: dark, the picture centred and enlarged
        #   keys        which key is which button
        #   controls    the screen's size and every button's keys as data: `<%= controls.to_json %>`
        #               (Controls), to show the controls in the template's own design
        #   controller  where the page says whether a controller is in use
        #   fullscreen  a button that fills the screen with the game (the F key does too)
        #   pause       a checkbox, ticked, for pausing the game while another window has the
        #               keyboard; write your own <input type="checkbox" id="pause"> without
        #               `checked` to start with it off, and a page without one pauses
        #   touchpad    the console's buttons on the screen, for a phone or a tablet, shown only
        #               while a finger is the screen's main pointer; with it on the page, the full
        #               screen button fills the screen with the whole page, so the pad comes too
        #   saves       two buttons that export the game's save as a .sav file and import one; empty
        #               for a game with no save memory (runtime/rg_mount.js)
        #   message     where a game that stops, or a page waiting for a click, says so, and a button,
        #               hidden, that copies the page's address where the browser cannot keep a
        #               shell's data (runtime/rg_mount.js)
        #   extras      touchpad, keys, controller, fullscreen, pause, saves and message together,
        #               in that order, those that are not empty
        #
        # The script finds the pieces it fills in by their id, and a page without one of them plays
        # the same, with nothing given there.
        module Page
          DEFAULT = Ractor.make_shareable(File.join(__dir__, "page.html.erb"))

          # Every pixel of the console's picture drawn as a square however big the canvas is drawn,
          # rather than smoothed into its neighbours. On the canvas itself, so no template loses
          # it; crisp-edges first, for a browser that does not know pixelated.
          SQUARE_PIXELS = "image-rendering: crisp-edges; image-rendering: pixelated"

          module_function

          # The page for +title+'s game, its +script+ inside, written by +template+, its canvas
          # +screen+ ([width, height] in pixels: the console the game is built as) +scale+ times
          # over, its key help and pad naming the console's +buttons+ alone (Console::Description#buttons:
          # the keys the page reads, rg_page.js's page_console_has), and player 2's keys only when
          # the game seats more than one player (+players+).
          # +pixel_size+ is how many of the console's pixels across and down each of the picture's is
          # shown as (Console::Description#pixel_size): a game of big pixels draws a canvas half the
          # console's width and height, and it is shown the console's size all the same.
          # A template that leaves the game out is a LoweringError, as anything else that stops a
          # web build is.
          def html(title:, script:, screen:, scale: 3, pixel_size: 1, template: DEFAULT, buttons: Console::ADVANCE.buttons,
                   players: 1, saves: false)
            pieces = pieces(title: title, script: script, scale: scale, screen: screen, pixel_size: pixel_size,
                            buttons: buttons, players: players, saves: saves)
            page = ERB.new(File.read(template, encoding: Encoding::UTF_8), trim_mode: "-").result_with_hash(pieces)
            return page if page.include?(pieces[:game])

            raise LoweringError, "The page template #{template} does not write the game, so the page will not " \
                                 "play it. Put <%= game %> in the template where the game goes."
          end

          # The screen and the keys as data, which a template writes out with `<%= controls.to_json %>`
          # so a site can show the controls in its own design and size the frame before the game
          # loads. +screen+ is the canvas's size and the pixel size in the console's pixels;
          # +first_player+ and +second_player+ (nil unless the game seats more than one) are each
          # button's browser key codes, for the console's buttons alone, the arrows among them;
          # +page_keys+ are the keys the page itself reads.
          Controls = Data.define(:screen, :first_player, :second_player, :page_keys) do
            def to_json(*args)
              { screen: screen.to_h, first_player: first_player, second_player: second_player, page_keys: page_keys }.to_json(*args)
            end
          end

          # The canvas's width and height in pixels, and how many of the console's pixels across and
          # down each of the picture's is shown as.
          Screen = Data.define(:width, :height, :pixel_size)

          # The keys the page reads for itself, by what each does (rg_page.js: fullscreenKey, and
          # rg_page_menu.js's PAGE_HOTKEY_KEYS).
          PAGE_KEYS = { fullscreen: "KeyF", menu: "F1" }.freeze

          # The order the buttons are said in beside the pad: player 1's, and player 2's, whose L and
          # R come before Start. L and R are said together, under :l, and L2 and R2 under :l2.
          FIRST_PLAYER_SAID = %i[a b start select l x y c l2].freeze
          SECOND_PLAYER_SAID = %i[a b l start select x y c l2].freeze

          # The one source of the keys, the same table the desktop window reads: player 1's layout and
          # player 2's, by button, as the names IR::ComputerControls gives them.
          SECOND_PLAYER_LAYOUT = IR::ComputerControls::SECOND_PLAYER_KEYS.each_with_object({}) do |(key, button), by_button|
            (by_button[button] ||= []) << key
          end.freeze

          # The browser's name for a key IR::ComputerControls names (a letter, a digit, enter, backspace,
          # right_shift or an arrow), as rg_page.js reads it.
          def key_code(name)
            case name
            when Integer then "Digit#{name}"
            when :enter then "Enter"
            when :backspace then "Backspace"
            when :right_shift then "ShiftRight"
            when :minus then "Minus"
            when :right, :left, :up, :down then "Arrow#{name.to_s.capitalize}"
            else "Key#{name.to_s.upcase}"
            end
          end

          # The key's name as the page says it in words.
          def key_word(name)
            case name
            when :enter then "Enter"
            when :backspace then "Backspace"
            when :minus then "-"
            else name.to_s.upcase
            end
          end

          def controls(screen:, pixel_size: 1, buttons: Console::ADVANCE.buttons, players: 1)
            codes = ->(layout) { layout.slice(*buttons).transform_values { |keys| keys.map { |key| key_code(key) } } }
            Controls.new(screen: Screen.new(width: screen[0], height: screen[1], pixel_size: pixel_size),
                         first_player: codes.call(IR::ComputerControls::LAYOUT_KEYS),
                         second_player: (codes.call(SECOND_PLAYER_LAYOUT) if players > 1), page_keys: PAGE_KEYS)
          end

          # The words for the buttons of +layout+ the console has, in +order+: "X is A", and L and R
          # together as "A and S are L and R".
          def words(layout, order, buttons)
            order.filter_map do |button|
              next unless buttons.include?(button)

              if %i[l l2].include?(button)
                pair = button == :l ? %i[l r] : %i[l2 r2]
                "<kbd>#{key_word(layout.fetch(pair[0]).first)}</kbd> and <kbd>#{key_word(layout.fetch(pair[1]).first)}</kbd> " \
                  "are #{pair[0].upcase} and #{pair[1].upcase}"
              else
                "<kbd>#{key_word(layout.fetch(button).first)}</kbd> is #{button.to_s.capitalize}"
              end
            end
          end

          def pieces(title:, script:, scale:, screen:, pixel_size: 1, buttons: Console::ADVANCE.buttons, players: 1,
                     saves: false)
            said = words(IR::ComputerControls::LAYOUT_KEYS, FIRST_PLAYER_SAID, buttons).join(", ")
            keys = <<~HTML.chomp
              <p class="keys">Arrows move. #{said}, <kbd>F</kbd> fills the screen, <kbd>F1</kbd> opens the menu, where the keys can be changed.
              Press a key or click to hear the sound.#{more_players_words(buttons) if players > 1}</p>
            HTML
            controller = '<p id="controller"></p>'
            fullscreen = '<button id="fullscreen" type="button">Full screen</button>'
            pause = '<label><input type="checkbox" id="pause" checked> Pause when another window is in front</label>'
            touchpad = touchpad(buttons: buttons)
            saves = saves ? saves_buttons : ""
            message = %(<p id="said" hidden></p>\n<button id="copy-link" type="button" hidden>Copy the link</button>)
            { title: CGI.escapeHTML(title.to_s), style: style(scale * pixel_size, screen), game: game(script, screen), keys: keys,
              controls: controls(screen: screen, pixel_size: pixel_size, buttons: buttons, players: players),
              controller: controller, fullscreen: fullscreen, pause: pause, touchpad: touchpad, saves: saves,
              message: message,
              extras: [touchpad, keys, controller, fullscreen, pause, saves, message].reject(&:empty?).join("\n") }
          end

          # The buttons that export the game's save and import one (runtime/rg_mount.js, mount_saves),
          # hidden until the page finds the game has save memory.
          def saves_buttons
            '<p id="saves" hidden><button id="save-export" type="button">Export save</button> ' \
              '<button id="save-import" type="button">Import save</button></p>'
          end

          # Player 2's keys (rg_page.js's PAGE_SECOND_PLAYER_KEYS) and the controllers' players, for
          # a game more than one person plays, for the console's +buttons+.
          def more_players_words(buttons)
            "\nPlayer 2: <kbd>I</kbd> <kbd>J</kbd> <kbd>K</kbd> <kbd>L</kbd> move, #{words(SECOND_PLAYER_LAYOUT, SECOND_PLAYER_SAID, buttons).join(', ')}. " \
              "Each controller is one player, in the order you connect them."
          end

          # The pad on the screen, for a phone or a tablet, which has no keys: the console's buttons
          # laid out as a GBA lays them out — L and R along the top, the cross on the left, B and A
          # on the right, Select and Start between. runtime/rg_mount.js finds them by id, "pad-" and
          # the button's name, and the cross, "pad-cross", is one piece a thumb rocks round; its
          # arrows are only drawn. It is hidden until the page finds a finger is the screen's main
          # pointer. How it is laid out is in `style`, so a template that leaves that out lays the
          # pad out itself. The pad has the console's +buttons+ alone: the Color's has no L and R,
          # the Genesis's no Select, and a console with X and Y, or C, has them among A and B, X on
          # top and Y or C on the left (class "pad-face more").
          def touchpad(buttons: Console::ADVANCE.buttons)
            pad_button = ->(name, label) { %(<button id="pad-#{name}" type="button">#{label}</button>) if buttons.include?(name.to_sym) }
            arrow = ->(direction, label) { %(<span class="pad-#{direction}">#{label}</span>) }
            more = buttons.intersect?(%i[x y c])
            [%(<div id="touchpad" class="touchpad" hidden>), pad_button.call("l", "L"), pad_button.call("r", "R"),
             %(<div id="pad-cross" class="pad-cross">), arrow.call("up", "▲"), arrow.call("left", "◀"),
             arrow.call("right", "▶"), arrow.call("down", "▼"), "</div>",
             %(<div class="pad-middle">), pad_button.call("select", "SELECT"), pad_button.call("start", "START"), "</div>",
             %(<div class="pad-face#{' more' if more}">), pad_button.call("x", "X"), pad_button.call("y", "Y"),
             pad_button.call("c", "C"), pad_button.call("b", "B"), pad_button.call("a", "A"), "</div>",
             "</div>"].compact.join("\n")
          end

          def game(script, (width, height))
            <<~HTML.chomp
              <canvas id="screen" width="#{width}" height="#{height}" style="#{SQUARE_PIXELS}"></canvas>
              <script>
              #{script.gsub('</script', '<\/script')}
              </script>
            HTML
          end

          # The default look, the canvas's +width+ and +height+ drawn +enlarged+ times over: the
          # page's scale times the game's pixel size.
          def style(enlarged, (width, height))
            <<~HTML.chomp
              <style>
                :root { color-scheme: dark; }
                body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; align-items: center;
                       justify-content: center; gap: 12px; background: #111; color: #ccc;
                       font: 14px/1.4 system-ui, sans-serif; }
                canvas { width: min(#{width * enlarged}px, 96vw); aspect-ratio: #{width} / #{height};
                         background: #000; }
                canvas:fullscreen { width: 100vw; height: 100vh; object-fit: contain; }
                p { margin: 0 16px; text-align: center; }
                kbd { border: 1px solid #555; border-radius: 3px; padding: 0 4px; }
                button { font: inherit; color: inherit; background: #222; border: 1px solid #555; border-radius: 4px;
                         padding: 4px 12px; cursor: pointer; }
                .touchpad { display: grid; grid-template: "l . r" "cross . face" "middle middle middle" / auto 1fr auto;
                            gap: 16px; align-items: center; width: min(#{width * enlarged}px, 96vw);
                            touch-action: none; user-select: none; -webkit-user-select: none; }
                .touchpad[hidden] { display: none; }
                .touchpad button { touch-action: none; padding: 0; min-width: 48px; min-height: 48px; font-size: 18px; }
                #pad-l { grid-area: l; justify-self: start; }
                #pad-r { grid-area: r; justify-self: end; }
                .pad-cross { grid-area: cross; justify-self: start; display: grid; gap: 2px;
                             grid-template: ". up ." 50px "left . right" 50px ". down ." 50px / 50px 50px 50px; }
                .pad-cross span { display: flex; align-items: center; justify-content: center; font-size: 18px;
                                  background: #222; border: 1px solid #555; border-radius: 4px; }
                .pad-up { grid-area: up; } .pad-left { grid-area: left; }
                .pad-right { grid-area: right; } .pad-down { grid-area: down; }
                .pad-middle { grid-area: middle; display: flex; gap: 8px; justify-content: center; }
                .pad-middle button { min-height: 28px; font-size: 11px; padding: 0 8px; border-radius: 14px; }
                .pad-face { grid-area: face; display: grid; grid-template-areas: ". a" "b ."; gap: 8px; justify-self: end; }
                .pad-face button { width: 60px; height: 60px; border-radius: 50%; }
                #pad-a { grid-area: a; } #pad-b { grid-area: b; }
                .pad-face.more { grid-template-areas: ". x ." "y . a" ". b ."; }
                #pad-x { grid-area: x; } #pad-y, #pad-c { grid-area: y; }
                /* The whole page filling the screen, as it does with the pad on it: the game as big
                   as fits, the pad, and nothing else. */
                :root:fullscreen body { background: #000; gap: 8px; }
                :root:fullscreen body > :not(canvas):not(.touchpad) { display: none; }
                :root:fullscreen canvas { width: min(100vw, 150vh); }
                /* A screen played with a finger has no keys to say. */
                @media (pointer: coarse) { .keys { display: none; } }
                /* A phone on its side: the game as tall as the screen, between the cross and the
                   buttons, as a GBA has them either side of its screen, and Select and Start under
                   the cross, as a GBA SP has them. */
                @media (pointer: coarse) and (orientation: landscape) {
                  body { justify-content: flex-start; padding-top: 8px; }
                  canvas, :root:fullscreen canvas { width: min(calc((100vh - 16px) * 1.5), calc(100vw - 360px)); }
                  .touchpad { position: fixed; inset: 0; width: auto; padding: 12px; box-sizing: border-box; pointer-events: none;
                              grid-template: "l . r" auto "cross . face" 1fr "middle . ." auto / auto 1fr auto; }
                  .touchpad button, .pad-cross { pointer-events: auto; }
                }
              </style>
            HTML
          end
        end
      end
    end
  end
end
