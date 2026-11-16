#!/usr/bin/env bash
# Initializes the AtomOne provider: NUM_VALIDATORS homes under
# /data/atomone/val<i>, one validator each, one shared genesis patched with
# the parameter profile, and the operator accounts (owner, user, one relayer
# per consumer) in val0's keyring, their mnemonics under /data/keys.
# Runs inside the AtomOne image (atomone-tools).
set -euo pipefail
source /scripts/node-config.sh

B=atomoned
D=/data/atomone
K=/data/keys
LAST=$((NUM_VALIDATORS - 1))
rm -rf "$D" "$K"
mkdir -p "$D" "$K"
home() { echo "$D/val$1"; }
V0="$(home 0)"

for i in $(seq 0 $LAST); do
	H="$(home "$i")"
	$B init "atomone-$i" --default-denom "$PROVIDER_DENOM" --chain-id "$PROVIDER_CHAIN_ID" --home "$H" >/dev/null 2>&1
	$B config set client chain-id "$PROVIDER_CHAIN_ID" --home "$H"
	$B config set client keyring-backend test --home "$H"
	$B keys add val --home "$H" --keyring-backend test --output json > "$K/val$i.json" 2>&1
done

# Operator accounts. Their mnemonics are imported on the consumers too, so
# the owner and the relayers have the same address bytes on every chain.
ACCOUNTS="owner user"
for c in $CONSUMERS; do ACCOUNTS="$ACCOUNTS relayer-$c"; done
for a in $ACCOUNTS; do
	$B keys add "$a" --home "$V0" --keyring-backend test --output json > "$K/$a.json" 2>&1
done

both="${PROVIDER_DENOM},${PROVIDER_FEE_DENOM}"
for i in $(seq 0 $LAST); do
	addr="$($B keys show val -a --home "$(home "$i")" --keyring-backend test)"
	$B genesis add-genesis-account "$addr" "1000000000000${PROVIDER_DENOM},1000000000000${PROVIDER_FEE_DENOM}" --home "$V0"
done
$B genesis add-genesis-account owner "10000000000${PROVIDER_DENOM},10000000000${PROVIDER_FEE_DENOM}" --home "$V0" --keyring-backend test
$B genesis add-genesis-account user "10000000000${PROVIDER_DENOM},10000000000${PROVIDER_FEE_DENOM}" --home "$V0" --keyring-backend test
for c in $CONSUMERS; do
	$B genesis add-genesis-account "relayer-$c" "1000000000${PROVIDER_DENOM},1000000000${PROVIDER_FEE_DENOM}" --home "$V0" --keyring-backend test
done

for i in $(seq 0 $LAST); do
	H="$(home "$i")"
	[ "$i" -ne 0 ] && cp "$V0/config/genesis.json" "$H/config/genesis.json"
	$B genesis gentx val "1000000000${PROVIDER_DENOM}" --home "$H" --keyring-backend test --chain-id "$PROVIDER_CHAIN_ID" >/dev/null 2>&1
	[ "$i" -ne 0 ] && cp "$H"/config/gentx/*.json "$V0/config/gentx/"
done
$B genesis collect-gentxs --home "$V0" >/dev/null 2>&1

G="$V0/config/genesis.json"
jq \
	--arg unbonding "$UNBONDING_TIME" --arg rotfee "$KEY_ROTATION_FEE" --arg denom "$PROVIDER_DENOM" --arg fee "$PROVIDER_FEE_DENOM" \
	--arg vote "$VOTING_PERIOD" --arg sw "$SLASHING_SIGNED_BLOCKS_WINDOW" --arg sm "$SLASHING_MIN_SIGNED_PER_WINDOW" --arg sj "$SLASHING_DOWNTIME_JAIL_DURATION" \
	--arg epoch "$BLOCKS_PER_EPOCH" --arg vto "$VAAS_TIMEOUT_PERIOD" --arg fpb "$FEES_PER_BLOCK_AMOUNT" --arg mdb "$MIN_DEPOSIT_BLOCKS" \
	--arg lgf "$LIVENESS_GRACE_FRACTION" --arg mpd "$MAX_PAUSE_DURATION" --arg eed "$EQUIVOCATION_EXECUTION_DELAY" --arg rvdm "$REMOVAL_VOTE_DEFERRAL_MARGIN" \
	--arg dsf "$DOWNTIME_SLASH_FRACTION" --arg dgp "$DOWNTIME_GRACE_PERIOD" --arg dsw "$DOWNTIME_SIGNED_BLOCKS_WINDOW" --arg dms "$DOWNTIME_MIN_SIGNED_PER_WINDOW" \
	--arg dma "$DOWNTIME_EVIDENCE_MAX_AGE" --arg dcw "$DOWNTIME_CHALLENGE_WINDOW" '
	.app_state.staking.params.unbonding_time = $unbonding
	| .app_state.staking.params.key_rotation_fee = {denom: $denom, amount: $rotfee}
	| .app_state.gov.params.voting_period = $vote
	| .app_state.gov.params.max_deposit_period = $vote
	| .app_state.gov.params.quorum_timeout = "0s"
	| .app_state.gov.params.max_voting_period_extension = $vote
	| .app_state.gov.params.min_deposit_throttler.update_period = $vote
	| .app_state.gov.params.min_initial_deposit_throttler.update_period = $vote
	| .app_state.slashing.params.signed_blocks_window = $sw
	| .app_state.slashing.params.min_signed_per_window = $sm
	| .app_state.slashing.params.downtime_jail_duration = $sj
	| .app_state.dynamicfee.params.fee_denom = $fee
	| .app_state.vaasprovider.params.blocks_per_epoch = $epoch
	| .app_state.vaasprovider.params.vaas_timeout_period = $vto
	| .app_state.vaasprovider.params.fees_per_block_amount = $fpb
	| .app_state.vaasprovider.params.min_deposit_blocks = $mdb
	| .app_state.vaasprovider.params.liveness_grace_fraction = $lgf
	| .app_state.vaasprovider.params.max_pause_duration = $mpd
	| .app_state.vaasprovider.params.equivocation_execution_delay = $eed
	| .app_state.vaasprovider.params.removal_vote_deferral_margin = $rvdm
	| .app_state.vaasprovider.params.infraction_parameters.downtime.slash_fraction = $dsf
	| .app_state.vaasprovider.params.infraction_parameters.downtime_grace_period = $dgp
	| .app_state.vaasprovider.params.infraction_parameters.signed_blocks_window = $dsw
	| .app_state.vaasprovider.params.infraction_parameters.min_signed_per_window = $dms
	| .app_state.vaasprovider.params.infraction_parameters.downtime_evidence_max_age = $dma
	| .app_state.vaasprovider.params.infraction_parameters.downtime_challenge_window = $dcw
	' "$G" > "$G.tmp" && mv "$G.tmp" "$G"
$B genesis validate "$G" --home "$V0"

ids=()
for i in $(seq 0 $LAST); do ids+=("$($B comet show-node-id --home "$(home "$i")")"); done
for i in $(seq 0 $LAST); do
	H="$(home "$i")"
	[ "$i" -ne 0 ] && cp "$G" "$H/config/genesis.json"
	configure_node "$H" atomone "$i" "0.01${PROVIDER_DENOM},0.01${PROVIDER_FEE_DENOM}"
	set_peers "$H" atomone "$i" "${ids[@]}"
done
chmod -R a+rwX "$D" "$K"
echo "provider initialized: $PROVIDER_CHAIN_ID, $NUM_VALIDATORS validators, profile params applied"
