((request) => {
  const key = Symbol.for("com.jackboylan.margin.highlights");
  const name = "margin-saved-passages";
  const version = 3;
  const reply = (status, matched = 0) => JSON.stringify({ status, matched });
  if (new URL(request.url).href !== location.href) return reply("changed");
  if (!["text/html", "application/xhtml+xml"].includes(document.contentType) ||
      !document.body || !globalThis.Highlight || !CSS.highlights) return reply("unsupported");
  const normalizeText = (value) => value.normalize("NFKC").replace(/\u00ad/g, "")
    .replace(/[\u2010\u2011]/g, "-").replace(/[“”]/g, '"').replace(/[‘’]/g, "'")
    .replace(/\s+/gu, " ").toUpperCase();
  const normalize = value => normalizeText(value).trim();
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  if (request.action === "anchor") return captureAnchor();
  const previous = window[key];
  if (previous?.version === version) return previous.update(request);
  previous?.dispose?.();
  if (!(request.passages ?? request.quotes)?.length) return reply("owned");

  const highlight = new Highlight();
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`::highlight(${name}) { background-color: rgba(255, 210, 45, 0.38); }`);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  CSS.highlights.set(name, highlight);
  let url = location.href;
  let passages = [];
  let anchors = [];
  let scheduled = 0;

  // Normalize complete text runs so combining characters can cross inline markup.
  function indexText(root) {
    const pieces = [], spans = [];
    let length = 0, run = null, lastWasSpace = true, group = 0;
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
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.matches("script,style,noscript,textarea,input,select,template")) return NodeFilter.FILTER_REJECT;
          const style = getComputedStyle(node);
          if (style.display === "none") return NodeFilter.FILTER_REJECT;
        } else {
          let box = node.parentElement;
          if (getComputedStyle(box).visibility !== "visible") return NodeFilter.FILTER_REJECT;
          while (box && getComputedStyle(box).display === "contents") box = box.parentElement;
          if (!box?.checkVisibility({ opacityProperty: true })) return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.tagName === "BR" && run) run.raw += "\n";
        continue;
      }
      // Browser selections skip user-select:none text, including GitHub blame gutters.
      if (getComputedStyle(node.parentElement).userSelect === "none") { group++; continue; }
      const block = blockFor(node.parentElement);
      if (run?.block !== block || run.group !== group) {
        const newBlock = run?.block !== block;
        flush();
        if (newBlock && !lastWasSpace) { pieces.push(" "); length++; lastWasSpace = true; }
        run = { block, group, raw: "", nodes: [] };
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
    const at = boundaries[fromStart ? low : boundaries.length - 1 - low];
    const outside = fromStart ? raw.slice(0, at) : raw.slice(at);
    return normalizeText(outside).length === omitted ? at : null;
  }

  function releaseSections() {
    const result = new Map();
    if (location.hostname !== "github.com") return result;
    const route = location.pathname.match(/^(\/[^/]+\/[^/]+\/releases)(?:\/tag\/(.+))?\/?$/);
    if (!route) return result;
    if (route[2]) {
      result.set(location.origin + location.pathname.replace(/\/$/, ""), document.body);
    } else {
      for (const section of document.querySelectorAll("section[id^='release-']")) {
        const tag = section.id.slice("release-".length);
        const prefix = route[1] + "/tag/";
        const link = [...section.querySelectorAll('a[href]')].find(a => {
          if (a.origin !== location.origin || !a.pathname.startsWith(prefix)) return false;
          try { return decodeURIComponent(a.pathname.slice(prefix.length)) === tag; } catch { return false; }
        });
        if (link) result.set(link.origin + link.pathname, section);
      }
    }
    return result;
  }

  function bounds(index, start, end) {
    const first = index.spans.find(span => span.start <= start && start < span.end);
    const last = index.spans.find(span => span.start < end && end <= span.end);
    if (!first || !last) return null;
    const from = offset(first, start - first.start + first.skipped, true);
    const to = offset(last, end - last.start + last.skipped, false);
    if (from === null || to === null) return null;
    const startNode = first.nodes.find(item => item.start <= from && from < item.end);
    const endNode = last.nodes.find(item => item.start < to && to <= item.end);
    if (!startNode || !endNode) return null;
    return { first, last, startNode, endNode, from, to };
  }

  function captureAnchor() {
    const sel = window.getSelection();
    const quote = normalize(request.quote);
    if (!quote || sel?.rangeCount !== 1 || normalize(sel.toString()) !== quote) return reply("unsupported");
    const range = sel.getRangeAt(0);
    for (const [releaseURL, root] of releaseSections()) {
      if (!root.contains(range.commonAncestorContainer)) continue;
      // Release notes have the same body in list and detail views, with different controls around it.
      const container = range.commonAncestorContainer;
      const element = container.nodeType === Node.ELEMENT_NODE ? container : container.parentElement;
      const prose = element?.closest(".markdown-body");
      const index = indexText(prose && root.contains(prose) ? prose : root);
      for (let i = index.text.indexOf(quote); i >= 0; i = index.text.indexOf(quote, i + 1)) {
        const end = i + quote.length;
        const b = bounds(index, i, end);
        if (!b || range.comparePoint(b.startNode.node, b.from - b.startNode.start) !== 0 ||
            range.comparePoint(b.endNode.node, b.to - b.endNode.start) !== 0) continue;
        return JSON.stringify({ status: "anchored", releaseURL,
          prefix: index.text.slice(Math.max(0, i - 96), i).replace(/^[\uDC00-\uDFFF]/, ""),
          suffix: index.text.slice(end, end + 96).replace(/[\uD800-\uDBFF]$/, "") });
      }
    }
    return reply("unsupported");
  }

  function match(index, { quote, prefix, suffix }) {
    const text = index.text;
    const first = text.indexOf(quote);
    if (first < 0) return -1;
    if (!prefix && !suffix) return text.indexOf(quote, first + 1) < 0 ? first : -1;
    let found = -1;
    for (let i = first; i >= 0; i = text.indexOf(quote, i + 1)) {
      if (prefix && !text.endsWith(prefix, i) || suffix && !text.startsWith(suffix, i + quote.length)) continue;
      if (found >= 0) return -1;
      found = i;
    }
    return found;
  }

  function paint() {
    if (scheduled) clearTimeout(scheduled);
    scheduled = 0;
    if (location.href !== url || !passages.length) { highlight.clear(); anchors = []; return; }
    const sections = passages.some(p => p.releaseURL) ? releaseSections() : null;
    const indexes = new Map();
    const next = [];
    for (const passage of passages) {
      const { quote, releaseURL } = passage;
      const root = releaseURL ? sections.get(releaseURL) : document.body;
      if (!root) continue;
      if (!indexes.has(root)) indexes.set(root, indexText(root));
      const index = indexes.get(root);
      const start = match(index, passage);
      if (start < 0) continue;
      const b = bounds(index, start, start + quote.length);
      if (!b) continue;
      const { first, last, startNode, endNode, from, to } = b;
      // Split around omitted text so the custom highlight also skips its glyphs.
      let head = startNode.node, headOffset = from - startNode.start;
      function addRange(tail, tailOffset) {
        const saved = anchors.find(item => item.quote === quote &&
          item.range.startContainer === head && item.range.startOffset === headOffset &&
          item.range.endContainer === tail && item.range.endOffset === tailOffset);
        const range = saved?.range ?? document.createRange();
        if (!saved) {
          range.setStart(head, headOffset);
          range.setEnd(tail, tailOffset);
        }
        next.push({ range, quote, passage });
      }
      if (first.group !== last.group) {
        let previous = first;
        for (const span of index.spans) {
          if (span.start <= first.start) continue;
          if (span.start > last.start) break;
          if (span.group !== previous.group) {
            const tail = previous.nodes.at(-1).node;
            addRange(tail, tail.length);
            head = span.nodes[0].node;
            headOffset = 0;
          }
          previous = span;
        }
      }
      addRange(endNode.node, to - endNode.start);
    }
    const retained = new Set(next.map(item => item.range));
    for (const range of highlight) if (!retained.has(range)) highlight.delete(range);
    for (const range of retained) if (!highlight.has(range)) highlight.add(range);
    anchors = next;
  }

  function schedule() {
    if (!scheduled) scheduled = setTimeout(paint, 80);
  }
  const observer = new MutationObserver(schedule);
  observer.observe(document.documentElement, {
    childList: true, characterData: true, subtree: true,
    attributes: true
  });
  window.navigation?.addEventListener("currententrychange", schedule);
  window.addEventListener("popstate", schedule);
  window.addEventListener("hashchange", schedule);
  window.addEventListener("pageshow", schedule);
  window.addEventListener("resize", schedule);

  const state = {
    version,
    update(next) {
      if (new URL(next.url).href !== location.href) return reply("changed");
      const items = next.passages ?? next.quotes.map(quote => ({ quote }));
      passages = items.map(p => ({ ...p, quote: normalize(p.quote) })).filter(p => p.quote);
      if (!passages.length) { state.dispose(); return reply("owned"); }
      url = location.href;
      // Stylesheet rules can change visibility without a DOM mutation.
      paint();
      return reply("owned", new Set(anchors.map(item => item.passage)).size);
    },
    dispose() {
      observer.disconnect();
      if (scheduled) clearTimeout(scheduled);
      window.navigation?.removeEventListener("currententrychange", schedule);
      window.removeEventListener("popstate", schedule);
      window.removeEventListener("hashchange", schedule);
      window.removeEventListener("pageshow", schedule);
      window.removeEventListener("resize", schedule);
      if (CSS.highlights.get(name) === highlight) CSS.highlights.delete(name);
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter(item => item !== sheet);
      delete window[key];
    }
  };
  window[key] = state;
  return state.update(request);
})(__MARGIN_REQUEST__)
