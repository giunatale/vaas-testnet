# From localnet to devnet: handoff notes

The localnet in this repository runs the whole network on one Docker host.
The devnet is the same network on the team's servers: private, not open to
the public, every key held by the VAAS team. This page lists what carries
over unchanged, what has to change, and what must be settled first.

## What carries over unchanged

- The images (`images/*.Dockerfile`) and their build arguments.
- The init logic: `scripts/provider-init.sh` and `scripts/consumer-init.sh`
  run inside the chain images and only need a data directory.
- The launch order in `scripts/testnet.sh`: provider genesis and start;
  per consumer, registration, consumer genesis, nodes, relayer, the two
  client declarations (with the voucher bridge before the pin on a
  photon-fees consumer), fee pool, first validator-set packet.
- The parameter set: `PROFILE=devnet` (`config/devnet.env`) is the devnet
  parameter set, with 5 s blocks, 11-minute epochs, 2-hour votes and a
  spawn 30 minutes after registration.

## What changes

1. **Images published.** The sources are already pinned commits of public
   repositories (`config/sources.env`). Build each
   image once and push it to a registry the servers pull from;
   `config/sources.env` then names registry tags instead of local ones.
2. **One host per validator.** Each of the four validator hosts runs one
   AtomOne node and one node of each consumer (4 containers). The compose
   file splits per host: the `atomone-<i>`, `ref-<i>`, `gno-<i>` and
   `photon-<i>` services of validator `i`. Peers then name hosts or IPs
   instead of compose hostnames (`set_peers` in `scripts/node-config.sh`),
   and port 26656 of every chain is reachable between the validator hosts
   (four chains on one host need distinct host ports or one IP per chain).
3. **An ops host** for the three relayers, the operator keyring (owner,
   user, relayer accounts) and the RPC/API endpoints the team uses; ideally
   one non-validating full node per chain there, so queries and relayers do
   not load the validators.
4. **Keys.** The localnet generates every key in one place. For the devnet
   that is still acceptable (the team holds everything), but:
   - keep `priv_validator_key.json` of each validator only on its host, plus
     an offline backup;
   - give each validator its own consumer consensus keys
     (`MsgAssignConsumerKey` while the consumer is registered or
     initialized, before spawn) instead of reusing the AtomOne key on every
     chain;
   - the owner key is the consumers' only authority (no governance on the
     reference consumer); keep it offline or in a multisig, and keep the
     relayer mnemonics in a secret store.
5. **Launch timing.** With `SPAWN_DELAY=1800`, register the consumers, fetch
   each consumer genesis once it launches, distribute it, and have every
   validator start its consumer nodes before the downtime grace period
   (2 h after spawn) ends.

## Sizing (measured on the localnet)

| Process | Memory | CPU at 2 s blocks |
|---|---|---|
| AtomOne node | about 220 MB | 7 to 10 % of a core |
| reference consumer node | about 150 MB | 6 to 8 % |
| gnoshard node | about 560 MB | about 8 % |
| ts-relayer | 100 to 160 MB | under 5 % |

A validator host (one node per chain) needs about 1.2 GB of memory plus
headroom; 4 GB and 2 cores is comfortable. Disk grows without bound because
every node keeps all blocks (`min-retain-blocks = 0`, which downtime
challenges need); plan for state pruning to stay `default` and for the block
store to grow at the block rate, and alert on disk.

## Monitoring

Every node exposes Prometheus metrics on 26660 (`prometheus = true`). What
the protocol needs watched, beyond node health:

- per consumer, `query vaasprovider consumer-liveness <id>`: last
  acknowledgement time, `degraded`, removal ETA;
- the fee pool balance against the epoch fee
  (`fees_per_block_amount * blocks_per_epoch`): a pool that cannot pay puts
  the consumer in debt;
- IBC client status on both sides of each path (a frozen or expired client
  stops validator-set updates);
- each relayer's `error.log` and its balances (on the photon consumer the
  relayer pays fees in the voucher and never earns them back);
- `pending-downtime-slashes`, `pending-equivocation-punishments` and
  consumer phases on the provider.

## Operations to know

- **Stopping the network at a height:** set `halt-height` in each node's
  `app.toml`. Neither app registers an upgrade handler, so a passed
  `MsgSoftwareUpgrade` halts every node and the next binary starts only with
  `--unsafe-skip-upgrades <height>`.
- **Relayer restarts:** a restarted relayer container keeps its keyring with
  the keyring-restart fix in the relayer source; an image built from
  allinbits/ibc-v2-ts-relayer before that fix merges loses it on restart.
- **Proposal and owner-exec bodies** for resume, removal, parameter changes,
  fee-pool subsidies and client recovery are in `proposals/`
  (`proposals/README.md`); `make propose` and `make owner-exec` run them on
  the localnet.

## Settle before the devnet

| Item | State |
|---|---|
| ts-relayer fixes | fork `giunatale/ibc-v2-ts-relayer@vaas-testnet` until allinbits/ibc-v2-ts-relayer#42 and #43 merge |
| VAAS release | integration branch `pre-mvp`; the 33 PRs merge first |
| AtomOne wiring | draft PR atomone-hub/atomone#393 against VAAS `main` |
| atomone-sdk | pseudo-version of `main` until its next release |
| gnovm fixes | fork `giunatale/gnovm@gnoroot` until ignite/gnovm#15 and #16 merge |
| gnoshard | `giunatale/gnoshard`, on the gnovm fork until ignite/gnovm#15 and #16 merge |
| consumer key assignment | not exercised on the localnet yet |
| parameters | `config/devnet.env`; to refine with devops for the servers |
