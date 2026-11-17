# VAAS testnet

The infrastructure as code for the VAAS test networks: the localnet on one
Docker host today, the private devnet on the team's servers next (see
`HANDOFF.md`), and possibly a public testnet later. The parameter profile
(`PROFILE=localnet|devnet`) picks the clocks; the network is the same.

AtomOne leasing its validator set to four consumer chains, all as code: four
AtomOne validators, and the same four validators running every consumer, each
consumer with its own ts-relayer. Every chain, relayer and init step runs in
Docker; `scripts/testnet.sh` only sequences them.

| Chain | Chain id | Role | Prefix | Fees | Host ports (validator 0) |
|---|---|---|---|---|---|
| AtomOne | `atomone-localnet` | VAAS provider (x/vaas/provider wired into AtomOne) | `atone` | `uphoton` (dynamicfee) | RPC 26657, API 1317, gRPC 9090 |
| ref | `vaas-ref-localnet` | VAAS reference consumer | `ref` | `uref` | RPC 26667, API 1318, gRPC 9092 |
| gno | `gnoshard-localnet` | gnoshard: reference consumer plus ignite/gnovm | `gnoshard` | `ushard` | RPC 26677, API 1319, gRPC 9093 |
| photon | `vaas-photon-localnet` | reference consumer with photon fees | `photon` | the `uphoton` voucher bridged from AtomOne | RPC 26687, API 1320, gRPC 9094 |
| forge | `vaas-forge-localnet` | reference consumer run by `consumer-forge`, which can be told to report a validator absent (localnet only) | `forge` | `uforge` | RPC 26697, API 1321, gRPC 9095 |

Names, denoms and prefixes are in `config/network.env`; the parameters in
`config/localnet.env` (fast clocks) and `config/devnet.env` (the devnet's
set); the image sources in `config/sources.env`.

## Requirements

- Docker with compose v2, at least 8 GB of memory for Docker (the running
  network uses about 5 GB), 3 GB of disk for images and build cache.
- On the host: `make`, `bash`, `jq`, `shasum`.
- Network access to GitHub: every image builds from a public repository at
  the commit pinned in `config/sources.env`.

| Image | Source | Branch | Commit |
|---|---|---|---|
| `vaas-testnet/atomone` | AtomOne wired as the VAAS provider | `vaas-pre-mvp` (giunatale/atomone) | 0a898191 |
| `vaas-testnet/vaas-consumer` | VAAS with every open pull request merged | `pre-mvp` (giunatale/vaas) | fa8d1585 |
| `vaas-testnet/gnoshard` | gnoshard (x/gnovm from ignite/gnovm `main`) | `main` (giunatale/gnoshard) | 1baa7399 |
| `vaas-testnet/ts-relayer` | ibc-v2-ts-relayer | `main` (allinbits/ibc-v2-ts-relayer) | a49e8141 |

`make sources-bump` moves every pinned commit to the head of its branch;
review the diff of `config/sources.env`, then `make images`. To build one
image from a local checkout instead, set its `<X>_SRC`, for example
`make image-relayer RELAYER_SRC=../ibc-v2-ts-relayer`.

## Launch

```bash
make images          # build the four images (once, or after a source change)
make up              # provider, then each consumer: register, init, start, relay, declare, fund, first VSC
make smoke           # end-to-end checks on every chain
make delegate        # just the delegation check, repeatable (smoke runs once per network)
make propose F=proposals/params-diff.json   # a provider proposal, every validator votes yes (proposals/README.md)
make check-proposals # every governance and owner template decodes against the running binaries
make status          # heights, consumer phases, liveness, fee pools, relayers
make drills          # downtime, forged accusation, relayer restart (see Drills)
```

`make up` takes about twelve minutes. Every step prints a `###` line; a failing
step stops the run with `ERROR:` and the reason.

Other targets: `make logs S=<service>` (for example `S=relayer-gno` or
`S=atomone-0`), `make provider`, `make consumer C=ref|gno|photon|forge`,
`make stop` (containers stop, `./data` stays), `make start` (resume a stopped
network), `make clean` (stop and delete `./data`). `PROFILE=devnet make up`
runs the devnet parameter set instead.

## What `make up` does

1. **Provider.** `provider-init.sh` (inside the AtomOne image) creates four
   validator homes, the operator accounts (owner, user, one relayer per
   consumer) in validator 0's keyring with their mnemonics in `data/keys`,
   the genesis with every validator's gentx, the parameter profile patched in
   (staking, gov, slashing, dynamicfee, vaasprovider), and the peer lists.
   The four `atomone-*` containers start.
2. **Per consumer**, in the order of `CONSUMERS`:
   1. `create-consumer` from the owner on AtomOne; the consumer launches at
      its spawn time (immediately on the localnet) and the provider serves
      its consumer genesis.
   2. `consumer-init.sh` (inside the consumer's image) creates four homes
      sharing a genesis built from the provider's consumer genesis, imports
      the owner, the user and the consumer's relayer from the provider
      mnemonics (same address bytes on every chain), funds them at genesis
      (the consumer admits only bootstrap traffic until the pin), and gives
      each node its validator's AtomOne consensus key. On the photon consumer
      it sets `photon_fees_enabled` and a zero node fee floor.
   3. The relayer gets its keys, gas prices and the IBC v2 path, then runs.
   4. The owner declares the provider-side client (`update-consumer`). On the
      photon consumer, `uphoton` is bridged to the relayer, the owner and the
      user before the pin, because from the pin on every fee is paid in the
      voucher. The owner pins the consumer-side client (`set-provider-client`);
      on the photon consumer the relayer and the node fee floor then switch
      to the voucher denom.
   5. The owner funds the consumer's fee pool, and the script waits for the
      first validator-set packet.

## Seeing it work

```bash
make status
curl -s localhost:26657/validators | jq '.result.validators[] | {address, voting_power}'
curl -s localhost:26677/validators | jq '.result.validators[] | {address, voting_power}'   # the same set on gnoshard

dc() { docker compose --env-file config/sources.env --env-file config/network.env "$@"; }
dc exec atomone-0 atomoned query vaasprovider list-consumer-chains --home /home/node
dc exec atomone-0 atomoned query vaasprovider consumer-liveness 1 --home /home/node
dc exec atomone-0 atomoned query vaasprovider blocks-until-next-epoch --home /home/node
dc --profile gno exec gno-0 gnoshardd query gnovm eval gno.land/r/demo/counter 'Render("")' --home /home/node
```

`make smoke` shows the protocol end to end, in order:

1. A delegation on AtomOne changes validator 1's power on every consumer at
   the next epoch.
2. A transfer on the reference consumer.
3. On the photon consumer, a transfer paid in the `uphoton` voucher commits
   and one paid in the native denom is refused.
4. On gnoshard, the counter realm is deployed, called twice (once with a
   simulated gas limit) and rendered.
5. Fee payouts: at the next epoch block every consumer's pool pays
   `fees_per_block x blocks_per_epoch`, split equally, to every bonded
   validator's operator account (checked from the balances one block before
   and at the epoch block).
6. Key assignment: validator 3 assigns a fresh consensus key on the
   reference consumer; once the consumer's validator set carries it, the
   node switches to it, signs with it, and is not accused of downtime.

It runs once per network (the realm can be deployed once); `make delegate`,
`make fee-payouts` and `make key-assignment C= V=` repeat single steps.

## Drills

Each drill leaves the network running and can be repeated.

| Target | What happens | About |
|---|---|---|
| `make downtime C=ref V=2` | Validator 2's node on the consumer stops. The consumer accuses it; a challenge against the true accusation is refused (the commit carries no signature from it); the slash matures after the challenge window and lowers its stake without jailing it; once the node is back, no later window accuses it. | 8 min |
| `make forge-challenge V=1` | Every forge node is restarted reporting validator 1 absent for two windows while it signs (`data/forge/lie.env`). The provider queues the forged accusation; a challenge proves from the real commits that it signed, which pauses the forge consumer and cancels the slash without touching the stake; a governance proposal resumes the consumer once the lie is over, and it acknowledges validator-set packets again. | 10 min |
| `make relayer-restart` | Every relayer container restarts; none may log an error, and a new delegation must reach every consumer through them. | 2 min |
| `make drills` | The three in turn. | 20 min |

The accusations, slashes and challenges are the provider's `pending-downtime-slashes`,
`challenge-consumer-downtime` and the consumer's downtime windows; the
localnet profile shortens their clocks (below).

Accounts: validator 0's home of each chain (`/home/node` in the `*-0`
containers) holds the `owner`, `user` and `relayer-<consumer>` keys in a
`test` keyring; their mnemonics are in `data/keys/*.json`. Governance on
AtomOne votes with each validator's `val` key in its own home.

## Parameter profiles

| | localnet | devnet |
|---|---|---|
| block time | 2 s | 5 s |
| epoch (`blocks_per_epoch`) | 20 blocks (about 45 s) | 120 blocks (about 11 min) |
| gov voting period | 120 s | 7200 s |
| spawn after registration | immediate | 30 min |
| downtime window | 30 consumer blocks | 600 consumer blocks |
| downtime challenge window, evidence max age | 3 min, 3 min | 12 h, 6 h |
| downtime grace after launch | 2 min | 2 h |
| consumers | ref, gno, photon, forge | ref, gno, photon |

Everything else is the same in both: 72 h unbonding,
the slashing window that tolerates restarts, the equivocation clock, 60 h
consumer unbonding, 1 h safe mode, `RELAY_MAX_AGE_*` 3600 s,
`min-retain-blocks = 0` on every node so downtime challenges can read
commits. The AtomOne image accepts voting periods down to 60 s
(`MIN_VOTING_PERIOD` in `config/sources.env`).

## Troubleshooting

- A relayer's own errors: `data/relayer-<consumer>/db/error.log` (the
  container log only says "Failed to ...").
- Right after `make start`, a relayer may log one `fetch failed` (its node
  is not up yet) or one `timeout elapsed` with a nonsensical current
  timestamp (it simulated against a node that has not produced its first
  block since the restart). Both clear on the next round; deliveries
  (`Relay N packets`) resume within a minute.
- A consumer stuck before its first VSC: `make status` shows its `client`;
  `make logs S=relayer-<consumer>`; the provider log shows `VSCPacket sent:
  clientId=...` every epoch once the provider side is declared.
- Re-running one consumer: `make consumer C=<consumer>` is idempotent for the
  registration and re-initializes the consumer's nodes and relayer, but a
  consumer keeps its first declared client for good; to start over use
  `make clean && make up`.

## Known limits

- Consumer nodes sign with their validator's AtomOne consensus key, except
  where `make key-assignment` (part of the smoke test) switched one to an
  assigned key. The devnet should assign every consumer key.
- The VAAS and AtomOne sources are integration branches, not releases.
