#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

shopt -s nullglob

here=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

# === Binaries ===

keygen="$here/target/release/solana-keygen"
validator="$here/target/release-with-debug/agave-validator"

# === Configuration ===

external_address=162.231.245.218
internal_address=192.168.1.30

ledger_dir="$here/profile-solana/ledger"
ledger_snapshots_dir="$here/profile-solana/ledger"
log_dir="$here/profile-solana/logs"

# bootstrap_external_address=entrypoint.mainnet-beta.solana.com

metrics_config=host=https://internal-metrics.solana.com:8086,db=illia-perf-db1,u=illia-perf-db1,p=password

keys_dir="$here/profile-solana/keys"
identity_keypair="$keys_dir/identity.json"

usage() {
  cat <<EOM
Usage:
  $0

Runs a validator for profiling purposes.
EOM
}

parse_arguments() {
  while [ $# -gt 0 ]; do
    name=$1
    shift

    case $name in
      -h|-\?|--help)
        usage
        exit
        ;;
      *)
        printf 'ERROR: Unexpected argument: "%s"\n\n' "$name" >&2
        usage
        exit 2
        ;;
    esac
  done
}

create_keypair_if_absent() {
  local keypair_path=$1

  if ! [ -e "$keypair_path" ]; then
    "$keygen" new --no-bip39-passphrase --silent \
      --outfile "$keypair_path" >/dev/null
  fi
}

get_or_create_pubkey() {
  local keypair_path=$1

  create_keypair_if_absent "$keypair_path"

  "$keygen" pubkey "$keypair_path"
}

# -- Main part --

# How to get RPC nodes:
#
# ```
# ❯ solana --url m leader-schedule \
#           | sed -e 's/^\s*[0-9]\+\s*//; /^\s*$/d' \
#           | sort -u \
#           | wc -l
# 824
# ```
# 
# Top 4 based on the slot count:
#
# ```
# ❯ solana --url m leader-schedule \
#           | sed -e 's/^\s*[0-9]\+\s*//; /^\s*$/d' \
#           | sort \
#           | uniq --count \
#           | sort --numeric-sort \
#           | tail --lines 4
#   11412 DRpbCBMxVnDK7maPM5tGv6MvB3v1sRMC86PZ8okm21hy
#   12532 Fd7btgySsrjuo25CJCj7oE7VPMyezDhnx7pZkj2v69Nk
#   13124 JupmVLmA8RoyTUbTMMuTtoPWHEiNQobxgTeGTrPNkzT
#   15188 HEL1USMZKAL2odpNBj2oCjffnFGaYwmbGmyewGv1e2TU
# ```

start_validator_as_systemd_service() {
  mkdir --parent "$ledger_dir"
  mkdir --parent "$ledger_snapshots_dir"
  mkdir --parent "$log_dir"

  declare -a service_env

  service_env+=(
    "--setenv=RUST_LOG=agave=info,solana=info,solana_ledger::blockstore_db=debug"
    "--setenv=SOLANA_METRICS_CONFIG=${metrics_config}"
  )

  declare -a args

  args+=(
    --bind-address "$internal_address"
    --dynamic-port-range 8100-8200
    --public-tpu-address "${external_address}:8004"
    --public-tpu-forwards-address "${external_address}:8037"
    --public-tvu-address "${external_address}:8005"

    # --expected-genesis-hash "$(< "$ledger_dir/genesis-hash" )"
    # This is needed because of `--wait-for-supermajority`.
    # --expected-shred-version "$(< "$ledger_dir/shred-version" )"

    --known-validator DRpbCBMxVnDK7maPM5tGv6MvB3v1sRMC86PZ8okm21hy
    --known-validator Fd7btgySsrjuo25CJCj7oE7VPMyezDhnx7pZkj2v69Nk
    --known-validator JupmVLmA8RoyTUbTMMuTtoPWHEiNQobxgTeGTrPNkzT
    --known-validator HEL1USMZKAL2odpNBj2oCjffnFGaYwmbGmyewGv1e2TU
    # --entrypoint "${bootstrap_external_address}:8001"
    --entrypoint entrypoint1.mainnet-beta.anza.xyz:8001
    --entrypoint entrypoint2.mainnet-beta.anza.xyz:8001
    --entrypoint entrypoint3.mainnet-beta.anza.xyz:8001
    --entrypoint entrypoint4.mainnet-beta.anza.xyz:8001

    --rpc-bind-address 0.0.0.0
    --rpc-port 8899
    # --full-rpc-api
    # --enable-rpc-transaction-history

    # --full-snapshot-interval-slots 200

    # We are not running a `solana-faucet` instance, so the faucet RPC is not
    # going to work.
    # --rpc-faucet-address 127.0.0.1:9900

    # It seems that without this flag the bootstrap node could run ahead of the
    # rest of the cluster.  And it seems to have trouble passing the epoch
    # boundary when the other nodes finally join.
    # --wait-for-supermajority 0
    # This is needed because of `--wait-for-supermajority`.
    # --expected-bank-hash "$(< "$ledger_dir/bank-hash")"

    --identity "$identity_keypair"
    # --vote-account "$vote_keypair"

    --ledger "$ledger_dir"
    --snapshots "$ledger_snapshots_dir"
    --log "$log_dir/profile-validator.log"

    # --init-complete-file "$here/node-init-complete"
  )

  sudo systemd-run \
    --no-ask-password \
    --uid="$(id --user --name)" \
    --gid="$(id --group --name)" \
    --unit "solana-validator.service" \
    --collect \
    --same-dir \
    "${service_env[@]}" \
    --service-type=exec \
    --property=LimitAS=infinity \
    --property=LimitRSS=infinity \
    --property=LimitCORE=infinity \
    --property=LimitNOFILE=1000000 \
    --property=LimitMEMLOCK=2000000000 \
    -- \
    "$validator" "${args[@]}"
}

main() {
  parse_arguments "$@"

  create_keypair_if_absent "$identity_keypair"

  start_validator_as_systemd_service
}

main "$@"
