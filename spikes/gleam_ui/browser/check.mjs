// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('requestfailed', request => errors.push(request.url()));
  // Serve only the copied distribution, using Playwright's in-memory routing.
  // No source checkout path or development server is available to the host.
  await page.route('**/*', async route => {
    const url = new URL(route.request().url());
    const relative = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname.slice(1));
    const target = path.resolve(dist, relative);
    if (url.origin !== 'http://elzoo.test' || !target.startsWith(dist)) {
      errors.push(`Unexpected request: ${url}`);
      return route.abort();
    }
    try {
      await route.fulfill({
        status: 200,
        contentType: target.endsWith('.mjs') ? 'text/javascript' : 'text/html',
        body: await readFile(target),
      });
    } catch (error) {
      errors.push(error.message);
      await route.abort();
    }
  });
  await page.goto('http://elzoo.test/');
  const expectValue = async (id, value) => {
    await page.waitForFunction(({ id, value }) =>
      document.getElementById(id)?.shadowRoot?.querySelector('output')?.textContent === String(value),
    { id, value });
  };
  const settled = () => page.evaluate(() => new Promise(resolve =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const changes = () => page.evaluate(() => window.changes);
  const first = page.locator('#first');
  const second = page.locator('#second');
  await expectValue('first', 2);
  await expectValue('second', 99);
  await settled();
  assert.deepEqual(await changes(), []);

  await first.getByRole('button', { name: 'Increase quantity' }).click();
  await expectValue('first', 3);
  await expectValue('second', 99);
  await settled();
  assert.deepEqual(await changes(), [{ id: 'first', value: 3 }]);
  await second.getByRole('button', { name: 'Increase quantity' }).click();
  await expectValue('second', 100);
  assert.equal(await second.getByRole('button', { name: 'Increase quantity' }).isDisabled(), true);
  await settled();
  assert.deepEqual(await changes(), [{ id: 'first', value: 3 }, { id: 'second', value: 100 }]);

  await first.evaluate(element => element.setAttribute('value', '0'));
  await expectValue('first', 0);
  assert.equal(await first.getByRole('button', { name: 'Decrease quantity' }).isDisabled(), true);
  for (const invalid of ['-1', '101', '1.5', '', '<script>', 'NaN']) {
    await first.evaluate((element, value) => element.setAttribute('value', value), invalid);
    await settled();
    await expectValue('first', 0);
  }
  await first.evaluate(element => element.removeAttribute('value'));
  await settled();
  await expectValue('first', 0);
  // Host changes never echo as user events, including rejected attributes.
  assert.equal((await changes()).length, 2);
  await first.evaluate(element => element.setAttribute('value', '40'));
  await expectValue('first', 40);
  const increment = first.getByRole('button', { name: 'Increase quantity' });
  await increment.focus();
  await page.keyboard.press('Enter');
  await expectValue('first', 41);
  await page.keyboard.press('Space');
  await expectValue('first', 42);
  await settled();
  assert.deepEqual(await changes(), [
    { id: 'first', value: 3 }, { id: 'second', value: 100 },
    { id: 'first', value: 41 }, { id: 'first', value: 42 },
  ]);
  assert.equal(await page.evaluate(() => window.submissions), 0);
  assert.deepEqual(errors, []);
  console.log('Browser host check passed: independent instances, attributes, bounds, events, keyboard, form isolation; no page/module errors.');
} finally {
  await browser.close();
}
