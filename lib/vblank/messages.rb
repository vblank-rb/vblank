# frozen_string_literal: true

# HOW A BUILD TALKS TO THE PERSON RUNNING IT, while it is still building — the English names
# for shared things, the progress line, where the printing goes, and which line of the author's
# own file to blame. None of it needs a cartridge to exist, which is what separates it from
# Diagnostics, the part that reads a finished or running one back.

require_relative "messages/made_names"     # Names the build makes up for what nobody wrote
require_relative "messages/plain_words"    # What a person calls a thing: the build's English
require_relative "messages/progress"       # What a build reports while it runs
require_relative "messages/build_output"   # Where a build prints
require_relative "messages/author_source"  # The first line outside the framework, to blame for a mistake
