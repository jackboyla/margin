async function highlightIncrement(original, marks) {
  const { PDFDocument, PDFName, decodeFromBase64, encodeToBase64 } = PDFLib;
  const bytes = decodeFromBase64(original);
  const document = await PDFDocument.load(bytes, {
    parseSpeed: Infinity,
    updateMetadata: false,
    throwOnInvalidObject: true,
  });
  const snapshot = document.takeSnapshot();
  const pages = document.getPages();
  const annotations = new Map();
  for (const { page, bounds, quadPoints } of marks) {
    const target = pages[page];
    let list = annotations.get(page);
    if (!list) {
      // A source PDF may give multiple pages the same indirect annotations array.
      list = target.node.Annots()?.clone() ?? document.context.obj([]);
      target.node.set(PDFName.of('Annots'), list);
      snapshot.markRefForSave(target.ref);
      annotations.set(page, list);
    }
    const mark = document.context.obj({
      Type: 'Annot', Subtype: 'Highlight', Rect: bounds, QuadPoints: quadPoints,
      C: [1, 1, 0], CA: 0.4, F: 4,
    });
    list.push(document.context.register(mark));
  }
  // CoreGraphics can drop an update when a table-based PDF switches to a cross-reference stream,
  // and can reject a stream-based PDF switched to a table. Follow the source's last startxref.
  const offset = snapshot.prevStartXRef;
  const table = bytes[offset] === 120 && bytes[offset + 1] === 114 &&
    bytes[offset + 2] === 101 && bytes[offset + 3] === 102;
  const stream = bytes[offset] >= 48 && bytes[offset] <= 57;
  if (!table && !stream) throw new Error('Unsupported PDF cross-reference section');
  // JavaScriptCore drains promises when control returns to Swift. Keep parsing and writing in this turn.
  const suffix = await document.saveIncremental(snapshot, { objectsPerTick: Infinity, useObjectStreams: stream });
  return encodeToBase64(suffix);
}
