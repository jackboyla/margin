((request) => {
  const reply = (status, fields = {}) => JSON.stringify({ status, ...fields });
  if (window !== top || location.href !== request.url) return reply("changed");
  if (!["http:", "https:"].includes(location.protocol) ||
      !["text/html", "application/xhtml+xml"].includes(document.contentType) || !document.body) return reply("notHTML");

  const key = Symbol.for("com.jackboylan.margin.stickyNotes");
  let view = window[key];
  if (view && view.url !== request.url) { view.dispose(); view = null; }

  function selectorFor(element) {
    const parts = [];
    for (let node = element; node && node !== document.body; node = node.parentElement) {
      if (node.id) {
        const id = "#" + CSS.escape(node.id);
        if (document.querySelectorAll(id).length === 1) { parts.unshift(id); return parts.join(" > "); }
      }
      let index = 1;
      for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
        if (sibling.localName === node.localName) index++;
      }
      parts.unshift(CSS.escape(node.localName) + ":nth-of-type(" + index + ")");
    }
    return ["body", ...parts].join(" > ");
  }

  if (request.action === "locate") {
    const { fractionX, fractionY } = request;
    if (![fractionX, fractionY].every(n => Number.isFinite(n) && n >= 0 && n <= 1)) return reply("unsupported");
    const x = Math.min(innerWidth - 1, fractionX * innerWidth);
    const y = Math.min(innerHeight - 1, fractionY * innerHeight);
    const anchor = { x: x + scrollX, y: y + scrollY };
    const element = document.elementFromPoint(x, y);
    if (element && document.body.contains(element) && element !== document.body) {
      const rect = element.getBoundingClientRect();
      const dx = x - rect.left, dy = y - rect.top;
      const selector = selectorFor(element);
      anchor.element = JSON.stringify(element.matches("img,video,canvas") && rect.width && rect.height
        ? [selector, dx / rect.width, dy / rect.height, "fraction"]
        : [selector, dx + element.scrollLeft, dy + element.scrollTop]);
    }
    return reply("point", { anchor, id: view?.hit(x, y) });
  }
  if (request.action !== "paint" || !Array.isArray(request.notes)) return reply("unsupported");
  const notes = request.notes.filter(({ anchor }) => anchor && anchor.page == null &&
    Number.isFinite(anchor.x) && Number.isFinite(anchor.y));
  if (!notes.length) { view?.dispose(); return reply("owned"); }
  if (!view) view = window[key] = createView();
  view.paint(notes);
  return reply("owned");

  function createView() {
    const url = location.href;
    const host = document.createElement("div");
    const shadow = host.attachShadow({ mode: "closed" });
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`
      :host { all: initial !important; display: block !important; position: fixed !important;
        inset: 0 !important; z-index: 2147483647 !important; pointer-events: none !important;
        overflow: hidden !important; direction: ltr !important; }
      article { position: absolute; left: var(--x); top: var(--y);
        translate: min(0px, calc(100vw - var(--x) - 100%)) min(0px, calc(100vh - var(--y) - 100%));
        box-sizing: border-box; width: max-content; max-width: min(218px, 100vw); max-height: min(9em, 100vh);
        overflow: hidden; padding: 8px 11px; border: 1px solid #d8b85d; border-radius: 4px;
        background: #fff0a5; color: #30291a; box-shadow: 0 2px 6px #30291a38;
        font: 14px/1.4 system-ui, sans-serif; white-space: pre-wrap; overflow-wrap: anywhere;
        user-select: none; pointer-events: none; }
      @media print { :host { display: none !important; } }
    `);
    shadow.adoptedStyleSheets = [sheet];
    let cards = [];
    let frame = 0;

    function layout() {
      if (location.href !== url) { dispose(); return; }
      if (!host.isConnected) document.documentElement.append(host);
      for (const { node, anchor, relative } of cards) {
        let x = anchor.x - scrollX, y = anchor.y - scrollY, target;
        if (relative) {
          const [selector, dx, dy, unit] = relative;
          try { target = document.querySelector(selector); } catch {}
          if (target) {
            const rect = target.getBoundingClientRect();
            x = rect.left + (unit === "fraction" ? dx * rect.width : dx - target.scrollLeft);
            y = rect.top + (unit === "fraction" ? dy * rect.height : dy - target.scrollTop);
          }
        }
        // Hit testing also respects nested scrollport clipping and occluding page headers.
        node.hidden = x < 0 || y < 0 || x >= innerWidth || y >= innerHeight ||
          !!target && !target.contains(document.elementFromPoint(x, y));
        node.style.setProperty("--x", x + "px");
        node.style.setProperty("--y", y + "px");
      }
    }
    function schedule() {
      if (!frame) frame = requestAnimationFrame(() => { frame = 0; layout(); });
    }
    function navigationChanged() { if (location.href !== url) dispose(); }
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { attributes: true, childList: true, characterData: true, subtree: true });
    const resize = new ResizeObserver(schedule);
    resize.observe(document.documentElement);
    resize.observe(document.body);
    window.addEventListener("scroll", schedule, true);
    window.addEventListener("load", schedule, true);
    window.addEventListener("resize", schedule);
    window.navigation?.addEventListener("currententrychange", navigationChanged);
    window.addEventListener("popstate", navigationChanged);
    window.addEventListener("hashchange", navigationChanged);
    function dispose() {
      observer.disconnect();
      resize.disconnect();
      window.removeEventListener("scroll", schedule, true);
      window.removeEventListener("load", schedule, true);
      window.removeEventListener("resize", schedule);
      window.navigation?.removeEventListener("currententrychange", navigationChanged);
      window.removeEventListener("popstate", navigationChanged);
      window.removeEventListener("hashchange", navigationChanged);
      cancelAnimationFrame(frame);
      host.remove();
      delete window[key];
    }
    return {
      url, dispose,
      paint(notes) {
        if (cards.length === notes.length && cards.every(({ id, node, anchor }, index) => {
          const next = notes[index];
          return id === next.id && node.textContent === next.text && anchor.x === next.anchor.x &&
            anchor.y === next.anchor.y && anchor.element === next.anchor.element;
        })) { layout(); return; }
        cards = notes.map(({ id, text, anchor }) => {
          const node = document.createElement("article");
          node.setAttribute("role", "note");
          node.textContent = text;
          let relative;
          if (anchor.element) {
            try {
              const parsed = JSON.parse(anchor.element);
              if (Array.isArray(parsed) && typeof parsed[0] === "string" &&
                  Number.isFinite(parsed[1]) && Number.isFinite(parsed[2])) relative = parsed;
            } catch {}
          }
          return { id, node, anchor, relative };
        });
        shadow.replaceChildren(...cards.map(card => card.node));
        layout();
      },
      hit(x, y) {
        layout();
        return cards.findLast(({ node }) => {
          const rect = node.getBoundingClientRect();
          return !node.hidden && x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
        })?.id;
      }
    };
  }
})(__MARGIN_REQUEST__)
