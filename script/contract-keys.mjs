// Shared between `script/check-artefact-keys.mjs` and `web/scripts/sync-contracts.mjs` so the
// two sides of the seam agree on the deployment-record keys that matter without either one
// reading the other's source: the checker runs in contexts (e.g. the public export) that do not
// carry `web/` at all.
//
// DIRECT_READ_KEYS: every key `sync-contracts.mjs` dereferences directly off the parsed record
// (`raw.<key>`), besides the address keys it walks dynamically through `CONTRACT_KEYS`/
// `ROLE_KEYS`. Those address keys are not listed here on purpose: some (`devVesting`,
// `artistVesting`, `ethZap`) are written by their own deploy scripts, not every path through
// `Deploy.s.sol`, so requiring them here would fail a deployment that simply has not run those
// scripts yet. This list is the narrow, always-required seam: the one that broke when
// `raw.entrancePoolId` was read while the script wrote only `entrancePool`.
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export const DIRECT_READ_KEYS = ['chainId', 'constants', 'deployBlock', 'entrancePoolId', 'startIndex']

// The record key that carries the periphery StateView address the web app actually calls
// (`getSlot0(entrancePoolId)`) to price $DOLL in ETH. Published to the bundle under
// `entrancePool` instead of this key.
export const VENUE_VIEW_KEY = 'stateView'

export const MAINNET_CHAIN_ID = 4663

/// The seven contracts a deployment is nothing without. Required non-zero in every record the
/// checker reads, and on mainnet together with `MAINNET_REQUIRED_EXTRA`.
export const CORE_ADDRESS_KEYS = ['router', 'lens', 'roundManager', 'factory', 'feeVault', 'bidDeployer', 'hook']
/// Also required non-zero, on every chain.
export const ALWAYS_REQUIRED_EXTRA = ['genesisToken', 'deployBlock']
/// NOT required, even on mainnet: private/LAUNCH_RUNBOOK.md §10 (curve-phase launch) treats a
/// record with no venue (`entrancePoolId` / `stateView` left empty, the deploy script writes
/// zeros) as a legitimate deployment, not an error - "the site then prints no ETH or USD
/// figure anywhere rather than a zero, which is the intended behaviour and not a bug." Kept as
/// an exported (empty) list rather than deleted so a future key that IS unconditionally
/// required on mainnet has a home without another seam like this one.
export const MAINNET_REQUIRED_EXTRA = []
/// Required when the check is run with `--launch`: both vesting locks (developer and
/// artist), which a real launch must have run (script/DeployVesting.s.sol once per
/// RECORD_KEY) before the record is usable. `ethZap` is NOT in this list: on 4663 it is
/// required only when the record also carries a venue (a non-zero `entrancePoolId`) - see
/// `ethZapRequired` below. A curve-phase record (the Pons bonding curve has not graduated,
/// so there is no venue pool yet) has no zap and no ETH entry, and that is a valid launch,
/// not a broken one.
export const LAUNCH_REQUIRED_EXTRA = ['devVesting', 'artistVesting']

/// True when a value is missing, empty, or all-zero (address, bytes32 or plain number),
/// exactly what a deploy script writes for a key it has nothing to put there. Shared so
/// `check-artefact-keys.mjs` and anything else reasoning about a record's zero-ness agrees.
export function isZeroValue(v) {
  return v === undefined || v === null || v === '' || /^0x0*$/.test(String(v)) || /^0+$/.test(String(v))
}

/// Whether `ethZap` must be present and non-zero in `raw`: on mainnet (4663), if and only if
/// the record carries a venue (a non-zero `entrancePoolId`). Off mainnet, or with no venue,
/// a zap has nothing to swap into and must be absent or zero.
export function ethZapRequired(raw, isMainnet) {
  return isMainnet && !isZeroValue(raw?.entrancePoolId)
}

/// Whether `expectedVenueId` (the venue the factory's ETH-anchored start may be bound to,
/// `FamilyFactory.EXPECTED_VENUE_ID`, written by `Deploy.s.sol`) must be present and non-zero
/// in `raw`: on mainnet, whenever the record comes from a factory with the ETH-anchored start
/// (its `constants.startFdvWei` is written by the same script run) - curve phase or not, since
/// the venue key is known before the venue exists. A zero id means the start can never be bound.
/// `venueOracle` itself is NOT required: it stays zero until the one-shot bind
/// (script/BindOracle.s.sol, or Deploy.s.sol when the venue was already live), and a record of an
/// earlier factory has no start rule to feed.
export function expectedVenueIdRequired(raw, isMainnet) {
  return isMainnet && raw?.constants?.startFdvWei !== undefined
}

/// Role EOAs in a record. None of them may be a well-known Anvil account.
export const ROLE_KEYS = ['deployer', 'developer', 'devVestingDeployer', 'roundManagerDeployer', 'steward']

/// The ten default accounts of `anvil` (mnemonic "test test ... junk"): their private keys are
/// public, so a record naming one as a role is a fork rehearsal, never a real deployment.
export const ANVIL_ACCOUNTS = [
  '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
  '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
  '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
  '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
  '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65',
  '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc',
  '0x976EA74026E726554dB657fA54763abd0C3a0aa9',
  '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955',
  '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f',
  '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
].map((a) => a.toLowerCase())

/// REHEARSALS ONLY. `DOLLHOUSE_REHEARSAL=1` lets a record whose roles are well-known Anvil
/// accounts through the checks below, so a local fork of a chain can be served and checked end
/// to end. Everything else is still enforced (chain id, core contracts, code over RPC). Every
/// run that waives the Anvil check prints `REHEARSAL_BANNER`. Never set it on a build box.
export const REHEARSAL_ENV = 'DOLLHOUSE_REHEARSAL'

/// True when the rehearsal override is set in `env` (default: the process environment).
export function isRehearsal(env = process.env) {
  return env[REHEARSAL_ENV] === '1'
}

export const REHEARSAL_BANNER = [
  '',
  '################################################################################',
  '##                                                                            ##',
  '##   REHEARSAL RECORD  -  DOLLHOUSE_REHEARSAL=1                               ##',
  '##   Anvil role accounts are ALLOWED. This record is a local fork, not a      ##',
  '##   deployment. Nothing built from it may be published.                      ##',
  '##                                                                            ##',
  '################################################################################',
  '',
].join('\n')

/// Prints the rehearsal banner to stderr, once per process.
let bannerShown = false
export function printRehearsalBanner() {
  if (bannerShown) return
  bannerShown = true
  console.error(REHEARSAL_BANNER)
}

/// The deployment record for `chainId`: `private/deployments/<id>.json` when present, else
/// `deployments/<id>.json`, else undefined. The ONE resolution rule, for the sync and the
/// checker alike.
export function recordPathFor(repo, chainId) {
  const privatePath = join(repo, 'private', 'deployments', `${chainId}.json`)
  const publicPath = join(repo, 'deployments', `${chainId}.json`)
  return existsSync(privatePath) ? privatePath : existsSync(publicPath) ? publicPath : undefined
}

/// What makes a record unusable for `chainId` whatever its values: a `chainId` that is not the
/// one being built, or a role held by a public Anvil key. Returned as messages, [] when fine.
/// Never prints an address: the message names the key only. With the rehearsal override
/// (`DOLLHOUSE_REHEARSAL=1`) Anvil role accounts are waived and the rehearsal banner is printed.
export function recordProblems(raw, chainId, { rehearsal = isRehearsal() } = {}) {
  const problems = []
  if (raw.chainId === undefined || Number(raw.chainId) !== Number(chainId)) {
    problems.push(
      `the record's chainId (${raw.chainId === undefined ? 'missing' : raw.chainId}) is not ${chainId}, the chain being built`,
    )
  }
  const anvil = ROLE_KEYS.filter((k) => typeof raw[k] === 'string' && ANVIL_ACCOUNTS.includes(raw[k].toLowerCase()))
  if (anvil.length > 0 && rehearsal) {
    printRehearsalBanner()
    console.error(`role account(s) [${anvil.join(', ')}] are well-known Anvil accounts: allowed by ${REHEARSAL_ENV}=1`)
  } else if (anvil.length > 0) {
    problems.push(
      `role account(s) [${anvil.join(', ')}] are well-known Anvil accounts: this is a fork rehearsal record, not a deployment`,
    )
  }
  return problems
}

/// A tiny .env reader: `KEY=value`, `#` comments, optional surrounding quotes. Deliberately
/// not a dependency.
export function readEnvFile(path) {
  if (!existsSync(path)) return {}
  const env = {}
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line)
    if (!m) continue
    let v = m[2].trim()
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1)
    env[m[1]] = v
  }
  return env
}

/// Vite's own env precedence for `mode`, lowest first: `.env`, `.env.local`, `.env.<mode>`,
/// `.env.<mode>.local`; a non-empty process environment variable beats every file. `npm run
/// build` is mode `production`, so `.env.production` is read there exactly as Vite reads it.
/// Returns a lookup `(key) => value | undefined`.
export function viteEnv(dir, mode) {
  const merged = {}
  for (const f of ['.env', '.env.local', `.env.${mode}`, `.env.${mode}.local`]) {
    Object.assign(merged, readEnvFile(join(dir, f)))
  }
  return (key) => {
    const fromProcess = process.env[key]
    if (fromProcess !== undefined && fromProcess !== '') return fromProcess
    const v = merged[key]
    return v === undefined || v === '' ? undefined : v
  }
}

/// `--name value` out of an argv array, or undefined.
export function flagValue(argv, name) {
  const i = argv.indexOf(name)
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined
}
