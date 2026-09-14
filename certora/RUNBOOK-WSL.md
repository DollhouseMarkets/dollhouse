# Running the Certora Prover from WSL (review-2)

For the maintainer, on a Windows machine with no prior WSL. `certora-cli` is not supported on
Windows (see the environment section of `RESULTS-review-1.md`); this avoids the local patches
entirely by running from a Linux userspace instead.

## 1. Install WSL Ubuntu

One PowerShell command, run as Administrator, then reboot when it asks:

```powershell
wsl --install -d Ubuntu
```

On first boot, Ubuntu opens a terminal and asks for a UNIX username and password (can differ from
the Windows login). Open Ubuntu and run `sudo apt update`.

## 2. Tooling inside Ubuntu

```sh
sudo apt install -y python3.12 python3.12-venv openjdk-21-jdk
python3.12 -m venv ~/certora-venv
source ~/certora-venv/bin/activate
pip install certora-cli==8.19.2      # the version review-1/1b ran; see RESULTS-review-1.md
java -version                        # confirm 21; review-1b's JDK 17 could not type-check locally
```

solc: the confs set `"solc": "solc0.8.26"`, i.e. a binary named exactly `solc0.8.26` on `PATH`.
Use `solc-select`, which names its binaries that way once selected:

```sh
pip install solc-select
solc-select install 0.8.26 && solc-select use 0.8.26
ln -sf ~/.solc-select/artifacts/solc-0.8.26/solc-0.8.26 ~/.local/bin/solc0.8.26
```

Foundry is not required; the confs list `.sol` files directly and the Prover compiles with the
pinned `solc0.8.26`, not `forge build`. Add `~/.local/bin` to `PATH` if `certoraRun` is not found
after `pip install` (`export PATH="$HOME/.local/bin:$PATH"`, added to `~/.bashrc`).

## 3. Get the code

Clone the review repository (the maintainer's private Dollhouse review repo, per
`docs/REVIEW_PACKAGE.md`) into WSL, rather than working against `/mnt/c/Users/<user>/infinite-coin`:

```sh
git clone <review-repo-url> ~/dollhouse-review && cd ~/dollhouse-review
forge install    # submodules only, if the review clone has forge available; otherwise skip
```

Cloning keeps this Windows machine's absolute paths out of the job logs, per
`docs/REVIEW_PACKAGE.md` §"External services": run the prover from the export directory or the
review clone, never from `/mnt/c/...`, which would echo this machine's Windows username into
`.certora_verify.json` or a call trace. Do not type that Windows path into any file that leaves
this machine.

## 4. Key

```sh
export CERTORAKEY=...    # from the password manager, this shell only, never into a file
```
## 5. Run order and commands

```sh
certoraRun certora/conf/DevVesting.conf   --msg "DevVesting review-2"
certoraRun certora/conf/Sleeve.conf       --msg "Sleeve review-2"
certoraRun certora/conf/FeeVault.conf     --msg "FeeVault review-2"
certoraRun certora/conf/RoundManager.conf --msg "RoundManager review-2"
certoraRun certora/conf/FamilyHook.conf   --msg "FamilyHook review-2"
```

Submit without `--wait_for_results` (the big three specs outran the CLI's local client timeout in
review-1); poll `jobData` instead, per `certora/README.md` §"Retrieving results from a finished
job". A CLI that supports a `--wait_for_results all` mode is fine to use instead. Expected
duration, from review-1/1b: DevVesting and Sleeve finish in minutes; FeeVault and RoundManager can
run past an hour; FamilyHook is in between.

## 6. Capture, then clear the scratch

After each run, before deleting anything, get the read key and record it with the job URL
(printed by `certoraRun`) in `private/certora/JOBS-review-2.md` on the Windows side (`/mnt/c/...`
is fine for this one private, gitignored file; it never leaves the machine):

```sh
grep -r "anonymous.*Key" .certora_internal | head     # the per-job read key
echo "FeeVault: <job-url>  <readKeyParam>=<key>" >> /mnt/c/Users/<user>/infinite-coin/private/certora/JOBS-review-2.md
```

Then clear the scratch before the next run, so a stale spec copy cannot shadow an edited one:

```sh
rm -rf .certora_internal .certora_sources .certora_config .certora_*.json
```

## 7. Fetch

`<readKeyParam>` is the per-job read key's query-parameter name (`anonymous…Key`); it is written
elided here so that grepping this repository for it stays empty, which is the check that no real key
ever lands in a tracked file.

```sh
curl -A "Mozilla/5.0" "<jobURL>/output.json?<readKeyParam>=<key>" -o /mnt/c/Users/<user>/infinite-coin/private/certora/<Spec>-review-2-output.json
curl -A "Mozilla/5.0" "<jobURL>/FinalResults.html?<readKeyParam>=<key>" -o /mnt/c/Users/<user>/infinite-coin/private/certora/<Spec>-review-2-FinalResults.html
```

## 8. Hand-off

Send back the updated `private/certora/JOBS-review-2.md` and the five
`<Spec>-review-2-output.json` files (plus `FinalResults.html` if fetched); the assessment against
`RESULTS-review-1.md`'s open items happens from those artefacts, not a description of what ran.

## 9. Troubleshooting

- **CVL type-check error naming an old JDK.** Confirm `java -version` reports 21 in this WSL shell
  (not the Windows `java`); JDK below 19 cannot type-check locally at all.
- **"stack too deep" during compile.** Do not touch `yul_optimizer_steps` in the confs; it already
  passes solc's own default Yul sequence, including the load-bearing space in `gv i f`.
- **Local type-check refuses to complete for an unrelated reason.** Fall back to
  `--disable_local_typechecking` for that submission only; it costs a five-second CVL error
  surfacing server-side instead of locally, not correctness.
- **403 on fetch.** Missing or default `User-Agent`; the endpoints reject curl/Python's default and
  need something browser-like, e.g. `-A "Mozilla/5.0"`.
- **Memory.** Proving runs in Certora's cloud; the only local work is `solc0.8.26`, which is light.
  The 16 GB / single-lock constraint on local Foundry runs does not apply here.
