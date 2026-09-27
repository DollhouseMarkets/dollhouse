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
// operators that the browser has no business with. The read side is `script/contract-keys.mjs`,
// a small module shared with `sync-contracts.mjs` rather than this script reading the web build
// directly, so the check still runs where `web/` is not present.
//
// Exit code 0 when every read key is produced, 1 with the missing ones listed.
//
// AND THE VALUES, when a written record is there to check:
//
//   node script/check-artefact-keys.mjs [path/to/record.json] [--launch] [--rpc <url>] [--mode <m>] [--quiet]
//
// `--quiet` (what `npm run build` passes, via web/scripts/check-record.mjs) names each checked
// key without echoing its value, so a build log never carries the record's addresses.
//
// The record is resolved exactly as `web/scripts/sync-contracts.mjs` resolves it:
// `private/deployments/<chainId>.json` when present, else `deployments/<chainId>.json`, for the
// chain in CHAIN_ID or VITE_CHAIN_ID (process environment first, then web/'s .env files with
// Vite's precedence for `--mode`, default `production`). A different file can be named on the
// command line or in DEPLOYMENT_RECORD.
//
// A record whose own `chainId` is not the chain being checked, or whose deployer / developer /
// steward is a well-known Anvil account (a fork rehearsal), fails outright.
//
// A key that is present and ZERO is as silent as a key that is missing. REQUIRED non-zero on
// every chain: the seven core contracts (router, lens, roundManager, factory, feeVault,
// bidDeployer, hook), genesisToken and deployBlock; with `--launch` also devVesting and
// artistVesting. `ethZap` is required only on mainnet (4663) AND only when the record also
// carries a venue (a non-zero entrancePoolId): the Pons bonding curve has not graduated at
// launch, so a curve-phase record has no venue, no zap and no ETH entry - a valid launch, not
// a broken one, and the check says so and passes rather than failing on it. The rest WARN when
// zero or missing - the legitimate but easily unnoticed "no venue behind the edge currency"
// deployment among them.
//
// `--rpc <url>` also asks that node, for every contract address in the record, `eth_getCode`,
// and fails on any address with no code (and on an `eth_chainId` that is not the record's).
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
import {
  ALWAYS_REQUIRED_EXTRA,
  CORE_ADDRESS_KEYS,
  DIRECT_READ_KEYS,
  ethZapRequired,
  flagValue,
  isZeroValue,
  LAUNCH_REQUIRED_EXTRA,
  MAINNET_CHAIN_ID,
  MAINNET_REQUIRED_EXTRA,
  recordPathFor,
  recordProblems,
  ROLE_KEYS,
  VENUE_VIEW_KEY,
  viteEnv,
} from './contract-keys.mjs'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const deploy = readFileSync(join(repo, 'script', 'Deploy.s.sol'), 'utf8')

/// Every `vm.serialize*(o, "key", ...)` in the record's own object. The constants object is a
/// nested one and is checked through the single key that carries it.
const produced = new Set()
for (const m of deploy.matchAll(/vm\.serialize\w+\(\s*o\s*,\s*"([A-Za-z0-9_]+)"/g)) produced.add(m[1])
for (const m of deploy.matchAll(/vm\.serializeString\(\s*"deployment"\s*,\s*"([A-Za-z0-9_]+)"/g)) produced.add(m[1])

/// Every key the sync script reads off the record directly, plus the venue view key, which it
/// reaches through the address map it has just built rather than off `raw` directly. Both come
/// from `contract-keys.mjs`, shared with `sync-contracts.mjs`, so this stays in step without
/// this script needing to read `web/` at all.
const read = new Set([...DIRECT_READ_KEYS, VENUE_VIEW_KEY])

// ---- arguments ----------------------------------------------------------------------
const argv = process.argv.slice(2)
const launch = argv.includes('--launch')
const rpcUrl = flagValue(argv, '--rpc')
const mode = flagValue(argv, '--mode') ?? 'production'
const quiet = argv.includes('--quiet')
/// One checked value: the label and the value, or only the label under `--quiet`.
const shown = (label, v) => (quiet ? `  ${label}: ok` : `  ${label} = ${v}`)
if (argv.includes('--rpc') && !rpcUrl) {
  console.error('--rpc needs a URL')
  process.exit(1)
}
const valueFlags = new Set(['--rpc', '--mode'])
const positional = argv.filter((a, i) => !a.startsWith('--') && !valueFlags.has(argv[i - 1]))

/// The chain being checked: CHAIN_ID / VITE_CHAIN_ID from the process, else web/'s env files
/// with Vite's precedence (the same value the web build would use), when web/ is present.
function expectedChainId() {
  const fromProcess = process.env.CHAIN_ID || process.env.VITE_CHAIN_ID
  if (fromProcess) return Number(fromProcess)
  const web = join(repo, 'web')
  if (!existsSync(web)) return undefined
  const v = viteEnv(web, mode)('VITE_CHAIN_ID')
  return v ? Number(v) : undefined
}
const chainId = expectedChainId()

/// The record whose VALUES are checked: named on the command line or in DEPLOYMENT_RECORD, else
/// the same private-first record the web sync reads. No record is not a failure: the key check
/// is the part that runs everywhere, toolchain or not.
function recordPath() {
  const named = positional[0] || process.env.DEPLOYMENT_RECORD
  if (named) return resolve(named)
  if (!chainId) return null
  return recordPathFor(repo, chainId) ?? null
}

/// Every value that must be non-zero for the deployment to mean anything. Mainnet and
/// `--launch` add to it (script/contract-keys.mjs). `ethZap` is added only with `--launch`
/// on mainnet AND only when `raw` already carries a venue (`ethZapRequired`); the caller
/// passes the parsed record once it has one.
function requiredKeys(isMainnet, raw) {
  return [
    ...CORE_ADDRESS_KEYS,
    ...ALWAYS_REQUIRED_EXTRA,
    ...(isMainnet ? MAINNET_REQUIRED_EXTRA : []),
    ...(launch ? LAUNCH_REQUIRED_EXTRA : []),
    ...(launch && ethZapRequired(raw, isMainnet) ? ['ethZap'] : []),
  ]
}
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
  ['artistVesting', (r) => r.artistVesting, 'the site does not link the artist vesting wallet'],
]

const isZero = isZeroValue

const valueErrors = []
const record = recordPath()
if (!record && chainId === MAINNET_CHAIN_ID) {
  valueErrors.push(
    'no mainnet deployment record (private/deployments/4663.json or deployments/4663.json) exists yet',
  )
}
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
  const checkedChain = chainId ?? Number(raw.chainId)
  if (chainId === undefined) console.log(`  (no CHAIN_ID/VITE_CHAIN_ID: checking as the record's own chain ${raw.chainId})`)
  for (const p of recordProblems(raw, checkedChain)) valueErrors.push(p)
  const isMainnet = checkedChain === MAINNET_CHAIN_ID
  const hasVenue = !isZero(raw.entrancePoolId)
  const required = requiredKeys(isMainnet, raw)
  for (const label of required) {
    const v = raw[label]
    if (isZero(v)) valueErrors.push(`${label} is ${v === undefined ? 'missing' : `zero (${v})`}`)
    else console.log(shown(label, v))
  }
  // A curve-phase record (the Pons bonding curve has not graduated, so there is no venue pool
  // yet): ethZap is correctly absent, and that is not a warning, it is the expected shape of
  // this launch. Say so plainly instead of letting the generic OPTIONAL warning below imply
  // something is missing.
  if (isMainnet && launch && !hasVenue) {
    console.log('  curve-phase record: no venue, no ETH entry')
    if (!isZero(raw.ethZap)) {
      valueErrors.push(
        'ethZap is set but entrancePoolId is zero/missing: a zap with no venue behind it cannot swap anything',
      )
    }
  }
  for (const [label, get, meaning] of OPTIONAL) {
    if (required.includes(label)) continue
    if (label === 'ethZap' && isMainnet && launch && !hasVenue) continue // said above, not warned here
    const v = get(raw)
    const why = v === undefined ? 'missing' : 'zero'
    if (isZero(v)) console.log(`  WARNING: ${label} is ${why}: ${meaning}`)
    else console.log(shown(label, v))
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
      console.log(`${shown('venuePoolId', raw.venuePoolId)} (matches entrancePoolId)`)
    }
  }
  if (rpcUrl && valueErrors.length === 0) await checkCode(raw, rpcUrl, valueErrors)
} else {
  console.log('\nno deployment record checked: pass one as an argument, or set CHAIN_ID')
  if (rpcUrl) valueErrors.push('--rpc was given but there is no record to check')
}

/// One JSON-RPC call with a 15 s timeout and two bounded retries; throws with the reason.
async function rpc(url, method, params) {
  let last
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(15_000),
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const body = await res.json()
      if (body.error) throw new Error(`${body.error.code}: ${body.error.message}`)
      return body.result
    } catch (err) {
      last = err
      await new Promise((r) => setTimeout(r, 500 * 2 ** attempt))
    }
  }
  throw new Error(`${method} failed after 3 attempts: ${last?.message ?? last}`)
}

/// `eth_getCode` on every CONTRACT address in the record (role accounts are EOAs and are
/// skipped). An address with no code is a record that points at nothing.
async function checkCode(raw, url, errors) {
  console.log(`\ncode checked over RPC`)
  try {
    const remote = Number(await rpc(url, 'eth_chainId', []))
    if (remote !== Number(raw.chainId)) {
      errors.push(`the RPC is chain ${remote}, the record is chain ${raw.chainId}`)
      return
    }
  } catch (err) {
    errors.push(`eth_chainId: ${err.message}`)
    return
  }
  const roles = new Set(ROLE_KEYS)
  const entries = Object.entries(raw).filter(
    ([k, v]) => !roles.has(k) && typeof v === 'string' && /^0x[0-9a-fA-F]{40}$/.test(v) && !isZero(v),
  )
  // `entrancePool` is the venue pool's address REFERENCE (a v4 pool has no contract of its own)
  const skip = new Set(['entrancePool'])
  for (const [k, v] of entries) {
    if (skip.has(k)) continue
    try {
      const code = await rpc(url, 'eth_getCode', [v, 'latest'])
      if (!code || code === '0x') errors.push(`${k} (${v}) has no code on chain ${raw.chainId}`)
      else console.log(`  ${k}: ${(code.length - 2) / 2} bytes`)
    } catch (err) {
      errors.push(`eth_getCode ${k}: ${err.message}`)
    }
  }
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
  console.error(`\nRECORD NOT USABLE (empty, wrong chain, rehearsal, or no code):${valueErrors.join('; ')}`)
  process.exit(1)
}
console.log('\nok: every key the web build reads is written by the deploy script')
