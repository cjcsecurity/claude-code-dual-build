#!/usr/bin/env bash
# Scaffolds an Express + vanilla-JS app with three intentional bugs.
# Bug 1 (server/index.js): POST /api/users crashes on empty body.
# Bug 2 (lib/dates.js): dayInPT returns local-machine day, ignoring timezone.
# Bug 3 (public/search.js): no debounce, hammers API on every keystroke.
set -euo pipefail

sandbox="${1:?sandbox path required}"
rm -rf "$sandbox"
mkdir -p "$sandbox"
cd "$sandbox"

git init -q -b main
git config user.email "test@example.com"
git config user.name "test"

npm init -y -q >/dev/null
npm pkg set type=module >/dev/null
npm i --silent express >/dev/null 2>&1 || npm i express

mkdir -p server lib public

cat > server/index.js <<'EOF'
import express from 'express';
const app = express();
app.use(express.json());

app.post('/api/users', (req, res) => {
  const { name, email } = req.body;
  // BUG: no validation — name is undefined when body is empty, crashes on .toLowerCase()
  res.json({ id: Math.random(), name: name.toLowerCase(), email });
});

app.listen(3000, () => console.log('running on 3000'));
EOF

cat > lib/dates.js <<'EOF'
// Returns the day-of-month in Pacific Time for the given date.
export function dayInPT(date) {
  // BUG: ignores timezone, returns local-machine day instead of PT day
  return new Date(date).getDate();
}
EOF

cat > public/search.js <<'EOF'
const input = document.querySelector('#search');
input.addEventListener('input', (e) => {
  // BUG: fires on every keystroke, no debounce — hammers /api/search
  fetch('/api/search?q=' + encodeURIComponent(e.target.value));
});
EOF

cat > public/index.html <<'EOF'
<!doctype html>
<html><head><title>buggy app</title></head>
<body>
  <input id="search" placeholder="search..." />
  <script type="module" src="search.js"></script>
</body></html>
EOF

git add .
git commit -qm "initial: app with 3 known bugs"

echo "Scaffolded buggy app at $sandbox"
