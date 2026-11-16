# frozen_string_literal: true

require "cgi/escape"
require "erb"

module VBlank
  module IR
    module Backends
      class JS
        # THE PAGE A GAME PLAYS IN: one HTML file holding the game and its runtime, with nothing
        # to fetch unless its data was built separate (JS#build_page), so it opens from a disk as
        # well as from a server. The picture is a <canvas> the
        # size of the console's screen, enlarged without smoothing so a pixel stays a square; the
        # keyboard and any controller are the gamepad (runtime/rg_page.js says which is which).
        #
        # THE PAGE IS A TEMPLATE, page.html.erb unless the build names another (`vblank build
        # --format=web --template FILE`). A template is ERB, and it is handed these, each a piece of
        # finished HTML:
        #
        #   game        the canvas and the script: the one piece a page must have
        #   title       the game's name, as text
        #   style       the default look: dark, the picture centred and enlarged
        #   keys        which key is which button
        #   controller  where the page says whether a controller is in use
        #   fullscreen  a button that fills the screen with the game (the F key does too)
        #   pause       a checkbox, ticked, for pausing the game while another window has the
        #               keyboard; write your own <input type="checkbox" id="pause"> without
        #               `checked` to start with it off, and a page without one pauses
        #   touchpad    the console's buttons on the screen, for a phone or a tablet, shown only
        #               while a finger is the screen's main pointer; with it on the page, the full
        #               screen button fills the screen with the whole page, so the pad comes too
        #   message     where a game that stops, or a page waiting for a click, says so
        #   extras      touchpad, keys, controller, fullscreen, pause and message together, in
        #               that order
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
                   players: 1)
            pieces = pieces(title: title, script: script, scale: scale, screen: screen, pixel_size: pixel_size,
                            buttons: buttons, players: players)
            page = ERB.new(File.read(template, encoding: Encoding::UTF_8), trim_mode: "-").result_with_hash(pieces)
            return page if page.include?(pieces[:game])

            raise LoweringError, "The page template #{template} does not write the game, so the page will not " \
                                 "play it. Put <%= game %> in the template where the game goes."
          end

          # The keys of the buttons beside the pad, in words, by the button each is for: player 1's
          # (rg_page.js's PAGE_KEYS) and player 2's (PAGE_SECOND_PLAYER_KEYS). L and R are said
          # together, under :l.
          FIRST_PLAYER_WORDS = { a: "<kbd>X</kbd> is A", b: "<kbd>Z</kbd> is B", start: "<kbd>Enter</kbd> is Start",
                                 select: "<kbd>Backspace</kbd> is Select", l: "<kbd>A</kbd> and <kbd>S</kbd> are L and R",
                                 x: "<kbd>W</kbd> is X", y: "<kbd>Q</kbd> is Y", c: "<kbd>C</kbd> is C" }.freeze
          SECOND_PLAYER_WORDS = { a: "<kbd>O</kbd> is A", b: "<kbd>U</kbd> is B", l: "<kbd>7</kbd> and <kbd>9</kbd> are L and R",
                                  start: "<kbd>0</kbd> is Start", select: "<kbd>8</kbd> is Select", x: "<kbd>H</kbd> is X",
                                  y: "<kbd>Y</kbd> is Y", c: "<kbd>B</kbd> is C" }.freeze

          def pieces(title:, script:, scale:, screen:, pixel_size: 1, buttons: Console::ADVANCE.buttons, players: 1)
            said = FIRST_PLAYER_WORDS.slice(*buttons).values.join(", ")
            keys = <<~HTML.chomp
              <p class="keys">Arrows move. #{said}, <kbd>F</kbd> fills the screen, <kbd>F1</kbd> opens the menu, where the keys can be changed.
              Press a key or click to hear the sound.#{more_players_words(buttons) if players > 1}</p>
            HTML
            controller = '<p id="controller"></p>'
            fullscreen = '<button id="fullscreen" type="button">Full screen</button>'
            pause = '<label><input type="checkbox" id="pause" checked> Pause when another window is in front</label>'
            touchpad = touchpad(buttons: buttons)
            message = '<p id="said" hidden></p>'
            { title: CGI.escapeHTML(title.to_s), style: style(scale * pixel_size, screen), game: game(script, screen), keys: keys,
              controller: controller, fullscreen: fullscreen, pause: pause, touchpad: touchpad, message: message,
              extras: [touchpad, keys, controller, fullscreen, pause, message].join("\n") }
          end

          # Player 2's keys (rg_page.js's PAGE_SECOND_PLAYER_KEYS) and the controllers' players, for
          # a game more than one person plays, for the console's +buttons+.
          def more_players_words(buttons)
            "\nPlayer 2: <kbd>I</kbd> <kbd>J</kbd> <kbd>K</kbd> <kbd>L</kbd> move, #{SECOND_PLAYER_WORDS.slice(*buttons).values.join(', ')}. " \
              "Each controller is one player, in the order you connect them."
          end

          # THE PAD ON THE SCREEN, for a phone or a tablet, which has no keys: the console's buttons
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
