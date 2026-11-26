//! What a game built to be tested (runtime/rg_headless.hx) asks of the harness, and how it is answered.
//!
//! The movie registers three callbacks with ExternalInterface, and the harness calls them:
//!
//!   rg_start(text)     the frames to play, then each option on a line of its own, once, before frame 1
//!   rg_buttons(line)   the buttons for the frame about to be played, as a line of numbers
//!   rg_picture()       the picture as a string, a character for each pixel, for the picture file
//!   rg_save_hex()      the save memory as hex digits, for the save file (written when the game ends)
//!
//! and the movie calls out rg_write_sound (a frame's sound) and rg_write_state (the state image, once).
//!
//! The movie traces "buttons?" when a frame has ended and it is waiting for the next frame's buttons. The
//! harness then reads standard input a line at a time: the line "picture" asks it to write the picture
//! file now (answered "picture-written"), and any other line is the buttons. The movie asks the harness to
//! stop with fscommand("rg_exit", "CODE:MESSAGE"): the harness writes the picture file once more, says the
//! message on standard error if there is one, and exits with CODE.
use ruffle_core::Player;
use ruffle_core::FloatDuration;
use ruffle_core::context::UpdateContext;
use ruffle_core::external::{ExternalInterfaceProvider, FsCommandProvider, Value};
use std::cell::{Cell, RefCell};
use std::io::{BufRead, Write};
use std::process::exit;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

/// The movie's request to stop: its exit code and what it has to say.
#[derive(Default)]
pub struct ExitRequest {
    pub requested: Cell<bool>,
    pub code: Cell<i32>,
    pub message: RefCell<String>,
}

pub struct ExitCommand {
    pub request: Rc<ExitRequest>,
}

impl FsCommandProvider for ExitCommand {
    fn on_fs_command(&self, command: &str, args: &str) -> bool {
        if command != "rg_exit" {
            return false;
        }
        let (code, message) = args.split_once(':').unwrap_or((args, ""));
        self.request.code.set(code.parse().unwrap_or(1));
        *self.request.message.borrow_mut() = message.to_string();
        self.request.requested.set(true);
        true
    }
}

/// Where the sound a movie makes goes, when a test asked for it (--sound-out FILE).
pub type SoundFile = Rc<RefCell<Option<std::fs::File>>>;

/// Where the state image the movie writes goes, when a test asked for it (--state-out FILE).
pub type StatePath = Rc<RefCell<Option<String>>>;

/// Makes ExternalInterface available to the movie. It calls out rg_write_sound: a frame's sound as hex digits (each
/// sample two bytes, low byte first, the left speaker's then the right's), written to the sound file at once, so whoever
/// plays the game can read it as it is made; and rg_write_state: the state image's text as hex digits, written to the
/// state file.
pub struct Provider {
    pub sound: SoundFile,
    pub state: StatePath,
}

impl ExternalInterfaceProvider for Provider {
    fn call_method(&self, _context: &mut UpdateContext<'_>, name: &str, args: &[Value]) -> Value {
        if name == "rg_write_sound" {
            if let (Some(file), Some(Value::String(digits))) = (self.sound.borrow_mut().as_mut(), args.first()) {
                let bytes: Vec<u8> = (0..digits.len() / 2).filter_map(|at| u8::from_str_radix(&digits[at * 2..at * 2 + 2], 16).ok()).collect();
                let _ = file.write_all(&bytes);
                let _ = file.flush();
            }
        }
        if name == "rg_write_state" {
            if let (Some(path), Some(Value::String(digits))) = (self.state.borrow().as_ref(), args.first()) {
                let bytes: Vec<u8> = (0..digits.len() / 2).filter_map(|at| u8::from_str_radix(&digits[at * 2..at * 2 + 2], 16).ok()).collect();
                if std::fs::write(path, bytes).is_err() {
                    eprintln!("the state could not be written to {path}");
                    exit(1);
                }
            }
        }
        Value::Null
    }

    fn on_callback_available(&self, _name: &str) {}

    fn get_id(&self) -> Option<String> {
        None
    }
}

fn picture_string(player: &Arc<Mutex<Player>>) -> String {
    match player.lock().unwrap().call_internal_interface("rg_picture", []) {
        Value::String(text) => text,
        _ => String::new(),
    }
}

/// Writes the picture file in place (the file is read by whoever is playing, through its own open
/// handle, so the file itself must stay the same one): two bytes a pixel, low byte first.
fn write_picture(path: &str, player: &Arc<Mutex<Player>>) {
    let mut bytes = Vec::new();
    for pixel in picture_string(player).encode_utf16() {
        bytes.extend_from_slice(&pixel.to_le_bytes());
    }
    if std::fs::write(path, bytes).is_err() {
        eprintln!("flash_player_harness: the picture could not be written to {path}");
        exit(2);
    }
}

/// The save memory the movie holds, as bytes (it gives them as hex digits; none for a game with no save memory).
fn save_bytes(player: &Arc<Mutex<Player>>) -> Vec<u8> {
    let digits = match player.lock().unwrap().call_internal_interface("rg_save_hex", []) {
        Value::String(text) => text,
        _ => String::new(),
    };
    (0..digits.len() / 2).filter_map(|at| u8::from_str_radix(&digits[at * 2..at * 2 + 2], 16).ok()).collect()
}

/// Writes the save file as the movie holds it: whole, under another name first and then renamed into place.
fn write_save(path: &str, player: &Arc<Mutex<Player>>) {
    let bytes = save_bytes(player);
    if bytes.is_empty() {
        return;
    }
    let writing = format!("{path}.writing");
    if std::fs::write(&writing, bytes).and_then(|_| std::fs::rename(&writing, path)).is_err() {
        eprintln!("the save memory could not be written to {path}");
        exit(1);
    }
}

fn finish(player: &Arc<Mutex<Player>>, picture_out: Option<&str>, save_file: Option<&str>, exit_request: &ExitRequest) -> ! {
    if let Some(path) = picture_out {
        write_picture(path, player);
    }
    if let Some(path) = save_file {
        write_save(path, player);
    }
    let _ = std::io::stdout().flush();
    let message = exit_request.message.borrow();
    if !message.is_empty() {
        eprintln!("{message}");
    }
    exit(exit_request.code.get());
}

/// Plays the movie as a game built to be tested, frame by frame, until it asks to stop.
pub fn play_headless(
    player: &Arc<Mutex<Player>>,
    frame_time: FloatDuration,
    frames: u32,
    options: &[String],
    picture_out: Option<&str>,
    save_file: Option<&str>,
    state_in: Option<&[u8]>,
    asked_for_buttons: &Rc<Cell<bool>>,
    exit_request: &Rc<ExitRequest>,
) -> ! {
    let mut start = frames.to_string();
    for option in options {
        start.push('\n');
        start.push_str(option);
    }
    // The save memory the game starts with, from the file a test handed over, if there is one.
    if let Some(bytes) = save_file.and_then(|path| std::fs::read(path).ok()) {
        let digits: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
        start.push_str("\n--save-bytes\n");
        start.push_str(&digits);
    }
    // The state the game starts from, likewise, if a test handed one over.
    if let Some(bytes) = state_in {
        let digits: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
        start.push_str("\n--state-bytes\n");
        start.push_str(&digits);
    }
    player.lock().unwrap().call_internal_interface("rg_start", [Value::String(start)]);

    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    // A frame the game plays ends at a frame boundary, so no more than the frames asked for, and a few
    // for a frame a timer's handler holds up, can pass before it says it is over.
    let most_frames = u64::from(frames) * 4 + 10_000;
    for _ in 0..most_frames {
        {
            let mut player = player.lock().unwrap();
            player.run_frame();
            player.update_timers(frame_time);
            player.audio_mut().tick();
        }
        if exit_request.requested.get() {
            finish(player, picture_out, save_file, exit_request);
        }
        if !asked_for_buttons.replace(false) {
            continue;
        }
        loop {
            let mut line = String::new();
            if input.read_line(&mut line).unwrap_or(0) == 0 {
                // Whoever played the game is gone: there are no buttons to wait for, and nobody to say anything to.
                eprintln!("standard input ended before the game did");
                exit(5);
            }
            let line = line.trim_end_matches(['\n', '\r']);
            if line == "picture" {
                if let Some(path) = picture_out {
                    write_picture(path, player);
                }
                let mut out = std::io::stdout().lock();
                if writeln!(out, "picture-written").and_then(|_| out.flush()).is_err() {
                    exit(5); // a broken pipe is the end of the run
                }
                continue;
            }
            player.lock().unwrap().call_internal_interface("rg_buttons", [Value::String(line.to_string())]);
            break;
        }
    }
    eprintln!("the game did not end after {frames} frames");
    exit(4);
}
