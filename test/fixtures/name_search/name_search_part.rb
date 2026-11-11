# frozen_string_literal: true

# A part of a game that looks for one file by its name in a copy that is an archive of files, as an
# original keeps its pictures and levels: three bytes of signature, then for each file a name of
# NameSearchPart::NAME_BYTES letters, a word saying how many bytes it holds, and those bytes. Each
# method answers where the named file's bytes start, or 0. They are the same search written with
# each loop a game can write, and every one counts the letters that differ in a name set to 0 at
# the top of each round of the outer loop.
#
# +build+ is the routine's builder, kept by the part and called by name (`@build.repeat`).
# +letters+ is a table of the name looked for.
class NameSearchPart
  FIRST_FILE_AT = 3
  NAME_BYTES = 4
  FILE_HEADER_BYTES = NAME_BYTES + 4

  def initialize(build, copy, size)
    @build = build
    @copy = copy
    @size = size
  end

  def start_counted_by_repeat(letters)
    at = FIRST_FILE_AT
    length = @copy.word(at + NAME_BYTES)
    start = 0
    while start == 0 && at + FILE_HEADER_BYTES + length <= @size
      differing = 0
      @build.repeat(NAME_BYTES) do |place|
        differing += 1 if @copy.byte(at + place) != letters[place]
      end
      start = at + FILE_HEADER_BYTES if differing == 0
      at += FILE_HEADER_BYTES + length
      length = @copy.word(at + NAME_BYTES)
    end
    start
  end

  # The names the loop's test reads are plain numbers when the loop is reached, and are changed
  # only under a test the routine makes as it plays.
  def start_moved_on_in_else(letters)
    at = FIRST_FILE_AT
    start = 0
    while start == 0 && at + FILE_HEADER_BYTES <= @size
      differing = 0
      @build.repeat(NAME_BYTES) do |place|
        differing += 1 if @copy.byte(at + place) != letters[place]
      end
      if differing == 0 then start = at + FILE_HEADER_BYTES else at += FILE_HEADER_BYTES + @copy.word(at + NAME_BYTES) end
    end
    start
  end

  def start_counted_in_until(letters)
    at = FIRST_FILE_AT
    length = @copy.word(at + NAME_BYTES)
    start = 0
    until start != 0 || at + FILE_HEADER_BYTES + length > @size
      differing = 0
      @build.repeat(NAME_BYTES) do |place|
        differing += 1 if @copy.byte(at + place) != letters[place]
      end
      start = at + FILE_HEADER_BYTES if differing == 0
      at += FILE_HEADER_BYTES + length
      length = @copy.word(at + NAME_BYTES)
    end
    start
  end

  def start_counted_by_inner_while(letters)
    at = FIRST_FILE_AT
    length = @copy.word(at + NAME_BYTES)
    start = 0
    while start == 0 && at + FILE_HEADER_BYTES + length <= @size
      differing = 0
      place = 0
      while place < NAME_BYTES
        differing += 1 if @copy.byte(at + place) != letters[place]
        place += 1
      end
      start = at + FILE_HEADER_BYTES if differing == 0
      at += FILE_HEADER_BYTES + length
      length = @copy.word(at + NAME_BYTES)
    end
    start
  end

  # +name+ is a Ruby list of the letters, so the comparison is written out once a letter.
  def start_counted_over_ruby_list(name)
    at = FIRST_FILE_AT
    length = @copy.word(at + NAME_BYTES)
    start = 0
    while start == 0 && at + FILE_HEADER_BYTES + length <= @size
      differing = 0
      name.each_with_index do |letter, place|
        differing += 1 if @copy.byte(at + place) != letter
      end
      start = at + FILE_HEADER_BYTES if differing == 0
      at += FILE_HEADER_BYTES + length
      length = @copy.word(at + NAME_BYTES)
    end
    start
  end
end

# The same search as a method of the game file's own, handed the builder as a name.
def name_search_start(build, copy, size, letters)
  at = NameSearchPart::FIRST_FILE_AT
  length = copy.word(at + NameSearchPart::NAME_BYTES)
  start = 0
  while start == 0 && at + NameSearchPart::FILE_HEADER_BYTES + length <= size
    differing = 0
    build.repeat(NameSearchPart::NAME_BYTES) do |place|
      differing += 1 if copy.byte(at + place) != letters[place]
    end
    start = at + NameSearchPart::FILE_HEADER_BYTES if differing == 0
    at += NameSearchPart::FILE_HEADER_BYTES + length
    length = copy.word(at + NameSearchPart::NAME_BYTES)
  end
  start
end
