// Writes capacitor.config.json from capacitor.config.base.json plus the deployment-specific hosts,
// which stay out of the repository:
//   1. environment variables RP_APP_URL and RP_AUTH_HOST (CI), else
//   2. app.local.json (gitignored, copy of app.local.example.json)
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const readJson = (name) => JSON.parse(readFileSync(join(root, name), 'utf8'));

let local = {};
if (existsSync(join(root, 'app.local.json'))) {
  local = readJson('app.local.json');
}
const appUrl = process.env.RP_APP_URL || local.appUrl;
const authHost = process.env.RP_AUTH_HOST || local.authHost;

if (!appUrl || !authHost) {
  console.error('Missing appUrl/authHost: copy app.local.example.json to app.local.json and fill it in,');
  console.error('or set RP_APP_URL and RP_AUTH_HOST.');
  process.exit(1);
}
if (!/^https:\/\/[^/]+\/?$/.test(appUrl)) {
  console.error(`appUrl must be an https origin like https://raid-planner.example.org, got: ${appUrl}`);
  process.exit(1);
}
if (!/^[a-z0-9.-]+$/i.test(authHost)) {
  console.error(`authHost must be a bare host name like keycloak.example.org, got: ${authHost}`);
  process.exit(1);
}

const config = readJson('capacitor.config.base.json');
config.server = {
  url: appUrl.replace(/\/$/, ''),
  allowNavigation: [authHost]
};
writeFileSync(join(root, 'capacitor.config.json'), JSON.stringify(config, null, 2) + '\n');
console.log(`capacitor.config.json written for ${config.server.url} (login via ${authHost})`);
