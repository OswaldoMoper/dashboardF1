import { expect, test, type Locator, type Page } from '@playwright/test';
import { openDashboard } from './serve';

type Box = { x: number; y: number; width: number; height: number };

// En el orden en que `Pages.Dashboard` monta sus capas: la capa n es la del layout n.
const LAYOUTS = ['Race Overview', 'Qualy'] as const;
type Layout = (typeof LAYOUTS)[number];

// Margen para el redondeo de los porcentajes a píxeles.
const EPS = 0.5;

function inside(inner: Box, outer: Box): boolean {
  return (
    inner.x >= outer.x - EPS &&
    inner.y >= outer.y - EPS &&
    inner.x + inner.width <= outer.x + outer.width + EPS &&
    inner.y + inner.height <= outer.y + outer.height + EPS
  );
}

// Se pisan si comparten más que un borde en los dos ejes.
function overlaps(a: Box, b: Box): boolean {
  const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return w > EPS && h > EPS;
}

// Pulsa el layout y espera a que su capa sea la que se ve, que no es en el mismo
// instante del clic.
async function show(page: Page, layout: Layout): Promise<Locator> {
  await page.getByRole('button', { name: layout, exact: true }).click();
  const layer = page.locator('.canvas__layer').nth(LAYOUTS.indexOf(layout));
  await expect(layer).not.toHaveClass(/canvas__layer--hidden/);
  return layer;
}

// Los rectángulos de las tarjetas de una capa, en el orden en que se pintan.
async function slots(layer: Locator): Promise<Box[]> {
  const shown = layer.locator(':scope > .widget-slot');
  await expect(shown.first()).toBeVisible();
  return shown.evaluateAll((els) =>
    els.map((el) => {
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    }),
  );
}

test('el instrumento: un borde compartido no pisa, un solape sí, y salirse del lienzo se ve', () => {
  const a = { x: 0, y: 0, width: 100, height: 100 };
  expect(overlaps(a, { x: 100, y: 0, width: 50, height: 100 })).toBe(false);
  expect(overlaps(a, { x: 90, y: 50, width: 50, height: 100 })).toBe(true);
  expect(inside({ x: 10, y: 10, width: 80, height: 80 }, a)).toBe(true);
  expect(inside({ x: 10, y: 10, width: 95, height: 80 }, a)).toBe(false);
});

test.describe('los layouts', () => {
  test.beforeEach(async ({ page }) => {
    await openDashboard(page);
  });

  for (const layout of LAYOUTS) {
    test(`${layout}: cada tarjeta dentro del lienzo y ninguna encima de otra`, async ({ page }) => {
      const layer = await show(page, layout);
      const canvas = await page.locator('.canvas').boundingBox();
      if (!canvas) throw new Error('el lienzo no se ve');
      const boxes = await slots(layer);
      for (const [i, box] of boxes.entries()) {
        expect(inside(box, canvas), `la tarjeta ${i} se sale del lienzo`).toBe(true);
      }
      for (const [i, a] of boxes.entries()) {
        for (const [j, b] of boxes.entries()) {
          if (j > i) expect(overlaps(a, b), `las tarjetas ${i} y ${j} se pisan`).toBe(false);
        }
      }
    });

    test(`${layout}: al volver de otro layout cada tarjeta sigue en su sitio`, async ({ page }) => {
      const before = await slots(await show(page, layout));
      for (const other of LAYOUTS.filter((l) => l !== layout)) await show(page, other);
      expect(await slots(await show(page, layout))).toEqual(before);
    });
  }
});
