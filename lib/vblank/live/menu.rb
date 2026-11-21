# frozen_string_literal: true

module VBlank
  module Live
    # THE MENU OVER THE WINDOW a game is played in (WindowMenu says what it holds and how it
    # looks): how it behaves, and where each of its boxes and words goes. Nothing here knows about
    # a window, so it is played in tests with none; the window hands it the keys meant for it
    # (#press), draws what it asks for (#drawing), and does what its settings ask for.
    #
    # It is the first of three. The desktop build has this same menu written in C, line for line
    # from this one (runtime/rg_window_menu.c), and test_native_window_menu.rb holds the two to
    # drawing the same thing after every key; the web page is to have it in JavaScript.
    #
    # It opens on the bar along the top, on the first heading, with that heading's lines showing
    # and none of them chosen. Left and right on the bar go from heading to heading; down, or
    # Enter, goes into the lines, and up from the first line comes back to the bar. In the lines,
    # left and right change a slider's number; on any other line they go on to the next heading,
    # back on the bar, so moving along never changes a line by the way. Enter does what a line
    # says, or switches it on or off. The game is held while the menu is open (the window sees to
    # that).
    class Menu
      # Keys named only as "key N", for a menu with no window to ask.
      class NumberedKeys
        def name(_key) = nil
        def key(_name) = nil
      end

      attr_reader :settings, :controls

      # What the box about the settings file says above the problems themselves.
      SETTINGS_PROBLEMS_INTRO = "The window cannot use some of the settings file. It uses the rest, and the game plays as usual."
      # What the OK of a box says beside it.
      CLOSE_CAPTION = "Press a button to close this."

      # +settings+ as the player last left them; +picture+, the game's picture's size, to say how
      # big the window is at each size; +scales+, the sizes the window can be made, in times the
      # picture's, which the frontend may make fewer than WindowMenu::SCALES (what fits the screen);
      # +controls+, the Settings that hold which key is what, and the rules for changing them. While
      # one is being chosen the window hands it the next key or gamepad button (#capture_key).
      # +states+ answers #text_for(slot) with the words for a place a state is kept (when it was
      # taken, or that it is empty); a menu given none has no Save or Load heading, which is how a
      # match with other players has none. +developer+ false leaves out the Developer heading, as a
      # frontend with no window of the game's variables does (WindowMenu.headings).
      def initialize(settings: WindowMenu::STARTING, picture: [240, 160], scales: WindowMenu::SCALES,
                     controls: Settings.new(key_names: NumberedKeys.new), states: nil, developer: true)
        @scales = scales
        @controls = controls
        @developer = developer
        self.states = states
        self.settings = settings
        @picture = picture
        @open = @quit = false
        @variables_open = false
        @filter = +"" # the letters typed into the window of variables
        @variables_scroll = 0 # the first of the lines it finds that the window shows
        @state_request = nil
        @heading = 0
        @row = -1
      end

      # The places states are kept in changed: a shell's window has none while its menu and unpacking play and
      # has them once its game does. The menu starts again on its first heading.
      def states=(states)
        @states = states
        @headings = WindowMenu.headings(states: states ? true : false, developer: @developer,
                                        buttons: IR::Buttons::NAMES.select { |button| @controls.console_has?(button) })
        @state_request = nil
        @heading = 0
        @row = -1
      end

      # What the player asked to save or load (a WindowMenu::StateRequest), once, or nil. The window
      # does it between two frames of the game, which is the only time a state can be taken.
      def take_state_request
        request = @state_request
        @state_request = nil
        request
      end

      # Whether a save or load has been asked for and not yet taken.
      def state_request_pending? = !@state_request.nil?

      # A save or load asked for by a key (F5, F9) rather than a line of the menu.
      def ask_state(action, slot)
        @state_request = WindowMenu::StateRequest.new(action: action, slot: slot)
      end

      # The settings changed from outside the menu: a hotkey, which switches one as its line would.
      def settings=(settings)
        @settings = settings.with(scale: settings.scale.clamp(@scales.min, @scales.max))
      end

      def open? = @open

      # Quit was chosen.
      def quit? = @quit

      # Opens the menu, on the bar on the first heading, or closes it.
      def toggle
        @open = !@open
        @heading = 0
        @row = -1
        @controls.capture_cancel
      end

      # The heading whose lines are showing, while the menu is open.
      def open_heading = (@headings[@heading].name if @open)

      # The line chosen under it, or nil while the bar is.
      def chosen_line = (lines[@row].label if @open && @row >= 0)

      # One of :up, :down, :left, :right, :enter or :close, pressed while the menu is open.
      def press(key)
        return toggle if key == :close
        return press_on_bar(key) if @row.negative?

        line = lines[@row]
        case key
        when :up then @row -= 1
        when :down then @row = (@row + 1) % lines.size
        when :left, :right then line.kind == :slider ? slide(line, key == :right ? 1 : -1) : move_heading(key)
        when :enter then enter(line)
        end
      end

      # WHAT THE WINDOW SAYS OVER THE PICTURE until the player presses a button: what could not be used
      # in the settings file (+problems+, the sentences as text, a file's name over its own), in the
      # middle as the window opens, since a player who opened the game by double-clicking it has no
      # terminal to read; and what a shell tells the player (#tell), at the foot of the window, so
      # the shell's own menu shows above it. Each has an OK, and the next button pressed answers both
      # (#answer_messages). Nothing waits for them: the game plays on under them.
      def problems=(text)
        @problems = (text unless text.nil? || text.empty?)
      end

      def tell(words)
        @told = (words unless words.nil? || words.empty?)
      end

      # A button was pressed: whatever was said over the picture has been seen.
      def answer_messages
        @problems = @told = nil
      end

      def messages_shown? = !(@problems || @told).nil?

      # Whether the window of the game's variables is open (WindowMenu::VARIABLE_ROWS).
      def variables_open? = @variables_open

      # One of :up, :down or :close, pressed while the window of variables is open and the menu is not:
      # up and down scroll it a line, and close shuts it. Gives whether the key was the window's.
      def press_on_variables(key)
        return false unless @variables_open && !@open

        case key
        when :up then @variables_scroll = [@variables_scroll - 1, 0].max
        when :down then @variables_scroll += 1
        when :close then @variables_open = false
        else return false
        end
        true
      end

      # Key +key+ (SDL's scancode) pressed while the window of variables is open and the menu is not: a
      # letter, digit or underscore goes on the end of what the window finds, and Backspace takes the
      # last off. Gives whether the key was the window's.
      def type_key(key)
        return false unless @variables_open && !@open

        if key == WindowMenu::BACKSPACE_KEY
          @filter = @filter[0...-1]
        else
          letter = WindowMenu.typed_letter(key) or return false
          @filter += letter if @filter.length < WindowMenu::FILTER_MOST
        end
        @variables_scroll = 0
        true
      end

      # WHAT A WINDOW DRAWS over the game, in its own pixels: the window of the game's +variables+
      # when it is open (name and value pairs, as the frontend read them from the game, with
      # +variables_dropped+ more it had no room to read), the menu when it is open, and in the top
      # right corner what the window is doing — the frame rate when it is asked for, how long the
      # game's own work took a frame (+frame_work+, in milliseconds, the developer's reading), and
      # PAUSED while the game is +held+ or the speed while it is played +fast_forward+ times as fast.
      # +width+ and +height+ are the window's in pixels, and +density+ how many pixels a point is (two
      # on a Retina screen). Gives WindowMenu::Box and WindowMenu::Words, back to front.
      def drawing(width:, height:, density:, held: false, fast_forward: nil, frame_rate: nil, frame_work: nil, variables: [],
                  variables_dropped: 0)
        @out = []
        @density = density
        @font = Graphics::MenuFont.load
        top = @open ? size(:bar) : 0
        draw_variables(top, variables, variables_dropped) if @variables_open
        draw_message("Load ROM", [@told], width, width * 9 / 10) { |high| height - size(:message_gap) - high } if @told
        if @problems
          wide = [size(:message_width), width - (2 * size(:status_gap))].min
          draw_message("The settings file", [SETTINGS_PROBLEMS_INTRO, @problems], width, wide) { |high| (height - high) / 2 }
        end
        if @open
          draw_bar(width)
          draw_lines(top)
        end
        draw_status(width, top, held, fast_forward, frame_rate, frame_work)
        @out
      end

      # WHAT A WINDOW WAITING FOR ITS GAME DRAWS (a game a helper process builds, BuildWatch): +lines+
      # of words in the middle of a window +width+ by +height+ pixels, one under another, a line too
      # wide for the window broken between words. Gives WindowMenu::Words.
      def waiting_drawing(lines, width:, height:, density:)
        @out = []
        @density = density
        @font = Graphics::MenuFont.load
        rows = lines.flat_map { |line| break_to_width(line, width - (2 * size(:pad))) }
        line = size(:status_line)
        top = (height - (rows.size * line)) / 2
        rows.each_with_index { |text, index| add_words(text, (width - width_of(text)) / 2, top + (index * line), :text) }
        @out
      end

      private

      # +text+ as lines no wider than +room+ pixels, broken between words; a word wider than that
      # has a line of its own.
      def break_to_width(text, room)
        text.split.each_with_object([]) do |word, rows|
          if rows.empty? || width_of("#{rows.last} #{word}") > room
            rows << word
          else
            rows[-1] = "#{rows.last} #{word}"
          end
        end
      end

      def lines = @headings[@heading].lines

      def press_on_bar(key)
        case key
        when :left, :right then move_heading(key)
        when :down, :enter then @row = 0
        end
      end

      def move_heading(key)
        @heading = (@heading + (key == :right ? 1 : -1)) % @headings.size
        @row = -1
      end

      def slide(line, direction)
        least, most = limits(line)
        now = @settings.setting(line.setting)
        @settings = @settings.with(line.setting => (now + (direction * line.step)).clamp(least, most))
      end

      # How far a slider goes: the window's size no further than the frontend allows.
      def limits(line)
        return [[line.range.min, @scales.min].max, [line.range.max, @scales.max].min] if line.setting == :scale

        [line.range.min, line.range.max]
      end

      def enter(line)
        case line.kind
        when :check then @settings = @settings.with(line.setting => !@settings.setting(line.setting))
        when :button then @controls.capture_for_button(line.place)
        when :hotkey then @controls.capture_for_hotkey(line.place)
        when :state then ask_state_and_close(line.request)
        when :action
          @open = false if line.does == :resume
          @quit = true if line.does == :quit
          show_variables(!@variables_open) if line.does == :variables
          @controls.reset_keys if line.does == :reset_keys
          @controls.reset_hotkeys if line.does == :reset_hotkeys
        end
      end

      # The window of variables opened or shut from its line, and the menu closed so the game plays
      # under it.
      def show_variables(shown)
        @variables_open = shown
        @open = false
      end

      # A save or load chosen from a line: asked for, and the menu closes so the game goes on.
      def ask_state_and_close(request)
        @state_request = request
        @open = false
      end

      # --- drawing ---

      def pixels(points) = (points * @density).round
      def size(name) = pixels(WindowMenu::SIZES.fetch(name))
      def color(name) = WindowMenu::COLORS.fetch(name)

      # A box to draw, added to what #drawing gives.
      def add_box(x, y, width, height, radius, color_name)
        @out << WindowMenu::Box.new(x: x, y: y, width: width, height: height, radius: radius, color: color(color_name))
      end

      # Words to draw, the top left of their line at +x+, +y+, added to what #drawing gives.
      def add_words(text, x, y, color_name)
        @out << WindowMenu::Words.new(text: text, color: color(color_name),
                                      letters: @font.layout(text, x, y, @density))
      end

      def width_of(text) = @font.width(text, @density)

      # +text+ with its line in the middle of a row +height+ pixels high from +top+.
      def add_words_in_row(text, x, top, height, color_name)
        add_words(text, x, top + ((height - @font.line_height(@density)) / 2), color_name)
      end

      # The bar along the top, its headings, and the open one marked. Gives how tall it is.
      def draw_bar(width)
        bar = size(:bar)
        add_box(0, 0, width, bar, 0, :bar)
        x = size(:pad)
        @headings.each_with_index do |heading, index|
          wide = width_of(heading.name)
          if index == @heading
            @heading_left = x - size(:heading_pad)
            add_box(@heading_left, 0, wide + (2 * size(:heading_pad)), bar, 0, @row.negative? ? :chosen : :open)
          end
          add_words_in_row(heading.name, x, 0, bar, :text)
          x += wide + size(:heading_gap)
        end
        bar
      end

      # The open heading's lines, in a box under it with a border a point wide.
      def draw_lines(top)
        pad = size(:pad)
        row = size(:row)
        notice = @controls.notice
        inner = [lines.map { |line| width_of(line.label) + size(:label_gap) + right_width(line) }.max,
                 size(:least_width), *(width_of(notice) if notice)].max
        wide = inner + (2 * pad)
        high = (lines.size * row) + (2 * pad) + (lines.count(&:line_before) * size(:line_before)) + (notice ? row : 0)
        border = pixels(1)
        add_box(@heading_left, top, wide, high, size(:corner), :border)
        add_box(@heading_left + border, top + border, wide - (2 * border), high - (2 * border), size(:corner) - border, :box)
        y = top + pad
        lines.each_with_index do |line, index|
          if line.line_before
            add_box(@heading_left + pad, y + (size(:line_before) / 2), inner, border, 0, :border)
            y += size(:line_before)
          end
          add_box(@heading_left + (pad / 2), y, wide - pad, row, size(:frame_corner), :chosen) if index == @row
          draw_line(line, @heading_left + pad, y, inner, row)
          y += row
        end
        add_words_in_row(notice, @heading_left + pad, y, row, :paused) if notice
      end

      # THE WINDOW OF THE GAME'S VARIABLES, in the top left corner, under the bar when the menu is
      # open: its title, the letters typed or what to type, a heading of Name and Value, a line for
      # each variable the letters find from the one scrolled to, and which lines those are. It is as
      # wide as its widest name needs, never narrower than variables_width, and always the same
      # height, so it stands still as the list changes.
      def draw_variables(top, variables, dropped)
        pad = size(:pad)
        row = size(:row)
        rows = WindowMenu::VARIABLE_ROWS
        found = variables.select { |name, _| name.downcase.include?(@filter) }
        @variables_scroll = @variables_scroll.clamp(0, [found.size - rows, 0].max)
        value_room = width_of(WindowMenu::WIDEST_VALUE)
        inner = [size(:variables_width), *variables.map { |name, _| width_of(name) + size(:label_gap) + value_room }].max
        wide = inner + (2 * pad)
        high = ((rows + 4) * row) + (2 * pad)
        x = size(:status_gap)
        y = top + size(:status_gap)
        border = pixels(1)
        add_box(x, y, wide, high, size(:corner), :border)
        add_box(x + border, y + border, wide - (2 * border), high - (2 * border), size(:corner) - border, :box)
        left = x + pad
        right = left + inner
        line = y + pad
        add_words_in_row("Game variables", left, line, row, :text)
        line += row
        if @filter.empty? then add_words_in_row("Type letters to find a name", left, line, row, :dim)
        else add_words_in_row(@filter, left, line, row, :text)
        end
        line += row
        add_words_in_row("Name", left, line, row, :dim)
        add_words_in_row("Value", right - width_of("Value"), line, row, :dim)
        line += row
        add_box(left, line, inner, border, 0, :border)
        found[@variables_scroll, rows].each do |name, value|
          add_words_in_row(name, left, line, row, :text)
          add_words_in_row(value.to_s, right - width_of(value.to_s), line, row, :text)
          line += row
        end
        add_words_in_row(variables_footer(found.size, dropped), left, y + pad + ((rows + 3) * row), row, :dim)
      end

      # Which of the lines found are shown, or that none are, and how many the frontend had no room for.
      def variables_footer(count, dropped)
        said = if count.zero? then @filter.empty? ? "No variables" : "No name has these letters"
               else "#{@variables_scroll + 1} to #{[@variables_scroll + WindowMenu::VARIABLE_ROWS, count].min} of #{count}"
               end
        dropped.positive? ? "#{said}, and #{dropped} more not shown" : said
      end

      # A BOX OF WORDS over the picture, +wide+ pixels across the middle of a window +width+ wide, its
      # top where the block puts it given how high it is: its +title+, then each of +texts+ broken to
      # fit, a line across between one and the next, and an OK with what answers it beside it.
      def draw_message(title, texts, width, wide)
        pad = size(:pad)
        row = size(:row)
        inner = wide - (2 * pad)
        rows = texts.map { |text| wrap_lines(text, inner) }
        high = ((rows.sum(&:size) + 2) * row) + ((texts.size - 1) * size(:line_before)) + (2 * pad)
        x = (width - wide) / 2
        y = yield(high)
        border = pixels(1)
        add_box(x, y, wide, high, size(:corner), :border)
        add_box(x + border, y + border, wide - (2 * border), high - (2 * border), size(:corner) - border, :box)
        left = x + pad
        line = y + pad
        add_words_in_row(title, left, line, row, :text)
        line += row
        rows.each_with_index do |lines, index|
          if index.positive?
            add_box(left, line + (size(:line_before) / 2), inner, border, 0, :border)
            line += size(:line_before)
          end
          lines.each do |text|
            add_words_in_row(text, left, line, row, :text) unless text.empty?
            line += row
          end
        end
        ok = width_of("OK") + (2 * pad)
        add_box(left, line + pixels(2), ok, row - pixels(4), size(:frame_corner), :chosen)
        add_words_in_row("OK", left + ((ok - width_of("OK")) / 2), line, row, :text)
        add_words_in_row(CLOSE_CAPTION, left + ok + pad, line, row, :dim)
      end

      # +text+ as lines no wider than +room+ pixels: each of its own lines broken between words, a
      # line with no words in it kept as an empty one.
      def wrap_lines(text, room)
        text.split("\n").flat_map { |part| part.split.empty? ? [""] : break_to_width(part, room) }
      end

      # How much room the right of a line takes: a slider, a shortcut, or a check mark.
      def right_width(line)
        case line.kind
        when :slider then size(:slider)
        when :check then size(:check)
        when :button, :hotkey then width_of(@controls.text_for(line))
        when :state then width_of(state_line_words(line))
        else line.shortcut ? width_of(line.shortcut) : 0
        end
      end

      # What a state line shows at its right: its key, or when its slot's state was taken.
      def state_line_words(line) = line.shortcut || @states.text_for(line.place)

      def draw_line(line, x, y, inner, row)
        add_words_in_row(line.label, x, y, row, :text)
        right = x + inner
        case line.kind
        when :action then add_words_in_row(line.shortcut, right - width_of(line.shortcut), y, row, :dim) if line.shortcut
        when :check then add_words_in_row("✓", right - width_of("✓"), y, row, :text) if @settings.setting(line.setting)
        when :slider then draw_slider(line, right - size(:slider), y + pixels(2), size(:slider), row - pixels(4))
        when :button, :hotkey
          text = @controls.text_for(line)
          add_words_in_row(text, right - width_of(text), y, row, line.place == @controls.capture_place(line.kind) ? :fast : :dim)
        when :state
          text = state_line_words(line)
          add_words_in_row(text, right - width_of(text), y, row, :dim)
        end
      end

      # A slider: a frame, a grab as far along it as the number is, and the
      # number written in the middle.
      def draw_slider(line, x, y, wide, high)
        add_box(x, y, wide, high, size(:frame_corner), :frame)
        inset = pixels(2)
        least, most = limits(line)
        value = @settings.setting(line.setting)
        travel = wide - size(:grab) - (2 * inset)
        along = most > least ? travel * (value - least) / (most - least) : 0
        add_box(x + inset + along, y + inset, size(:grab), high - (2 * inset), pixels(2), :grab)
        text = slider_text(line, value)
        add_words_in_row(text, x + ((wide - width_of(text)) / 2), y, high, :text)
      end

      def slider_text(line, value)
        case line.written
        when :times then "#{value}x"
        when :percent then "#{value}%"
        when :window then "#{value}x  (#{@picture[0] * value} × #{@picture[1] * value})"
        end
      end

      # What the window is doing, in a see-through box in the top right corner, under the bar when
      # the menu is open.
      def draw_status(width, top, held, fast_forward, frame_rate, frame_work)
        said = []
        said << ["#{frame_rate} fps", :text] if frame_rate
        said << ["#{frame_work} ms of work a frame", :text] if frame_work
        if held then said << ["PAUSED", :paused]
        elsif fast_forward then said << ["FAST FORWARD #{fast_forward}x", :fast]
        end
        return if said.empty?

        pad = size(:status_pad)
        line = size(:status_line)
        wide = said.map { |text, _| width_of(text) }.max + (2 * pad)
        x = width - wide - size(:status_gap)
        y = top + size(:status_gap)
        add_box(x, y, wide, (said.size * line) + (2 * pad), size(:corner), :status)
        said.each_with_index { |(text, color_name), index| add_words(text, x + pad, y + pad + (index * line), color_name) }
      end
    end
  end
end
