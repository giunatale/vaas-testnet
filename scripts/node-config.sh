# Shared node configuration, sourced by the init scripts (run inside the
# chain images). configure_node HOME CHAIN_HOST_PREFIX INDEX MIN_GAS_PRICES
configure_node() {
	local H="$1" host_prefix="$2" i="$3" gas="$4"
	local cfg="$H/config/config.toml" app="$H/config/app.toml"
	sed -i "s#^timeout_commit = .*#timeout_commit = \"${TIMEOUT_COMMIT}\"#" "$cfg"
	sed -i 's#laddr = "tcp://127.0.0.1:26657"#laddr = "tcp://0.0.0.0:26657"#' "$cfg"
	sed -i 's#^cors_allowed_origins = .*#cors_allowed_origins = ["*"]#' "$cfg"
	sed -i 's#^addr_book_strict = .*#addr_book_strict = false#' "$cfg"
	sed -i 's#^allow_duplicate_ip = .*#allow_duplicate_ip = true#' "$cfg"
	sed -i 's#^prometheus = .*#prometheus = true#' "$cfg"
	sed -i "s#^moniker = .*#moniker = \"${host_prefix}-${i}\"#" "$cfg"
	sed -i "s#^minimum-gas-prices = .*#minimum-gas-prices = \"${gas}\"#" "$app"
	# keep every block: a downtime challenge reads commits up to the horizon
	sed -i 's#^min-retain-blocks = .*#min-retain-blocks = 0#' "$app"
	# API, gRPC and the API's CORS on every interface
	awk 'BEGIN{s=""} /^\[/{s=$0} s=="[api]" && /^enable = /{$0="enable = true"} s=="[api]" && /^enabled-unsafe-cors = /{$0="enabled-unsafe-cors = true"} {print}' "$app" > "$app.tmp" && mv "$app.tmp" "$app"
	sed -i 's#address = "tcp://localhost:1317"#address = "tcp://0.0.0.0:1317"#' "$app"
	sed -i 's#address = "localhost:9090"#address = "0.0.0.0:9090"#' "$app"
}

# set_peers HOME CHAIN_HOST_PREFIX INDEX NODE_IDS... : every other node of the
# chain by its compose hostname
set_peers() {
	local H="$1" host_prefix="$2" i="$3"; shift 3
	local peers="" j=0
	for id in "$@"; do
		if [ "$j" -ne "$i" ]; then
			peers="${peers:+$peers,}${id}@${host_prefix}-${j}:26656"
		fi
		j=$((j + 1))
	done
	sed -i "s#^persistent_peers = .*#persistent_peers = \"${peers}\"#" "$H/config/config.toml"
}
