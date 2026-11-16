# Proposal and owner-exec templates

Bodies for every governance action the provider offers and for the two
actions a consumer's owner takes. Provider proposals go through AtomOne's
governance; consumer actions go through `owner-exec`, signed by the owner the
provider seeded into the consumer. The smoke test uses none of them: they are
for operating a running network.

## Submitting a provider proposal

```bash
make propose F=proposals/resume.json ARGS="consumer-id=1"
```

`propose` fills in `<gov-authority>`, and every other `<placeholder>` from
`ARGS` (`name=value`, space-separated); it refuses a body with a placeholder
left. `JQ` takes a jq filter to edit the filled body, for example
`JQ='.messages[0].amount="3000"'`. It submits the proposal from the `user` key, has every validator vote
yes, and prints the outcome once the voting period ends (2 minutes on the
localnet profile). Consumer ids are in `make status`.

`make check-proposals` fills every template with sample values and has the
running binaries decode it without broadcasting anything; run it after
moving a source to a new commit.

Each body is proto JSON: a numeric id is a quoted string. On another network,
submit a filled body with `atomoned tx gov submit-proposal <file>`; the gov
module's address is `atomoned query auth module-account gov`.

| Body | Message | When |
|---|---|---|
| `resume.json` | `MsgResumeConsumer` | a paused consumer (downtime challenge, refusal threshold, chain-id mismatch) comes back |
| `remove.json` | `MsgRemoveConsumer` | the consumer leaves; cancels a punishment waiting on the vote |
| `params-diff.json` | `MsgUpdateParams` | one or more provider parameters change; the message is a diff |
| `fees-per-block.json` | `MsgSetConsumerFeesPerBlock` | one consumer pays more per block than the module-wide amount |
| `fund-from-community-pool.json` | `MsgFundConsumerFeePool` signed by governance | the community pool subsidizes a consumer's fee pool |
| `clawback.json` | `MsgWithdrawConsumerFeePool` signed by governance | the subsidy returns to the community pool |
| `recover-and-resume.json` | `MsgRecoverClient` then `MsgResumeConsumer` | the provider's client of the consumer froze on a fork |
| `rename-and-resume.json` | `MsgUpdateConsumer` with `new_chain_id` then `MsgResumeConsumer` | the consumer bumped its revision and the provider paused it on the mismatch |
| `software-upgrade.json` | `MsgSoftwareUpgrade` | a coordinated halt; read the caveat in the body |

## The substitute client for a recovery

`MsgRecoverClient` needs a second, healthy client of the same chain on the
same side. Nothing creates one on its own:

1. Have the relayer add the path again: `ibc-v2-ts-relayer add-path` with the
   same two endpoints creates a fresh client on each chain and registers the
   counterparties. Note the new client ids on both sides.
2. The frozen side's new client is the substitute: on the provider, the new
   provider-side client (`query ibc client states`, the one whose
   `chain_id` is the consumer's and whose status is `Active`); on the
   consumer, the new consumer-side client.
3. Submit the recovery with the frozen client as the subject and the new one
   as the substitute. A substitute that expires while the proposal waits (its
   trusting period passed with no update) is refused; add the path once more
   and resubmit with the newer client.
4. After the recovery the subject is active again and the consumer keeps
   serving it; the substitute may be left to expire.

The resume after a fork is refused until the fork wait is over; the refusal
text names the time ("resume at or after ..."). Submit the proposal so that
it executes after that time, or resume in a second proposal.

## Consumer-side actions by the owner

```bash
make owner-exec C=ref F=proposals/owner-exec-update-params.json JQ='.messages[0].params.safe_mode_threshold="7200s"'
```

`owner-exec` fills in `<owner-authority>`, `<current-params>` (the
consumer's parameters as they are) and the `ARGS` placeholders, applies `JQ`,
and signs with the `owner` key on validator 0 of consumer `C` (`ref`, `gno`
or `photon`).

| Body | Message | When |
|---|---|---|
| `owner-exec-recover.json` | `MsgRecoverClient` | the consumer's client of the provider froze; the substitute comes from the step above, consumer side |
| `owner-exec-update-params.json` | `MsgUpdateParams` (consumer) | a consumer parameter changes; the consumer's message carries the full params object, unlike the provider's diff |

Every message in an owner-exec file names the owner authority as its signer,
and the messages execute in order, all or nothing. The owner's account on the
consumer is the provider-side owner's address bytes under the consumer's
prefix; it needs a balance in the consumer's fee denom.
