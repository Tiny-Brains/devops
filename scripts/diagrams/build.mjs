#!/usr/bin/env node
// THE ARCHITECTURE DIAGRAMS, BUILT: `node scripts/diagrams/build.mjs`, from devops/.
//
// Each diagrams/src/<name>.<type>.json is an archify candidate. This runs archify's `finalize` on it
// -- every gate, the real-browser check included -- and then dresses the page it wrote in the
// TinyBrains design system, and writes the landing page beside them. diagrams/ is what the `pages`
// workflow publishes, as committed: CI builds nothing.
//
// THE DESIGN SYSTEM IS FETCHED, NEVER COPIED BY HAND. tokens.css and the logo come from
// Tiny-Brains/web (TB_WEB_REF, default main), or from a checkout named by TB_WEB_DIR to try an
// unreleased change; web/README.md says tokens.css is the only copy of those values. Archify's own
// variables are then MAPPED onto the tokens, so one palette decides both themes and a token change
// is a rebuild.
//
// ONE LOOK. Archify ships four visual styles; the style menu and its S shortcut are removed, and the
// light/dark toggle stays, switching the TinyBrains palettes. The logo is CC BY 3.0: its attribution
// travels in each page's source and is printed at the foot of every page.

import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const OUT = join(ROOT, 'diagrams')
const ARCHIFY = process.env.ARCHIFY || join(homedir(), '.claude/skills/archify/bin/archify.mjs')
const WEB_DIR = process.env.TB_WEB_DIR
const WEB_REF = process.env.TB_WEB_REF || 'main'

// What the landing page says about each diagram, by source name; a source missing here fails the build.
const PAGES = {
  'production-runtime': 'The central Orion node, the Orion runners and Orion UI, with every store and edge around them.',
  'submission-to-rating': "One model's path in order: upload, Orion's admission on a runner, a trial match, the rating.",
  'model-version-lifecycle': 'The states a submitted version moves through, what moves it, and where it ends.',
}

const CREDIT = 'Logo derived from “Ai Brain” by Rizqi Auliya, from ' +
  '<a href="https://thenounproject.com/icon/ai-brain-7276116/">The Noun Project</a>, under ' +
  '<a href="https://creativecommons.org/licenses/by/3.0/">CC BY 3.0</a>.'

async function webFile(path) {
  if (WEB_DIR) return readFileSync(join(WEB_DIR, path), 'utf8')
  const url = `https://raw.githubusercontent.com/Tiny-Brains/web/${WEB_REF}/${path}`
  const res = await fetch(url)
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`)
  return res.text()
}

function once(text, find, replace, what) {
  const n = text.split(find).length - 1
  if (n !== 1) throw new Error(`${what}: expected one match, found ${n} -- archify's page changed shape`)
  return text.replace(find, replace)
}

const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

// The standalone logo is drawn in the dark palette's literals; inline, each region reads its token
// instead, as web's Logo.tsx does, so the mark follows the theme. Its file comment speaks of web's
// own files, so the inline copy carries the attribution alone.
function inlineLogo(svg) {
  const fills = { '#EEF3FF': 'var(--ink)', '#76A7FF': 'var(--frontal)', '#50D6CE': 'var(--parietal)',
    '#74C6F5': 'var(--temporal)', '#A194FF': 'var(--occipital)', '#FF9776': 'var(--cerebellum)' }
  if (!/^\s*<!--[\s\S]*?CC BY 3\.0[\s\S]*?-->/.test(svg)) throw new Error('logo: its attribution comment is missing')
  let out = svg.replace(/^\s*<!--[\s\S]*?-->\s*/, '<!-- TinyBrains logo. Derived from "Ai Brain" by Rizqi Auliya ' +
    'from Noun Project (https://thenounproject.com/icon/ai-brain-7276116/), licensed under CC BY 3.0 ' +
    '(https://creativecommons.org/licenses/by/3.0/). -->')
  out = out.replace(/ width="512" height="512"/, '')
  for (const [hex, token] of Object.entries(fills)) {
    if (!out.includes(`fill="${hex}"`)) throw new Error(`logo: no ${hex} region -- web's logo changed`)
    out = out.split(`fill="${hex}"`).join(`fill="${token}"`)
  }
  return out
}

// Archify's variables, in terms of the TinyBrains roles. `:root[data-theme]` outranks archify's own
// `[data-theme=...]` blocks and, coming later, its style-scoped ones.
const MAP = `
:root[data-theme] {
  --bg: var(--bg-base);
  --grid: color-mix(in srgb, var(--line) 30%, var(--bg-base));
  --canvas-dot: color-mix(in srgb, var(--muted) 20%, transparent);
  --text: var(--ink);
  --text-muted: var(--muted);
  --text-dim: color-mix(in srgb, var(--muted) 62%, var(--bg-base));
  --text-faint: color-mix(in srgb, var(--muted) 82%, var(--bg-base));
  --panel: var(--surface);
  --panel-border: var(--line);
  --lane-fill: color-mix(in srgb, var(--surface) 55%, transparent);
  --lane-stroke: var(--line);
  --arrow: color-mix(in srgb, var(--muted) 78%, var(--bg-base));
  --arrow-emphasis: var(--accent);
  --mask: var(--surface);
  --frontend-stroke: var(--temporal);    --frontend-fill: color-mix(in srgb, var(--temporal) 14%, transparent);
  --backend-stroke: var(--parietal);     --backend-fill: color-mix(in srgb, var(--parietal) 14%, transparent);
  --database-stroke: var(--occipital);   --database-fill: color-mix(in srgb, var(--occipital) 16%, transparent);
  --cloud-stroke: var(--warning);        --cloud-fill: color-mix(in srgb, var(--warning) 12%, transparent);
  --security-stroke: var(--danger);      --security-fill: color-mix(in srgb, var(--danger) 13%, transparent);
  --messagebus-stroke: var(--cerebellum); --messagebus-fill: color-mix(in srgb, var(--cerebellum) 13%, transparent);
  --external-stroke: var(--stem);        --external-fill: color-mix(in srgb, var(--stem) 14%, transparent);
  --toolbar-bg: color-mix(in srgb, var(--surface) 90%, transparent);
  --toolbar-border: var(--line);
  --toolbar-text: var(--ink);
  --toolbar-hover: var(--surface-raised);
  --toolbar-menu-bg: var(--surface);
}
body { background: var(--bg-base); color: var(--ink); font-family: var(--font-sans); }
h1, .subtitle { color: var(--ink); }
svg { font-family: var(--font-mono); }
svg .t-primary { font-family: var(--font-sans); font-weight: 650; }
.c-region { fill: color-mix(in srgb, var(--warning) 5%, transparent); }
.preset-wrap { display: none !important; }
.header-row { flex-wrap: wrap; gap: 14px; }
.tb-brand { display: flex; align-items: center; gap: 11px; color: var(--ink); text-decoration: none;
  font: 750 25px/1 var(--font-sans); letter-spacing: -.02em; }
.tb-brand:hover { text-decoration: none; }
.tb-brand svg { width: 39px; height: 39px; min-width: 0; flex: none; }
.tb-brand b { color: var(--muted); font-weight: inherit; }
.tb-sep { width: 1px; height: 28px; background: var(--line); }
.header h1 { font: 700 22px/1.2 var(--font-sans); letter-spacing: -.02em; margin: 0; }
.tb-credit { max-width: 1400px; margin: 8px auto 32px; padding: 0 24px; color: var(--muted);
  font: 400 12px/1.5 var(--font-sans); }
.tb-credit a { color: inherit; }
`

// After archify's own script: settle on its one style, and take S back from the style cycler.
const SCRIPT = `
<script id="tb-brand-script">
(function () {
  try { if (window.Archify && Archify.preset) { Archify.preset.apply('classic'); Archify.preset.cycle = function () { return false; }; } } catch (_) {}
  document.addEventListener('keydown', function (e) {
    var t = e.target, typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    if (!typing && !e.metaKey && !e.ctrlKey && !e.altKey && (e.key === 's' || e.key === 'S')) e.stopImmediatePropagation();
  }, true);
})();
</script>`

function brand(html, { tokens, logo, favicon, title }) {
  const head = `<link rel="icon" href="${favicon}">\n<style id="tb-tokens">\n${tokens}\n</style>\n<style id="tb-brand">${MAP}</style>\n`
  let out = once(html, '</head>', head + '</head>', 'head')
  out = out.replace(/<title>[^<]*<\/title>/, `<title>${escape(title)} · TinyBrains</title>`)
  out = once(out, '<div class="pulse-dot"></div>',
    `<a class="tb-brand" href="./" aria-label="TinyBrains diagrams">${logo}<span>tiny<b>brains</b></span></a>` +
    '<span class="tb-sep" aria-hidden="true"></span>', 'header')
  out = once(out, '</body>', `<footer class="tb-credit">${CREDIT}</footer>${SCRIPT}\n</body>`, 'body')
  return out
}

function landing({ tokens, logo, favicon, pages }) {
  const cards = pages.map((p) => `    <li><a class="card" href="${p.name}.html">
      <h2>${escape(p.title)}</h2>
      <p>${escape(p.blurb)}</p>
    </a></li>`).join('\n')
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TinyBrains Architecture</title>
<meta name="description" content="How the TinyBrains platform runs on Orion: the production runtime, a submission's path to a rating, and a model version's lifecycle.">
<link rel="icon" href="${favicon}">
<script>
  // Before the first paint, as the site does: the reader's stored choice, else the system's. The key is
  // archify's, so a choice made here carries to every diagram; ?theme= wins, as it does on theirs.
  (function () {
    var t = null;
    try { t = new URLSearchParams(location.search).get('theme'); } catch (_) {}
    try { if (t !== 'light' && t !== 'dark') t = localStorage.getItem('archify-theme'); } catch (_) {}
    if (t !== 'light' && t !== 'dark') t = window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', t);
  })();
</script>
<style id="tb-tokens">
${tokens}
</style>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 var(--font-sans); }
  main { max-width: 880px; margin: 0 auto; padding: var(--space-12) var(--space-4) var(--space-16); }
  header { display: flex; align-items: center; justify-content: space-between; gap: var(--space-4); margin-bottom: var(--space-8); }
  .brand { display: flex; align-items: center; gap: 11px; color: var(--ink); text-decoration: none;
    font: 750 25px/1 var(--font-sans); letter-spacing: -.02em; }
  .brand svg { width: 39px; height: 39px; flex: none; }
  .brand b { color: var(--muted); font-weight: inherit; }
  .theme { height: 34px; padding: 0 var(--space-3); border: 1px solid var(--line); border-radius: var(--radius-md);
    background: var(--surface); color: var(--ink); font: 500 14px var(--font-sans); cursor: pointer; }
  .theme:focus-visible, a.card:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  h1 { font: 700 30px/1.15 var(--font-sans); letter-spacing: -.02em; margin: 0 0 var(--space-2); }
  .lede { color: var(--muted); margin: 0 0 var(--space-8); }
  .lede strong { color: var(--ink); }
  ol { list-style: none; margin: 0; padding: 0; display: grid; gap: var(--space-3); }
  a.card { display: block; padding: 20px 22px; background: var(--surface); border: 1px solid var(--line);
    border-radius: var(--radius-lg); color: inherit; text-decoration: none; }
  a.card:hover { border-color: var(--accent); }
  .card h2 { font: 650 18px/1.3 var(--font-sans); margin: 0 0 var(--space-1); }
  .card h2::after { content: " \\2192"; color: var(--accent); }
  .card p { margin: 0; color: var(--muted); font-size: 15px; }
  footer { margin-top: var(--space-8); color: var(--muted); font-size: 13px; }
  footer p { margin: 0 0 var(--space-1); }
  footer a { color: inherit; }
  code { font-family: var(--font-mono); font-size: .92em; }
</style>
</head>
<body>
<main>
  <header>
    <a class="brand" href="./" aria-label="TinyBrains diagrams">${logo}<span>tiny<b>brains</b></span></a>
    <button class="theme" type="button" id="theme" aria-label="Toggle colour theme"></button>
  </header>
  <h1>Architecture</h1>
  <p class="lede">The platform behind tinybrains.dev runs on <strong>Orion</strong>: one central Orion node serves the site and runs the ladder's clocks, every runner is an Orion node of its own, and <strong>Orion UI</strong> operates it all.</p>
  <ol>
${cards}
  </ol>
  <footer>
    <p>Drawn with archify from <code>diagrams/src/</code> in Tiny-Brains/devops.</p>
    <p>${CREDIT}</p>
  </footer>
</main>
<script>
  (function () {
    var html = document.documentElement, btn = document.getElementById('theme');
    function label() { btn.textContent = html.getAttribute('data-theme') === 'light' ? 'Light' : 'Dark'; }
    btn.addEventListener('click', function () {
      var next = html.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
      html.setAttribute('data-theme', next);
      try { localStorage.setItem('archify-theme', next); } catch (_) {}
      label();
    });
    label();
  })();
</script>
</body>
</html>
`
}

async function main() {
  if (!existsSync(ARCHIFY)) throw new Error(`no archify at ${ARCHIFY} -- set ARCHIFY, or: npx skills add tt-a1i/archify -g`)
  const tokens = (await webFile('public/design-system/tokens.css')).trim()
  const logoFile = await webFile('public/logo-circuit.svg')
  const logo = inlineLogo(logoFile)
  const favicon = 'data:image/svg+xml;base64,' + Buffer.from(logoFile).toString('base64')

  const evidence = mkdtempSync(join(tmpdir(), 'tb-diagrams-'))
  const pages = []
  try {
    for (const file of readdirSync(join(OUT, 'src')).filter((f) => f.endsWith('.json')).sort()) {
      const [name, type] = file.split('.')
      if (!(name in PAGES)) throw new Error(`${file}: no landing-page line for "${name}" in PAGES`)
      const spec = JSON.parse(readFileSync(join(OUT, 'src', file), 'utf8'))
      const html = join(OUT, `${name}.html`)
      if (spec.meta.output !== `diagrams/${name}.html`) throw new Error(`${file}: meta.output must be diagrams/${name}.html`)
      process.stdout.write(`${name} (${type}): archify finalize ... `)
      try {
        execFileSync('node', [ARCHIFY, 'finalize', type, `diagrams/src/${file}`, `diagrams/${name}.html`,
          '--quality', 'showcase', '--json', '--out-dir', join(evidence, name)], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] })
      } catch (err) {
        console.log('FAILED')
        throw new Error(`${file}: archify finalize failed\n${err.stdout || ''}${err.stderr || ''}`)
      }
      writeFileSync(html, brand(readFileSync(html, 'utf8'), { tokens, logo, favicon, title: spec.meta.title }))
      rmSync(join(OUT, `${name}.delivery.json`), { force: true })
      console.log('ok')
      pages.push({ name, title: spec.meta.title, blurb: PAGES[name] })
    }
  } finally {
    rmSync(evidence, { recursive: true, force: true })
  }
  const order = Object.keys(PAGES)
  pages.sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name))
  writeFileSync(join(OUT, 'index.html'), landing({ tokens, logo, favicon, pages }))
  console.log(`index: ${pages.length} diagrams`)
}

main().catch((err) => { console.error(err.message); process.exit(1) })
