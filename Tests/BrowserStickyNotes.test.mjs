import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { chromium } from 'playwright';

const resource = name => readFile(new URL('../Sources/Margin/Resources/' + name + '.js', import.meta.url), 'utf8');
const sticky = await resource('BrowserStickyNotes');
const highlights = await resource('BrowserHighlights');
const url = 'https://margin.test/notes';

function run(page, script, fields) {
  return page.evaluate(script.replace('__MARGIN_REQUEST__', () => JSON.stringify({ url, ...fields }))).then(JSON.parse);
}

test('page points and notes follow scrolling, reflow, restoration and exact-URL navigation', async t => {
  const browser = await chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage({ viewport: { width: 600, height: 500 } });
  const fixture = `<!doctype html><style>
    body { margin: 0; height: 2000px } #pane { margin: 100px 20px 0; height: 190px; width: 300px; overflow: auto }
    #pane img { display: block; width: 240px; height: 90px; background: blue }
    #space { height: 80px } #end { height: 500px }
    </style><div id="pane"><div id="space"></div><img id="image" alt="illustration"><div id="end"></div></div>`;
  await page.route(url, r => r.fulfill({ contentType: 'text/html', body: fixture }));
  await page.goto(url);

  const locate = (x, y, target = url) => run(page, sticky, { url: target, action: 'locate', fractionX: x/600, fractionY: y/500 });
  const paint = notes => run(page, sticky, { action: 'paint', notes });
  const frame = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const literal = '<img src=x onerror="window.executed=true"> $&';
  const image = { id: 'image', text: literal, anchor: (await locate(35, 192)).anchor };
  const space = { id: 'space', text: 'A note on whitespace', anchor: (await locate(530, 390)).anchor };
  assert.ok(image.anchor.element);
  assert.deepEqual(space.anchor, { x: 530, y: 390 });
  assert.equal((await paint([image, space])).status, 'owned');
  assert.equal((await locate(55, 201)).id, image.id);
  assert.equal((await locate(520, 405)).id, space.id); // Card stays visible at the right edge.
  const ax = await page.context().newCDPSession(page);
  async function visibleText() {
    const { nodes } = await ax.send('Accessibility.getFullAXTree');
    return nodes.filter(n => n.role.value === 'StaticText').map(n => n.name.value);
  }
  async function imageCard() {
    const { nodes } = await ax.send('Accessibility.getFullAXTree');
    const text = nodes.find(n => n.role.value === 'StaticText' && n.name.value === literal);
    const note = nodes.find(n => n.nodeId === text.parentId);
    const { model } = await ax.send('DOM.getBoxModel', { backendNodeId: note.backendDOMNodeId });
    return { id: note.backendDOMNodeId, point: model.border.slice(0, 2) };
  }
  const originalCard = await imageCard();
  assert.deepEqual(originalCard.point, [35, 192]);
  await paint([image, space]);
  assert.deepEqual(await imageCard(), originalCard);
  assert.equal(await page.evaluate(() => window.executed), undefined);
  assert.equal((await run(page, highlights, { quotes: [space.text] })).matched, 0);
  assert.equal(await page.evaluate(() => document.elementFromPoint(55, 201).id), 'image');

  await page.evaluate(() => document.querySelector('#pane').scrollTop = 50);
  await frame();
  assert.deepEqual((await imageCard()).point, [35, 142]);
  await page.evaluate(() => window.scrollTo(0, 60));
  await frame();
  assert.deepEqual((await imageCard()).point, [35, 82]);
  assert.equal((await locate(520, 345)).id, space.id);
  await page.evaluate(() => document.querySelector('#space').style.height = '115px');
  await frame();
  assert.deepEqual((await imageCard()).point, [35, 117]);
  await page.evaluate(() => {
    const image = document.querySelector('#image');
    image.style.width = '120px';
    image.style.height = '45px';
  });
  await frame();
  assert.deepEqual((await imageCard()).point, [27.5, 111]);
  await page.evaluate(() => document.querySelector('#pane').scrollTop = 175);
  await frame();
  assert.ok(!(await visibleText()).includes(literal)); // Anchor clipped above its scrollport.

  await page.reload();
  await page.evaluate(() => window.scrollTo(0, 0));
  await paint([image, space]);
  assert.equal((await locate(55, 201)).id, image.id);
  await paint([space]);
  assert.equal((await locate(55, 201)).id, undefined);
  assert.equal((await locate(520, 405)).id, space.id);
  assert.equal((await locate(520, 405, url + '#other')).status, 'changed');
  await page.evaluate(() => history.pushState({}, '', '#other'));
  await frame();
  assert.ok(!(await visibleText()).includes(space.text));
  assert.equal((await paint([space])).status, 'changed');
  assert.equal((await locate(520, 405, url + '#other')).id, undefined);
  assert.equal(await page.evaluate(() => document.documentElement.lastElementChild.tagName), 'BODY');
  await page.route(url, r => r.fulfill({ contentType: 'text/plain', body: 'plain document' }));
  await page.goto(url);
  assert.equal((await paint([space])).status, 'notHTML');
});
