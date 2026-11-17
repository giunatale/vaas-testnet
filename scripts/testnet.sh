#!/usr/bin/env bash
# Orchestrates the network (PROFILE=localnet|devnet) through docker compose.
# Every chain, relayer and init step runs in a container; this script only
# sequences them and reads their JSON. Host requirements: docker (compose v2), bash, jq, shasum.
#
#   scripts/testnet.sh up                 everything, in order
#   scripts/testnet.sh provider           init and start the AtomOne validators
#   scripts/testnet.sh consumer <c>       register, init, start, relay, declare, fund one consumer
#   scripts/testnet.sh smoke              delegation reaches every consumer, plus each consumer's own check
#   scripts/testnet.sh delegate           only the delegation check (repeatable)
#   scripts/testnet.sh relayer-restart    restart every relayer, then the delegation check
#   scripts/testnet.sh fee-payouts        an epoch's fee leaves every pool and reaches every validator
#   scripts/testnet.sh propose F k=v..    a provider proposal from proposals/, every validator votes yes
#   scripts/testnet.sh owner-exec C F k=v.. a consumer owner action from proposals/
#   scripts/testnet.sh check-proposals    every template decodes against the running binaries
#   scripts/testnet.sh status             heights, phases, liveness, pools, relayers
#   scripts/testnet.sh stop | start       stop (data kept) | resume a stopped network
#   scripts/testnet.sh clean              stop and delete ./data
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PROFILE="${PROFILE:-localnet}"
set -a
source config/sources.env
source config/network.env
source "config/$PROFILE.env"
set +a

COMPOSE=(docker compose --env-file config/sources.env --env-file config/network.env)
dc() { "${COMPOSE[@]}" "$@"; }
log() { printf '\n### %s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
up_var() { local n="$(echo "$1" | tr '[:lower:]' '[:upper:]')_$2"; echo "${!n}"; }

# --- chain access -----------------------------------------------------------
# P / C run a CLI command on validator 0 of the provider / consumer $1, with
# val0's home (it holds the operator keyring).
P() { dc exec -T atomone-0 atomoned "$@" --home /home/node; }
C() { local c="$1"; shift; dc exec -T "$c-0" "$(up_var "$c" BINARY)" "$@" --home /home/node; }
# V runs a CLI command on AtomOne validator $1 with its own home (its `val` key).
V() { local i="$1"; shift; dc exec -T "atomone-$i" atomoned "$@" --home /home/node; }

height() { # service
	dc exec -T "$1" curl -sf localhost:26657/status 2>/dev/null | jq -r '.result.sync_info.latest_block_height // empty' || true
}
wait_height() { # service min label
	local h
	for _ in $(seq 1 120); do
		h="$(height "$1")"
		[ -n "$h" ] && [ "$h" -ge "$2" ] && { echo "  $3 at height $h"; return 0; }
		sleep 2
	done
	dc logs --tail 30 "$1" >&2; die "$3 did not reach height $2"
}

# tx_wait <runner...>: broadcasts, waits for inclusion, fails on a non-zero code
tx() {
	local out err hash code
	# stdout carries the JSON; stderr carries the gas estimate and errors
	err="$(mktemp data/.tx-stderr.XXXXXX)"
	out="$("$@" -y -o json 2>"$err")" || { tail -3 "$err" >&2; rm -f "$err"; return 1; }
	hash="$(echo "$out" | jq -r '.txhash // empty' 2>/dev/null)"
	[ -n "$hash" ] || { echo "$out" | tail -3 >&2; tail -3 "$err" >&2; rm -f "$err"; return 1; }
	rm -f "$err"
	code="$(echo "$out" | jq -r '.code')"
	[ "$code" = "0" ] || { echo "  check-tx refused: $(echo "$out" | jq -r .raw_log | cut -c1-300)" >&2; return 1; }
	local runner=("$1"); case "$1" in C|V) runner=("$1" "$2") ;; esac
	for _ in $(seq 1 30); do
		sleep 2
		res="$("${runner[@]}" query tx "$hash" -o json 2>/dev/null)" || continue
		code="$(echo "$res" | jq -r '.code')"
		[ "$code" = "0" ] || { echo "  tx $hash failed: $(echo "$res" | jq -r .raw_log | cut -c1-300)" >&2; return 1; }
		echo "  tx $hash ok"; return 0
	done
	die "tx $hash not included"
}
ptx() { tx P tx "$@" --keyring-backend test --chain-id "$PROVIDER_CHAIN_ID" --gas auto --gas-adjustment 1.5 --fees "30000${PROVIDER_FEE_DENOM}"; }
ctx() { local c="$1"; shift; tx C "$c" tx "$@" --keyring-backend test --chain-id "$(up_var "$c" CHAIN_ID)" --gas 400000 --fees "$(consumer_fee "$c")"; }
consumer_fee() { # fee for a consumer transaction: the voucher once a photon-fees consumer is pinned
	if [ "$(up_var "$1" PHOTON_FEES)" = "true" ] && [ -s "data/$1/voucher_denom" ]; then echo "10000$(cat "data/$1/voucher_denom")"
	else echo "10000$(up_var "$1" DENOM)"; fi
}
addr_on() { # chain-runner key: P owner | C ref owner
	if [ "$1" = P ]; then P keys show "$2" -a --keyring-backend test; else C "$2" keys show "$3" -a --keyring-backend test; fi
}
consumer_id() { P query vaasprovider list-consumer-chains -o json | jq -r --arg c "$(up_var "$1" CHAIN_ID)" '.chains[] | select(.chain_id == $c) | .consumer_id' | head -1; }
newest_client() { # json-of-client-states tracked-chain-id
	jq -r --arg c "$2" '[.client_states[] | select(.client_state.chain_id == $c) | .client_id] | sort_by(split("-") | last | tonumber) | last // empty' <<<"$1"
}
voucher_denom() { echo "ibc/$(printf 'transfer/%s/%s' "$1" "$PROVIDER_FEE_DENOM" | shasum -a 256 | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"; }

# --- provider ---------------------------------------------------------------
provider() {
	log "provider: init $NUM_VALIDATORS validators ($PROFILE profile)"
	dc run --rm -T atomone-tools /scripts/provider-init.sh
	log "provider: start"
	dc up -d atomone-0 atomone-1 atomone-2 atomone-3
	wait_height atomone-0 2 "$PROVIDER_CHAIN_ID"
}

# --- consumers --------------------------------------------------------------
register() { # c
	local c="$1" chain rev spawn id
	chain="$(up_var "$c" CHAIN_ID)"
	id="$(consumer_id "$c")"
	if [ -z "$id" ]; then
		log "$c: register $chain on the provider"
		rev=0; [[ "$chain" =~ -([0-9]+)$ ]] && rev="${BASH_REMATCH[1]}"
		spawn="$(jq -nr --argjson t "$(( $(date +%s) + SPAWN_DELAY ))" '$t | todate')"
		mkdir -p data/atomone/val0/tmp
		jq -n --arg chain "$chain" --arg name "$(up_var "$c" NAME)" --arg spawn "$spawn" --argjson rev "$rev" \
			--argjson ub "$CONSUMER_UNBONDING_PERIOD" --argjson vto "$CONSUMER_VAAS_TIMEOUT_PERIOD" \
			--argjson smt "$CONSUMER_SAFE_MODE_THRESHOLD" --argjson he "$CONSUMER_HISTORICAL_ENTRIES" '{
			chain_id: $chain,
			metadata: {name: $name, description: ($name + " on the VAAS localnet"), metadata: "{}"},
			initialization_parameters: {
				initial_height: {revision_number: $rev, revision_height: 1},
				genesis_hash: "", binary_hash: "", spawn_time: $spawn,
				unbonding_period: ($ub * 1000000000), vaas_timeout_period: ($vto * 1000000000),
				safe_mode_threshold: ($smt * 1000000000), historical_entries: $he}}' > "data/atomone/val0/tmp/create-$c.json"
		ptx vaasprovider create-consumer "/home/node/tmp/create-$c.json" --from owner
		id="$(consumer_id "$c")"
	fi
	[ -n "$id" ] || die "$c: not registered"
	echo "$id" > "data/$c.consumer_id" 2>/dev/null || { mkdir -p "data/$c"; echo "$id" > "data/$c.consumer_id"; }
	log "$c: consumer $id, waiting for the launch (spawn delay ${SPAWN_DELAY}s)"
	for _ in $(seq 1 $(( SPAWN_DELAY / 5 + 60 ))); do
		P query vaasprovider consumer-genesis "$id" -o json > "data/$c.consumer_genesis.tmp" 2>/dev/null && break
		sleep 5
	done
	[ -s "data/$c.consumer_genesis.tmp" ] || die "$c: no consumer genesis"
	mkdir -p "data/$c"; mv "data/$c.consumer_genesis.tmp" "data/$c/consumer_genesis.json"
	echo "  phase: $(P query vaasprovider consumer-chain "$id" -o json | jq -r .phase)"
}

start_consumer() { # c
	local c="$1"
	log "$c: init $NUM_VALIDATORS nodes and start"
	dc --profile "$c" rm -sf "$c-0" "$c-1" "$c-2" "$c-3" >/dev/null 2>&1 || true
	dc run --rm -T "$c-tools" /scripts/consumer-init.sh
	dc --profile "$c" up -d "$c-0" "$c-1" "$c-2" "$c-3"
	wait_height "$c-0" 2 "$(up_var "$c" CHAIN_ID)"
}

relayer() { # c
	local c="$1" chain mn out
	chain="$(up_var "$c" CHAIN_ID)"
	mn="$(jq -r .mnemonic data/keys/relayer-$c.json)"
	log "$c: relayer"
	dc --profile "relayer-$c" rm -sf "relayer-$c" >/dev/null 2>&1 || true
	rm -rf "data/relayer-$c"; mkdir -p "data/relayer-$c/db" "data/relayer-$c/keyrings"
	R() { dc run --rm -T "relayer-$c" ibc-v2-ts-relayer "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
	R add-mnemonic -c "$PROVIDER_CHAIN_ID" --mnemonic "$mn" | grep -v -i mnemonic | tail -1
	R add-mnemonic -c "$chain" --mnemonic "$mn" | grep -v -i mnemonic | tail -1
	R add-gas-price -c "$PROVIDER_CHAIN_ID" --gas-adjustment 2.0 "0.025${PROVIDER_FEE_DENOM}" | tail -1
	R add-gas-price -c "$chain" --gas-adjustment 2.0 "0.025$(up_var "$c" DENOM)" | tail -1
	for attempt in 1 2 3 4 5; do
		out="$(R add-path -s "$PROVIDER_CHAIN_ID" -d "$chain" --surl http://atomone-0:26657 --durl "http://$c-0:26657" --ibc-version 2)"
		echo "$out" | grep -q 'Added new relay path' && { echo "  path added"; break; }
		echo "$out" | grep -E 'ERROR|error' | tail -2
		[ "$attempt" = 5 ] && die "$c: relayer path not added (see data/relayer-$c/db/error.log)"
		sleep 6
	done
	dc --profile "relayer-$c" up -d "relayer-$c"
}

declare_clients() { # c
	local c="$1" chain id pcid ccid
	chain="$(up_var "$c" CHAIN_ID)"; id="$(cat "data/$c.consumer_id")"
	pcid="$(newest_client "$(P query ibc client states -o json)" "$chain")"
	ccid="$(newest_client "$(C "$c" query ibc client states -o json)" "$PROVIDER_CHAIN_ID")"
	[ -n "$pcid" ] && [ -n "$ccid" ] || die "$c: relayer clients missing"
	log "$c: declare the provider side ($pcid)"
	jq -n --argjson id "$id" --arg cl "$pcid" '{consumer_id: $id, client_id: $cl}' > "data/atomone/val0/tmp/declare-$c.json"
	for attempt in 1 2 3 4 5 6; do
		ptx vaasprovider update-consumer "/home/node/tmp/declare-$c.json" --from owner && break
		[ "$attempt" = 6 ] && die "$c: provider-side declaration refused"
		echo "  (the counterparty registration may still be landing; retrying)"; sleep 10
	done
	if [ "$(up_var "$c" PHOTON_FEES)" = "true" ]; then
		fund_vouchers_before_pin "$c" "$pcid" "$ccid"
	fi
	log "$c: pin the consumer side ($ccid)"
	ctx "$c" vaasconsumer set-provider-client "$ccid" --from owner
	if [ "$(up_var "$c" PHOTON_FEES)" = "true" ]; then
		switch_to_voucher_fees "$c"
	fi
}

# A photon-fees consumer takes fees only in the uphoton voucher once pinned,
# the relayer's deliveries included: bridge vouchers to the relayer, the owner
# and the user before the pin (VAAS docs/consumer-launch-runbook.md, section 4).
fund_vouchers_before_pin() { # c pcid ccid
	local c="$1" pcid="$2" ccid="$3" vd addr deadline
	vd="$(voucher_denom "$ccid")"
	log "$c: bridge $PROVIDER_FEE_DENOM to the fee payers before the pin (voucher $vd)"
	for a in "relayer-$c" owner user; do
		addr="$(addr_on C "$c" "$a")"
		deadline=$(( $(date +%s) + 600 ))
		ptx ibc-transfer transfer transfer "$pcid" "$addr" "500000000${PROVIDER_FEE_DENOM}" --from owner \
			--absolute-timeouts --packet-timeout-height 0-0 --packet-timeout-timestamp "$deadline"
	done
	for a in "relayer-$c" owner user; do
		addr="$(addr_on C "$c" "$a")"
		for _ in $(seq 1 60); do
			bal="$(C "$c" query bank balance "$addr" "$vd" -o json 2>/dev/null | jq -r '.balance.amount // "0"')"
			[ "$bal" != "0" ] && { echo "  $a holds $bal $vd"; break; }
			sleep 3
		done
		[ "$bal" != "0" ] || die "$c: vouchers never reached $a"
	done
	echo "$vd" > "data/$c/voucher_denom"
}

switch_to_voucher_fees() { # c
	local c="$1" vd; vd="$(cat "data/$c/voucher_denom")"
	log "$c: relayer and node fee floor switch to the voucher"
	dc run --rm -T "relayer-$c" ibc-v2-ts-relayer add-gas-price -c "$(up_var "$c" CHAIN_ID)" --gas-adjustment 2.0 "0.025$vd" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -1
	dc --profile "relayer-$c" restart "relayer-$c"
	for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
		sed -i.bak "s#^minimum-gas-prices = .*#minimum-gas-prices = \"0.01$vd\"#" "data/$c/val$i/config/app.toml"
	done
	local h; h="$(height "$c-0")"
	dc --profile "$c" restart "$c-0" "$c-1" "$c-2" "$c-3"
	wait_height "$c-0" "$(( h + 2 ))" "$(up_var "$c" CHAIN_ID)"
}

fund_pool() { # c
	local c="$1" id; id="$(cat "data/$c.consumer_id")"
	log "$c: fund the fee pool ($FEE_POOL_DEPOSIT$PROVIDER_FEE_DENOM)"
	ptx vaasprovider fund-consumer-fee-pool "$id" "${FEE_POOL_DEPOSIT}${PROVIDER_FEE_DENOM}" --from owner
}

wait_vsc() { # c
	local c="$1"
	log "$c: waiting for the first validator-set packet"
	for _ in $(seq 1 $(( BLOCKS_PER_EPOCH * 3 ))); do
		# grep -q closes the pipe at the first match; under pipefail the
		# writer's SIGPIPE would count as a failure, hence the `|| true`
		{ dc --profile "$c" logs "$c-0" 2>&1 || true; } | grep -q 'successfully handled VSCPacket' && { echo "  VSC received"; return 0; }
		sleep 3
	done
	die "$c: no VSC received"
}

consumer() { # c
	register "$1"; start_consumer "$1"; relayer "$1"; declare_clients "$1"; fund_pool "$1"; wait_vsc "$1"
}

# --- checks -----------------------------------------------------------------
# A delegation on AtomOne's second validator, then its new power on every
# consumer within three epochs.
delegate() {
	local val1 before after want powers
	log "a delegation on AtomOne reaches every consumer's validator set"
	val1="$(dc exec -T atomone-1 atomoned keys show val --bech val -a --keyring-backend test --home /home/node)"
	before="$(P query staking validator "$val1" -o json | jq -r '.validator.tokens // .tokens')"
	ptx staking delegate "$val1" "500000000${PROVIDER_DENOM}" --from user
	after="$(P query staking validator "$val1" -o json | jq -r '.validator.tokens // .tokens')"
	echo "  atomone-1 tokens $before -> $after"
	want=$(( after / 1000000 ))
	for c in $CONSUMERS; do
		for _ in $(seq 1 $(( BLOCKS_PER_EPOCH * 3 ))); do
			powers="$(dc exec -T "$c-0" curl -s localhost:26657/validators | jq -r '[.result.validators[].voting_power] | join(",")')"
			echo ",$powers," | grep -q ",$want," && { echo "  $c: validator powers $powers"; break; }
			sleep 3
		done
		echo ",$powers," | grep -q ",$want," || die "$c: power $want never appeared ($powers)"
	done
}

smoke() {
	delegate

	log "smoke: ref, a native-denom transfer"
	ctx ref bank send user "$(addr_on C ref owner)" "1$(up_var ref DENOM)" --from user

	log "smoke: photon, a voucher-fee transfer commits and a native-denom fee is refused"
	ctx photon bank send user "$(addr_on C photon owner)" "1$(up_var photon DENOM)" --from user
	if tx C photon tx bank send user "$(addr_on C photon owner)" "1$(up_var photon DENOM)" --from user --keyring-backend test \
		--chain-id "$PHOTON_CHAIN_ID" --gas 400000 --fees "10000$(up_var photon DENOM)" 2>/dev/null; then
		die "photon: a native-denom fee was accepted"
	fi
	echo "  native-denom fee refused, as expected"

	log "smoke: gno, the counter realm"
	mkdir -p data/gno/val0/realms && cp -r scripts/realms/counter data/gno/val0/realms/
	tx C gno tx gnovm add-package /home/node/realms/counter --from user --keyring-backend test \
		--chain-id "$GNO_CHAIN_ID" --gas 5000000 --fees "50000${GNO_DENOM}"
	tx C gno tx gnovm call gno.land/r/demo/counter Increment --from user --keyring-backend test \
		--chain-id "$GNO_CHAIN_ID" --gas 5000000 --fees "50000${GNO_DENOM}"
	# the second call with a simulated gas limit
	tx C gno tx gnovm call gno.land/r/demo/counter Increment --from user --keyring-backend test \
		--chain-id "$GNO_CHAIN_ID" --gas auto --gas-adjustment 1.3 --fees "50000${GNO_DENOM}"
	echo "  render: $(C gno query gnovm eval gno.land/r/demo/counter 'Render("")' -o json | jq -r .result)"
	fee_payouts
	log "smoke: passed"
}

status() {
	printf '%-22s %-8s %s\n' CHAIN HEIGHT NODES
	for s in atomone $CONSUMERS; do
		hs=""; for i in $(seq 0 $((NUM_VALIDATORS - 1))); do hs="$hs $(height "$s-$i" || true)"; done
		chain="$PROVIDER_CHAIN_ID"; [ "$s" != atomone ] && chain="$(up_var "$s" CHAIN_ID)"
		printf '%-22s %-8s %s\n' "$chain" "$(height "$s-0")" "$hs"
	done
	echo
	for c in $CONSUMERS; do
		[ -s "data/$c.consumer_id" ] || continue
		id="$(cat "data/$c.consumer_id")"
		cc="$(P query vaasprovider consumer-chain "$id" -o json 2>/dev/null)"
		live="$(P query vaasprovider consumer-liveness "$id" -o json 2>/dev/null)"
		pool="$(jq -r '.fee_pool_address // empty' <<<"$cc")"
		bal="$( [ -n "$pool" ] && P query bank balance "$pool" "$PROVIDER_FEE_DENOM" -o json 2>/dev/null | jq -r .balance.amount )"
		printf '%-7s id=%s %-26s client=%-17s last_ack=%s degraded=%s pool=%s%s relayer=%s\n' "$c" "$id" \
			"$(jq -r .phase <<<"$cc")" "$(jq -r '.client_id // "-"' <<<"$cc")" \
			"$(jq -r '.last_ack_time // "-"' <<<"$live")" "$(jq -r '.degraded // false' <<<"$live")" \
			"${bal:-?}" "$PROVIDER_FEE_DENOM" "$(docker inspect -f '{{.State.Status}}' "vaas-testnet-relayer-$c-1" 2>/dev/null || echo absent)"
	done
}

# relayer_restart: restarts every relayer container, fails on any error a
# restarted relayer logs (a lost keyring shows as PermissionDenied), then
# checks that a new delegation still reaches every consumer through them.
relayer_restart() {
	local c since n
	log "relayers: restart"
	since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	for c in $CONSUMERS; do dc --profile "relayer-$c" restart "relayer-$c"; done
	sleep 30
	for c in $CONSUMERS; do
		[ "$(docker inspect -f '{{.State.Status}}' "vaas-testnet-relayer-$c-1")" = running ] || die "relayer-$c not running"
		n="$(dc --profile "relayer-$c" logs --since "$since" "relayer-$c" 2>&1 | grep -ciE 'error|denied' || true)"
		[ "$n" = 0 ] || { dc --profile "relayer-$c" logs --since "$since" "relayer-$c" 2>&1 | grep -iE 'error|denied' | tail -3 >&2; die "relayer-$c logged errors after the restart"; }
		echo "  relayer-$c running, no errors since the restart"
	done
	delegate
}

# --- drills -----------------------------------------------------------------
val_acct() { V "$1" keys show val -a --keyring-backend test; }
cid_of() { cat "data/$1.consumer_id"; }
balance_at() { # address denom height
	P query bank balances "$1" --height "$3" -o json | jq -r --arg d "$2" '[.balances[] | select(.denom == $d) | .amount][0] // "0"'
}

# fee_payouts: at the next epoch block every consumer's pool pays its epoch
# fee (fees_per_block x blocks_per_epoch, split equally) to every bonded
# validator's operator account.
fee_payouts() {
	local E n h H c cid pool fpb share b0 b1 sum=0 i
	log "fee payouts: at an epoch block every pool pays every bonded validator"
	E="$(P query vaasprovider params -o json | jq -r '.blocks_per_epoch // .params.blocks_per_epoch')"
	n="$(P query staking validators -o json | jq '[.validators[] | select(.status == "BOND_STATUS_BONDED")] | length')"
	h="$(height atomone-0)"; H=$(( (h / E + 1) * E )); [ $(( H - h )) -ge 3 ] || H=$(( H + E ))
	wait_height atomone-0 $(( H + 1 )) "$PROVIDER_CHAIN_ID (epoch block $H)"
	for c in $CONSUMERS; do
		cid="$(cid_of "$c")"
		pool="$(P query vaasprovider consumer-chain "$cid" -o json | jq -r .fee_pool_address)"
		fpb="$(P query vaasprovider consumer-fees-per-block "$cid" -o json | jq -r .fees_per_block.amount)"
		share=$(( fpb * E / n ))
		b0="$(balance_at "$pool" "$PROVIDER_FEE_DENOM" $(( H - 1 )))"; b1="$(balance_at "$pool" "$PROVIDER_FEE_DENOM" "$H")"
		[ $(( b0 - b1 )) -eq $(( share * n )) ] || die "$c: pool paid $(( b0 - b1 )), expected $n x $share"
		echo "  $c: pool paid $n x $share$PROVIDER_FEE_DENOM ($fpb per block x $E blocks)"
		sum=$(( sum + share ))
	done
	for i in $(seq 0 $(( NUM_VALIDATORS - 1 ))); do
		a="$(val_acct "$i")"
		b0="$(balance_at "$a" "$PROVIDER_FEE_DENOM" $(( H - 1 )))"; b1="$(balance_at "$a" "$PROVIDER_FEE_DENOM" "$H")"
		[ $(( b1 - b0 )) -eq "$sum" ] || die "validator $i received $(( b1 - b0 )), expected $sum"
	done
	echo "  every validator received $sum$PROVIDER_FEE_DENOM at height $H"
}

# --- governance and owner actions ------------------------------------------
# fill_template FILE KEY=VALUE...: prints FILE with each <KEY> replaced; fails
# while a <placeholder> remains.
fill_template() {
	local f="$1" body kv; shift
	[ -f "$f" ] || die "no file $f"
	body="$(cat "$f")"
	for kv in "$@"; do body="${body//<${kv%%=*}>/${kv#*=}}"; done
	# JQ (environment): a jq filter applied to the filled body
	[ -z "${JQ:-}" ] || body="$(jq "$JQ" <<<"$body")" || die "JQ filter failed"
	if grep -o '<[a-z-]*>' <<<"$body" | sort -u | grep -q .; then
		die "$f: fill $(grep -o '<[a-z-]*>' <<<"$body" | sort -u | tr '\n' ' ')(as name=value)"
	fi
	echo "$body"
}

# propose FILE KEY=VALUE...: submits a provider proposal from the `user` key
# with <gov-authority> filled in, every validator votes yes, and the outcome is
# printed once the voting period ends.
propose() {
	local f="$1" gov id status left; shift
	gov="$(P query auth module-account gov -o json | jq -r '.account.value.address // .account.base_account.address')"
	fill_template "$f" "gov-authority=$gov" "$@" > data/.proposal.json
	dc cp data/.proposal.json atomone-0:/tmp/proposal.json
	log "proposal: $(jq -r .title data/.proposal.json)"
	ptx gov submit-proposal /tmp/proposal.json --from user
	id="$(P query gov proposals -o json | jq -r '.proposals[-1].id')"
	for i in $(seq 0 $(( NUM_VALIDATORS - 1 ))); do
		tx V "$i" tx gov vote "$id" yes --from val --keyring-backend test --chain-id "$PROVIDER_CHAIN_ID" \
			--gas auto --gas-adjustment 1.5 --fees "30000${PROVIDER_FEE_DENOM}"
	done
	left=$(( ${VOTING_PERIOD%s} + 60 ))
	while [ "$left" -gt 0 ]; do
		status="$(P query gov proposal "$id" -o json | jq -r '.proposal.status // .status')"
		case "$status" in *VOTING_PERIOD|*DEPOSIT_PERIOD) sleep 5; left=$(( left - 5 )) ;; *) break ;; esac
	done
	echo "  proposal $id: $status $(P query gov proposal "$id" -o json | jq -r '.proposal.failed_reason // empty')"
	case "$status" in *PASSED) ;; *) return 1 ;; esac
}

# owner_exec C FILE KEY=VALUE...: runs a consumer owner action with
# <owner-authority> filled in, signed by the `owner` key on consumer C.
owner_exec() {
	local c="$1" f="$2" owner; shift 2
	owner="$(C "$c" query vaasconsumer owner-authority -o json | jq -r .authority)"
	# <current-params>: the consumer's parameters as they are, to edit with JQ
	jq --argjson p "$(C "$c" query vaasconsumer params -o json | jq -c .params)" \
		'(.. | select(. == "<current-params>")) |= $p' "$f" > data/.owner-exec.in.json
	fill_template data/.owner-exec.in.json "owner-authority=$owner" "$@" > "data/.owner-exec.json"
	dc --profile "$c" cp data/.owner-exec.json "$c-0:/tmp/owner-exec.json"
	log "owner-exec on $c: $(jq -r '[.messages[]["@type"]] | join(", ")' data/.owner-exec.json)"
	ctx "$c" vaasconsumer owner-exec /tmp/owner-exec.json --from owner
}

# check_proposals: fills every template in proposals/ with sample values and
# has the binaries decode it (--generate-only, nothing is broadcast), so a
# template that no longer matches the provider's or consumer's messages fails.
check_proposals() {
	local f gov owner sample=(consumer-id=0 frozen-provider-client-id=07-tendermint-0 frozen-client-id=07-tendermint-0
		substitute-client-id=07-tendermint-9 chain-id-the-client-tracks=sample-1 halt-height=1000000 upgrade-name=sample) bad=0
	gov="$(P query auth module-account gov -o json | jq -r '.account.value.address // .account.base_account.address')"
	owner="$(C ref query vaasconsumer owner-authority -o json | jq -r .authority)"
	for f in proposals/*.json; do
		case "$(basename "$f")" in
		owner-exec-*)
			jq --argjson p "$(C ref query vaasconsumer params -o json | jq -c .params)" \
				'(.. | select(. == "<current-params>")) |= $p' "$f" > data/.check.in.json
			fill_template data/.check.in.json "owner-authority=$owner" "${sample[@]}" > data/.check.json
			dc --profile ref cp data/.check.json ref-0:/tmp/check.json >/dev/null 2>&1
			if C ref tx vaasconsumer owner-exec /tmp/check.json --from owner --keyring-backend test \
				--chain-id "$REF_CHAIN_ID" --generate-only >/dev/null 2>data/.check.err; then echo "  ok   $f"
			else echo "  FAIL $f: $(grep -v '^$' data/.check.err | tail -1 | cut -c1-200)"; bad=1; fi ;;
		*)
			fill_template "$f" "gov-authority=$gov" "${sample[@]}" > data/.check.json
			dc cp data/.check.json atomone-0:/tmp/check.json >/dev/null 2>&1
			if P tx gov submit-proposal /tmp/check.json --from user --keyring-backend test \
				--chain-id "$PROVIDER_CHAIN_ID" --generate-only >/dev/null 2>data/.check.err; then echo "  ok   $f"
			else echo "  FAIL $f: $(grep -v '^$' data/.check.err | tail -1 | cut -c1-200)"; bad=1; fi ;;
		esac
	done
	[ "$bad" = 0 ]
}

# Every long-running service: the provider, each consumer's nodes, each relayer.
run_profiles() { local a=(); for c in $CONSUMERS; do a+=(--profile "$c" --profile "relayer-$c"); done; echo "${a[@]}"; }
stop() { dc --profile '*' down --remove-orphans; }
start() {
	[ -d data/atomone ] || die "no network in ./data: run up first"
	# shellcheck disable=SC2046
	dc $(run_profiles) up -d
	wait_height atomone-0 "$(( $(jq -r '.initial_height // "1"' data/atomone/val0/config/genesis.json) + 1 ))" "$PROVIDER_CHAIN_ID"
	status
}
clean() { stop; rm -rf data; echo "data removed"; }

case "${1:-}" in
	up) provider; for c in $CONSUMERS; do consumer "$c"; done; status ;;
	provider) provider ;;
	consumer) consumer "${2:?consumer name}" ;;
	register|start_consumer|relayer|declare_clients|fund_pool|wait_vsc) "$1" "${2:?consumer name}" ;;
	smoke) smoke ;;
	delegate) delegate ;;
	relayer-restart) relayer_restart ;;
	fee-payouts) fee_payouts ;;
	propose) shift; propose "$@" ;;
	owner-exec) shift; owner_exec "$@" ;;
	check-proposals) check_proposals ;;
	status) status ;;
	stop|down) stop ;;
	start) start ;;
	clean) clean ;;
	*) sed -n '2,15p' "$0"; exit 1 ;;
esac
