#!/bin/bash
# Prepara ~/FaroDemo: un proyecto web de ejemplo (Next.js simulado, git con cambios y un remoto)
# para grabar el vídeo de presentación sin datos reales. Se puede repetir.
set -euo pipefail
DEMO="${HOME:?}/FaroDemo"
rm -rf "${DEMO:?}"
mkdir -p "$DEMO"
export GIT_AUTHOR_NAME="Acme" GIT_AUTHOR_EMAIL="dev@acme.dev" GIT_COMMITTER_NAME="Acme" GIT_COMMITTER_EMAIL="dev@acme.dev"
export GIT_CONFIG_GLOBAL=/dev/null

APP="$DEMO/acme-web"
mkdir -p "$APP/src/app" "$APP/node_modules/.bin"
cat > "$APP/package.json" <<'JSON'
{
  "name": "acme-web",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "test": "node test.js",
    "lint": "next lint"
  }
}
JSON
cat > "$APP/node_modules/.bin/next" <<'JS'
#!/usr/bin/env node
// Imita `next dev`: el mismo mensaje y un servidor en el puerto 3000.
const http = require("http");
const port = Number(process.env.PORT || 3000);
const server = http.createServer((req, res) => res.end("<h1>Acme</h1>"));
server.on("error", (err) => {
  console.error(` ⨯ Failed to start server`);
  console.error(`Error: listen ${err.code}: address already in use :::${port}`);
  process.exit(1);
});
server.listen(port, () => {
  console.log(`   \x1b[1m\x1b[35m▲ Next.js 15.2.0\x1b[0m`);
  console.log(`   - Local:        http://localhost:${port}`);
  console.log(`   - Network:      http://192.168.1.42:${port}\n`);
  console.log(` \x1b[32m✓\x1b[0m Starting...`);
  setTimeout(() => console.log(` \x1b[32m✓\x1b[0m Ready in 1243ms`), 700);
  setTimeout(() => console.log(` \x1b[2m○ Compiling / ...\x1b[0m`), 1600);
  setTimeout(() => console.log(` \x1b[32m✓\x1b[0m Compiled / in 812ms \x1b[2m(512 modules)\x1b[0m`), 2300);
});
JS
chmod +x "$APP/node_modules/.bin/next"
cat > "$APP/test.js" <<'JS'
const { formatPrice, slugify } = require("./src/lib/price");
const checks = [["formatPrice(1999)", "19,99 €", formatPrice(1999)], ["slugify('Hola Mundo')", "hola-mundo", slugify("Hola Mundo")]];
let failed = 0;
for (const [name, expected, got] of checks) {
  if (expected === got) console.log(` \x1b[32m✓\x1b[0m ${name}`);
  else { failed++; console.log(` \x1b[31m✗\x1b[0m ${name}\n     esperado: ${expected}\n     recibido: ${got}`); }
}
console.log(`\n ${checks.length - failed} correctos, \x1b[31m${failed} fallido\x1b[0m`);
process.exit(failed ? 1 : 0);
JS
cat > "$APP/src/app/page.tsx" <<'TSX'
export default function Home() {
  return <main className="hero">Hola desde Acme</main>
}
TSX
cat > "$APP/src/app/layout.tsx" <<'TSX'
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="es"><body>{children}</body></html>
}
TSX
printf "# Acme Web\n\nLa web de Acme.\n" > "$APP/README.md"
printf "node_modules\n.next\n" > "$APP/.gitignore"

git init -q --bare -b main "$DEMO/.remote/acme-web.git"
cd "$APP"
git init -q -b main
git add -A && git commit -qm "Primera versión"
git remote add origin "$DEMO/.remote/acme-web.git"
git push -q -u origin main 2>/dev/null
mkdir -p src/lib
cat > src/lib/price.js <<'JS'
exports.formatPrice = (cents) => (cents / 100).toFixed(2) + " €";
exports.slugify = (text) => text.toLowerCase().trim().replace(/\s+/g, "-");
JS
git add -A && git commit -qm "Precios en euros"
printf "\n## Desarrollo\n\nnpm run dev\n" >> README.md
sed -i '' 's/Hola desde Acme/Hola desde Acme 👋/' src/app/page.tsx

# En este proyecto de ejemplo Claude puede ejecutar y leer sin preguntar (las ediciones las acepta con ⇧⇥ en el vídeo), sin tocar git.
mkdir -p .claude
cat > .claude/settings.local.json <<'JSON'
{ "permissions": { "defaultMode": "default", "allow": ["Bash", "Read", "Grep", "Glob"] } }
JSON
printf ".claude\n" >> .git/info/exclude

for other in api mobile docs; do
  mkdir -p "$DEMO/$other"
  printf '{ "name": "%s", "scripts": { "dev": "node index.js" } }\n' "$other" > "$DEMO/$other/package.json"
done
echo "Demo lista en $DEMO"
git -C "$APP" status -sb
