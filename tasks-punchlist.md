# Punchlist

A brutally simple todo app. No features. No opinions. Just circles and text.

## The Vibe

Remember The Milk before it got ambitious. A text box. A list. Tappable circles. That's it.

## Spec

### UI
- Single page, dark theme
- Text input at top, full width
- Enter key adds item to top of list
- Each item: tappable circle + text
- Tap circle → strikethrough + move to bottom of list
- No modal, no toast, no confirmation
- No parsing, no tags, no dates, no smart anything

### Technical
- **Backend**: Single Go binary
  - `GET /` → serves the HTML/JS
  - `GET /api/items` → returns JSON array
  - `POST /api/items` → adds item (body: `{"text": "..."}`)
  - `PATCH /api/items/:id` → toggle done status
  - `DELETE /api/items/:id` → remove item (optional, maybe just let done items accumulate)
- **Storage**: JSON file (`/var/lib/punchlist/items.json`)
- **Conflict resolution**: Last-write-wins. No CRDT, no merge, just overwrite.

### Deployment
- **Domain**: `punchlist.gisi.network`
- **Auth**: OIDC Gatekeeper, VPN bypass
- **PWA**: Service worker + manifest for offline mobile use
- **SPA-friendly**: Can be pinned as app on work laptop without living in browser tabs

### Data shape
```json
{
  "items": [
    {"id": "uuid", "text": "do the thing", "done": false, "created": "2026-01-22T..."},
    {"id": "uuid", "text": "did this one", "done": true, "created": "2026-01-22T..."}
  ]
}
```

### PWA requirements
- `manifest.json` with app name, icons, theme color
- Service worker that caches the shell and allows offline viewing
- When offline, queue writes and sync when back online (or just show stale and let user refresh)

## Non-goals
- Multi-list support
- Due dates
- Tags or priorities
- Collaboration
- History or undo
- Search
- Literally anything else

## Success criteria
Kevin can add "buy milk" from his phone in a tunnel and check it off from his work laptop 10 minutes later.
