#!/usr/bin/env node
// ---------------------------------------------------------------------------------------------
// THE SEAM BETWEEN THE DEPLOY SCRIPT AND THE WEB BUILD.
//
//   node script/check-artefact-keys.mjs
//
// `script/Deploy.s.sol` writes the deployment record; `web/scripts/sync-contracts.mjs` reads it
// and generates what the browser ships. Nothing joins the two, so a key the web reads and the
// script never writes is silent: `raw.entrancePoolId` was read for a whole release while the
// script wrote only `entrancePool`, and the site simply printed no ETH price and said nothing.
//
// This is that check, and it is one-directional on purpose: every key the web READS must be
// produced by the deploy script. The reverse is not required - the record carries keys for
// operators that the browser has no business with.
//
// Exit code 0 when every read key is produced, 1 with the missing ones listed.
//
// AND THE VALUES, when a written record is there to check:
//
//   node script/check-artefact-keys.mjs [deployments/<chainId>.json]
//
// A key that is present and ZERO is as silent as a key that is missing. With a record named on
// the command line (or CHAIN_ID / VITE_CHAIN_ID set, resolved the way the web build resolves it),
// this also fails on a zero `genesisToken`, and WARNS on a zero or missing
// `entrancePoolId` or `stateView` - the legitimate but easily unnoticed "no venue behind the edge
// currency" deployment.
//
// WHAT IS ALLOWED TO BE ZERO. `constants.bondBaseDoll` and `constants.minBountyDoll`
// were failures, and neither is wrong at zero: a bond of zero is a chain anyone may enter, and a
// minimum bounty of zero is the proportional 1% with no floor under it, which is what the edge
// bid already pays. Both are deliberate configurations, so they warn rather than fail. A record
// that is not readable JSON now says which file and why instead of throwing a stack trace.
// ---------------------------------------------------------------------------------------------
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const sync = readFileSync(join(repo, 'web', 'scripts', 'sync-contracts.mjs'), 'utf8')
const deploy = readFileSync(join(repo, 'script', 'Deploy.s.sol'), 'utf8')

/// Every `vm.serialize*(o, "key", ...)` in the record's own object. The constants object is a
/// nested one and is checked through the single key that carries it.
const produced = new Set()
for (const m of deploy.matchAll(/vm\.serialize\w+\(\s*o\s*,\s*"([A-Za-z0-9_]+)"/g)) produced.add(m[1])
for (const m of deploy.matchAll(/vm\.serializeString\(\s*"deployment"\s*,\s*"([A-Za-z0-9_]+)"/g)) produced.add(m[1])

/// Every key the sync script reads off the record: `raw.<key>`, plus the venue view key, which
/// it reaches through the address map it has just built rather than off `raw` directly.
const read = new Set()
for (const m of sync.matchAll(/\braw\.([A-Za-z0-9_]+)/g)) read.add(m[1])
const venue = /const VENUE_VIEW_KEY = '([A-Za-z0-9_]+)'/.exec(sync)
if (venue) read.add(venue[1])

/// The record whose VALUES are checked, if one was named or can be resolved. No record is not a
/// failure: the key check is the part that runs everywhere, toolchain or not.
function recordPath() {
  const named = process.argv[2]
  if (named) return resolve(named)
  const chainId = process.env.CHAIN_ID || process.env.VITE_CHAIN_ID
  if (!chainId) return null
  for (const p of [
    join(repo, 'private', 'deployments', `${chainId}.json`),
    join(repo, 'deployments', `${chainId}.json`),
  ]) {
    if (existsSync(p)) return p
  }
  return null
}

/// Every value that must be non-zero for the deployment to mean anything, and the two that are
/// allowed to be absent but must say so out loud.
const REQUIRED = [['genesisToken', (r) => r.genesisToken]]
/// Zero here is a legitimate deployment, not a broken record - but it is one nobody should
/// discover by accident, so each one says what zero MEANS on the chain that ships it.
const OPTIONAL = [
  ['entrancePoolId', (r) => r.entrancePoolId, 'the site prints no ETH or USD figure'],
  ['stateView', (r) => r.stateView, 'the site prints no ETH or USD figure'],
  ['constants.bondBaseDoll', (r) => r.constants?.bondBaseDoll, 'candidates post NO bond on this chain'],
  [
    'constants.minBountyDoll',
    (r) => r.constants?.minBountyDoll,
    'keeper bounties are the proportional rate with NO floor under them',
  ],
  ['ethZap', (r) => r.ethZap, 'the site hides the ETH buy/sell option and keeps the $DOLL-only flow'],
  ['devVesting', (r) => r.devVesting, 'the site does not link the developer vesting wallet'],
]

const isZero = (v) =>
  v === undefined || v === null || v === '' || /^0x0*$/.test(String(v)) || /^0+$/.test(String(v))

const valueErrors = []
const record = recordPath()
if (record) {
  let raw
  try {
    raw = JSON.parse(readFileSync(record, 'utf8'))
  } catch (err) {
    console.error(`\nUNREADABLE deployment record ${record}: ${err.message}`)
    console.error('  It must be the JSON object script/Deploy.s.sol writes. Nothing was checked.')
    process.exit(1)
  }
  console.log(`\nvalues checked against ${record}`)
  for (const [label, get] of REQUIRED) {
    const v = get(raw)
    if (isZero(v)) valueErrors.push(`${label} is ${v === undefined ? 'missing' : `zero (${v})`}`)
    else console.log(`  ${label} = ${v}`)
  }
  for (const [label, get, meaning] of OPTIONAL) {
    const v = get(raw)
    const why = v === undefined ? 'missing' : 'zero'
    if (isZero(v)) console.log(`  WARNING: ${label} is ${why}: ${meaning}`)
    else console.log(`  ${label} = ${v}`)
  }
  // The zap swaps ETH against the SAME pool the site prices $DOLL in ETH with. If a record
  // names both, they must be the same pool - a zap pointed at a different venue would swap
  // at a price the site never shows and never protects against.
  if (!isZero(raw.ethZap) && !isZero(raw.entrancePoolId)) {
    if (isZero(raw.venuePoolId)) {
      console.log(
        '  WARNING: ethZap is set but venuePoolId is not recorded: cannot confirm it swaps ' +
          'the same pool entrancePoolId prices $DOLL in ETH with',
      )
    } else if (String(raw.venuePoolId).toLowerCase() !== String(raw.entrancePoolId).toLowerCase()) {
      valueErrors.push(`venuePoolId (${raw.venuePoolId}) != entrancePoolId (${raw.entrancePoolId})`)
    } else {
      console.log(`  venuePoolId = ${raw.venuePoolId} (matches entrancePoolId)`)
    }
  }
} else {
  console.log('\nno deployment record checked: pass one as an argument, or set CHAIN_ID')
}

const missing = [...read].filter((k) => !produced.has(k)).sort()
const report = (label, set) => console.log(`${label}: ${[...set].sort().join(', ')}`)
report('produced by Deploy.s.sol', produced)
report('read by sync-contracts.mjs', read)

if (missing.length > 0) {
  console.error(
    `\nMISSING from the deployment record: ${missing.join(', ')}\n` +
      '  Serialize them in script/Deploy.s.sol, or stop reading them in web/scripts/sync-contracts.mjs.',
  )
  process.exit(1)
}
if (valueErrors.length > 0) {
  console.error(`\nEMPTY where the record needs a value: ${valueErrors.join('; ')}`)
  process.exit(1)
}
console.log('\nok: every key the web build reads is written by the deploy script')
