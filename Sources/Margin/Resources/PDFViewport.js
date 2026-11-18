((request) => {
  const reply = status => JSON.stringify({ status });
  if (location.href !== request.url || window !== top) return reply("changed");
  if (document.contentType !== "application/pdf" || location.origin !== "https://arxiv.org" ||
      !location.pathname.startsWith("/pdf/") || !document.body) return reply("notPDF");

  const key = Symbol.for("com.jackboylan.margin.pdfViewport");
  const state = window[key] ??= { active: null, pending: null };
  const token = request.token;
  if (typeof token !== "string" || !token) return reply("failed");

  function remove(view) {
    if (!view) return;
    clearTimeout(view.timeout);
    view.frame.remove();
    URL.revokeObjectURL(view.blob);
  }

  function status() {
    if (state.pending?.token === token) return state.pending.status;
    if (!state.active) return "original";
    return state.active.token === token ? "active" : "different";
  }

  if (request.action === "status") return reply(status());
  if (request.action === "cancel") {
    if (state.pending?.token === token) {
      remove(state.pending);
      state.pending = null;
    }
    return reply(status());
  }
  if (request.action === "commit") {
    const next = state.pending;
    if (state.active?.token === token && !next) return reply("active");
    if (next?.token !== token || next.status !== "ready" || !next.frame.isConnected) return reply("failed");
    clearTimeout(next.timeout);
    next.frame.title = "PDF with saved highlights";
    next.frame.removeAttribute("tabindex");
    next.frame.style.opacity = "1";
    next.frame.style.pointerEvents = "auto";
    const previous = state.active;
    (previous?.frame ?? document.body).inert = true;
    state.active = next;
    state.pending = null;
    requestAnimationFrame(() => requestAnimationFrame(() => remove(previous)));
    return reply("active");
  }
  if (request.action !== "stage") return reply("failed");
  if (state.active?.token === token) return reply("active");
  const { page, zoom, left, top: offsetTop } = request;
  if (!Number.isSafeInteger(page) || page < 1 || !(Number.isFinite(zoom) && zoom > 0) ||
      !Number.isFinite(left) || !Number.isFinite(offsetTop)) return reply("failed");

  const fragment = '#page=' + page + '&zoom=' + zoom + ',' + left + ',' + offsetTop;
  const previous = state.pending;
  if (previous?.token === token && previous.fragment === fragment) return reply(previous.status);
  let blob;
  try {
    if (typeof request.append === "string" && typeof request.sourceID === "string") {
      // Every edit appends an independent annotation update to the same unmarked paper.
      if (state.source?.id !== request.sourceID) {
        if (!request.sourceBytes) return reply("sourceNeeded");
        state.source = { id: request.sourceID, pdf: new Blob([Uint8Array.fromBase64(request.sourceBytes)]) };
      }
      blob = URL.createObjectURL(new Blob([state.source.pdf, Uint8Array.fromBase64(request.append)],
        { type: "application/pdf" }));
    } else if (previous?.token === token && previous.status === "ready") {
      blob = previous.blob;
    } else {
      return reply("failed");
    }
  } catch {
    return reply("failed");
  }

  if (previous?.blob === blob) {
    clearTimeout(previous.timeout);
    previous.frame.remove();
  } else {
    remove(previous);
  }
  const frame = document.createElement("iframe");
  frame.title = "Margin PDF staging";
  frame.tabIndex = -1;
  // Chrome can skip painting a fully transparent PDF. Give the replacement a composited layer before revealing it.
  frame.style.cssText = "position:fixed;inset:0;width:100%;height:100%;border:0;z-index:2147483647;will-change:opacity;opacity:0.001;pointer-events:none";
  const candidate = { token, blob, frame, fragment, status: "pending" };
  state.pending = candidate;
  function fail() {
    if (state.pending !== candidate) return;
    candidate.status = "failed";
    remove(candidate);
  }
  candidate.timeout = setTimeout(fail, 30000);
  frame.addEventListener("error", fail, { once: true });
  frame.addEventListener("load", () => {
    if (state.pending !== candidate || candidate.status !== "pending") return;
    try {
      if (frame.contentDocument?.contentType === "application/pdf" &&
          frame.contentDocument.URL.split("#")[0] === blob) {
        // The wrapper loads before Chrome draws the paper tiles at the requested zoom.
        setTimeout(() => {
          if (state.pending === candidate && candidate.status === "pending") candidate.status = "ready";
        }, 350);
        return;
      }
    } catch {}
    fail();
  }, { once: true });
  frame.src = blob + fragment;
  document.documentElement.append(frame);
  return reply("pending");
})(__MARGIN_REQUEST__);
