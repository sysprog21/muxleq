// Browser-side driver for the MUXLEQ VM running the baked eForth image.
//
// The VM cannot block on a keystroke here, so mux_run() interprets a bounded
// slice and returns. This file turns that into something a page can use: type a
// line, get output back, and let a long-running program keep the tab alive by
// yielding between slices.
//
// Nothing the page needs rides on the byte stream, because the byte stream
// belongs to the user. Both side channels are blocks of Forth memory read
// straight out of the wasm heap:
//   report      the data stack, snapshotted by a custom <ok> hook after each
//               interpreted line: sequence, base, depth, then the cells.
//   graphics    one cell per pixel, which is how the canvas gets its contents
//               without the image having to emit them a byte at a time.
// Only their two addresses are announced on the stream, in a single framed
// message at the end of boot, before any user code can run. After that the
// framing is switched off, so a program is free to "1 emit" without the page
// mistaking its output for a report.

const FRAME_START = 0x01;
const FRAME_END = 0x02;

// Run status, matching the enum in muxleq-core.h.
const MUX_OK = 0;
const MUX_YIELD = 4;
const MUX_NEED_INPUT = 5;

export const GFX_WIDTH = 24;
export const GFX_HEIGHT = 24;
const GFX_CELLS = GFX_WIDTH * GFX_HEIGHT;

// The one framed message, tagged so it cannot be confused with stray output:
// "G <graphics> <report>".
const GRAPHICS_TAG = "G";

// report block: [0] sequence, [1] base, [2] depth, [3...] cells bottom to top.
const REPORT_SEQ = 0;
const REPORT_BASE = 1;
const REPORT_DEPTH = 2;
const REPORT_ITEMS = 3;
const MAX_ITEMS = 32;
const REPORT_CELLS = REPORT_ITEMS + MAX_ITEMS + 1;

// Render a cell the way eForth's own "." would: signed, in the current base,
// with hex digits in capitals.
function formatCell(v, base) {
  const digits = Math.abs(v).toString(base).toUpperCase();
  return v < 0 ? "-" + digits : digits;
}

// Everything the page needs on top of stock eForth. Kept deliberately small:
// it is meant to be readable by someone working through the tutorial, not a
// second language layered on top.
//
// The reporter itself is a :noname definition, so it adds no dictionary entry
// and stays quiet while compiling, exactly as the stock "ok" does. That matters
// for a tutorial: a colon definition typed over several lines must not produce
// a stack report on every one of them.
//
// eForth's error handler re-initializes the task, and that puts the stock "ok"
// back. "+ok" reinstalls the reporter, and is immediate so that sending it can
// never be mistaken for text to compile.
const PRELUDE = `decimal
create graphics ${GFX_CELLS} cells allot
graphics ${GFX_CELLS} cells erase
create report ${REPORT_CELLS} cells allot
report ${REPORT_CELLS} cells erase
variable seed  12345 seed !
: random ( u -- 0..u-1 )
  seed @ dup 13 lshift xor dup 17 rshift xor dup 5 lshift xor
  dup seed ! 32767 and swap mod ;
: ekey ( -- c|0 ) $FF02 emit key dup $100 = if drop 0 then ;
variable ok-xt
:noname state @ ?exit
  base @ report cell+ !
  depth report 2 cells + !
  report 2 cells + @ ${MAX_ITEMS} min 0 ?do
    report 2 cells + @ ${MAX_ITEMS} min i - 1- pick
    report 3 cells + i cells + !
  loop
  report @ 1+ report ! ; ok-xt !
: +ok ok-xt @ <ok> ! ; immediate
+ok
1 emit 71 emit graphics . report . 2 emit
`;

// eForth's error handler prints the throw code as " <n>?" and then re-initializes
// the task, which puts the stock "ok" back and stops the stack snapshots. That
// spelling is the cue to reinstall the reporter.
// eForth's error handler prints the throw code on a line of its own, as the
// last thing before it goes back to reading, e.g. "zzz?\n  -13?\n". Anchoring
// on a preceding newline AND on the end of output is what keeps ordinary prose
// from matching: a program printing "what is 2 - 3? " has no newline before the
// digits, and a rolling-window cut cannot fake one the way a bare ^ would.
//
// This narrows the hazard below rather than removing it. The host cannot tell
// "the interpreter wants the next line" from "a user program is blocked in
// key", so a program whose LAST output really does look like a throw report
// still receives the recovery text as keystrokes. Closing that properly means
// not routing recovery through the input stream at all.
const ERROR_REPORT = /\n[ \t]*-?\d+\?[ \t\r\n]*$/;
// Enough trailing output to hold a report that straddles a chunk boundary.
const ERROR_TAIL_KEEP = 64;


// Node has neither of these; the tutorial's own tests drive the VM headless.
const now =
  typeof performance !== "undefined" ? () => performance.now() : Date.now;
const raf =
  typeof requestAnimationFrame !== "undefined"
    ? requestAnimationFrame
    : (fn) => setTimeout(fn, 0);
const unraf =
  typeof cancelAnimationFrame !== "undefined" ? cancelAnimationFrame : clearTimeout;

let modulePromise = null;

// Compile the module once; every editor on the page instantiates its own copy
// so each gets a private 256 KiB image.
export function loadForthModule(url = "muxleq.wasm") {
  if (!modulePromise) {
    modulePromise = WebAssembly.instantiateStreaming
      ? WebAssembly.compileStreaming(fetch(url))
      : fetch(url)
          .then((r) => r.arrayBuffer())
          .then((b) => WebAssembly.compile(b));
  }
  return modulePromise;
}

export class Forth {
  // handlers: { onOutput(text), onStack(text), onIdle(halted) }
  constructor(wasmModule, handlers = {}) {
    this.ex = new WebAssembly.Instance(wasmModule, {}).exports;
    if (this.ex._initialize) this.ex._initialize();
    this.on = handlers;

    // Instructions per turn, retuned as it runs so one turn stays near one
    // display frame regardless of how fast the machine is.
    this.slice = 200000;

    // Asked for rather than assumed: this is the point at which the host cuts a
    // turn short so the page can drain, and a copy here would drift from the C.
    this.outHighWater = this.ex.mux_out_high_water();

    this.inFrame = false;
    this.frame = "";
    this.text = "";
    this.pending = "";
    this.sawError = false;
    this.running = false;
    this.pendingFrame = 0;
    this.booting = true;
    this.gotGraphics = false;
    this.graphics = 0;
    this.report = 0;
    this.lastSeq = 0;
    this.dead = false;
    this.tail = "";

    this.ex.mux_reset();
    this.mem = new Uint32Array(this.ex.memory.buffer, this.ex.mux_mem(),
                               this.ex.mux_cells());
    this.send(PRELUDE);
    this.pump();
  }

  // Queue text for the interpreter. The VM's input queue is finite, so anything
  // that does not fit waits in "pending" and goes in as turns free up space.
  // Appending rather than replacing matters: two sends before the queue drains
  // used to drop whatever the first one had left over.
  send(text) {
    this.pending += text;
    this.flush();
  }

  // Move as much of "pending" into the VM's queue as it will take.
  flush() {
    let n = 0;
    while (n < this.pending.length) {
      const c = this.pending.charCodeAt(n);
      if (!this.ex.mux_push(c > 0xff ? 0x3f : c)) break; // '?' for non-ASCII
      n++;
    }
    if (n) this.pending = this.pending.slice(n);
  }

  // Interpret one line typed at the prompt. Anything in "keys" is queued behind
  // the newline, so a line whose code goes looking for keystrokes finds them
  // already waiting.
  submit(text, keys = "") {
    this.send((text.endsWith("\n") ? text : text + "\n") + keys);
    this.pump();
  }

  // Interpret until the image wants input, halts, or the time cap is hit. A
  // REPL line finishes inside the cap and so feels immediate; anything longer
  // continues on animation frames, which is what keeps a game loop drawing.
  //
  // Returns true only when the image actually came to rest. Hitting the cap
  // looks identical from outside -- not running, control returned -- but there
  // is still work queued, so the two must not be confused.
  pump(capMs = 30) {
    if (this.dead || this.running) return false;
    this.running = true;
    // Defence in depth for the flag itself: every ordinary exit below clears it,
    // but an exception thrown anywhere in the loop would otherwise leave it set
    // and every later pump() would return false at the guard above, with the
    // widget stuck reporting that a program is still running.
    try {
      return this.pumpLoop(capMs);
    } finally {
      this.running = false;
    }
  }

  pumpLoop(capMs) {
    const deadline = now() + capMs;
    for (;;) {
      const t0 = now();
      const status = this.ex.mux_run(this.slice);
      const produced = this.ex.mux_out_len();
      // Only a turn that actually spent its slice says anything about how fast
      // this machine is. A turn that stopped early for input finished in no
      // time no matter how big the slice was, and so did one the host cut short
      // to let the output buffer drain -- treating that as "fast" ratchets the
      // slice up until a compute-heavy stretch blocks the tab.
      if (status === MUX_YIELD && produced < this.outHighWater)
        this.retune(now() - t0);
      this.drain();
      this.checkReport();
      // Decide before flushing: flush() can empty `pending` into the VM queue on
      // this very iteration, which would make unconsumed input look like rest.
      const cameToRest = status === MUX_NEED_INPUT && !this.pending;
      this.flush();
      if (cameToRest) {
        // Only inject the repair once the image is asking for input, so a
        // running program's own key reads never see it. The flag is rolling
        // rather than per-submit: several lines can be in flight at once during
        // a file load, and an error on an early one must not be forgotten just
        // because a later one was submitted before this point was reached.
        if (this.sawError) {
          this.sawError = false;
          this.send("+ok\n");
          continue;
        }
        // Reaching rest still "booting" means the whole prelude was consumed
        // without the address message arriving, so it failed somewhere. Stop
        // swallowing output and show whatever it did say, rather than leaving a
        // blank editor and no explanation.
        if (this.booting) {
          this.booting = false;
          this.emit(); // release it now: a later turn may produce no bytes at all
        }
        this.running = false;
        if (this.on.onIdle) this.on.onIdle(false);
        return true;
      }
      if (status === MUX_OK) {
        this.running = false;
        if (this.on.onIdle) this.on.onIdle(true);
        return true;
      }
      if (now() >= deadline) {
        this.running = false;
        this.resume();
        return false;
      }
    }
  }

  // Run to a standstill, for callers with no animation frames to fall back on.
  // pump() caps a turn and then defers to the frame loop, which never arrives
  // outside a browser, so a headless caller has to keep asking. Returns false if
  // the image was still busy after "turns", which means a program that does not
  // stop rather than a slow one.
  runToIdle(turns = 20000) {
    for (let i = 0; i < turns; i++) if (this.pump(1000)) return true;
    return false;
  }

  resume() {
    if (this.dead || this.pendingFrame) return;
    this.pendingFrame = raf(() => {
      this.pendingFrame = 0;
      this.pump(8);
    });
  }

  // Abandoning an instance is not enough to stop it: a scheduled frame holds a
  // closure over it, so it keeps running, keeps calling the handlers it was
  // built with, and keeps its memory alive. Resetting an editor while a program
  // is running has to actually stop the old machine.
  stop() {
    this.dead = true;
    if (this.pendingFrame) unraf(this.pendingFrame);
    this.pendingFrame = 0;
  }

  // Aim for roughly half a 60 Hz frame per turn so the page stays responsive
  // on a slow machine without throttling a fast one.
  retune(ms) {
    if (ms < 3 && this.slice < 1 << 22) this.slice *= 2;
    else if (ms > 10 && this.slice > 1 << 12) this.slice = this.slice >> 1;
  }

  // Turn raw VM output into transcript text. Framing is only honored during
  // boot, when the only thing running is the prelude; afterwards every byte is
  // the user's, including 0x01 and 0x02.
  drain() {
    const len = this.ex.mux_out_len();
    if (!len) return;
    const bytes = new Uint8Array(this.ex.memory.buffer, this.ex.mux_out(), len);
    for (let i = 0; i < len; i++) {
      const b = bytes[i];
      if (this.booting && b === FRAME_START) {
        this.inFrame = true;
        this.frame = "";
      } else if (this.inFrame && b === FRAME_END) {
        this.inFrame = false;
        this.readAddresses(this.frame.trim());
        this.frame = "";
      } else if (this.inFrame) {
        this.frame += String.fromCharCode(b);
      } else if (b !== 0x0d) {
        this.text += String.fromCharCode(b);
      }
    }
    this.ex.mux_out_clear();
    this.emit();
  }

  // Hand the accumulated text to the page. Separate from drain() because a turn
  // that produced no bytes returns early, and the boot-failure path still has to
  // be able to release what the prelude managed to say before it stopped.
  emit() {
    if (!this.text || this.booting) return;
    // Match against a rolling tail, not this chunk: a slice boundary can fall
    // inside " -13?", and then no single chunk contains the whole report. The
    // error would go unnoticed, the reporter would never be reinstalled, and
    // the stack viewer would stay dead for the rest of the session.
    this.tail = (this.tail + this.text).slice(-ERROR_TAIL_KEEP);
    if (ERROR_REPORT.test(this.tail)) {
      this.sawError = true;
      this.tail = "";
    }
    if (this.on.onOutput) this.on.onOutput(this.text);
    this.text = "";
  }

  // The data stack, read out of the report block rather than parsed back from
  // printed text. The sequence cell is what says a new snapshot was taken: the
  // hook stays silent while compiling, and without the sequence an unchanged
  // block would be indistinguishable from a fresh identical one.
  checkReport() {
    if (!this.report) return;
    const seq = this.mem[this.report + REPORT_SEQ];
    if (seq === this.lastSeq) return;
    this.lastSeq = seq;
    if (!this.on.onStack) return;

    // base is an ordinary eForth variable, so the image can legitimately hold
    // anything: "37 base !" is not an error in Forth, but Number#toString
    // throws outside 2..36. That exception used to escape pump() and strand
    // running = true, wedging the instance for good. `|| 10` caught only zero.
    const raw = this.mem[this.report + REPORT_BASE];
    const base = raw >= 2 && raw <= 36 ? raw : 10;
    // The block holds at most MAX_ITEMS cells, but it records the true depth, so
    // a deeper stack can say how much of itself is not being shown instead of
    // pretending it is only 32 deep.
    const depth = this.mem[this.report + REPORT_DEPTH] | 0;
    const values = [];
    for (let i = 0; i < Math.min(depth, MAX_ITEMS); i++)
      values.push(this.mem[this.report + REPORT_ITEMS + i] | 0);
    this.on.onStack({
      base,
      depth,
      values,
      items: values.map((v) => formatCell(v, base)),
    });
  }

  // The prelude's last line announces where the two blocks live, which is also
  // the signal that boot is over. Anything printed before it is the prelude's
  // own "ok" chatter and is dropped; anything after it belongs to the user, even
  // if it was typed while the machine was still starting.
  readAddresses(body) {
    if (!body.startsWith(GRAPHICS_TAG)) return;
    const [gfx, rep] = body
      .slice(GRAPHICS_TAG.length)
      .trim()
      .split(/\s+/)
      .map((n) => parseInt(n, 10));
    // eForth addresses bytes over 32-bit cells; the VM is indexed by cell.
    this.graphics = (gfx | 0) >> 2;
    this.report = (rep | 0) >> 2;
    this.gotGraphics = this.graphics > 0 && this.report > 0;
    this.booting = false;
    this.text = "";
  }

  // The graphics block, as a live view of the VM's cells.
  pixels() {
    return this.mem.subarray(this.graphics, this.graphics + GFX_CELLS);
  }
}
