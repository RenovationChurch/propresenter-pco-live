# API notes

## Planning Center Services: verified against the real API (Oct 11, 2026)

Checked with read-only calls on the Weekend Gatherings service type.

| Fact | Status |
|---|---|
| HTTP Basic auth with a Personal Access Token works; `GET /services/v2/me` returns the token's Person id | **Verified** |
| `.../plans?filter=future` includes today's plan (first result was Oct 11 on Oct 11) | **Verified.** `--plan next` picks today's plan on a Sunday. |
| `.../plans/{plan}/items` returns `title`, `item_type` (`header`, `item`, `song`, ...), `sequence` | **Verified** |
| `.../plans/{plan}/plan_times` returns `time_type` (`service`, `rehearsal`, `other`) and `starts_at`; this plan has two `service` times | **Verified** |
| `.../live` `meta.can_include`: `controller`, `current_item_time`, `items`, `next_item_time`, `service_type` | **Verified** |
| Live attributes include `can_control` and `can_take_control` (both true for this token) | **Verified** |
| Live `links` list exactly three actions: `go_to_next_item`, `go_to_previous_item`, `toggle_control` | **Verified** |
| **There is no "jump to item" action** | **Verified** (not in `links`). The engine steps one item at a time and re-reads LIVE after every step. |
| With no controller, `relationships.controller.data` is `null` and `links.controller` is `null` | **Verified** |
| `ItemTime` has `relationships.item`, `relationships.plan_time` and `attributes.live_start_at` / `live_end_at` / `exclude` | **Verified** |
| Before a service starts, LIVE's `next_item_time` is an ItemTime with **`item: null`** pointing at the first service PlanTime: a "service start" stop | **Verified** (shape). The engine models a service-start slot ahead of each service time's items. |
| Each item has one ItemTime per service time | **Verified** |
| No LIVE recorded times (`live_start_at`) on the last 6 Weekend Gatherings plans | **Verified.** There's no manual-recording baseline to compare against yet. |

### Still unverified (needs a test plan and an armed run)

- Does `toggle_control` take control when nobody holds it? (Almost certainly.) What does it do when someone else holds it? (Only used with `--take-over`.)
- When a controller is set, is `relationships.controller.data.id` the controller's Person id? The parser also handles the case where only the link is present.
- Do next/previous skip header items? Do they skip ItemTimes marked `exclude: true`? The engine doesn't depend on either: it re-reads after every step and stops on overshoot.
- Does "next" from the last item of the 9:00 service go to the 11:00 service-start stop?
- Do API-driven moves record `live_start_at` / `live_end_at` the same way manual clicks do?

## ProPresenter (21.x / 7.x Network API)

From Renewed Vision's OpenAPI spec (openapi.propresenter.com; a copy is in `alxpark/propresenter-mcp/api/swagger.json`):

- `GET /version`
- `GET /v1/playlist/active` returns `{presentation: {playlist: {uuid,name,index}, item: {uuid,name,index}}, announcements: {...}}`. "Active" means the most recently triggered cue that belongs to a library playlist. An index of `4294967295` means none.
- `GET /v1/playlist/{id}` returns `{id, items: [{id: {uuid,name,index}, type, is_hidden, is_pco, header_color, duration, presentation_info, target_uuid}]}`. `type` is one of `presentation`, `placeholder`, `header`, `media`, `audio`, `livevideo`. `is_pco` marks entries that came from the PCO plan.
- Streaming: `GET /v1/playlist/active?chunked=true` sends a chunk each time it changes. `POST /v1/status/updates` with `["playlist/active"]` aggregates streams. This build polls (0.5 s by default). Streaming is a possible later improvement.

To verify on the Mac: `curl http://127.0.0.1:<port>/v1/playlist/active`, then `curl http://127.0.0.1:<port>/v1/playlist/<uuid>`.

**Repeated presentations:** every copy of a presentation in a playlist (a song used twice, e.g. before and after baptisms) has the same uuid, both as `item.uuid` from `/v1/playlist/active` and as the entry's `id.uuid`. The uuid alone can't tell the copies apart, so the matcher uses it only when it is unique in the playlist and otherwise picks the copy by `item.index`.

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
