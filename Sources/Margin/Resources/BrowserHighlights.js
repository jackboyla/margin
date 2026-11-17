((request) => {
  const key = Symbol.for("com.jackboylan.margin.highlights");
  const name = "margin-saved-passages";
  const version = 1;
  const reply = (status, matched = 0) => JSON.stringify({ status, matched });
  if (new URL(request.url).href !== location.href) return reply("changed");
  if (!["text/html", "application/xhtml+xml"].includes(document.contentType) ||
      !document.body || !globalThis.Highlight || !CSS.highlights) return reply("unsupported");
  const previous = window[key];
  if (previous?.version === version) return previous.update(request);
  previous?.dispose?.();
  if (!request.quotes.length) return reply("owned");

  const normalizeText = (value) => value.normalize("NFKC").replace(/\u00ad/g, "")
    .replace(/[\u2010\u2011]/g, "-").replace(/[“”]/g, '"').replace(/[‘’]/g, "'")
    .replace(/\s+/gu, " ").toLowerCase();
  const normalize = value => normalizeText(value).trim();
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const highlight = new Highlight();
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`::highlight(${name}) { background-color: rgba(255, 210, 45, 0.38); }`);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  CSS.highlights.set(name, highlight);
  let url = location.href;
  let quotes = [];
  let signature = "";
  let anchors = [];
  let scheduled = 0;
  let dirty = true;

  // Normalize complete text runs so combining characters can cross inline markup.
  function indexText() {
    const pieces = [], spans = [];
    let length = 0, run = null, lastWasSpace = true;
    const blocks = new WeakMap();
    function flush() {
      if (!run) return;
      const normalized = normalizeText(run.raw);
      const skipped = lastWasSpace && normalized.startsWith(" ") ? 1 : 0;
      const value = normalized.slice(skipped);
      if (value) {
        spans.push({ ...run, start: length, end: length + value.length, skipped, normalizedLength: normalized.length });
        pieces.push(value); length += value.length; lastWasSpace = value.endsWith(" ");
      }
      run = null;
    }
    function blockFor(element) {
      if (!element || element === document.body) return document.body;
      if (blocks.has(element)) return blocks.get(element);
      const display = getComputedStyle(element).display;
      const block = display === "contents" || display.startsWith("inline") ? blockFor(element.parentElement) : element;
      blocks.set(element, block);
      return block;
    }
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.matches("script,style,noscript,textarea,input,select,template,[hidden]")) return NodeFilter.FILTER_REJECT;
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden") return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.tagName === "BR" && run) run.raw += "\n";
        continue;
      }
      const block = blockFor(node.parentElement);
      if (run?.block !== block) {
        flush();
        if (!lastWasSpace) { pieces.push(" "); length++; lastWasSpace = true; }
        run = { block, raw: "", nodes: [] };
      }
      run.nodes.push({ node, start: run.raw.length, end: run.raw.length + node.length });
      run.raw += node.data;
    }
    flush();
    return { text: pieces.join(""), spans };
  }

  function offset(span, units, fromStart) {
    const raw = span.raw;
    if (raw.length === span.normalizedLength && /^[\x00-\x7f]*$/.test(raw)) return units;
    const boundaries = [...segmenter.segment(raw)].map(part => part.index).concat(raw.length);
    const omitted = fromStart ? units : span.normalizedLength - units;
    let low = 0, high = boundaries.length - 1;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      const at = boundaries[fromStart ? middle : boundaries.length - 1 - middle];
      const outside = fromStart ? raw.slice(0, at) : raw.slice(at);
      if (normalizeText(outside).length <= omitted) low = middle;
      else high = middle - 1;
    }
    return boundaries[fromStart ? low : boundaries.length - 1 - low];
  }

  function paint() {
    if (scheduled) clearTimeout(scheduled);
    scheduled = 0;
    if (location.href !== url) { highlight.clear(); anchors = []; return; }
    if (!quotes.length) { highlight.clear(); anchors = []; return; }
    if (!dirty) return;
    dirty = false;
    const index = indexText();
    const next = [];
    for (const quote of quotes) {
      const start = index.text.indexOf(quote);
      if (start < 0 || index.text.indexOf(quote, start + 1) !== -1) continue;
      const end = start + quote.length;
      const first = index.spans.find(span => span.start <= start && start < span.end);
      const last = index.spans.find(span => span.start < end && end <= span.end);
      if (!first || !last) continue;
      const from = offset(first, start - first.start + first.skipped, true);
      const to = offset(last, end - last.start + last.skipped, false);
      const startNode = first.nodes.find(item => item.start <= from && from < item.end);
      const endNode = last.nodes.find(item => item.start < to && to <= item.end);
      if (!startNode || !endNode) continue;
      const saved = anchors.find(item => item.quote === quote &&
        item.range.startContainer === startNode.node && item.range.startOffset === from - startNode.start &&
        item.range.endContainer === endNode.node && item.range.endOffset === to - endNode.start);
      const range = saved?.range ?? document.createRange();
      if (!saved) {
        range.setStart(startNode.node, from - startNode.start);
        range.setEnd(endNode.node, to - endNode.start);
      }
      next.push({ range, quote });
    }
    const retained = new Set(next.map(item => item.range));
    for (const range of highlight) if (!retained.has(range)) highlight.delete(range);
    for (const range of retained) if (!highlight.has(range)) highlight.add(range);
    anchors = next;
  }

  function schedule() {
    dirty = true;
    if (!scheduled) scheduled = setTimeout(paint, 80);
  }
  const observer = new MutationObserver(schedule);
  observer.observe(document.documentElement, {
    childList: true, characterData: true, subtree: true,
    attributes: true, attributeFilter: ["hidden", "class", "style"]
  });
  window.navigation?.addEventListener("currententrychange", schedule);
  window.addEventListener("popstate", schedule);
  window.addEventListener("hashchange", schedule);
  window.addEventListener("pageshow", schedule);

  const state = {
    version,
    update(next) {
      if (new URL(next.url).href !== location.href) return reply("changed");
      const nextQuotes = [...new Set(next.quotes.map(normalize).filter(Boolean))];
      if (!nextQuotes.length) { state.dispose(); return reply("owned"); }
      const nextSignature = JSON.stringify(nextQuotes);
      if (url !== location.href || signature !== nextSignature) {
        url = location.href;
        quotes = nextQuotes;
        signature = nextSignature;
        dirty = true;
      }
      paint();
      return reply("owned", anchors.length);
    },
    dispose() {
      observer.disconnect();
      if (scheduled) clearTimeout(scheduled);
      window.navigation?.removeEventListener("currententrychange", schedule);
      window.removeEventListener("popstate", schedule);
      window.removeEventListener("hashchange", schedule);
      window.removeEventListener("pageshow", schedule);
      if (CSS.highlights.get(name) === highlight) CSS.highlights.delete(name);
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter(item => item !== sheet);
      delete window[key];
    }
  };
  window[key] = state;
  return state.update(request);
})(__MARGIN_REQUEST__)
