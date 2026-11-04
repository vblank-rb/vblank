# frozen_string_literal: true

require "open3"

# A COPY OF A GAME BUILT AS JAVASCRIPT, PLAYED BY NODE, TAKING PART IN A MATCH THE TEST CONTROLS. The copy
# runs as a process of its own (JS#build_headless with `--match`), and cannot reach the test's network by
# itself, so this carries its messages: what node says to the room it prints as a line, and what the room says
# to it is handed over when it asks for one. The network is whatever gives the transport (a
# Network::SimulatedNetwork endpoint, with its delays, held messages and drops), so a node copy plays beside
# Ruby copies, and beside other node copies, in the same match.
#
# The lines between the two are:
#   node -> test   net-out JSON    a message for the room (the wire format, without who sent it)
#   node -> test   net?            "I need a message to go on": the test answers with
#   test -> node   net-in JSON     each message that has come (with who sent it), then
#   test -> node   net-end         ...no more for now; or net-closed first, when the link is gone
#   node -> test   pass N CRC PIC  pass N ended: the CRC of the game's state, and of the picture
#   node -> test   event N KIND P  something that happened on pass N (a player left)
#   node -> test   fingerprint CONSOLE DIGEST
#   node -> test   chat FROM TEXT  a line of chat that came from another player
#
# A copy that meets the others through a RELAY (relay_copy) is carried the same way, but what it says to the
# relay is text for a line: `relay-out TEXT`, `relay?` and `relay-in TEXT` / `relay-end` / `relay-closed`, and it
# says `room CODE` when it has made a room. The line is a Network::InProcessLine to a StandInRelay, or anything
# that answers send_text, receive_text, wait_for_text and closed?.
module NodeCopy
  Wire = VBlank::Network::Wire

  # What a copy came to: each pass's state CRC and picture CRC (as numbers and hex), the events it saw, the
  # fingerprint it carries, what it said on its error stream, and whether it ended well.
  Played = Data.define(:states, :pictures, :events, :fingerprint, :room, :chats, :error, :success)

  # A callable for Network::Scheduler#play that plays the copy: +program+ built as JavaScript, as player
  # +endpoint.id+, to host (+host:+ with the match's settings) or to join. +passes+ is how many to play and
  # +hold+ the buttons the copy's player holds from pass 2.
  def self.copy(program, endpoint:, passes:, hold: 0, host: nil, title: "WANDERERS", says: nil)
    -> { play(program, endpoint, passes, hold, host, title, says: says) }
  end

  # A callable that plays the copy through a relay: it makes a room (when +host+ gives the match's settings),
  # and puts the room's code in +code_box+ for the others; or it joins the room whose code is in +code_box+.
  def self.relay_copy(program, line:, passes:, code_box:, hold: 0, host: nil, title: "WANDERERS")
    lambda do
      relay = host ? ["--relay-make"] : ["--relay-join", code_box.first.to_s]
      play(program, line, passes, hold, host, title, relay: relay, code_box: code_box)
    end
  end

  def self.play(program, carrier, passes, hold, host, title, relay: nil, code_box: nil, says: nil)
    script = VBlank::IR::Backends::JS.new.build_headless(program)
    role = host ? ["--match-host", *host.values_at(:seed, :input_delay, :checkpoint_every, :players).map(&:to_s)] : ["--match-join"]
    you = relay ? [] : ["--you", carrier.id.to_s]
    chat = says ? ["--chat-at", says.first.to_s, says.last] : []
    command = ["node", script, passes.to_s, *role, *you, *relay.to_a, "--title", title, "--hold", hold.to_s, *chat]
    Open3.popen3(*command) do |stdin, stdout, stderr, waiter|
      reader = Thread.new { stderr.read }
      result = converse(stdin, stdout, carrier, code_box)
      stdin.close
      Played.new(**result, error: reader.value, success: waiter.value.success?)
    end
  end

  def self.converse(stdin, stdout, carrier, code_box = nil)
    found = { states: [], pictures: [], events: [], fingerprint: nil, room: nil, chats: [] }
    while (line = stdout.gets)
      case line
      when /\Anet-out (.*)/ then carrier.send_message(Wire.decode(Regexp.last_match(1)).message)
      when /\Anet\?/ then answer(stdin, carrier)
      when /\Arelay-out (.*)/ then carrier.send_text(Regexp.last_match(1))
      when /\Arelay\?/ then answer_from_line(stdin, carrier)
      when /\Aroom (\w+)/ then found[:room] = Regexp.last_match(1) and code_box&.concat([found[:room]] * 8) # one for each machine that may join
      when /\Apass (\d+) (\d+) (\h+)/ then found[:states] << Regexp.last_match(2).to_i and found[:pictures] << Regexp.last_match(3).to_i(16)
      when /\Aevent (\d+) (\w+) (\d+)/ then found[:events] << [Regexp.last_match(1).to_i, Regexp.last_match(2).to_sym, Regexp.last_match(3).to_i]
      when /\Achat (\d+) (.*)/ then found[:chats] << [Regexp.last_match(1).to_i, Regexp.last_match(2)]
      when /\Afingerprint (\w+) (\h+)/ then found[:fingerprint] = [Regexp.last_match(1), Regexp.last_match(2)]
      end
    end
    found
  end

  # The same through a line to a relay: the relay's text for the machine, as it comes.
  def self.answer_from_line(stdin, line)
    delivered = deliver_text(stdin, line)
    until delivered || line.closed?
      line.wait_for_text
      delivered = deliver_text(stdin, line)
    end
    stdin.puts("relay-closed") if line.closed? && !delivered
    stdin.puts("relay-end")
    stdin.flush
  end

  def self.deliver_text(stdin, line)
    any = false
    while (text = line.receive_text)
      stdin.puts("relay-in #{text}")
      any = true
    end
    any
  end

  # Hands node the messages that have come; if none has, the other copies play until one does.
  def self.answer(stdin, endpoint)
    delivered = deliver(stdin, endpoint)
    until delivered || endpoint.closed?
      endpoint.wait_for_message
      delivered = deliver(stdin, endpoint)
    end
    stdin.puts("net-closed") if endpoint.closed? && !delivered
    stdin.puts("net-end")
    stdin.flush
  end

  def self.deliver(stdin, endpoint)
    any = false
    while (envelope = endpoint.receive_message)
      stdin.puts("net-in #{Wire.encode(envelope.message, from: envelope.from)}")
      any = true
    end
    any
  end
end
