// Shared between `script/check-artefact-keys.mjs` and `web/scripts/sync-contracts.mjs` so the
// two sides of the seam agree on the deployment-record keys that matter without either one
// reading the other's source: the checker runs in contexts (e.g. the public export) that do not
// carry `web/` at all.
//
// DIRECT_READ_KEYS: every key `sync-contracts.mjs` dereferences directly off the parsed record
// (`raw.<key>`), besides the address keys it walks dynamically through `CONTRACT_KEYS`/
// `ROLE_KEYS`. Those address keys are not listed here on purpose: some (`devVesting`, `ethZap`)
// are written by their own deploy scripts, not every path through `Deploy.s.sol`, so requiring
// them here would fail a deployment that simply has not run those scripts yet. This list is the
// narrow, always-required seam: the one that broke when `raw.entrancePoolId` was read while the
// script wrote only `entrancePool`.
export const DIRECT_READ_KEYS = ['constants', 'deployBlock', 'entrancePoolId', 'startIndex']

// The record key that carries the periphery StateView address the web app actually calls
// (`getSlot0(entrancePoolId)`) to price $DOLL in ETH. Published to the bundle under
// `entrancePool` instead of this key.
export const VENUE_VIEW_KEY = 'stateView'
