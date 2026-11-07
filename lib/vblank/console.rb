# frozen_string_literal: true

# THE CONSOLES THEMSELVES, NAMED: what a game can tell about each one (its screen, its buttons, how
# many sprites it shows, what it does with each verb), and for each the addresses of the registers
# that drive its display, sound, copying engines and timers, and the flags written into them; and
# which of the library's parts serve each one (Console::Kit). Nothing here does anything; it
# is the table every part that talks to the hardware reads its numbers from, and the parts it
# names are only asked for once everything is loaded, so it needs nothing loaded before it.

require_relative "console/original_formats"  # How a console's games keep tiles, colours and numbers
require_relative "console/hardware"          # Register addresses, flags and memory map
require_relative "console/sample_clock"      # The rates a console's mix of recordings can run at
require_relative "console/description"       # What a game can tell about a console: screen, buttons, sprites
require_relative "console/variant"           # Hardware only some copies of a console have
require_relative "console/gbc_hardware"      # The Game Boy Color's addresses, flags and memory map
require_relative "console/snes_hardware"     # The Super Nintendo's addresses, flags and memory map
require_relative "console/genesis_hardware"  # The Sega Genesis's ports, registers, header and memory map
require_relative "console/ps1_hardware"      # The PlayStation's ports, graphics commands and memory map
require_relative "console/questions"         # What a line of a game asks of its console
require_relative "console/answers"           # What an answer to "what does this verb do here?" is
require_relative "console/advance_answers"   # The Game Boy Advance's answers: every verb works
require_relative "console/color_answers"     # The Game Boy Color's answers: works or refused
require_relative "console/snes_answers"      # The Super Nintendo's answers: works or refused
require_relative "console/genesis_answers"   # The Sega Genesis's answers: works or refused
require_relative "console/ps1_answers"       # The PlayStation's answers: works or refused
require_relative "console/kit"               # Which parts of the library serve each console
