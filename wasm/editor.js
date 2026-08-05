// The interactive editor widget used throughout the tutorial.
//
// Each ".editor" element on the page gets its own eForth: its own image, its
// own dictionary, its own stack. Defining a word in one editor deliberately
// does not leak into the next, so every section of the book starts clean.
//
// Structure of an editor element:
//   <div class="editor" data-size="small" data-canvas data-src="snake">
// data-size   "small" for a short transcript
// data-canvas add a 24x24 pixel display wired to the "graphics" block
// data-src    URL of a .fth file to load and run when the editor starts

import { Forth, loadForthModule, GFX_WIDTH, GFX_HEIGHT } from "./forth.js";
import { StackView, renderStatic } from "./stackview.js";

// Sent for the arrow keys while a program is running. They sit above ASCII so a
// program can tell them from anything typeable.
const ARROWS = {
  ArrowLeft: 0x80,
  ArrowUp: 0x81,
  ArrowRight: 0x82,
  ArrowDown: 0x83,
};

// Pixel value 0 is the background; the rest are picked to stay legible on both
// a light and a dark page.
const PALETTE = [
  "#12141c", "#f2f4f8", "#e5484d", "#46a758", "#3b82f6", "#f5a524",
  "#a855f7", "#22d3ee", "#f472b6", "#84cc16", "#f97316", "#64748b",
  "#0ea5e9", "#dc2626", "#facc15", "#e2e8f0",
];

// Word-at-a-time only works when the words are independent lines of Forth. A
// string, a comment or a definition swallows the rest of its line, so feeding
// those a word at a time would change what the line means. Run them whole.
function steppable(line) {
  const text = line.trim();
  if (!text) return false;
  if (/["(\\]/.test(text)) return false; // ." ... "  ( ... )  \ ...
  // Words that read the NEXT word from the input as their argument. Fed one
  // word per line, the name is already gone by the time the word runs: the
  // tutorial's own "variable total" becomes "variable" (-16, zero-length name)
  // then "total" (-13, undefined). Run these lines whole.
  if (
    /(^|\s)(variable|constant|create|value|to|defer|is|marker|forget|see|char|\[char\]|postpone|'|\['\])(\s|$)/.test(
      text,
    )
  )
    return false;
  return !/(^|\s)[:;\[\]]($|\s)/.test(text); // definitions and state switches
}

class EditorView {
  constructor(el, wasmModule) {
    this.el = el;
    // Handy from the console, and it lets the browser test assert on the
    // machine an editor is actually holding rather than infer it from timing.
    el.__editor = this;
    this.stepDelay = 550;
    this.history = [""];
    this.historyAt = null;
    this.busy = false;
    this.stepping = false; // a stepped line is mid-flight (spans its pauses)
    this.watching = false;
    this.forth = null;

    el.innerHTML = `
      <div class="stack-viewer" title="the data stack, bottom to top"></div>
      <div class="editor-body">
        <div class="transcript"><div class="lines"></div></div>
        ${el.hasAttribute("data-canvas")
          ? `<canvas class="canvas" width="240" height="240"></canvas>`
          : ""}
      </div>
      <textarea class="input" rows="1" spellcheck="false"
                aria-label="Forth input"></textarea>
      <div class="editor-tools">
        <label class="step-toggle" title="run a line one word at a time">
          <input type="checkbox" class="step"> step
        </label>
        <button class="reset" type="button" title="restart this eForth">reset</button>
      </div>`;

    this.stack = new StackView(el.querySelector(".stack-viewer"));
    this.stepBox = el.querySelector(".step");
    this.transcript = el.querySelector(".transcript");
    this.lines = el.querySelector(".lines");
    this.input = el.querySelector(".input");
    this.canvas = el.querySelector(".canvas");
    this.ctx = this.canvas ? this.canvas.getContext("2d") : null;
    if (el.dataset.size === "small") el.classList.add("small");
    if (this.canvas) el.classList.add("has-canvas");

    this.wasmModule = wasmModule;
    this.start();

    this.input.addEventListener("keydown", (e) => this.onKey(e));
    el.querySelector(".reset").addEventListener("click", () => {
      this.lines.textContent = "";
      this.start();
      this.input.focus();
    });
    el.addEventListener("click", (e) => {
      if (!e.target.closest(".lines, .reset")) this.input.focus();
    });
  }

  start() {
    this.forth?.stop();
    this.stack.clear();
    if (this.ctx) {
      this.ctx.fillStyle = PALETTE[0];
      this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    }
    this.forth = new Forth(this.wasmModule, {
      onOutput: (t) => this.print(t),
      onStack: (s) => this.stack.update(s),
      onIdle: () => this.setBusy(false),
    });
    this.shadow = null;
    this.paint(true);
    // Booting takes a moment. Show it as busy so nothing is typed into a
    // machine that is still reading its own start-up code.
    this.setBusy(this.forth.booting);

    const src = this.el.dataset.src;
    if (src) {
      // Tie the result to the machine it was started for. A reset can land while
      // the fetch is in flight, and a late callback would otherwise compile into
      // -- or report a failure against -- the session that replaced it.
      const forth = this.forth;
      fetch(new URL(src, document.baseURI))
        .then((r) => (r.ok ? r.text() : Promise.reject(new Error(`HTTP ${r.status}`))))
        .then((text) => this.forth === forth && this.load(src, text, forth))
        .catch((err) => {
          if (this.forth !== forth) return;
          this.print(
            `could not load ${src}: ${err}\n` +
              `Nothing from that file is defined, so the words below will not ` +
              `resolve. The page has to be served over http rather than opened ` +
              `as a file; press reset once it is.\n`,
          );
        });
    }
  }

  // Compile a whole file without echoing it line by line: the source is on the
  // page already, and 150 echoed lines would bury the part worth reading.
  // A 404 is rejected before this: an error page compiled as Forth would report
  // a screenful of undefined words rather than the one thing that went wrong.
  load(name, text, forth) {
    this.echo(`\\ loaded ${name}`);
    for (const line of text.split("\n")) {
      if (this.forth !== forth) return;
      this.setBusy(true);
      forth.submit(line);
    }
  }

  setBusy(busy) {
    this.busy = busy;
    this.input.classList.toggle("busy", busy);
    this.input.placeholder = busy ? "running -- keys go to your program" : "";
    this.paint(false);
    if (busy) this.watchCanvas();
  }

  // While a program runs it writes pixels straight into VM memory, so the
  // canvas is refreshed from the frame loop rather than from any event.
  watchCanvas() {
    if (!this.canvas || this.watching) return;
    this.watching = true;
    const tick = () => {
      this.paint(false);
      if (this.busy) requestAnimationFrame(tick);
      else this.watching = false;
    };
    requestAnimationFrame(tick);
  }

  // Called from the idle handler too, which can fire from inside the Forth
  // constructor, before this.forth has been assigned. Waiting for the graphics
  // address as well matters: until the prelude reports it there is no block to
  // read, and cell 0 is the image's own code, which paints as noise.
  paint(force) {
    if (!this.canvas || !this.forth || !this.forth.gotGraphics) return;
    const ctx = this.ctx;
    const px = this.canvas.width / GFX_WIDTH;
    const cells = this.forth.pixels();
    if (force || !this.shadow) {
      this.shadow = new Int32Array(GFX_WIDTH * GFX_HEIGHT).fill(-1);
    }
    for (let i = 0; i < cells.length; i++) {
      const v = cells[i] & 0x0f;
      if (v === this.shadow[i]) continue;
      this.shadow[i] = v;
      ctx.fillStyle = PALETTE[v];
      ctx.fillRect((i % GFX_WIDTH) * px, Math.floor(i / GFX_WIDTH) * px, px, px);
    }
  }

  print(text) {
    const target = this.lines.lastElementChild || this.lines;
    // A terminal echoes the Enter you pressed, so a program's first output
    // starts below what you typed. Echoing the line without that break glues
    // them together: "-3 sign" plus ." negative" reads as one word,
    // "-3 signnegative". Only the first chunk after an echo needs it; output
    // that continues output must flow on unbroken.
    const after = target.lastElementChild;
    const span = document.createElement("span");
    span.className = "output";
    span.textContent =
      after && after.classList.contains("code") ? "\n" + text : text;
    target.appendChild(span);
    this.scroll();
  }

  echo(code) {
    const p = document.createElement("p");
    const span = document.createElement("span");
    span.className = "code";
    span.textContent = code;
    p.appendChild(span);
    this.lines.appendChild(p);
    this.scroll();
  }

  scroll() {
    this.transcript.scrollTop = this.transcript.scrollHeight;
  }

  // Async because a stepped line takes real time: without awaiting it, several
  // stepped lines from one paste would interleave their words into a single
  // input queue, and a non-steppable line would jump the queue entirely.
  async run(code) {
    for (const line of code.split("\n")) {
      this.historyAt = null;
      if (line.trim()) this.history.push(line);
      if (this.stepBox.checked && steppable(line)) {
        await this.step(line);
        continue;
      }
      this.echo(line);
      this.setBusy(true);
      this.forth.submit(line);
    }
  }

  // Starting Forth teaches the stack by drawing it after each word of "3 4 +"
  // in turn. Step mode does that with the reader's own line: the words are fed
  // one at a time, with a pause, so the stack viewer walks through the same
  // states instead of jumping to the answer.
  async step(line) {
    const words = line.trim().split(/\s+/);
    // Reset is a click, not a keystroke, so it is not blocked while busy and can
    // land between two words. Hold the machine this line belongs to and stop if
    // it is replaced, rather than feeding the rest of the line to its successor.
    const forth = this.forth;
    // busy alone cannot express "this line is still in flight": each submitted
    // word runs to rest, which fires onIdle and clears busy, so the input would
    // be live for the whole pause and a line typed then interleaves word by word
    // with this one. This flag spans the pauses; the finally makes sure it is
    // cleared even if a reset or an exception cuts the loop short.
    this.stepping = true;
    this.setBusy(true);
    try {
      for (const word of words) {
        if (this.forth !== forth) return;
        this.echo(word);
        forth.submit(word);
        // The viewer updates when the interpreter reports; the pause is purely
        // so a human can see one state before the next replaces it.
        await new Promise((done) => setTimeout(done, this.stepDelay));
        if (!this.stepBox.checked) break; // unticked mid-run: stop pacing
      }
    } finally {
      this.stepping = false;
    }
    if (this.forth === forth) this.setBusy(false);
  }

  recall(delta) {
    const n = this.history.length;
    if (this.historyAt === null) this.historyAt = n;
    this.historyAt = (this.historyAt + delta + n + 1) % (n + 1);
    this.input.value = this.historyAt === n ? "" : this.history[this.historyAt];
  }

  onKey(e) {
    if (this.forth.booting) {
      e.preventDefault(); // the prelude is still being read; do not interleave
      return;
    }
    // A running program owns the keyboard: everything typed becomes input for
    // it, which is what makes the game in the last chapter playable.
    if (this.busy || this.stepping) {
      const arrow = ARROWS[e.key];
      if (arrow) this.forth.send(String.fromCharCode(arrow));
      else if (e.key.length === 1) this.forth.send(e.key);
      else if (e.key === "Enter") this.forth.send("\n");
      else return;
      e.preventDefault();
      this.forth.pump();
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      const code = this.input.value;
      this.input.value = "";
      this.run(code);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      this.recall(-1);
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      this.recall(1);
    }
  }
}

// The book's inline stack pictures are drawn by the same code as the live
// viewer, so an illustration and the real thing cannot look like two different
// notations. These need no VM, so they are done before the module loads.
for (const el of document.querySelectorAll(".stack")) renderStatic(el);

loadForthModule(new URL("muxleq.wasm", import.meta.url)).then(
  (wasmModule) => {
    for (const el of document.querySelectorAll(".editor"))
      new EditorView(el, wasmModule);
  },
  (err) => {
    for (const el of document.querySelectorAll(".editor"))
      el.textContent = `Could not load the eForth image: ${err}. The page must be
        served over http, not opened as a file.`;
  },
);
