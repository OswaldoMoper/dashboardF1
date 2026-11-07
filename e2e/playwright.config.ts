import { defineConfig, devices } from '@playwright/test';

// Tres procesos que se reparten las pruebas una a una, de las dos ventanas, y un
// reintento: una prueba que solo pasa al reintentar sale como «flaky», y ese aviso se lee.
export default defineConfig({
  testDir: '.',
  fullyParallel: true,
  workers: 3,
  retries: 1,
  reporter: 'list',
  use: {
    // El HAR está a nombre de :3000 (`dashboardF1-e2e-datos`).
    baseURL: 'http://localhost:3000',
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'edge-1912x914',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1912, height: 914 } },
    },
    {
      name: 'portatil-1280x720',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 720 } },
    },
  ],
});
