# frozen_string_literal: true

# A part of a game that walks a list in the copy until a record says it is the last, as an original
# walks a group of pictures: records of four words (where from, where to, how many, another follows)
# from byte +at+ on. Two ways of keeping "another follows": as the number read, and as true or false.
class RecordWalkPart
  def initialize(copy, pack)
    @copy = copy
    @pack = pack
  end

  def fill(at)
    more = 1
    while more != 0
      more = @copy.word(at + 12)
      @copy.copy_bytes at: @copy.word(at), count: @copy.word(at + 8), into: @pack[:out], start: @copy.word(at + 4)
      at += 16
    end
  end

  def fill_with_flag(at)
    more = true
    while more
      more = @copy.word(at + 12) != 0
      @copy.copy_bytes at: @copy.word(at), count: @copy.word(at + 8), into: @pack[:out], start: @copy.word(at + 4)
      at += 16
    end
  end
end
