/dual-build Fix three bugs in this Express + vanilla-JS app:

(a) `server/index.js` — `POST /api/users` crashes with TypeError when the body is empty because it calls `.toLowerCase()` on `undefined`. Add validation that returns HTTP 400 with a descriptive error if `name` or `email` is missing or not a string.

(b) `lib/dates.js` — `dayInPT(date)` returns the local-machine day, ignoring the timezone. Fix it to actually convert to `America/Los_Angeles` before extracting the day-of-month. Use `Intl.DateTimeFormat`.

(c) `public/search.js` — the input handler fires on every keystroke and hammers the API. Add a 250ms debounce so it only fires after the user stops typing.

Add a regression test for each fix (use `node --test` / `node:test`). Tests should fail against the current code and pass after the fix.

Read the codebase, decompose into file-disjoint subtasks, propose the split.
