/*
 * THE ROOM A RELAY KEEPS, AS A LOCKSTEP'S TRANSPORT, in JavaScript: the same as RelayTransport in Ruby
 * (lib/vblank/network/relay_transport.rb). It makes a room on a relay or joins one by its code, and from then on
 * carries a match's messages as text, one message each, over a line: a WebSocket to the real relay in a
 * browser (RgWebSocketLine), or, in a test, a line the test carries to a relay of its own.
 *
 * A line answers send_text(text), receive_text() (the next text that has come, or null), and closed().
 * A browser cannot open any other kind of connection, which is why it plays through a relay and not by address.
 *
 * Like the session (rg_lockstep.js), nothing here waits: asking for a room is a generator that yields while the
 * relay has not answered.
 */

/* A relay that would not make a room or join one, with the relay's reason (docs/network/protocol.md). */
class RgRoomRefused extends Error {
  constructor(reason, words) {
    super(words || `The relay did not do that (${reason}). To fix this, check the code and try again.`);
    this.reason = reason;
  }
}

/* A relay that does not speak this program's version of the format, or the other way round. */
class RgVersionMismatch extends Error {
  constructor(supported) {
    const known = supported.join(", ");
    super(Math.max(...supported) < RG_WIRE_VERSION
      ? `The relay knows version ${known} of the network format, and this game speaks version ${RG_WIRE_VERSION}. To fix this, use a newer relay.`
      : `The relay speaks version ${known} of the network format, and this game speaks the older version ${RG_WIRE_VERSION}. To fix this, update this game.`);
    this.supported = supported;
  }
}

class RgRelayTransport {
  constructor(line) {
    this.line = line;
    this.id = 0;
    this.code = null;
  }

  /* Makes a room: finishes with this machine in it as player 1, and its code to give to the others. */
  *makeRoom() {
    this.line.send_text(JSON.stringify({ v: RG_WIRE_VERSION, type: "make_room" }));
    const made = yield* this.answer();
    this.code = made.code;
    this.id = made.you;
  }

  /* Joins the room with +code+: finishes with this machine's number in it. */
  *joinRoom(code) {
    this.line.send_text(JSON.stringify({ v: RG_WIRE_VERSION, type: "join_room", code }));
    const joined = yield* this.answer();
    this.code = joined.code;
    this.id = joined.you;
  }

  /* The relay's reply to what was just asked, or an error in plain words. */
  *answer() {
    let text = this.line.receive_text();
    while (text === null) {
      if (this.line.closed()) throw new RgConnectionLost();
      yield;
      text = this.line.receive_text();
    }
    const reply = JSON.parse(text);
    if (reply.type === "error") {
      if (reply.reason === "version") throw new RgVersionMismatch(reply.supported || []);
      throw new RgRoomRefused(reply.reason, reply.words);
    }
    return reply;
  }

  send(message) { if (!this.line.closed()) this.line.send_text(JSON.stringify(message)); }

  /* The next message of the match as { from, message }, or null when there is none yet. */
  receive() {
    const text = this.line.receive_text();
    if (text === null) return null;
    const message = JSON.parse(text);
    return { from: message.from, message };
  }

  closed() { return this.line.closed(); }
}

/* A WebSocket as a line, in a browser (or any JavaScript that has the standard WebSocket). */
class RgWebSocketLine {
  constructor(url) {
    this.texts = [];
    this.ended = false;
    this.socket = new WebSocket(url);
    this.queued = [];
    this.socket.onopen = () => { for (const text of this.queued) this.socket.send(text); this.queued = []; };
    this.socket.onmessage = (event) => { if (typeof event.data === "string") this.texts.push(event.data); };
    this.socket.onclose = () => { this.ended = true; };
    this.socket.onerror = () => { this.ended = true; };
  }

  send_text(text) {
    if (this.socket.readyState === 1) this.socket.send(text); else this.queued.push(text);
  }

  receive_text() { return this.texts.length > 0 ? this.texts.shift() : null; }

  /* True once the relay has gone and every message it sent has been read. */
  closed() { return this.ended && this.texts.length === 0; }

  close() { this.socket.close(); }
}
