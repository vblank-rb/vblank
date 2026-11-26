import flash.Lib;
import flash.display.Sprite;
import flash.events.Event;
import flash.events.KeyboardEvent;

// Traces "frame 1", "frame 2" and so on, and a line for each key pressed or let go.
class Main extends Sprite {
	var frame = 0;

	static function main() {
		Lib.current.addChild(new Main());
	}

	public function new() {
		super();
		addEventListener(Event.ENTER_FRAME, function(_) {
			frame++;
			Lib.trace("frame " + frame);
		});
		Lib.current.stage.addEventListener(KeyboardEvent.KEY_DOWN, function(event:KeyboardEvent) {
			Lib.trace("key down " + event.keyCode);
		});
		Lib.current.stage.addEventListener(KeyboardEvent.KEY_UP, function(event:KeyboardEvent) {
			Lib.trace("key up " + event.keyCode);
		});
	}
}
