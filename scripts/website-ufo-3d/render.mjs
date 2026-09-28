import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const root = dirname(fileURLToPath(import.meta.url));
const destination = resolve(root, '../../assets/website-ufo-3d');
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json' };
const server = createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const file = resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!file.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
    res.setHeader('Content-Type', mime[extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.writeHead(404); res.end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
let browser;
try {
  browser = await chromium.launch({ channel: 'chrome', args: ['--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1536, height: 1024 } });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction(() => window.ufo3d?.ready, null, { timeout: 30000 });
  const inspection = await page.evaluate(() => ufo3d.inspect());
  assert.equal(inspection.windows.length, 12);
  for (const [i, window] of inspection.windows.entries()) {
    assert.ok(Math.abs(Math.hypot(window.position[0], window.position[2]) - 2.96) < 1e-8);
    assert.ok(Math.abs(window.angleDegrees - (i + .5) * 30) < 1e-8);
    assert.ok(Math.abs(Math.hypot(...window.surfaceNormal) - 1) < 1e-8);
    assert.equal(window.holeClear, true, `${window.name}: underside must have a real opening`);
  }
  const png = await page.evaluate(() => ufo3d.render());
  const glb = await page.evaluate(() => ufo3d.export());
  const roundtrip = await page.evaluate(async encoded => {
    const { GLTFLoader } = await import('three/addons/loaders/GLTFLoader.js');
    const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
    const model = await new GLTFLoader().parseAsync(bytes.buffer, '');
    return model.scene.getObjectByName('Twelve_radial_portholes').children.length;
  }, glb);
  assert.equal(roundtrip, 12);
  const underside = await page.evaluate(() => ufo3d.render(-65, 0, true));
  assert.deepEqual(errors, []);
  await mkdir(destination, { recursive: true });
  await writeFile(resolve(destination, 'ufo-hero.png'), Buffer.from(png.split(',')[1], 'base64'));
  await writeFile(resolve(destination, 'ufo.glb'), Buffer.from(glb, 'base64'));
  await writeFile(resolve(destination, 'ufo-underside.png'), Buffer.from(underside.split(',')[1], 'base64'));
  await writeFile(resolve(destination, 'geometry.json'), JSON.stringify(inspection, null, 2) + '\n');
  if (process.argv.includes('--embed')) {
    const htmlPath = resolve(root, '../../docs/website-preview.html');
    const html = await readFile(htmlPath, 'utf8');
    const pattern = /(<img class="craft" src=")[^"]+("[^>]*>)/;
    assert.ok(pattern.test(html), 'Expected a dedicated craft image in the website');
    await writeFile(htmlPath, html.replace(pattern, (_, prefix, suffix) => prefix + png + suffix));
  }
  console.log(JSON.stringify({ destination, meshes: inspection.meshCount, portholes: 12, verified: ['equal angular spacing', 'surface normals', 'physical holes', 'GLB roundtrip'] }));
} finally {
  await browser?.close();
  await new Promise(r => server.close(r));
}
