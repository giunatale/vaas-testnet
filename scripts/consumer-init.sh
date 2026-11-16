#!/usr/bin/env bash
# Initializes one consumer (CONSUMER=ref|gno|photon): NUM_VALIDATORS homes
# under /data/$CONSUMER/val<i>, sharing a genesis that carries the
# provider-built consumer genesis (/data/$CONSUMER/consumer_genesis.json,
# fetched by the orchestrator once the consumer launched on the provider),
# the operator accounts imported from the provider's mnemonics, and, on a
# photon-fees consumer, photon_fees_enabled. Each node signs with its
# validator's provider consensus key (no key assignment on the localnet).
# Runs inside the consumer's image (<consumer>-tools).
set -euo pipefail
source /scripts/node-config.sh

U="$(echo "$CONSUMER" | tr '[:lower:]' '[:upper:]')"
v() { local n="${U}_$1"; echo "${!n}"; }
B="$(v BINARY)"; CHAIN_ID="$(v CHAIN_ID)"; DENOM="$(v DENOM)"; PHOTON_FEES="$(v PHOTON_FEES)"
D="/data/$CONSUMER"
K=/data/keys
CG="$D/consumer_genesis.json"
LAST=$((NUM_VALIDATORS - 1))
[ -s "$CG" ] || { echo "missing $CG: launch the consumer on the provider first"; exit 1; }
home() { echo "$D/val$1"; }
V0="$(home 0)"
find "$D" -mindepth 1 -maxdepth 1 -name 'val*' -exec rm -rf {} +

for i in $(seq 0 $LAST); do
	H="$(home "$i")"
	$B init "$CONSUMER-$i" --default-denom "$DENOM" --chain-id "$CHAIN_ID" --home "$H" >/dev/null 2>&1
	$B config set client chain-id "$CHAIN_ID" --home "$H"
	$B config set client keyring-backend test --home "$H"
done

for a in owner user "relayer-$CONSUMER"; do
	jq -r .mnemonic "$K/$a.json" | $B keys add "$a" --recover --home "$V0" --keyring-backend test >/dev/null 2>&1
	# Until the owner pins the provider client, the consumer admits only
	# bootstrap traffic: the relayer's account must exist from genesis.
	$B genesis add-genesis-account "$a" "10000000000${DENOM}" --home "$V0" --keyring-backend test
done

G="$V0/config/genesis.json"
jq --slurpfile cg "$CG" '.app_state.vaasconsumer = $cg[0]' "$G" > "$G.tmp" && mv "$G.tmp" "$G"
if [ "$PHOTON_FEES" = "true" ]; then
	# The provider-built consumer genesis always writes photon fees off;
	# enabling them is the consumer's own genesis choice.
	jq '.app_state.vaasconsumer.params.photon_fees_enabled = true' "$G" > "$G.tmp" && mv "$G.tmp" "$G"
fi
if jq -e '.app_state.gnovm' "$G" >/dev/null; then
	jq --arg d "$DENOM" '.app_state.gnovm.params.default_deposit |= sub("[a-z]+$"; $d)
		| .app_state.gnovm.params.storage_price |= sub("[a-z]+$"; $d)' "$G" > "$G.tmp" && mv "$G.tmp" "$G"
fi
$B genesis validate "$G" --home "$V0"

# A photon-fees consumer starts with a zero node floor: before the pin the
# relayer's deliveries pass free, and after it fees are in the voucher, whose
# floor the orchestrator sets once the voucher denom exists.
if [ "$PHOTON_FEES" = "true" ]; then gas="0${DENOM}"; else gas="0.01${DENOM}"; fi

ids=()
for i in $(seq 0 $LAST); do ids+=("$($B comet show-node-id --home "$(home "$i")")"); done
for i in $(seq 0 $LAST); do
	H="$(home "$i")"
	[ "$i" -ne 0 ] && cp "$G" "$H/config/genesis.json"
	cp "/data/atomone/val$i/config/priv_validator_key.json" "$H/config/priv_validator_key.json"
	configure_node "$H" "$CONSUMER" "$i" "$gas"
	set_peers "$H" "$CONSUMER" "$i" "${ids[@]}"
done
chmod -R a+rwX "$D"
echo "consumer initialized: $CHAIN_ID ($CONSUMER), photon fees $PHOTON_FEES"
