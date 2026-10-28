// Prints an Anatomy sheet (the HTML `print.mjs` lays out) to an A4 PDF and a preview PNG with Playwright.
// Why: Chrome's own --print-to-pdf hung in a headless Linux container; this path printed the poster.
// Usage: node print-pdf.cjs <sheet.html> <out.pdf> <out.png> [figure width share, 0.74 for the workshop]
// The share shrinks the figure so the numbers and parts rows get room; the logged boxes must not overlap
// (sideBottom <= legendTop).
const { chromium } = require('playwright');
const [html, pdf, png, fig = '1'] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 794, height: 1123 }, deviceScaleFactor: 2 });
  await p.goto('file://' + html, { waitUntil: 'load' });
  await p.emulateMedia({ media: 'print' });
  await p.addStyleTag({ content: `.pp-wide .pp-art .ps-fig{width:${fig * 100}%!important;margin:0 auto}` });
  await p.waitForTimeout(600);
  const clash = await p.evaluate(() => {
    const box = (s) => document.querySelector(s).getBoundingClientRect();
    const side = box('.pp-side'), legend = box('.pp-legend'), art = box('.pp-art'), ft = box('.ps-ft');
    const nums = [...document.querySelectorAll('.ps-num')].map((n) => n.getBoundingClientRect().bottom);
    return { sideBottom: Math.max(side.bottom, ...nums), legendTop: legend.top, legendBottom: legend.bottom, footTop: ft.top, artBottom: art.bottom, sideTop: side.top };
  });
  console.log(JSON.stringify(clash));
  await p.pdf({ path: pdf, format: 'A4', printBackground: true, preferCSSPageSize: true });
  await p.screenshot({ path: png, fullPage: true });
  await b.close();
})();
