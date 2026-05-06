/dual-build Build a markdown pastebin web app from scratch in this empty project. Stack: Node + Express + better-sqlite3 + vanilla HTML/JS frontend, with `marked` for markdown rendering server-side and `highlight.js` via CDN for code blocks.

Required behavior:
- POST `/api/pastes` with body `{ content, expires_in_hours, language_hint }` returns `{ slug }`.
- GET `/api/pastes/:slug` returns the paste row or 404 if expired.
- GET `/` serves a create form (textarea, expiry select dropdown for 1h/1d/7d/never, optional language hint).
- GET `/:slug` renders the paste server-side as HTML using marked + a syntax-highlight class wrapper.

Schema: `pastes` table with `id`, `slug`, `content`, `language_hint`, `created_at`, `expires_at`. Cleanup logic to delete expired rows.

Include a README with run instructions and a sample paste seeded on first run.

Read the empty starter, decompose into file-disjoint subtasks, propose the split.
