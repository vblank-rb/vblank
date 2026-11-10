# THE STATE IMAGE: everything a game and its runtime keep between two frames, written as text by
# name, and read back into the same build so the game plays on from there. This is
# native/runtime/rg_state.h in Ruby, line for line, and the text is the same: one line a field, its
# name, a tab, how many numbers it holds, and the numbers, all as decimal whole numbers, a run of one
# number as one word "times*number". So an image
# written by the C or the JavaScript runtime reads here, and the other way round.
#
# EACH FIELD IS NAMED ONCE AND USED BOTH WAYS. A part hands a field to rg_state_numbers (or the
# game's own calls, rg_state_number and rg_state_list, which the build writes into
# rg_game_visit_state); writing the image adds the field as a line, and reading it stores what the
# image holds under that name into the field. Writing and reading cannot disagree about what a field
# is or where it lives.
#
# Only at a frame boundary: every routine that can wait is stopped at its wait then, so the chain of
# routines the game is inside is numbers in its globals, and the image holds it whole.

# The image as text: the game's fields, then the runtime's, then the save memory's.
def rg_state_write
  @rg_state_lines = []
  rg_state_visit_all
  text = @rg_state_lines.join
  @rg_state_lines = nil
  text
end

# Reads an image from +text+ into the game and its runtime. One that names a field this build does
# not keep, lacks one it does, or holds a different count stops the game saying which.
def rg_state_read(text)
  @rg_state_image = rg_state_parse(text)
  @rg_state_taken = {}
  rg_state_visit_all
  @rg_state_image.each_key do |name|
    next if @rg_state_taken[name]

    rg_fault("This state is for another game: it holds \"#{name}\", and this game has none. Load a state that this game wrote.")
  end
  @rg_state_image = nil
  @rg_state_taken = nil
end

# Whether an image is being read just now, rather than written.
def rg_state_reading = !@rg_state_image.nil?

def rg_state_visit_all
  rg_game_visit_state
  rg_runtime_visit_state
  rg_save_visit_state
  rg_screen_visit_state
end

RG_STATE_SHORTEST_RUN = 4 # The shortest run of one number written as "times*number"

# The image's lines as name => numbers.
def rg_state_parse(text)
  image = {}
  text.each_line(chomp: true) do |line|
    next if line.empty?

    name, rest = line.split("\t", 2)
    numbers = rest && rg_state_parse_numbers(rest.split)
    if numbers.nil? || image.key?(name)
      rg_fault("This state is damaged: a line is not a name, a tab, a count and numbers. Load a state that this game wrote.")
    end
    image[name] = numbers
  end
  image
end

# The numbers a line's words after its name hold: the count, then each number or run of one number
# ("times*number"). Nil for words that are not that, or that hold more or fewer than the count.
def rg_state_parse_numbers(words)
  return nil unless words.first&.match?(/\A\d+\z/)

  count = words.first.to_i
  numbers = []
  words.drop(1).each do |word|
    if (run = word.match(/\A(\d+)\*(-?\d+)\z/))
      times = run[1].to_i
      return nil if times < 1 || numbers.length + times > count

      numbers.fill(run[2].to_i, numbers.length, times)
    elsif word.match?(/\A-?\d+\z/)
      numbers << word.to_i
    else
      return nil
    end
  end
  numbers.length == count ? numbers : nil
end

# A field's numbers as the words of its line: a run of RG_STATE_SHORTEST_RUN or more of one number as one.
def rg_state_words(values)
  values.chunk_while { |a, b| a == b }.flat_map do |run|
    run.length >= RG_STATE_SHORTEST_RUN ? ["#{run.length}*#{run.first}"] : run.map(&:to_s)
  end
end

# The image's numbers for field +name+, which this game keeps +count+ of.
def rg_state_field_named(name, count)
  numbers = @rg_state_image.fetch(name) do
    rg_fault("This state is for another game: it has no \"#{name}\". Load a state that this game wrote.")
  end
  if numbers.length != count
    rg_fault("This state is for another game: it holds #{numbers.length} numbers for \"#{name}\", and this game keeps " \
             "#{count}. Load a state that this game wrote.")
  end
  @rg_state_taken[name] = true
  numbers
end

# A field of the numbers in the Array +values+: written, or replaced by what the image holds.
def rg_state_numbers(name, values)
  if @rg_state_image
    values.replace(rg_state_field_named(name, values.length))
  else
    @rg_state_lines << "#{name}\t#{[values.length, *rg_state_words(values)].join(" ")}\n"
  end
  values
end

# A field of one number the build wrote as a global: written, or given back from the image.
def rg_state_number(name, value) = rg_i32(rg_state_numbers(name, [value]).first)

# A list: where the oldest item is, how many it holds, and every slot, used or not, as the ring
# stands, so the game's next push and shift land where they would have.
def rg_state_list(name, list)
  numbers = [list.front, list.length, *list.items.first(list.capacity)]
  rg_state_numbers(name, numbers)
  return unless @rg_state_image

  front, length = numbers
  if front.negative? || front >= [list.capacity, 1].max || length.negative? || length > list.capacity
    rg_fault("This state is damaged: the list \"#{name}\" has a place outside its #{list.capacity} slots. " \
             "Load a state that this game wrote.")
  end
  list.front = front
  list.length = length
  list.capacity.times { |slot| list.items[slot] = rg_list_fit(list, numbers[slot + 2]) }
end
