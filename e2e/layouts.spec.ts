import { expect, test, type Locator, type Page, type Route } from '@playwright/test';
import { openDashboard } from './serve';
import feedP3 from './recordings/live-feed-p3.json';

type Box = { x: number; y: number; width: number; height: number };

// En el orden en que `Pages.Dashboard` monta sus capas: la capa n es la del layout n.
const LAYOUTS = ['Race Overview', 'Qualy', 'Strategy'] as const;
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

// El HAR sirve `/api/live` de OpenF1 y sin `liveStints`: la tarjeta lo dice y no
// pinta filas. Sin retraso, para no esperar los 41 s de fábrica.
test('Tyre Strategy fuera del feed: el aviso y ninguna fila', async ({ page }) => {
  await openDashboard(page);
  await page.goto('/?retraso=0');
  const card = (await show(page, 'Strategy')).locator('.widget--tyre-strategy');
  await expect(card.locator('.tyre-strategy__notice')).toHaveText('Sin stints de la última sesión');
  await expect(card.locator('.tyre-strategy__row')).toHaveCount(0);
});

// La foto de `/api/live` al acabar la P3 (`E2eDatos.feedP3`), servida como del feed: 22 coches,
// 75 stints en 40 juegos (9 ya usados al montarlos, 35 pasos por boxes dentro de un juego) y la
// vuelta más alta en la 23.
async function showFeed(page: Page, table: unknown): Promise<Locator> {
  await openDashboard(page);
  await page.route('**/api/live', (route) =>
    route.fulfill({
      contentType: 'application/json;charset=utf-8',
      headers: { 'X-Data-Source': 'feed', 'X-Data-Origin': 'live', 'X-Data-Fetched-At': new Date().toISOString() },
      body: JSON.stringify(table),
    }),
  );
  await page.goto('/?retraso=0');
  return (await show(page, 'Strategy')).locator('.widget--tyre-strategy');
}

test('Tyre Strategy con el feed: una barra por juego, su total, el rayado, las muescas y el eje', async ({ page }) => {
  const card = await showFeed(page, feedP3);
  await expect(card.locator('.tyre-strategy__row')).toHaveCount(22);
  await expect(card.locator('.tyre-strategy__bar')).toHaveCount(40);
  await expect(card.locator('.tyre-strategy__bar--used')).toHaveCount(9);
  await expect(card.locator('.tyre-strategy__notch')).toHaveCount(35);
  await expect(card.locator('.tyre-strategy__grid')).toHaveCount(22 * 4);
  await expect(card.locator('.tyre-strategy__tick')).toHaveText(['0', '5', '10', '15', '20']);
  await expect(card.locator('.tyre-strategy__scale')).toHaveText('23 vueltas');
  const lec = card.locator('.tyre-strategy__row').filter({ hasText: '3 LEC' });
  await expect(lec.locator('.tyre-strategy__total')).toHaveText(['11', '12']);
  await expect(lec.locator('.tyre-strategy__bar').first()).toHaveAttribute(
    'title', 'MEDIUM · vueltas 1–11 (11) · nuevo, edad 0 · 3 salidas: 1–4, 5–8, 9–11');
  await expect(card.locator('.tyre-strategy__empty')).toHaveCount(0);
});

test('Tyre Strategy: la fila entra 6 px en el relleno y su contenido, 8 px más adentro que antes', async ({ page }) => {
  const card = await showFeed(page, feedP3);
  const left = async (l: Locator) => (await l.boundingBox())!.x;
  const c = await left(card);
  const row = card.locator('.tyre-strategy__row').filter({ hasText: '3 LEC' });
  expect(await left(row) - c).toBe(7);
  expect(await left(row.locator('.tyre-strategy__label')) - c).toBe(21);
  expect(await left(card.locator('.tyre-strategy__axis')) - c).toBe(7);
});

test('Tyre Strategy: cada fila, la pastilla de su piloto delante del nombre; quien no está en la tabla, en gris', async ({ page }) => {
  const card = await showFeed(page, feedP3);
  const rows = card.locator('.tyre-strategy__row');
  await expect(rows.locator('.tyre-strategy__label .group-pill')).toHaveCount(22);
  const inks = (driver: string) =>
    rows.filter({ hasText: driver }).locator('.group-pill > span')
      .evaluateAll((ss) => ss.map((s) => getComputedStyle(s).backgroundColor));
  expect(await inks('3 LEC')).toEqual(['rgb(237, 17, 49)', 'rgb(255, 255, 255)']);
  expect(await inks('22 BOT')).toEqual(['rgb(144, 144, 144)', 'rgb(110, 168, 255)']);
  const lec = rows.filter({ hasText: '3 LEC' });
  await expect(lec.locator('.tyre-strategy__label')).toHaveText('3 LEC');
  // La pista empieza donde acaba la etiqueta, en la fila y en el eje.
  const x = async (l: Locator) => (await l.boundingBox())!.x;
  expect(await x(lec.locator('.tyre-strategy__track'))).toBe(await x(card.locator('.tyre-strategy__axis .tyre-strategy__track')));
});

test('Tyre Strategy con el feed: un coche sin stints dice que aún no salió', async ({ page }) => {
  const table = { ...feedP3, liveStints: feedP3.liveStints.filter((s) => s.tsCar !== '77') };
  const card = await showFeed(page, table);
  const bot = card.locator('.tyre-strategy__row').filter({ hasText: '22 BOT' });
  await expect(bot.locator('.tyre-strategy__empty')).toHaveText('aún sin salir a pista');
  await expect(bot.locator('.tyre-strategy__bar')).toHaveCount(0);
  await expect(card.locator('.tyre-strategy__empty')).toHaveCount(1);
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
  const RACE = [[0, 0, 60, 90], [60, 0, 60, 85], [0, 90, 60, 30], [60, 90, 60, 30]];

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

  test('Constructores encima de Lap Comparison la baja, y Esc lo deja todo como estaba', async ({ page }) => {
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await carry(page, 3, 0, -88);
    await expect(page.locator('.widget-slot--held')).toHaveCount(1);
    await expect(page.locator('.canvas__layer:not(.canvas__layer--hidden) .canvas__target')).toBeVisible();
    await page.keyboard.press('Escape');
    await page.mouse.up();
    await page.waitForTimeout(400);
    expect(await units(page)).toEqual(RACE);

    await carry(page, 3, 0, -88);
    await page.mouse.up();
    await page.waitForTimeout(400);
    await expect(page.locator('.widget-slot--held')).toHaveCount(0);
    expect(await units(page)).toEqual([[0, 0, 60, 90], [60, 30, 60, 85], [0, 90, 60, 30], [60, 0, 60, 30]]);
  });

  test('Pilotos a la columna derecha no se deja: se marca y al soltar vuelve', async ({ page }) => {
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await carry(page, 2, 60, -55);
    await expect(page.locator('.widget-slot--blocked')).toHaveCount(1);
    await expect(page.locator('.canvas__layer:not(.canvas__layer--hidden) .canvas__target')).toBeHidden();
    await page.mouse.up();
    await page.waitForTimeout(400);
    expect(await units(page)).toEqual(RACE);
  });

  test('la esquina ◢ estira Lap Comparison y Constructores encoge', async ({ page }) => {
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    const layer = await page.locator('.canvas__layer').first().boundingBox();
    const slot = page.locator('.canvas__layer').first().locator(':scope > .widget-slot').nth(1);
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
    expect(await units(page)).toEqual([[0, 0, 60, 90], [60, 0, 60, 95], [0, 90, 60, 30], [60, 95, 60, 25]]);
  });

  test('fuera de edición el título no coge la tarjeta', async ({ page }) => {
    await carry(page, 3, 0, -88);
    await page.mouse.up();
    await page.waitForTimeout(400);
    await expect(page.locator('.widget-slot--held')).toHaveCount(0);
    expect(await units(page)).toEqual(RACE);
  });

  test.describe('el layout se recuerda', () => {
    // Race Overview con Constructores arriba del todo y Lap Comparison bajada a 30.
    const MOVED = [[0, 0, 60, 90], [60, 30, 60, 85], [0, 90, 60, 30], [60, 0, 60, 30]];
    const edit = (page: Page) => page.getByRole('button', { name: '✎ Editar layout' }).click();
    // La página escribe lo guardado una vuelta del bucle después del clic: se espera a esa vuelta,
    // o una recarga inmediata lo pierde.
    const finish = async (page: Page) => {
      await page.getByRole('button', { name: '✓ Terminar edición' }).click();
      await page.evaluate(() => new Promise((done) => setTimeout(done, 0)));
    };
    // Lo guardado de Race Overview, tal cual está en el navegador ('' si no hay nada).
    const stored = (page: Page) =>
      page.evaluate(() => localStorage.getItem('dashboardF1.layout.race-overview') ?? '');
    const question = (page: Page) => page.locator('.confirm--reset .confirm__question');
    const cancelQuestion = (page: Page) => page.locator('.confirm--cancel .confirm__question');
    const cancel = (page: Page) => page.getByRole('button', { name: '✗ Cancelar' });
    const yes = (page: Page) => page.getByRole('button', { name: 'Sí', exact: true });

    async function moveConstructors(page: Page): Promise<void> {
      await edit(page);
      await carry(page, 3, 0, -88);
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
      await yes(page).click();
      await page.waitForTimeout(400);
      expect(await units(page)).toEqual(RACE);
      await finish(page);
      await expect(reset).toBeHidden();
      await reload(page);
      expect(await units(page)).toEqual(RACE);
    });

    test('«Restablecer» no pregunta si lo que se ve ya es el de fábrica', async ({ page }) => {
      const reset = page.getByRole('button', { name: '↺ Restablecer' });
      await edit(page);
      await reset.click();
      await expect(question(page)).toBeHidden();
      await expect(reset).toBeVisible();
      expect(await units(page)).toEqual(RACE);
    });

    test('los grupos guardados se conservan; «Restablecer» dice cuántos quita, y «Cancelar» los devuelve', async ({ page }) => {
      test.setTimeout(45_000);
      const reset = page.getByRole('button', { name: '↺ Restablecer' });
      // Race Overview de fábrica con «Leclerc» en Live Timing y «Contra P1» sin tarjetas.
      const ids = ['live-timing', 'lap-comparison', 'driver-stats', 'constructor-stats'];
      const seeded = JSON.stringify({
        savedCards: RACE.map(([x, y, w, h], i) => ({
          savedId: ids[i], savedX: x, savedY: y, savedW: w, savedH: h,
          ...(i === 0 ? { savedGroups: ['g1'] } : {}),
        })),
        savedLayoutGroups: [
          { groupId: 'g1', groupName: 'Leclerc', groupDrivers: ['LEC'], groupSession: null },
          { groupId: 'g2', groupName: 'Contra P1', groupDrivers: [], groupSession: 'FP1' },
        ],
      });
      await page.evaluate((s) => localStorage.setItem('dashboardF1.layout.race-overview', s), seeded);
      await reload(page);
      expect(await units(page)).toEqual(RACE);
      await expect(page.getByRole('button', { name: 'Race Overview', exact: true })).toBeVisible();

      await edit(page);
      await finish(page);
      const kept = JSON.parse(await stored(page));
      expect(kept.savedLayoutGroups.map((g: { groupName: string }) => g.groupName)).toEqual(['Leclerc', 'Contra P1']);
      expect(kept.savedCards[0].savedGroups).toEqual(['g1']);

      await edit(page);
      await reset.click();
      await expect(question(page)).toContainText('¿Volver a la configuración predeterminada? Se quitan 2 grupos.');
      await yes(page).click();
      await cancel(page).click();
      await yes(page).click();
      await edit(page);
      await reset.click();
      await expect(question(page)).toContainText('Se quitan 2 grupos.');
      await yes(page).click();
      await finish(page);
      const after = await stored(page);
      expect(after.startsWith('[')).toBe(true);
      expect(after).not.toContain('Group');
    });

    test('«No», y un clic fuera de la pregunta, no restablecen', async ({ page }) => {
      const reset = page.getByRole('button', { name: '↺ Restablecer' });
      await moveConstructors(page);
      await reset.click();
      await expect(question(page)).toBeVisible();
      await expect(reset).toBeHidden();
      await page.getByRole('button', { name: 'No', exact: true }).click();
      await expect(question(page)).toBeHidden();
      await expect(reset).toBeVisible();
      expect(await units(page)).toEqual(MOVED);

      await reset.click();
      await expect(question(page)).toBeVisible();
      await finish(page);
      await expect(question(page)).toBeHidden();
      await reload(page);
      expect(await units(page)).toEqual(MOVED);
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
      await yes(page).click();
      await expect(body).not.toHaveClass(right);
      await finish(page);
      await reload(page);
      await expect(body).not.toHaveClass(right);
    });

    test('«Cancelar» sin nada cambiado sale sin preguntar, y el imán vuelve como estaba', async ({ page }) => {
      await edit(page);
      await page.getByRole('button', { name: '⊞ Imán ✓', exact: true }).click();
      await expect(page.getByRole('button', { name: '⊞ Imán', exact: true })).toBeVisible();
      await cancel(page).click();
      await expect(cancelQuestion(page)).toBeHidden();
      await expect(page.getByRole('button', { name: '✎ Editar layout' })).toBeVisible();
      await edit(page);
      await expect(page.getByRole('button', { name: '⊞ Imán ✓', exact: true })).toBeVisible();
    });

    test('«Cancelar» pregunta, y con «Sí» devuelve los dos layouts a como estaban sin guardar nada', async ({ page }) => {
      const body = page.locator('.comparison__body');
      const right = /comparison__body--control-right/;
      await moveConstructors(page);
      await finish(page);

      await edit(page);
      await page.getByRole('button', { name: '↺ Restablecer' }).click();
      await yes(page).click();
      await page.waitForTimeout(400);
      expect(await units(page)).toEqual(RACE);
      await page.locator('.comparison__swap').click();
      await expect(body).toHaveClass(right);
      await page.getByRole('button', { name: 'Qualy', exact: true }).click();

      await cancel(page).click();
      await expect(cancelQuestion(page)).toBeVisible();
      await page.getByRole('button', { name: 'No', exact: true }).click();
      await expect(cancelQuestion(page)).toBeHidden();
      await expect(page.getByRole('button', { name: '✓ Terminar edición' })).toBeVisible();

      await cancel(page).click();
      await yes(page).click();
      await expect(page.getByRole('button', { name: '✎ Editar layout' })).toBeVisible();
      await page.getByRole('button', { name: 'Race Overview', exact: true }).click();
      await page.waitForTimeout(400);
      expect(await units(page)).toEqual(MOVED);
      await expect(body).not.toHaveClass(right);
      await reload(page);
      expect(await units(page)).toEqual(MOVED);
      await expect(body).not.toHaveClass(right);
    });

    test('la banda y el modo de Lap Comparison se recuerdan al pulsar, fuera de la edición', async ({ page }) => {
      const row = page.locator('.comparison__frontiers');
      const pieces = page.locator('.comparison__band-piece');
      const modes = page.locator('select.comparison__modes');
      await expect(row).toBeVisible();
      await expect(pieces).toHaveCount(0);
      await row.click();
      await expect(pieces.first()).toBeVisible();
      await modes.selectOption('values');
      // Lo elegido fuera de la edición se escribe un fotograma después: se espera a verlo guardado.
      await expect.poll(() => stored(page)).toContain('"savedMode":"values"');
      await reload(page);
      await expect(pieces.first()).toBeVisible();
      await expect(modes).toHaveValue('values');
    });

    test('«Gráficas ▾» elige las gráficas de las trazas, la última no se desmarca y se recuerdan', async ({ page }) => {
      const entry = (car: string, driver: string, lap: string, sectors: number[]) => ({
        ceCar: car, ceDriver: driver, ceLap: lap, cePart: null, ceSectors: sectors, ceFrontiers: null, ceTrace: [],
      });
      const traced = {
        lcEntries: [entry('16', 'LEC', '1:35.202', [30.1, 35.0, 30.102]), entry('1', 'NOR', '1:36.282', [30.426, 35.6, 30.256])],
        lcSamples: 100,
        lcNotice: '',
      };
      await page.route((url) => url.pathname === '/api/comparison', (route) => route.fulfill({ json: traced }));
      const c = page.locator('.canvas__layer:not(.canvas__layer--hidden) .widget--comparison');
      const type = c.locator('select.comparison__type');
      const menu = c.locator('.comparison__charts');
      const rows = () =>
        c.locator('.comparison__traces--row').evaluateAll((es) => es.map((e) => e.getAttribute('data-channel')));
      await type.selectOption({ label: 'Telemetría comparativa' });
      await expect.poll(rows).toEqual(['speed', 'throttle', 'brake']);
      await menu.getByRole('button', { name: 'Gráficas ▾' }).click();
      await menu.getByLabel('Velocidad').uncheck();
      await menu.getByLabel('Acelerador').uncheck();
      await expect.poll(rows).toEqual(['brake']);
      await expect(menu.getByLabel('Freno')).toBeChecked();
      await expect(menu.getByLabel('Freno')).toBeDisabled();
      await expect.poll(() => stored(page)).toContain('"savedCharts":["brake"]');
      await reload(page);
      // El tipo no se guarda: se vuelve a elegir, y las gráficas son las guardadas.
      await type.selectOption({ label: 'Telemetría comparativa' });
      await expect.poll(rows).toEqual(['brake']);
    });

    test('con una sola gráfica que no es la velocidad, la gráfica arriba, la leyenda y los pilotos con todas sus vueltas debajo', async ({ page }) => {
      const entry = (car: string, driver: string, lap: string, sectors: number[]) => ({
        ceCar: car, ceDriver: driver, ceLap: lap, cePart: null, ceSectors: sectors, ceFrontiers: null, ceTrace: [],
      });
      const traced = {
        lcEntries: [
          entry('16', 'LEC', '1:35.202', [30.1, 35.0, 30.102]),
          entry('1', 'NOR', '1:36.282', [30.426, 35.6, 30.256]),
          entry('81', 'PIA', '1:36.500', [30.5, 35.7, 30.3]),
        ],
        lcSamples: 100,
        lcNotice: '',
      };
      await page.route((url) => url.pathname === '/api/comparison', (route) => route.fulfill({ json: traced }));
      const c = page.locator('.canvas__layer:not(.canvas__layer--hidden) .widget--comparison');
      const main = c.locator('.comparison__main');
      const menu = c.locator('.comparison__charts');
      const laps = c.locator('.comparison__lap');
      const top = (s: string) => c.locator(s).first().evaluate((e) => e.getBoundingClientRect().top);
      const bottom = (s: string) => c.locator(s).first().evaluate((e) => e.getBoundingClientRect().bottom);
      await c.locator('select.comparison__type').selectOption({ label: 'Telemetría comparativa' });
      await expect(laps).toHaveCount(2);
      await expect(main).not.toHaveClass(/comparison__main--first/);
      await menu.getByRole('button', { name: 'Gráficas ▾' }).click();
      await menu.getByLabel('Velocidad').uncheck();
      await menu.getByLabel('Acelerador').uncheck();
      await expect(main).toHaveClass(/comparison__main--(side|below)/);
      await expect(laps).toHaveCount(3);
      expect(await bottom('.comparison__plot')).toBeLessThanOrEqual(await top('.comparison__keys'));
      expect(await bottom('.comparison__keys')).toBeLessThanOrEqual(await top('.comparison__lap'));
      await menu.getByLabel('Velocidad').check();
      await expect(main).not.toHaveClass(/comparison__main--first/);
      await expect(laps).toHaveCount(2);
    });

    test('«Restablecer» devuelve la banda y el modo a los de fábrica, y «Cancelar» a como estaban', async ({ page }) => {
      const pieces = page.locator('.comparison__band-piece');
      const modes = page.locator('select.comparison__modes');
      await page.locator('.comparison__frontiers').click();
      await modes.selectOption('values');
      await expect(pieces.first()).toBeVisible();

      await edit(page);
      await page.getByRole('button', { name: '↺ Restablecer' }).click();
      await yes(page).click();
      await expect(pieces).toHaveCount(0);
      // «Eje y valores» se enseña como «Solo eje» si sus dos líneas no caben.
      await expect(modes).not.toHaveValue('values');

      await cancel(page).click();
      await yes(page).click();
      await expect(pieces.first()).toBeVisible();
      await expect(modes).toHaveValue('values');
      await reload(page);
      await expect(pieces.first()).toBeVisible();
      await expect(modes).toHaveValue('values');
    });

    test('con lo guardado que no encajó, la banda no se recuerda hasta terminar una edición', async ({ page }) => {
      test.setTimeout(45_000);
      const pieces = page.locator('.comparison__band-piece');
      await page.evaluate(() => localStorage.setItem('dashboardF1.layout.race-overview', '[]'));
      await reload(page);
      await page.locator('.comparison__frontiers').click();
      await expect(pieces.first()).toBeVisible();
      await reload(page);
      await expect(pieces).toHaveCount(0);

      await page.locator('.comparison__frontiers').click();
      await edit(page);
      await finish(page);
      await reload(page);
      await expect(pieces.first()).toBeVisible();
    });

    test('«Cancelar» devuelve el asterisco y la nota del guardado que no encajó', async ({ page }) => {
      await page.evaluate(() => localStorage.setItem('dashboardF1.layout.race-overview', '[]'));
      await reload(page);
      const noted = page.getByRole('button', { name: 'Race Overview*', exact: true });
      await expect(noted).toBeVisible();
      await edit(page);
      await expect(noted).toHaveCount(0);
      await cancel(page).click();
      await expect(noted).toBeVisible();
      await expect(page.locator('.layout-note--open')).toHaveCount(1);
    });

    test('lo guardado que no encaja: el de fábrica, con asterisco y nota hasta terminar una edición', async ({ page }) => {
      test.setTimeout(45_000);
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
      await expect(note).toContainText('Race Overview y Qualy volvieron a la configuración predeterminada');
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

test.describe('la fila de grupos', () => {
  test.beforeEach(async ({ page }) => {
    await openDashboard(page);
  });

  const layer = (page: Page) => page.locator('.canvas__layer:not(.canvas__layer--hidden)');
  const row = (page: Page, card: string) => layer(page).locator(`.widget--${card} .group-row`);
  const stored = (page: Page) =>
    page.evaluate(() => localStorage.getItem('dashboardF1.layout.race-overview') ?? '');

  test('solo en edición, y Constructores sin ella', async ({ page }) => {
    await expect(page.locator('.widget--comparison')).toBeVisible();
    await expect(row(page, 'live-timing')).toBeHidden();
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await expect(row(page, 'live-timing')).toBeVisible();
    await expect(row(page, 'driver-stats')).toBeVisible();
    await expect(layer(page).locator('.widget--constructor-stats .group-row')).toHaveCount(0);
  });

  test('crear, meter otra tarjeta, guardar al terminar; sacar y borrar preguntan en la fila', async ({ page }) => {
    test.setTimeout(45_000);
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    const live = row(page, 'live-timing');
    await live.getByRole('button', { name: '+ Grupo' }).click();
    const form = layer(page).locator('.widget--live-timing .group-form');
    const create = form.getByRole('button', { name: 'Crear grupo' });
    await expect(create).toBeDisabled();
    await form.locator('.group-tag', { hasText: 'LEC' }).click();
    await expect(form.locator('.group-form__name')).toHaveValue('Leclerc');
    await expect(create).toBeEnabled();
    await create.click();
    await expect(live.locator('.group-chip')).toHaveText(['Leclerc✕']);

    const lap = row(page, 'comparison');
    await lap.getByRole('button', { name: '+ Grupo' }).click();
    await layer(page).locator('.widget--comparison .group-menu__item', { hasText: 'Leclerc' }).click();
    await page.locator('.group-backdrop').click({ position: { x: 5, y: 5 } });
    await expect(lap.locator('.group-chip')).toHaveText(['Leclerc✕']);

    await page.getByRole('button', { name: '✓ Terminar edición' }).click();
    await page.evaluate(() => new Promise((done) => setTimeout(done, 0)));
    const kept = JSON.parse(await stored(page));
    expect(kept.savedLayoutGroups.map((g: { groupName: string }) => g.groupName)).toEqual(['Leclerc']);
    await page.reload();
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await expect(live.locator('.group-chip')).toHaveText(['Leclerc✕']);

    await live.locator('.group-chip__out').click();
    await expect(live).toContainText('¿Sacar «Live Timing» de «Leclerc»?');
    await live.getByRole('button', { name: 'Sacar' }).click();
    await expect(live.locator('.group-chip')).toHaveCount(0);
    await expect(lap.locator('.group-chip')).toHaveCount(1);

    await lap.locator('.group-chip__open').click();
    const lapForm = layer(page).locator('.widget--comparison .group-form');
    await expect(lapForm.locator('h4')).toHaveText('Editar «Leclerc»');
    await lapForm.locator('.group-tag', { hasText: 'NOR' }).click();
    await expect(lapForm.locator('.group-form__name')).toHaveValue('Leclerc y Norris');
    await lapForm.locator('.group-tag', { hasText: 'NOR' }).click();
    await expect(lapForm.locator('.group-form__name')).toHaveValue('Leclerc');
    await lapForm.getByRole('button', { name: 'Borrar el grupo' }).click();
    await expect(lap).toContainText('¿Borrar «Leclerc»? Sale de esta tarjeta.');
    await lap.getByRole('button', { name: 'Borrar' }).click();
    await expect(lap.locator('.group-chip')).toHaveCount(0);
    await live.getByRole('button', { name: '+ Grupo' }).click();
    await expect(form.locator('.group-form__name')).toHaveValue('');
  });

  test('fuera de la edición, un punto por piloto y la etiqueta de sesión; destacadas solo sus filas', async ({ page }) => {
    const seeded = JSON.stringify({
      savedCards: [
        { savedId: 'live-timing', savedX: 0, savedY: 0, savedW: 60, savedH: 90, savedGroups: ['g1', 'g2'] },
        { savedId: 'lap-comparison', savedX: 60, savedY: 0, savedW: 60, savedH: 85 },
        { savedId: 'driver-stats', savedX: 0, savedY: 90, savedW: 60, savedH: 30, savedGroups: ['g1'] },
        { savedId: 'constructor-stats', savedX: 60, savedY: 90, savedW: 60, savedH: 30 },
      ],
      savedLayoutGroups: [
        { groupId: 'g1', groupName: 'Leclerc y Norris', groupDrivers: ['LEC', 'NOR'], groupSession: null },
        { groupId: 'g2', groupName: 'Contra P1', groupDrivers: [], groupSession: 'FP1' },
      ],
    });
    await page.evaluate((s) => localStorage.setItem('dashboardF1.layout.race-overview', s), seeded);
    await page.goto('/?retraso=0');
    const dots = layer(page).locator('.widget--live-timing .group-dots');
    await expect(dots).toHaveAttribute('title', 'Grupos: Leclerc y Norris · Contra P1');
    await expect(dots.locator('.group-dot')).toHaveCount(2);
    await expect(dots.locator('.group-session-tag')).toHaveText('P1');
    await expect(layer(page).locator('.widget--comparison .group-dots')).toHaveCount(0);

    // Cada tabla: con estilo, justo las filas de LEC y NOR; la clave en la columna `col`.
    const styled = (card: string, col: number) =>
      layer(page).locator(`.widget--${card} tbody tr`).evaluateAll(
        (rows, c) => rows.map((r) => [r.children[c]?.textContent ?? '', r.hasAttribute('style')] as [string, boolean]),
        col,
      );
    for (const [card, col] of [['live-timing', 1], ['driver-stats', 1]] as const) {
      await expect(layer(page).locator(`.widget--${card} tbody tr`).first()).toBeAttached();
      const rows = await styled(card, col);
      expect(rows.length).toBeGreaterThan(0);
      expect(rows.filter(([, s]) => s).map(([c]) => c).sort())
        .toEqual(rows.map(([c]) => c).filter((c) => c === 'LEC' || c === 'NOR').sort());
    }

    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await expect(layer(page).locator('.group-dots')).toHaveCount(0);
  });

  test('Live Timing con un grupo que suma la P1: una cifra por sesión, cada una con su etiqueta y su morado', async ({ page }) => {
    const seeded = JSON.stringify({
      savedCards: [
        { savedId: 'live-timing', savedX: 0, savedY: 0, savedW: 60, savedH: 90, savedGroups: ['g1'] },
        { savedId: 'lap-comparison', savedX: 60, savedY: 0, savedW: 60, savedH: 85 },
        { savedId: 'driver-stats', savedX: 0, savedY: 90, savedW: 60, savedH: 30 },
        { savedId: 'constructor-stats', savedX: 60, savedY: 90, savedW: 60, savedH: 30 },
      ],
      savedLayoutGroups: [{ groupId: 'g1', groupName: 'Contra P1', groupDrivers: [], groupSession: 'FP1' }],
    });
    // La P1: LEC, más rápido que en la P3 (1:33.302); NOR, más lento (1:33.000).
    const p1 = {
      ...feedP3,
      liveRows: feedP3.liveRows.map((r) =>
        r.ltDriver === 'LEC' ? { ...r, ltBestLap: '1:32.900' } : r.ltDriver === 'NOR' ? { ...r, ltBestLap: '1:34.000' } : r),
    };
    for (const [key, table] of [['2026-21-FP3', feedP3], ['2026-21-FP1', p1]] as const) {
      await page.route(
        (url) => url.pathname === '/api/live' && url.searchParams.get('session') === key,
        (route) => route.fulfill({
          contentType: 'application/json;charset=utf-8',
          headers: { 'X-Data-Source': 'feed', 'X-Data-Origin': 'cached', 'X-Data-Fetched-At': new Date().toISOString() },
          body: JSON.stringify(table),
        }),
      );
    }
    await page.evaluate((s) => localStorage.setItem('dashboardF1.layout.race-overview', s), seeded);
    await page.goto('/?retraso=0&sesion=2026-21-FP3');
    const best = (driver: string) =>
      layer(page).locator('.widget--live-timing tbody tr', { hasText: driver }).locator('td.live-timing__best');
    const figs = (driver: string) => best(driver).locator('.live-timing__fig');
    await expect(figs('LEC')).toHaveText(['1:33.302P3', '1:32.900P1']);
    await expect(figs('LEC').nth(1).locator('.live-timing__from--other')).toHaveText('P1');
    await expect(figs('NOR')).toHaveText(['1:33.000P3', '1:34.000P1']);
    await expect(figs('NOR').nth(0).locator('.live-timing__from--here')).toHaveText('P3');
    // El morado normal, en la más rápida de la sesión que se ve; el tenue, en la más rápida de la P1.
    await expect(figs('NOR').nth(0)).toHaveClass(/live-timing__best--part/);
    await expect(best('NOR')).not.toHaveClass(/live-timing__best--part/);
    await expect(figs('LEC').nth(1)).toHaveClass(/live-timing__fig--other-fastest/);
    await expect(layer(page).locator('.live-timing__fig--other-fastest')).toHaveCount(1);
  });

  test('Live Timing con otra sesión: lado a lado y las etiquetas en la cabecera si cabe; si no, una debajo de otra', async ({ page }) => {
    const seeded = JSON.stringify({
      savedCards: [
        { savedId: 'live-timing', savedX: 0, savedY: 0, savedW: 60, savedH: 90, savedGroups: ['g1'] },
        { savedId: 'lap-comparison', savedX: 60, savedY: 0, savedW: 60, savedH: 85 },
        { savedId: 'driver-stats', savedX: 0, savedY: 90, savedW: 60, savedH: 30 },
        { savedId: 'constructor-stats', savedX: 60, savedY: 90, savedW: 60, savedH: 30 },
      ],
      savedLayoutGroups: [{ groupId: 'g1', groupName: 'Contra P1', groupDrivers: [], groupSession: 'FP1' }],
    });
    for (const key of ['2026-21-FP3', '2026-21-FP1']) {
      await page.route(
        (url) => url.pathname === '/api/live' && url.searchParams.get('session') === key,
        (route) => route.fulfill({
          contentType: 'application/json;charset=utf-8',
          headers: { 'X-Data-Source': 'feed', 'X-Data-Origin': 'cached', 'X-Data-Fetched-At': new Date().toISOString() },
          body: JSON.stringify(feedP3),
        }),
      );
    }
    await page.setViewportSize({ width: 1280, height: 720 });
    await page.evaluate((s) => localStorage.setItem('dashboardF1.layout.race-overview', s), seeded);
    await page.goto('/?retraso=0&sesion=2026-21-FP3');
    const table = layer(page).locator('.widget--live-timing table.live-timing');
    const heads = table.locator('th.live-timing__best .live-timing__head');
    const tags = table.locator('tbody tr', { hasText: 'LEC' }).locator('td.live-timing__best .live-timing__from');
    await expect(table.locator('tbody tr', { hasText: 'LEC' }).locator('.live-timing__fig')).toHaveCount(2, { timeout: 30000 });
    await expect(table).toHaveClass(/live-timing--side/);
    await expect(heads).toHaveText(['P3', 'P1']);
    await expect(heads.first()).toBeVisible();
    await expect(tags.first()).toBeHidden();
    await expect(table.locator('th.live-timing__best')).toHaveCSS('text-align', 'center');
    await page.setViewportSize({ width: 1000, height: 720 });
    await expect(table).not.toHaveClass(/live-timing--side/);
    await expect(heads.first()).toBeHidden();
    await expect(tags).toHaveText(['P3', 'P1']);
    await expect(tags.first()).toBeVisible();
  });

  // Las Vegas, la ronda 21 de 2026; en 2025 fue la 22, y en 2022 no se corrió.
  const vegasRounds = [{ crYear: 2025, crRound: 22, crName: 'Las Vegas Grand Prix' }, { crYear: 2024, crRound: 22, crName: 'Las Vegas Grand Prix' }, { crYear: 2023, crRound: 21, crName: 'Las Vegas Grand Prix' }];
  const json = (body: unknown) => (route: Route) =>
    route.fulfill({
      contentType: 'application/json;charset=utf-8',
      headers: { 'X-Data-Source': 'feed', 'X-Data-Origin': 'cached', 'X-Data-Fetched-At': new Date().toISOString() },
      body: JSON.stringify(body),
    });
  const api = (path: string, session: string) => (url: URL) =>
    url.pathname === path && url.searchParams.get('session') === session;

  test('otra temporada en el formulario: el desplegable, su pista y el nombre', async ({ page }) => {
    const codes = ['FP1', 'FP2', 'FP3', 'Q', 'R'];
    const season = [{
      raceRound: 21, raceName: 'Las Vegas Grand Prix',
      raceSessions: codes.map((c, i) => ({ ssnKey: `2026-21-${c}`, ssnStart: 1700000000 + i * 3600 })),
    }];
    await page.route((url) => url.pathname === '/api/season', json(season));
    await page.route(api('/api/circuit-seasons', '2026-21-FP3'), json(vegasRounds));
    await page.route(api('/api/live', '2026-21-FP3'), json(feedP3));
    await page.goto('/?retraso=0&sesion=2026-21-FP3');
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await row(page, 'live-timing').getByRole('button', { name: '+ Grupo' }).click();
    const form = layer(page).locator('.widget--live-timing .group-form');
    await form.locator('.group-tag', { hasText: 'LEC' }).click();
    const seasonSelect = form.locator('.group-form__season');
    await expect(seasonSelect.locator('option')).toHaveCount(1 + 5 + 8);
    await expect(seasonSelect.locator('option', { hasText: 'Las Vegas 2022 · no se corrió' })).toBeDisabled();
    await expect(form.getByRole('button', { name: 'FP3', exact: true })).toBeDisabled();
    await seasonSelect.selectOption({ label: '1 año antes' });
    await expect(form.getByRole('button', { name: 'FP3', exact: true })).toBeEnabled();
    await form.getByRole('button', { name: 'Q', exact: true }).click();
    await expect(form.locator('.group-form__hint').first())
      .toHaveText('De este circuito, Las Vegas 2025. Viendo otro circuito, la de ese circuito 1 año antes.');
    await expect(form.locator('.group-form__name')).toHaveValue('LEC contra Q, 1 año antes');
    await form.getByRole('button', { name: 'Crear grupo' }).click();
    await page.getByRole('button', { name: '✓ Terminar edición' }).click();
    await page.evaluate(() => new Promise((done) => setTimeout(done, 0)));
    const kept = JSON.parse(await stored(page));
    expect(kept.savedLayoutGroups.map((g: { groupSession: string }) => g.groupSession)).toEqual(['Q@-1']);
  });

  test('otra temporada con dos GP el mismo año en el circuito: una entrada por cada uno, y se guarda cuál', async ({ page }) => {
    const codes = ['FP1', 'FP2', 'FP3', 'Q', 'R'];
    const season = [{
      raceRound: 21, raceName: 'Las Vegas Grand Prix',
      raceSessions: codes.map((c, i) => ({ ssnKey: `2026-21-${c}`, ssnStart: 1700000000 + i * 3600 })),
    }];
    const rounds = [
      { crYear: 2025, crRound: 22, crName: 'Las Vegas Grand Prix' },
      { crYear: 2021, crRound: 8, crName: 'Styrian Grand Prix' },
      { crYear: 2021, crRound: 9, crName: 'Austrian Grand Prix' },
    ];
    await page.route((url) => url.pathname === '/api/season', json(season));
    await page.route(api('/api/circuit-seasons', '2026-21-FP3'), json(rounds));
    await page.route(api('/api/live', '2026-21-FP3'), json(feedP3));
    await page.goto('/?retraso=0&sesion=2026-21-FP3');
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    await row(page, 'live-timing').getByRole('button', { name: '+ Grupo' }).click();
    const form = layer(page).locator('.widget--live-timing .group-form');
    const seasonSelect = form.locator('.group-form__season');
    await expect(seasonSelect.locator('option')).toHaveCount(1 + 6 + 9);
    await expect(seasonSelect.locator('option', { hasText: '5 años antes' }))
      .toHaveText(['5 años antes · Styrian Grand Prix', '5 años antes · Austrian Grand Prix']);
    await seasonSelect.selectOption({ label: '2021 · Austrian Grand Prix' });
    await form.getByRole('button', { name: 'Q', exact: true }).click();
    await expect(form.locator('.group-form__hint').first())
      .toHaveText('De este circuito, Austrian Grand Prix 2021. Viendo otro circuito, la de ese circuito en 2021.');
    await form.getByRole('button', { name: 'Crear grupo' }).click();
    await page.getByRole('button', { name: '✓ Terminar edición' }).click();
    await page.evaluate(() => new Promise((done) => setTimeout(done, 0)));
    const kept = JSON.parse(await stored(page));
    expect(kept.savedLayoutGroups.map((g: { groupSession: string }) => g.groupSession)).toEqual(['Q@2021#2']);
  });

  test('Live Timing con otra temporada: la del mismo circuito, con su año en la etiqueta', async ({ page }) => {
    const seeded = JSON.stringify({
      savedCards: [
        { savedId: 'live-timing', savedX: 0, savedY: 0, savedW: 60, savedH: 90, savedGroups: ['g1'] },
        { savedId: 'lap-comparison', savedX: 60, savedY: 0, savedW: 60, savedH: 85 },
        { savedId: 'driver-stats', savedX: 0, savedY: 90, savedW: 60, savedH: 30 },
        { savedId: 'constructor-stats', savedX: 60, savedY: 90, savedW: 60, savedH: 30 },
      ],
      savedLayoutGroups: [{ groupId: 'g1', groupName: 'Contra P3 2025', groupDrivers: [], groupSession: 'FP3@-1' }],
    });
    const lastYear = {
      ...feedP3,
      liveRows: feedP3.liveRows.map((r) => (r.ltDriver === 'LEC' ? { ...r, ltBestLap: '1:32.900' } : r)),
    };
    await page.route(api('/api/circuit-seasons', '2026-21-FP3'), json(vegasRounds));
    await page.route(api('/api/live', '2026-21-FP3'), json(feedP3));
    await page.route(api('/api/live', '2025-22-FP3'), json(lastYear));
    await page.evaluate((s) => localStorage.setItem('dashboardF1.layout.race-overview', s), seeded);
    await page.goto('/?retraso=0&sesion=2026-21-FP3');
    const best = (driver: string) =>
      layer(page).locator('.widget--live-timing tbody tr', { hasText: driver }).locator('td.live-timing__best');
    await expect(best('LEC').locator('.live-timing__fig')).toHaveText(['1:33.302P3', '1:32.900P3 2025']);
    await expect(best('LEC').locator('.live-timing__from--other')).toHaveText('P3 2025');
    await expect(best('NOR').locator('.live-timing__from--here')).toHaveText('P3');
    await expect(layer(page).locator('.widget--live-timing .group-dots .group-session-tag')).toHaveText('P3 2025');
  });
});

test.describe('Lap Comparison y la cuenta de F1TV', () => {
  // La hora del aviso es la del navegador: fijarla hace que la prueba diga también si la
  // zona se lee.
  test.use({ timezoneId: 'America/Mexico_City' });

  const until = '2026-11-07T23:06:58Z';
  const entry = (car: string, driver: string, lap: string, sectors: number[]) => ({
    ceCar: car, ceDriver: driver, ceLap: lap, cePart: null, ceSectors: sectors, ceFrontiers: null, ceTrace: [],
  });
  const comparison = {
    lcEntries: [entry('16', 'LEC', '1:35.202', [30.1, 35.0, 30.102]), entry('1', 'NOR', '1:36.282', [30.426, 35.6, 30.256])],
    lcSamples: 0,
    lcNotice: '',
  };

  // La tarjeta con la cuenta, la procedencia de la comparación y la comparación que se le dan.
  async function card(page: Page, account: object, origin: Record<string, string>, body: object = comparison): Promise<Locator> {
    await openDashboard(page);
    await page.route('**/api/f1tv', (route) => route.fulfill({ json: account }));
    await page.route(
      (url) => url.pathname === '/api/comparison',
      (route) => route.fulfill({ contentType: 'application/json;charset=utf-8', headers: origin, body: JSON.stringify(body) }),
    );
    await page.goto('/?retraso=0');
    const c = page.locator('.canvas__layer:not(.canvas__layer--hidden) .widget--comparison');
    await expect(c.locator('.comparison__lap').first()).toBeVisible();
    return c;
  }

  test('caducada y con el ejemplo: el aviso encima de la gráfica, con el comando y sin la línea del pie', async ({ page }) => {
    const c = await card(page, { state: 'expired', until }, { 'X-Data-Origin': 'sample' });
    const notice = c.locator('.comparison__canvas .comparison__notice');
    await expect(notice).toContainText(
      'La cuenta de F1TV caducó el sáb 7 a las 17:06: las sesiones acabadas salen de ejemplo.');
    await expect(notice.locator('code')).toHaveText(['dashboardF1-f1tv']);
    await expect(notice).not.toContainText('reinicia');
    await expect(notice.getByRole('button', { name: 'Copiar' })).toBeVisible();
    await expect(c.locator('.comparison__account')).toHaveCount(0);
  });

  test('válida y con lo fresco: solo la línea del pie', async ({ page }) => {
    const c = await card(page, { state: 'valid', until }, { 'X-Data-Origin': 'fresh', 'X-Data-Source': 'fastf1' });
    await expect(c.locator('.comparison__account')).toHaveText('F1TV: vale hasta sáb 7, 17:06');
    await expect(c.locator('.comparison__account')).not.toHaveClass(/comparison__account--warn/);
    await expect(c.locator('.comparison__notice')).toHaveCount(0);
  });

  test('la línea del pie va debajo de la leyenda, sin pisarla, y dentro de la tarjeta', async ({ page }) => {
    const c = await card(page, { state: 'valid', until }, { 'X-Data-Origin': 'fresh', 'X-Data-Source': 'fastf1' });
    await expect(c.locator('.comparison__account')).toBeVisible();
    const legend = await c.locator('.comparison__legend').boundingBox();
    const account = await c.locator('.comparison__account').boundingBox();
    const widget = await c.boundingBox();
    expect(legend && account && widget).toBeTruthy();
    expect(account!.y).toBeGreaterThanOrEqual(legend!.y + legend!.height);
    expect(account!.y + account!.height).toBeLessThanOrEqual(widget!.y + widget!.height);
  });

  test('estrecha y en dos columnas, el desplegable de la vuelta no entra en la gráfica', async ({ page }) => {
    const c = await card(page, { state: 'valid', until }, { 'X-Data-Origin': 'fresh', 'X-Data-Source': 'fastf1' });
    await page.getByRole('button', { name: '✎ Editar layout' }).click();
    const slot = page.locator('.canvas__layer').first().locator(':scope > .widget-slot').nth(1);
    await slot.hover();
    const grip = await slot.locator('.widget-slot__grip').boundingBox();
    const before = await slot.boundingBox();
    if (!grip || !before) throw new Error('no se ve la esquina');
    // Hasta ~480 px de ancho: la tabla de mando, más estrecha que su fila de tiempos.
    const x = grip.x + grip.width / 2;
    const y = grip.y + grip.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x - (before.width - 480), y, { steps: 12 });
    await page.mouse.up();
    await expect(c.locator('.comparison__body--stacked')).toHaveCount(0);
    await expect.poll(async () => {
      const plot = await c.locator('.comparison__plot').boundingBox();
      const picks = await c.locator('.comparison__pick').evaluateAll((es) => es.map((e) => e.getBoundingClientRect().right));
      return plot && picks.length > 0 ? Math.max(...picks) - plot.x : NaN;
    }).toBeLessThanOrEqual(0);
  });

  test('válida y con lo guardado: el aviso de guardado, sin comando', async ({ page }) => {
    const c = await card(page, { state: 'valid', until },
      { 'X-Data-Origin': 'cached', 'X-Data-Source': 'fastf1', 'X-Data-Fetched-At': '2026-11-07T20:15:00Z' });
    const notice = c.locator('.comparison__canvas .comparison__notice');
    await expect(notice).toHaveText('Dato guardado: la fuente no responde ahora mismo (14:15)');
    await expect(notice.locator('code')).toHaveCount(0);
    await expect(c.locator('.comparison__account')).toHaveText('F1TV: vale hasta sáb 7, 17:06');
  });

  test('la telemetría incompleta: con trazas, el aviso con el % y la hora; en Delta por sectores, ninguno', async ({ page }) => {
    const gap = { ...comparison, lcSamples: 100, lcTelemetry: { coverage: 0.0421, retryAt: '2026-11-07T00:40:05Z' } };
    const c = await card(page, { state: 'valid', until }, { 'X-Data-Origin': 'fresh', 'X-Data-Source': 'fastf1' }, gap);
    await expect(c.locator('.comparison__notice')).toHaveCount(0);
    await c.locator('select', { has: page.locator('option', { hasText: 'Telemetría comparativa' }) })
      .selectOption({ label: 'Telemetría comparativa' });
    await expect(c.locator('.comparison__canvas .comparison__notice')).toHaveText(
      'Telemetría incompleta: cubre el 4 % de las vueltas. Se vuelve a pedir a las 18:40.');
  });
});

test.describe('Lap Comparison con 3 a 5 pilotos', () => {
  const entry = (car: string, driver: string, lap: string, sectors: number[]) => ({
    ceCar: car, ceDriver: driver, ceLap: lap, cePart: null, ceSectors: sectors, ceFrontiers: null, ceTrace: [],
  });
  const cars: Record<string, object> = {
    '16': entry('16', 'LEC', '1:35.202', [30.1, 35.0, 30.102]),
    '1': entry('1', 'NOR', '1:36.282', [30.426, 35.6, 30.256]),
    '3': entry('3', 'VER', '1:34.700', [29.9, 34.8, 30.0]),
    '63': entry('63', 'RUS', '1:35.300', [30.0, 35.1, 30.2]),
    '81': entry('81', 'PIA', '1:35.500', [30.2, 35.1, 30.2]),
    '44': entry('44', 'HAM', '1:35.600', [30.3, 35.1, 30.2]),
  };
  const grid = [
    { deNumber: '16', deCode: 'LEC', deTeam: 'Ferrari' },
    { deNumber: '1', deCode: 'NOR', deTeam: 'McLaren' },
    { deNumber: '3', deCode: 'VER', deTeam: 'Red Bull Racing' },
    { deNumber: '63', deCode: 'RUS', deTeam: 'Mercedes' },
    { deNumber: '81', deCode: 'PIA', deTeam: 'McLaren' },
    { deNumber: '44', deCode: 'HAM', deTeam: 'Ferrari' },
  ];

  // La tarjeta con esa parrilla y una comparación que responde a los coches pedidos, en su
  // orden; sin `drivers`, LEC contra NOR. Devuelve también los `drivers` de cada petición.
  async function card(page: Page, seeded?: string, laps = 2): Promise<{ c: Locator; asked: string[] }> {
    const asked: string[] = [];
    await openDashboard(page);
    if (seeded) await page.evaluate((s) => localStorage.setItem('dashboardF1.layout.race-overview', s), seeded);
    await page.route((url) => url.pathname === '/api/drivers', (route) => route.fulfill({ json: grid }));
    await page.route((url) => url.pathname === '/api/comparison', (route) => {
      const drivers = new URL(route.request().url()).searchParams.get('drivers') ?? '16,1';
      asked.push(drivers);
      return route.fulfill({ json: { lcEntries: drivers.split(',').map((d) => cars[d]), lcSamples: 0, lcNotice: '' } });
    });
    await page.goto('/?retraso=0');
    const c = page.locator('.canvas__layer:not(.canvas__layer--hidden) .widget--comparison');
    await expect(c.locator('.comparison__lap')).toHaveCount(laps);
    return { c, asked };
  }

  test('añadir, llevar al frente y quitar: una fila por piloto, una curva por cada uno y la fila de fronteras del frente', async ({ page }) => {
    const { c, asked } = await card(page);
    const tags = c.locator('.car-selector__tag');
    await expect(tags).toHaveText(['NOR']);
    await expect(c.locator('.car-selector__tag-x')).toHaveCount(0);

    await c.locator('select.car-selector__add').selectOption('3');
    await expect(c.locator('.comparison__lap .comparison__driver')).toHaveText(['LEC', 'NOR', 'VER']);
    expect(asked.at(-1)).toBe('16,1,3');
    await expect(tags).toHaveText(['NOR✕', 'VER✕']);
    await expect(c.locator('.comparison__key-curve')).toHaveText([/NOR: por encima/, /^\s*VER\s*$/]);
    await expect(c.locator('.comparison__frontier-value')).toHaveText([/0\.000/, /0\.326/, /0\.926/, /1\.080/]);

    await c.locator('.comparison__key-curve', { hasText: 'VER' }).click();
    await expect(c.locator('.comparison__key-curve--front')).toHaveText(/VER: por encima/);
    await expect(c.locator('.comparison__frontier-value')).toHaveText([/0\.000/, /0\.200/, /0\.400/, /0\.502/]);

    await c.locator('.car-selector__tag', { hasText: 'NOR' }).locator('.car-selector__tag-x').click();
    await expect(c.locator('.comparison__lap .comparison__driver')).toHaveText(['LEC', 'VER']);
    expect(asked.at(-1)).toBe('16,3');
    await expect(tags).toHaveText(['VER']);
  });

  test('con cinco no se ofrece añadir otro, aunque quede alguno libre', async ({ page }) => {
    const { c } = await card(page);
    for (const [car, code] of [['3', 'VER'], ['63', 'RUS'], ['81', 'PIA']]) {
      await c.locator('select.car-selector__add').selectOption(car);
      await expect(c.locator('.car-selector__tag', { hasText: code })).toBeVisible();
    }
    await expect(c.locator('.comparison__lap')).toHaveCount(5);
    await expect(c.locator('select.car-selector__add')).toHaveCount(0);
  });

  test('los pilotos del grupo entran detrás, tenues y «del grupo», y el que no cabe se avisa al final', async ({ page }) => {
    const seeded = JSON.stringify({
      savedCards: [
        { savedId: 'live-timing', savedX: 0, savedY: 0, savedW: 60, savedH: 90 },
        { savedId: 'lap-comparison', savedX: 60, savedY: 0, savedW: 60, savedH: 85, savedGroups: ['g1'] },
        { savedId: 'driver-stats', savedX: 0, savedY: 90, savedW: 60, savedH: 30 },
        { savedId: 'constructor-stats', savedX: 60, savedY: 90, savedW: 60, savedH: 30 },
      ],
      savedLayoutGroups: [
        { groupId: 'g1', groupName: 'Verstappen y Hamilton', groupDrivers: ['VER', 'LEC', 'HAM'], groupSession: null },
      ],
    });
    const { c, asked } = await card(page, seeded, 4);
    expect(asked.at(-1)).toBe('16,1,3,44');
    await expect(c.locator('.comparison__lap .comparison__driver')).toHaveText(['LEC', 'NOR', 'VER', 'HAM']);
    await expect(c.locator('.comparison__lap--group .comparison__driver')).toHaveText(['VER', 'HAM']);
    await expect(c.locator('.car-selector__tag')).toHaveText(['NOR']);
    await expect(c.locator('.comparison__key-curve')).toHaveText([/NOR: por encima/, /VER, del grupo/, /HAM, del grupo/]);

    for (const [car, code] of [['63', 'RUS'], ['81', 'PIA']]) {
      await c.locator('select.car-selector__add').selectOption(car);
      await expect(c.locator('.car-selector__tag', { hasText: code })).toBeVisible();
    }
    await expect(c.locator('.comparison__lap .comparison__driver')).toHaveText(['LEC', 'NOR', 'RUS', 'PIA', 'VER']);
    expect(asked.at(-1)).toBe('16,1,63,81,3');
    await expect(c.locator('.comparison__left-out')).toHaveText('· HAM, del grupo, no cabe');
  });
});
