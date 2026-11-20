// Generates the iOS app icon and launch images from the web app's logo.
//   npm run icons
// Writes into ios/App/App/Assets.xcassets (AppIcon 1024x1024, Splash 2732x2732).
import sharp from 'sharp';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const logo = readFileSync(join(root, 'www', 'logo.svg'));
const assets = join(root, 'ios', 'App', 'App', 'Assets.xcassets');

// --rp-bg / --rp-surface-2 / --rp-primary-deep from the web app's styles.scss
const background = (size) => Buffer.from(`
<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">
  <defs>
    <radialGradient id="g" cx="50%" cy="38%" r="75%">
      <stop offset="0%" stop-color="#123257"/>
      <stop offset="60%" stop-color="#0b2545"/>
      <stop offset="100%" stop-color="#061933"/>
    </radialGradient>
  </defs>
  <rect width="100%" height="100%" fill="url(#g)"/>
</svg>`);

async function compose(size, logoWidth, flatBackground) {
  const mark = await sharp(logo, { density: 600 }).resize({ width: logoWidth }).png().toBuffer();
  const base = flatBackground
    ? sharp({ create: { width: size, height: size, channels: 3, background: '#061933' } })
    : sharp(background(size));
  return base.composite([{ input: mark, gravity: 'center' }]).flatten({ background: '#061933' }).removeAlpha();
}

// App Store icons must not have an alpha channel.
await (await compose(1024, 740, false)).png().toFile(join(assets, 'AppIcon.appiconset', 'AppIcon-512@2x.png'));

// Launch image: flat --rp-bg like the web view's background, so the hand-over is seamless.
const splash = await (await compose(2732, 640, true)).png().toBuffer();
for (const name of ['splash-2732x2732.png', 'splash-2732x2732-1.png', 'splash-2732x2732-2.png']) {
  await sharp(splash).toFile(join(assets, 'Splash.imageset', name));
}
console.log('Icons and splash written to', assets);
