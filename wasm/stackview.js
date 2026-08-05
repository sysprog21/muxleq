// The data stack, drawn as a stack.
//
// A line of text is a poor way to teach the one thing Forth is about. Following
// Starting Forth, each cell is a box rather than a word in a sentence, and what
// a line did to the stack is reported in the same ( before -- after ) notation
// the book uses for stack effects, computed from the two states rather than
// written by hand.
//
// Boxes run left to right, bottom of the stack to top, which is the order the
// notation itself reads: in ( n1 n2 -- sum ) the rightmost item is the topmost.
// The top is labelled anyway, because that is the thing beginners get wrong.
//
// Click a cell for the other readings of those 32 bits. That is the shortest
// route to understanding why true is -1 here.

const MAX_SHOWN = 24; // a runaway stack should not push the page around

const EMPTY = { base: 10, items: [], values: [] };

export class StackView {
  constructor(el) {
    this.el = el;
    this.el.classList.add("stack-view");
    this.stack = EMPTY;
    this.effect = null;
    this.same = 0;
    this.selected = null;
    this.el.addEventListener("click", (e) => {
      const cell = e.target.closest(".stack-cell");
      if (cell) this.select(Number(cell.dataset.index));
    });
    this.render();
  }

  // stack: {base, items, values} as parsed from the interpreter's report.
  update(stack) {
    const before = this.stack;
    // Cells shared with the previous state, counted from the bottom. Whatever
    // lies past that is what this line consumed and produced, which is exactly
    // the stack effect.
    let same = 0;
    while (
      same < stack.values.length &&
      same < before.values.length &&
      stack.values[same] === before.values[same]
    )
      same++;

    this.same = same;
    this.effect =
      same === before.items.length && same === stack.items.length
        ? null
        : { took: before.items.slice(same), gave: stack.items.slice(same) };
    this.stack = stack;
    if (this.selected !== null && this.selected >= stack.items.length)
      this.selected = null;
    this.render();
  }

  select(index) {
    this.selected = this.selected === index ? null : index;
    this.render();
  }

  // Back to empty, for a machine that has been reset: the old cells are not
  // this machine's and must not linger until the new one first reports.
  clear() {
    this.stack = EMPTY;
    this.effect = null;
    this.same = 0;
    this.selected = null;
    this.render();
  }

  render() {
    const { items, values, base } = this.stack;
    this.el.textContent = "";

    const row = document.createElement("div");
    row.className = "stack-row";
    this.el.appendChild(row);

    if (!items.length) {
      const empty = document.createElement("span");
      empty.className = "stack-empty";
      empty.textContent = "stack empty";
      row.appendChild(empty);
    }

    // Two reasons cells can be missing from the left: this view caps what it
    // draws, and the report block caps what the image records. Both are "below".
    const depth = this.stack.depth ?? items.length;
    const hidden = Math.max(0, items.length - MAX_SHOWN) + (depth - items.length);
    if (hidden) {
      const more = document.createElement("span");
      more.className = "stack-more";
      more.textContent = `${hidden} more below`;
      row.appendChild(more);
    }

    const skipped = Math.max(0, items.length - MAX_SHOWN);
    items.slice(skipped).forEach((text, i) => {
      const index = skipped + i;
      const cell = document.createElement("button");
      cell.type = "button";
      cell.className = "stack-cell";
      cell.dataset.index = index;
      cell.textContent = text;
      if (index >= this.same) cell.classList.add("fresh");
      if (index === items.length - 1) cell.classList.add("top");
      if (index === this.selected) cell.classList.add("selected");
      cell.setAttribute(
        "aria-label",
        `${items.length - index} from the top, value ${text}`,
      );
      row.appendChild(cell);
    });

    const note = document.createElement("span");
    note.className = "stack-note";
    note.textContent = this.caption();
    row.appendChild(note);

    if (this.selected !== null && values[this.selected] !== undefined)
      this.el.appendChild(detail(values[this.selected]));
  }

  // "( 3 4 -- 7 )" for the line that just ran, in Starting Forth's notation,
  // followed by the depth and, when it is not the usual one, the base.
  caption() {
    const parts = [];
    if (this.effect)
      parts.push(
        `( ${this.effect.took.join(" ")} -- ${this.effect.gave.join(" ")} )`,
      );
    parts.push(`depth ${this.stack.depth ?? this.stack.items.length}`);
    if (this.stack.base !== 10) parts.push(`base ${this.stack.base}`);
    return parts.join("   ");
  }
}

// The four readings of one 32-bit cell that a Forth programmer actually wants:
// what it is as a number, what the same bits are unsigned and in hex, and
// whether it is a character. This is where -1 and $FFFFFFFF stop being two
// different things.
function detail(value) {
  const unsigned = value >>> 0;
  const parts = [
    `signed ${value}`,
    `unsigned ${unsigned}`,
    `hex $${unsigned.toString(16).toUpperCase().padStart(8, "0")}`,
  ];
  if (value >= 32 && value < 127)
    parts.push(`char "${String.fromCharCode(value)}"`);
  if (value === 0) parts.push("= false");
  if (value === -1) parts.push("= true, every bit set");

  const box = document.createElement("div");
  box.className = "stack-detail";
  const text = document.createElement("span");
  text.textContent = parts.join("   ");
  const bits = document.createElement("span");
  bits.className = "stack-bits";
  bits.textContent = unsigned
    .toString(2)
    .padStart(32, "0")
    .replace(/(.{8})(?=.)/g, "$1 ");
  box.append(text, bits);
  return box;
}

// The book's inline illustrations are the same shape as the live viewer, so the
// same code draws them from the text already in the element.
export function renderStatic(el) {
  const items = el.textContent.trim().split(/\s+/).filter(Boolean);
  // data-same is how many cells at the bottom the drawn word left alone, so the
  // ones it produced light up the way the live viewer lights up a real change.
  // Without it an illustration is a still life: nothing is marked, which is
  // right for a picture of a stack but wrong for a picture of an effect.
  const same = Number(el.dataset.same ?? items.length);
  const view = new StackView(el);
  view.stack = { base: 10, items, values: items.map(Number) };
  view.same = Number.isFinite(same) ? same : items.length;
  view.render();
  return view;
}
