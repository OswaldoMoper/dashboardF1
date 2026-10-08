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

test.describe('el modo edición', () => {
  test.beforeEach(async ({ page }) => {
    await openDashboard(page);
  });

  // El borde de la primera tarjeta de la capa que se ve y lo que lleva delante su título.
  async function look(page: Page): Promise<{ border: string; mark: string }> {
    const card = page.locator('.canvas__layer:not(.canvas__layer--hidden) .widget').first();
    return card.evaluate((el) => ({
      border: getComputedStyle(el).borderTopStyle,
      mark: getComputedStyle(el.querySelector('.widget__head > h2')!, '::before').content,
    }));
  }

  test('entra y sale: bordes discontinuos, la ⠿ en el título y «⇄» solo en edición', async ({ page }) => {
    const swap = page.locator('.comparison__swap');
    await expect(page.locator('.widget--comparison')).toBeVisible();
    await expect(swap).toBeHidden();
    expect(await look(page)).toEqual({ border: 'solid', mark: 'none' });

    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await expect(page.getByRole('button', { name: '✓ Terminar edición' })).toBeVisible();
    await expect(swap).toBeVisible();
    expect(await look(page)).toEqual({ border: 'dashed', mark: '"⠿ "' });

    await page.getByRole('button', { name: '✓ Terminar edición' }).click();
    await expect(page.getByRole('button', { name: '✎ Editar layout' })).toBeVisible();
    await expect(swap).toBeHidden();
    expect(await look(page)).toEqual({ border: 'solid', mark: 'none' });
  });

  test('plegar la cabecera y cambiar de layout no sacan de la edición', async ({ page }) => {
    const canvas = page.locator('.canvas');
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await expect(canvas).toHaveClass(/canvas--editing/);

    await page.locator('.header-toggle').click();
    await expect(canvas).toHaveClass(/canvas--header-hidden/);
    await expect(canvas).toHaveClass(/canvas--editing/);
    await page.locator('.header-toggle').click();

    await show(page, 'Qualy');
    await expect(canvas).toHaveClass(/canvas--editing/);
    expect((await look(page)).border).toBe('dashed');
  });
});

test.describe('el arrastre', () => {
  // Race Overview tal como lo escribe `Pages.Dashboard`, en unidades del lienzo.
  const RACE = [[0, 0, 60, 90], [60, 0, 60, 35], [60, 35, 60, 50], [0, 90, 60, 30], [60, 90, 60, 30]];

  test.beforeEach(async ({ page }) => {
    await openDashboard(page);
    await expect(page.locator('.widget--comparison')).toBeVisible();
  });

  // Los rectángulos de Race Overview en unidades del lienzo, redondeados.
  async function units(page: Page): Promise<number[][]> {
    return page.locator('.canvas__layer').first().evaluate((layer) => {
      const c = layer.getBoundingClientRect();
      return Array.from(layer.querySelectorAll(':scope > .widget-slot'), (el) => {
        const r = el.getBoundingClientRect();
        return [r.left - c.left, r.top - c.top, r.width, r.height].map((v, i) =>
          Math.round((v / (i % 2 ? c.height : c.width)) * 120),
        );
      });
    });
  }

  // Coge la tarjeta n de Race Overview por su título y la lleva (dx, dy) unidades, sin soltar.
  async function carry(page: Page, n: number, dx: number, dy: number): Promise<void> {
    const layer = await page.locator('.canvas__layer').first().boundingBox();
    const title = await page.locator('.canvas__layer').first()
      .locator(':scope > .widget-slot').nth(n).locator('.widget__head > h2').boundingBox();
    if (!layer || !title) throw new Error('no se ve el título');
    const x = title.x + 10;
    const y = title.y + title.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + (dx * layer.width) / 120, y + (dy * layer.height) / 120, { steps: 12 });
  }

  test('Constructores encima de Lap Comparison la baja (D125), y Esc lo deja todo como estaba', async ({ page }) => {
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await carry(page, 4, 0, -55);
    await expect(page.locator('.widget-slot--held')).toHaveCount(1);
    await expect(page.locator('.canvas__layer:not(.canvas__layer--hidden) .canvas__target')).toBeVisible();
    await page.keyboard.press('Escape');
    await page.mouse.up();
    await page.waitForTimeout(400);
    expect(await units(page)).toEqual(RACE);

    await carry(page, 4, 0, -55);
    await page.mouse.up();
    await page.waitForTimeout(400);
    await expect(page.locator('.widget-slot--held')).toHaveCount(0);
    expect(await units(page)).toEqual([[0, 0, 60, 90], [60, 0, 60, 35], [60, 65, 60, 50], [0, 90, 60, 30], [60, 35, 60, 30]]);
  });

  test('Pilotos a la columna derecha no se deja (D126): se marca y al soltar vuelve', async ({ page }) => {
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await carry(page, 3, 60, -55);
    await expect(page.locator('.widget-slot--blocked')).toHaveCount(1);
    await expect(page.locator('.canvas__layer:not(.canvas__layer--hidden) .canvas__target')).toBeHidden();
    await page.mouse.up();
    await page.waitForTimeout(400);
    expect(await units(page)).toEqual(RACE);
  });

  test('la esquina ◢ estira Lap Comparison y Constructores encoge', async ({ page }) => {
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    const layer = await page.locator('.canvas__layer').first().boundingBox();
    const slot = page.locator('.canvas__layer').first().locator(':scope > .widget-slot').nth(2);
    await slot.hover();
    const grip = await slot.locator('.widget-slot__grip').boundingBox();
    if (!layer || !grip) throw new Error('no se ve la esquina');
    const x = grip.x + grip.width / 2;
    const y = grip.y + grip.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x, y + (11 * layer.height) / 120, { steps: 12 });
    await expect(page.locator('.widget-slot--held')).toHaveCount(1);
    await page.mouse.up();
    await page.waitForTimeout(400);
    expect(await units(page)).toEqual([[0, 0, 60, 90], [60, 0, 60, 35], [60, 35, 60, 60], [0, 90, 60, 30], [60, 95, 60, 25]]);
  });

  test('fuera de edición el título no coge la tarjeta', async ({ page }) => {
    await carry(page, 4, 0, -55);
    await page.mouse.up();
    await page.waitForTimeout(400);
    await expect(page.locator('.widget-slot--held')).toHaveCount(0);
    expect(await units(page)).toEqual(RACE);
  });

  test.describe('el layout se recuerda', () => {
    // Race Overview con Constructores encima de Lap Comparison (D125).
    const MOVED = [[0, 0, 60, 90], [60, 0, 60, 35], [60, 65, 60, 50], [0, 90, 60, 30], [60, 35, 60, 30]];
    const edit = (page: Page) => page.getByRole('button', { name: '✎ Editar layout' }).click();
    const finish = (page: Page) => page.getByRole('button', { name: '✓ Terminar edición' }).click();

    async function moveConstructors(page: Page): Promise<void> {
      await edit(page);
      await carry(page, 4, 0, -55);
      await page.mouse.up();
      await page.waitForTimeout(400);
      expect(await units(page)).toEqual(MOVED);
    }

    async function reload(page: Page): Promise<void> {
      await page.reload();
      await expect(page.locator('.widget--comparison')).toBeVisible();
    }

    test('lo movido se guarda al terminar la edición, y sin terminar se pierde', async ({ page }) => {
      await moveConstructors(page);
      await reload(page);
      expect(await units(page)).toEqual(RACE);

      await moveConstructors(page);
      await finish(page);
      await reload(page);
      expect(await units(page)).toEqual(MOVED);
    });

    test('«Restablecer» solo se ve en edición, y devuelve al de fábrica al terminar', async ({ page }) => {
      const reset = page.getByRole('button', { name: '↺ Restablecer' });
      await expect(reset).toBeHidden();
      await moveConstructors(page);
      await finish(page);
      await reload(page);

      await edit(page);
      await reset.click();
      await page.waitForTimeout(400);
      expect(await units(page)).toEqual(RACE);
      await finish(page);
      await expect(reset).toBeHidden();
      await reload(page);
      expect(await units(page)).toEqual(RACE);
    });

    test('el lado de «⇄» se guarda al terminar la edición, y sin terminar se pierde', async ({ page }) => {
      const body = page.locator('.comparison__body');
      const right = /comparison__body--control-right/;
      await edit(page);
      await page.locator('.comparison__swap').click();
      await expect(body).toHaveClass(right);
      await reload(page);
      await expect(body).not.toHaveClass(right);

      await edit(page);
      await page.locator('.comparison__swap').click();
      await finish(page);
      await reload(page);
      await expect(body).toHaveClass(right);
    });

    test('«Restablecer» devuelve la tabla de mando a la izquierda, y se guarda al terminar', async ({ page }) => {
      const body = page.locator('.comparison__body');
      const right = /comparison__body--control-right/;
      await edit(page);
      await page.locator('.comparison__swap').click();
      await finish(page);
      await reload(page);
      await expect(body).toHaveClass(right);

      await edit(page);
      await page.getByRole('button', { name: '↺ Restablecer' }).click();
      await expect(body).not.toHaveClass(right);
      await finish(page);
      await reload(page);
      await expect(body).not.toHaveClass(right);
    });

    test('lo guardado que no encaja: el de fábrica, con asterisco y nota hasta terminar una edición', async ({ page }) => {
      await page.evaluate(() => localStorage.setItem('dashboardF1.layout.race-overview', '[]'));
      await reload(page);
      expect(await units(page)).toEqual(RACE);
      const noted = page.getByRole('button', { name: 'Race Overview*', exact: true });
      const note = page.locator('.layout-note--open');
      await expect(noted).toBeVisible();
      await expect(note).toHaveCount(1);
      await note.click();
      await expect(note).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Qualy', exact: true })).toBeVisible();

      await reload(page);
      await expect(noted).toBeVisible();
      await edit(page);
      await expect(noted).toBeHidden();
      await expect(page.getByRole('button', { name: 'Race Overview', exact: true })).toBeVisible();
      await finish(page);
      await reload(page);
      await expect(page.getByRole('button', { name: 'Race Overview', exact: true })).toBeVisible();
      await expect(page.locator('.layout-note--open')).toHaveCount(0);
    });

    test('si los dos no encajan, una sola nota bajo el primero los nombra, y vuelve al pasar el ratón', async ({ page }) => {
      await page.evaluate(() => {
        localStorage.setItem('dashboardF1.layout.race-overview', '{');
        localStorage.setItem('dashboardF1.layout.qualy', '[]');
      });
      await reload(page);
      const note = page.locator('.layout-note--open');
      await expect(note).toHaveCount(1);
      await expect(note).toContainText('Race Overview y Qualy volvieron al de fábrica');
      await expect(page.getByRole('button', { name: 'Race Overview*', exact: true })).toBeVisible();
      const qualy = page.getByRole('button', { name: 'Qualy*', exact: true });
      await expect(qualy).toBeVisible();

      await note.click();
      await expect(note).toHaveCount(0);
      await qualy.hover();
      await expect(note).toHaveCount(1);
      await page.mouse.move(1500, 600);
      await expect(note).toHaveCount(0);
    });
  });
});
