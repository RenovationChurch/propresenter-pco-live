# API notes (Phase 0 findings)

The recon for this first build couldn't reach the live APIs. The cloud environment's network policy blocked `api.planningcenteronline.com`, and the build had no access to a running ProPresenter. These notes list where each fact came from and how sure we are. **Confirm the "unverified" items with read-only calls before relying on them.**

## Planning Center Services

| Fact | Source | Confidence |
|---|---|---|
| HTTP Basic auth with Personal Access Token (app ID : secret) | PCO docs, prior art | High |
| `GET .../plans/{plan}/items` gives `title`, `item_type` (`song`, `header`, `media`, `item`), `sequence` | PCO docs | High |
| `GET .../plans/{plan}/plan_times` gives `time_type` (`service`, `rehearsal`, `other`), `starts_at` | PCO docs | High |
| `GET .../plans/{plan}/live?include=current_item_time,controller` | prior art uses `include=current_item_time,items` and `include=items,controller,next_item_time` | High that the includes exist |
| The current item comes from the included `ItemTime`'s `relationships.item` | prior art | High |
| `ItemTime.relationships.plan_time` says which service time LIVE is in | PCO data model | **Unverified.** If missing, the tool falls back to the selected service time. |
| `data.relationships.controller.data.id` is the controller's Person id | JSON:API convention | **Unverified.** Prior art only checks that `data.links.controller` is non-null. The parser handles both shapes. |
| `POST .../live/go_to_next_item`, `go_to_previous_item`, `toggle_control` | prior art (`pastorhudson/ProPresenter-PCO-Live-Auto-Control`), which works in production | High |
| **No "jump to item" action** | nothing found in prior art or docs search | **Unverified.** The engine steps one item at a time and re-reads LIVE after every step, so it works either way. |
| `toggle_control` when someone else controls takes control from them | inferred from the LIVE UI's "Take Control" | **Unverified.** Only used with `--take-over`. |
| next/previous skip header items | LIVE UI behaviour | **Unverified.** The engine doesn't depend on it; it re-reads after every step. |
| LIVE runs service times in order and next from the last item moves into the next service time | LIVE UI behaviour | **Unverified** |
| `GET /services/v2/me` gives the token's Person id | PCO docs | Medium. Falls back to `/people/v2/me`. |
| Rate limit about 100 requests / 20 s, 429 with `Retry-After` | PCO docs | High. The client honours `Retry-After` (capped at 30 s). |
| API-driven advances record times like manual clicks | — | **Unknown. Check on a test plan (Phase 3).** |

## ProPresenter (21.x / 7.x Network API)

From Renewed Vision's OpenAPI spec (openapi.propresenter.com; a copy is in `alxpark/propresenter-mcp/api/swagger.json`):

- `GET /version`
- `GET /v1/playlist/active` returns `{presentation: {playlist: {uuid,name,index}, item: {uuid,name,index}}, announcements: {...}}`. "Active" means the most recently triggered cue that belongs to a library playlist. An index of `4294967295` means none.
- `GET /v1/playlist/{id}` returns `{id, items: [{id: {uuid,name,index}, type, is_hidden, is_pco, header_color, duration, presentation_info, target_uuid}]}`. `type` is one of `presentation`, `placeholder`, `header`, `media`, `audio`, `livevideo`. `is_pco` marks entries that came from the PCO plan.
- Streaming: `GET /v1/playlist/active?chunked=true` sends a chunk each time it changes. `POST /v1/status/updates` with `["playlist/active"]` aggregates streams. This build polls (0.5 s by default). Streaming is a possible later improvement.

To verify on the Mac: `curl http://127.0.0.1:<port>/v1/playlist/active`, then `curl http://127.0.0.1:<port>/v1/playlist/<uuid>`.

**Open question:** is `item.uuid` from `/v1/playlist/active` the same as the playlist entry's `id.uuid`? The matcher looks the entry up by uuid first, then by index plus name, so it copes either way.

## Read-only commands to run first

```sh
python -m pcosync test-connection
python -m pcosync service-types
python -m pcosync --service-type <ID> plans
python -m pcosync --service-type <ID> --plan <PLAN> items
python -m pcosync --service-type <ID> --plan <PLAN> live
python -m pcosync --service-type <ID> --plan <PLAN> mapping
python -m pcosync -v --service-type <ID> --plan <PLAN> run      # dry-run
```
