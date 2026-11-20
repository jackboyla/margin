import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { chromium } from 'playwright';

const source = await readFile(new URL('../Sources/Margin/Resources/BrowserHighlights.js', import.meta.url), 'utf8');
const url = 'https://margin.test/article';
const quote = 'selected words that wrap across the next line';
const paragraph = `Leave this prefix alone. These ${quote} belong to the saved passage. Leave this ending alone.`;
const fixture = `<style>body{margin:20px;font:18px/1.5 sans-serif}p{width:310px}.spacer{height:1200px}#pane{height:180px;overflow:auto;border:1px solid}#inner{height:800px}</style>
<p id="passage">${paragraph.replace('selected words', '<strong>selected words</strong>')}</p>
<p>Emoji 🙂 and efﬁcient café words stay intact.</p><div id="pane"><p id="nested">Nested scrolling keeps this saved phrase attached.</p><div id="inner"></div></div><div class="spacer"></div>`;
const install = async (page, quotes, target = url) => JSON.parse(await page.evaluate(source.replace('__MARGIN_REQUEST__', () => JSON.stringify({ url: target, quotes }))));
const settle = page => page.evaluate(() => new Promise(resolve => setTimeout(() => requestAnimationFrame(resolve), 120)));

async function setup(t) {
  const browser = await chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage({ viewport: { width: 600, height: 500 } });
  await page.route('https://margin.test/**', route => route.fulfill({ contentType: 'text/html; charset=utf-8', body: fixture }));
  await page.goto(url);
  return page;
}

// These tests run the shipped script in Chromium, including its real DOM ranges and compositor-owned highlights.
test('exact ranges remain attached through clicks, scrolling, reflow and DOM replacement', async t => {
  const page = await setup(t);
  assert.deepEqual(await install(page, [quote, 'efficient café']), { status: 'owned', matched: 2 });
  const baseline = await page.evaluate(() => {
    window.testHighlight = CSS.highlights.get('margin-saved-passages');
    window.testRanges = [...testHighlight];
    return { text: testRanges.map(r => r.toString()), y: testRanges[0].getBoundingClientRect().y, lines: testRanges[0].getClientRects().length, height: testRanges[0].getBoundingClientRect().height };
  });
  assert.deepEqual(baseline.text, [quote, 'efﬁcient café']);
  assert.ok(baseline.lines > 1);
  await page.mouse.move(480, 200);
  await page.mouse.wheel(0, 70);
  await page.waitForFunction(() => scrollY > 0);
  await page.mouse.click(480, 200);
  await settle(page);
  assert.equal(await page.evaluate(y => {
    const h = CSS.highlights.get('margin-saved-passages');
    return h === testHighlight && [...h].every((r, i) => r === testRanges[i]) &&
      Math.abs(testRanges[0].getBoundingClientRect().y + scrollY - y) < 0.1;
  }, baseline.y), true);
  assert.equal((await install(page, [quote, 'efficient café'])).matched, 2);
  assert.equal(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')][0] === testRanges[0]), true);
  await page.evaluate(() => document.querySelector('#passage').style.width = '190px');
  await settle(page);
  assert.ok(await page.evaluate(height => testRanges[0].getBoundingClientRect().height > height, baseline.height));
  await page.evaluate(() => { const p = document.querySelector('#passage'); p.innerHTML = p.innerHTML; });
  await settle(page);
  assert.deepEqual(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')].map(r => r.toString()).sort()), [quote, 'efﬁcient café'].sort());

  assert.equal((await install(page, ['saved phrase attached'])).matched, 1);
  await page.locator('#pane').scrollIntoViewIfNeeded();
  const before = await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')][0].getBoundingClientRect().y);
  await page.locator('#pane').hover();
  await page.mouse.wheel(0, 25);
  await page.waitForFunction(() => document.querySelector('#pane').scrollTop > 0);
  await settle(page);
  assert.equal(await page.evaluate(y => {
    const range = [...CSS.highlights.get('margin-saved-passages')][0];
    return Math.abs(range.getBoundingClientRect().y + document.querySelector('#pane').scrollTop - y) < 0.1;
  }, before), true);
});

test('navigation, reload, deletion, ambiguous quotes and quoted code stay conservative', async t => {
  const page = await setup(t);
  assert.equal((await install(page, [quote])).matched, 1);
  assert.equal((await install(page, ['another phrase'], 'https://margin.test/other')).status, 'changed');
  assert.equal(await page.evaluate(() => CSS.highlights.get('margin-saved-passages').size), 1);
  await page.evaluate(() => history.pushState({}, '', '/other'));
  await settle(page);
  assert.equal(await page.evaluate(() => (CSS.highlights.get('margin-saved-passages')?.size ?? 0)), 0);
  assert.equal((await install(page, [quote])).status, 'changed');
  await page.goto(url);
  assert.equal((await install(page, [quote])).matched, 1);
  assert.equal((await install(page, [])).matched, 0);
  assert.equal(await page.evaluate(() => (CSS.highlights.get('margin-saved-passages')?.size ?? 0)), 0);
  await page.evaluate(() => {
    const duplicate = document.querySelector('#passage').cloneNode(true);
    duplicate.removeAttribute('id'); document.body.append(duplicate);
  });
  assert.equal((await install(page, [quote])).matched, 0);
  const literal = 'Literal "); window.unwanted = true; (" is only quoted text.';
  await page.evaluate(value => { const p = document.createElement('p'); p.textContent = value; document.body.prepend(p); }, literal);
  assert.equal((await install(page, [literal])).matched, 1);
  assert.equal(await page.evaluate(() => window.unwanted), undefined);
  assert.equal((await install(page, [])).matched, 0);
});


test('live changes keep exact visible text and remove stale or ambiguous ranges', async t => {
  const page = await setup(t);
  await page.evaluate(() => {
    document.body.innerHTML = '<p id="joined">a<span aria-hidden="true">WRONG</span>b</p>' +
      '<p>caf<span>e</span>́ noir</p><p>Ο<span>Σ</span></p><p>Cost $$ per item</p>' +
      '<p id="hidden" hidden>A passage revealed later</p><p id="break">lead<br>finish</p><p id="clock">0</p>';
  });
  assert.equal((await install(page, ['ab'])).matched, 0);
  assert.equal((await install(page, ['café noir', 'ΟΣ', 'Cost $$ per item'])).matched, 3);
  assert.deepEqual(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')].map(r => r.toString())), ['café noir', 'ΟΣ', 'Cost $$ per item']);
  assert.equal((await install(page, ['A passage revealed later'])).matched, 0);
  await page.evaluate(() => document.querySelector('#hidden').hidden = false);
  await settle(page);
  assert.equal((await install(page, ['A passage revealed later'])).matched, 1);
  await page.evaluate(() => document.body.append(document.querySelector('#hidden').cloneNode(true)));
  await settle(page);
  assert.equal((await install(page, ['A passage revealed later'])).matched, 0);
  assert.equal((await install(page, ['lead finish', 'not present'])).matched, 1);
  await page.evaluate(() => window.testRange = [...CSS.highlights.get('margin-saved-passages')][0]);
  await page.evaluate(() => document.querySelector('#clock').textContent = '1');
  await settle(page);
  assert.equal(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')][0] === testRange), true);
  await page.evaluate(() => {
    const body = document.createElement('body');
    body.innerHTML = '<p>lead<br>finish</p>';
    document.body.replaceWith(body);
  });
  await settle(page);
  assert.equal(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')][0]?.startContainer.isConnected), true);
  assert.equal((await install(page, ['lead finish', 'not present'])).matched, 1);
  assert.equal(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')][0].toString()), 'leadfinish');
  await install(page, []);
  assert.equal(await page.evaluate(() => CSS.highlights.has('margin-saved-passages') ||
    !!window[Symbol.for('com.jackboylan.margin.highlights')]), false);
});


test('normalization boundaries and CSS visibility cannot paint a different passage', async t => {
  const page = await setup(t);
  await page.evaluate(() => {
    document.body.innerHTML = '<style>[data-state="closed"]{display:none}@media(max-width:500px){#responsive{display:block}}@media(min-width:501px){#responsive{display:none}}</style>' +
      '<p>Use ⅓ cup of water.</p><p>A<span style="visibility:hidden"><span style="visibility:visible">WRONG</span></span>B</p>' +
      '<p>An essay on ΟΣΑ and other words</p>' +
      '<p>A unique visible passage</p><details><summary>Closed</summary><p>A unique visible passage</p></details>' +
      '<p>A changing duplicate</p><p id="duplicate" data-state="closed">A changing duplicate</p>' +
      '<p>A responsive duplicate</p><p id="responsive">A responsive duplicate</p>';
  });
  assert.equal((await install(page, ['3 cup of water', 'AB'])).matched, 0);
  assert.equal((await install(page, ['⅓ cup of water', 'essay on ΟΣ', 'A unique visible passage'])).matched, 3);
  assert.deepEqual(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')].map(r=>r.toString())), ['⅓ cup of water', 'essay on ΟΣ', 'A unique visible passage']);
  assert.equal((await install(page, ['A changing duplicate'])).matched, 1);
  await page.evaluate(() => document.querySelector('#duplicate').dataset.state = 'open');
  await settle(page);
  assert.equal(await page.evaluate(() => CSS.highlights.get('margin-saved-passages').size), 0);
  assert.equal((await install(page, ['A responsive duplicate'])).matched, 1);
  await page.setViewportSize({width:450,height:500});
  await settle(page);
  assert.equal(await page.evaluate(() => CSS.highlights.get('margin-saved-passages').size), 0);
});

// All variants have identical text and page geometry. Only page two's native highlight annotations change.
function paperWithMarks(ids = []) {
  const lines = [540, 480, 420, 360, 300].map((y, i) => `BT /F1 16 Tf 75 ${y} Td (Passage ${i + 1} for the reader.) Tj ET`).join('\n');
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>',
    ...['[]', '9 0 R'].map(annotations => `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R /Annots ${annotations} >>`),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Length ${lines.length} >>\nstream\n${lines}\nendstream`,
    ...[480, 420].map(y => `<< /Type /Annot /Subtype /Highlight /C [1 1 0] /Rect [72 ${y-3} 155 ${y+13}] /QuadPoints [72 ${y+13} 155 ${y+13} 72 ${y-3} 155 ${y-3}] >>`),
    '[]',
  ];
  let pdf = '%PDF-1.7\n';
  const offsets = [];
  for (const [i, object] of objects.entries()) {
    offsets.push(pdf.length);
    pdf += `${i + 1} 0 obj\n${object}\nendobj\n`;
  }
  const start = pdf.length;
  pdf += `xref\n0 ${objects.length+1}\n0000000000 65535 f \n`;
  for (const offset of offsets) pdf += String(offset).padStart(10, '0') + ' 00000 n \n';
  pdf += `trailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`;
  if (ids.length) {
    const position = pdf.length;
    pdf += `9 0 obj\n[${ids.map(id => id + ' 0 R').join(' ')}]\nendobj\n`;
    const xref = pdf.length;
    pdf += `xref\n9 1\n${String(position).padStart(10, '0')} 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R /Prev ${start} >>\nstartxref\n${xref}\n%%EOF\n`;
  }
  return Buffer.from(pdf);
}

test('saving PDF highlights preserves the visible text, zoom and reading position in Chrome', async t => {
  const script = await readFile(new URL('../Sources/Margin/Resources/PDFViewport.js', import.meta.url), 'utf8');
  const context = await chromium.launchPersistentContext('', { channel: 'chromium' });
  t.after(() => context.close());
  const page = await context.newPage();
  const paper = 'https://arxiv.org/pdf/2506.01844';
  const url = paper + '#page=2&zoom=125,0,180';
  await page.route(paper, route => route.fulfill({ contentType: 'application/pdf', body: paperWithMarks() }));
  await page.goto(url);
  async function run(action, token, extra = {}) {
    const request = JSON.stringify({ url, action, token, ...extra });
    return JSON.parse(await page.evaluate(script.replace('__MARGIN_REQUEST__', () => request))).status;
  }
  async function stage(token, top, ids) {
    const base = paperWithMarks();
    const fields = { page: 2, zoom: 100, left: 0, top };
    if (ids !== undefined) {
      fields.sourceID = 'fixture';
      fields.append = paperWithMarks(ids).subarray(base.length).toString('base64');
    }
    let result = await run('stage', token, fields);
    if (result === 'sourceNeeded') {
      assert.equal(await page.locator('iframe[title="PDF with saved highlights"]').count(), 0);
      result = await run('stage', token, { ...fields, sourceBytes: base.toString('base64') });
    }
    assert.equal(result, 'pending');
    await until(async () => await run('status', token) === 'ready');
  }
  async function until(predicate) {
    const deadline = Date.now() + 8000;
    while (!await predicate()) {
      assert.ok(Date.now() < deadline, 'Chrome did not reach the expected rendered state');
      await new Promise(resolve => setTimeout(resolve, 60));
    }
  }
  async function pixels() {
    const buffer = await page.screenshot({ clip: { x: 385, y: 80, width: 780, height: 580 } });
    return page.evaluate(async png => {
      const image = new Image();
      image.src = 'data:image/png;base64,' + png;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = image.width; canvas.height = image.height;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(image, 0, 0);
      const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
      let ink = 0, last = -2;
      const bands = [], lines = [];
      for (let y = 0; y < canvas.height; y++) {
        let yellow = 0, left = canvas.width, right = -1;
        for (let x = 0; x < canvas.width; x++) {
          const i = 4 * (y * canvas.width + x);
          if (data[i] < 128 && data[i+1] < 128) {
            ink++;
            left = Math.min(left, x);
            right = x;
          }
          if (data[i] > 200 && data[i+1] > 200 && data[i+2] < 120) yellow++;
        }
        if (right > left) {
          const prior = lines.at(-1);
          if (prior && prior[3] === y - 1) {
            prior[0] = Math.min(prior[0], left);
            prior[2] = Math.max(prior[2], right);
            prior[3] = y;
          } else {
            lines.push([left, y, right, y]);
          }
        }
        if (yellow > 20) {
          if (y > last + 1) bands.push(y);
          last = y;
        }
      }
      return { ink, lines, bands };
    }, buffer.toString('base64'));
  }
  async function atPosition(expected, count) {
    let result;
    await until(async () => {
      result = await pixels();
      return result.ink > 750 && result.ink < 20000 && result.bands.length === count && result.lines.length >= 2 &&
        (!expected || result.lines.length === expected.lines.length && result.lines.every((line, i) =>
          line.every((edge, j) => Math.abs(edge - expected.lines[i][j]) <= 1)));
    });
    return result;
  }

  const initial = await atPosition(null, 0);
  const originalViewer = page.frames().find(frame => frame.url().startsWith('chrome-extension://'));
  const readingPosition = () => originalViewer.evaluate(() => {
    const viewport = document.querySelector('pdf-viewer').viewport;
    return [viewport.getMostVisiblePage(), viewport.getZoom(), viewport.position.x, viewport.position.y];
  });
  const start = await readingPosition();
  await stage('abandoned', 0, [7]);
  assert.equal(await run('cancel', 'abandoned'), 'original');
  assert.equal(await page.getByTitle('Margin PDF staging').count(), 0);
  assert.equal(await page.evaluate(() => document.body.inert), false);
  await stage('first', 0, [7]);
  assert.deepEqual(await readingPosition(), start);
  await atPosition(initial, 0);
  await stage('first', 180);
  assert.equal(await run('commit', 'first'), 'active');
  const first = await atPosition(initial, 1);
  await page.mouse.click(850, 350);
  await atPosition(first, 1);
  await page.mouse.move(695, 285);
  await page.mouse.wheel(0, 80);
  await until(async () => Math.abs((await pixels()).bands[0] - first.bands[0] + 80) <= 1);
  const scrolled = await pixels();
  await stage('second', 244, [7, 8]);
  assert.equal(await run('commit', 'second'), 'active');
  const second = await atPosition(scrolled, 2);
  assert.ok(Math.abs(second.bands[0] - scrolled.bands[0]) <= 1);
  await stage('remaining', 244, [8]);
  assert.equal(await run('commit', 'remaining'), 'active');
  const remaining = await atPosition(scrolled, 1);
  assert.ok(Math.abs(remaining.bands[0] - second.bands[1]) <= 1);
  await stage('removed', 244, []);
  assert.equal(await run('commit', 'removed'), 'active');
  await atPosition(scrolled, 0);
  assert.equal(page.url(), url);
  await page.reload();
  await atPosition(initial, 0);
  await stage('second', 180, [7, 8]);
  assert.equal(await run('commit', 'second'), 'active');
  await atPosition(initial, 2);
  await page.route(paper, route => route.fulfill({ status: 503, contentType: 'text/html', body: '<p>Paper unavailable</p>' }));
  await page.reload();
  assert.equal(await run('status', 'restored'), 'notPDF');
});

test('a multiline code selection excludes unselectable line numbers from every painted range', async t => {
  const page = await setup(t);
  await page.setContent('<div><span style="user-select:none">1</span><code>#ifndef STRBUF_H</code></div>' +
    '<div><span style="user-select:none">2</span><code>#define STRBUF_H</code></div>');
  const selected = await page.evaluate(() => {
    const lines = document.querySelectorAll('code');
    const range = new Range();
    range.setStartBefore(lines[0].firstChild);
    range.setEndAfter(lines[1].lastChild);
    getSelection().addRange(range);
    return getSelection().toString();
  });
  assert.deepEqual(selected.split(/\s+/), ['#ifndef', 'STRBUF_H', '#define', 'STRBUF_H']);
  assert.equal((await install(page, [selected])).matched, 1);
  assert.deepEqual(await page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')].map(r => r.toString())),
    ['#ifndef STRBUF_H', '#define STRBUF_H']);
});

test('release selections keep their tag and occurrence across the release list and detail page', async t => {
  const list = 'https://github.com/example/project/releases';
  const tag = list + '/tag/v2';
  const repeated = 'Download the installer.';
  const sentence = '<p>First option: <b>Download the installer.</b> Read the guide.</p>';
  const other = '<p>Second option: <b>Download the installer.</b> See the appendix.</p>';
  const prose = '<div class="markdown-body">' + sentence + other + '</div>';
  const sections = ['v1', 'v2'].map(name => '<section id="release-' + name + '"><a href="' + list + '/tag/' + name + '">' + name + '</a>' + prose + '</section>').join('');
  const browser = await chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.route(list + '**', r => r.fulfill({ contentType: 'text/html', body: r.request().url().includes('/tag/') ? prose : sections }));
  const run = fields => page.evaluate(source.replace('__MARGIN_REQUEST__', () => JSON.stringify({ url: page.url(), ...fields }))).then(JSON.parse);
  const paint = async passages => (await run({passages})).matched;
  const capture = async selector => {
    await page.locator(selector).evaluate(e => getSelection().selectAllChildren(e));
    const anchor = await run({ action: 'anchor', quote: repeated });
    assert.equal(anchor.status, 'anchored');
    await page.evaluate(() => getSelection().removeAllRanges());
    return { quote: repeated, prefix: anchor.prefix, suffix: anchor.suffix, releaseURL: anchor.releaseURL };
  };
  const painted = () => page.evaluate(() => [...CSS.highlights.get('margin-saved-passages')].map(r =>
    [r.startContainer.parentElement.closest('section')?.id, r.startContainer.parentElement.closest('p').innerText, r.toString()]));
  await page.goto(list);
  assert.equal((await run({ quotes: [repeated] })).matched, 0);
  const passage = await capture('#release-v2 p:last-child b');
  assert.equal(passage.releaseURL, tag);
  assert.equal(await paint([passage]), 1);
  assert.deepEqual(await painted(), [['release-v2', 'Second option: Download the installer. See the appendix.', repeated]]);
  await page.goto(tag + '/');
  assert.deepEqual(await capture('p:last-child b'), passage);
  assert.equal(await paint([passage]), 1);
  await page.locator('p:last-child').evaluate(e => e.remove());
  await settle(page);
  assert.deepEqual(await painted(), []);
  await page.goto(list);
  assert.equal(await paint([passage]), 1);
  await page.locator('#release-v2').evaluate(e => e.remove());
  await settle(page);
  assert.deepEqual(await painted(), []);
});
