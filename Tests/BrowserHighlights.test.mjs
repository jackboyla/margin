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
