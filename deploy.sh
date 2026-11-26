#!/bin/bash
# Tapster deploy script for macOS and Linux.
#
#   ./deploy.sh            deploy tapmath, tapster and tab to the onyx testnet
#   ./deploy.sh status     show whether each package is enabled yet
#   ./deploy.sh reporters  create 2 extra reporter keys, fund and stake them
#
# It downloads gnokey (checksum-verified) into ./bin, creates or reuses a key
# named tapster-admin, rewrites the package paths to that key's namespace,
# submits the three packages in dependency order and waits for the testnet's
# approver to enable them. Nothing is sent without showing you first.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="v1.8.0-rc.1"                         # the release onyx-1 runs
CHAIN_ID="${CHAIN_ID:-onyx-1}"
RPC="${RPC:-https://rpc.onyx.testnets.gno.land:443}"
GNOWEB="${GNOWEB:-https://onyx.testnets.gno.land}"
GPAS="${GPAS:-https://gpas.latest.testnets.gno.land}"
KEY="${KEY:-tapster-admin}"
GAS_FEE="${GAS_FEE:-60000ugnot}"             # 1 ugnot per 1000 gas on onyx
GAS_WANTED="${GAS_WANTED:-60000000}"
MAX_DEPOSIT="${MAX_DEPOSIT:-25000000ugnot}"   # storage deposit cap per package
ADDPKG_GAS="${ADDPKG_GAS:-120000000}"          # tapster needs ~66M; headroom
ADDPKG_FEE="${ADDPKG_FEE:-130000ugnot}"
NEED_UGNOT=40000000                           # ~40 GNOT: deploy (~12), stake+fund (10), 2 extra reporters (8), gas

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "\033[33m▸\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# gnokey
GNOKEY="$(command -v gnokey || true)"
if [ -z "$GNOKEY" ]; then
  mkdir -p bin
  GNOKEY="$PWD/bin/gnokey"
  if [ ! -x "$GNOKEY" ]; then
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
    [ "$arch" = "x86_64" ] && arch=amd64; [ "$arch" = "aarch64" ] && arch=arm64
    f="gnokey_${os}_${arch}"; base="https://github.com/gnolang/gno/releases/download/$VERSION"
    info "Downloading $f $VERSION"
    curl -fsSL -o "bin/$f" "$base/$f"; curl -fsSL -o bin/CHECKSUMS.txt "$base/CHECKSUMS.txt"
    want="$(grep " $f\$" bin/CHECKSUMS.txt | awk '{print $1}')"
    got="$(shasum -a 256 "bin/$f" 2>/dev/null | awk '{print $1}' || sha256sum "bin/$f" | awk '{print $1}')"
    [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $f"
    mv "bin/$f" "$GNOKEY"; chmod +x "$GNOKEY"
    xattr -d com.apple.quarantine "$GNOKEY" 2>/dev/null || true
  fi
fi
info "gnokey: $GNOKEY"

# Run a gnokey transaction. With KEY_PASSWORD set the password is piped in;
# otherwise gnokey asks for it.
tx() {
  if [ -n "${KEY_PASSWORD+x}" ]; then
    # flags must come before the key name, which is the last argument
    local n=$# keyname="${!#}"
    printf '%s\n' "$KEY_PASSWORD" | "$GNOKEY" maketx "${@:1:$((n-1))}" -insecure-password-stdin "$keyname"
  else
    "$GNOKEY" maketx "$@"
  fi
}

addr_of() { "$GNOKEY" list 2>/dev/null | grep -E "\. $1 \(" | sed -E 's/.*addr: (g1[0-9a-z]+).*/\1/'; }
balance() { "$GNOKEY" query "bank/balances/$1" -remote "$RPC" 2>/dev/null | sed -nE 's/^data: "([0-9]*)ugnot"$/\1/p'; }
query()   { "$GNOKEY" query "$1" -data "$2" -remote "$RPC" 2>/dev/null | sed -n 's/^data: //p'; }
pkg_status() { query vm/qpkgmeta_json "$1" | grep -oE '"status": ?"[a-z]+"' | head -1 | sed -E 's/.*"([a-z]+)"$/\1/'; }

ensure_key() {
  local name="$1"
  if [ -z "$(addr_of "$name")" ]; then
    bold "Creating key '$name'. WRITE DOWN THE MNEMONIC it shows; it is the only backup."
    "$GNOKEY" add "$name"
  fi
  addr_of "$name"
}

ADMIN="$(ensure_key "$KEY")"
[ -n "$ADMIN" ] || die "could not read the address of key $KEY"
TAPMATH="gno.land/p/$ADMIN/tapmath/v0"
TAPSTER="gno.land/r/$ADMIN/tapster/v0"
TAB="gno.land/r/$ADMIN/tab/v0"
LASTCALL="gno.land/r/$ADMIN/lastcall/v0"

show_status() {
  for p in "$TAPMATH" "$TAPSTER" "$TAB" "$LASTCALL"; do
    s="$(pkg_status "$p")"; printf "  %-70s %s\n" "$p" "${s:-unknown}"
  done
  echo "  Approver verdicts: https://gpas.latest.testnets.gno.land/?path=<package path>"
}

if [ "${1:-}" = "status" ]; then show_status; exit 0; fi

# ---------------------------------------------------------------------------
# Extra reporters (optional, for a livelier demo)
if [ "${1:-}" = "reporters" ]; then
  for n in tapster-r2 tapster-r3; do
    a="$(ensure_key "$n")"; b="$(balance "$a")"
    if [ "${b:-0}" -lt 3500000 ]; then
      info "Sending 4 GNOT from $KEY to $n ($a)"
      tx send -to "$a" -send 4000000ugnot -gas-fee 20000ugnot -gas-wanted 2000000 \
        -broadcast -chainid "$CHAIN_ID" -remote "$RPC" "$KEY"
    fi
    info "Staking 2 GNOT as $n"
    tx call -pkgpath "$TAPSTER" -func Stake -args "$n" -send 2000000ugnot \
      -gas-fee "$GAS_FEE" -gas-wanted "$GAS_WANTED" -broadcast -chainid "$CHAIN_ID" -remote "$RPC" "$n"
  done
  bold "Done. Add them to bot/.env: REPORTER_KEYS=$KEY,tapster-r2,tapster-r3"
  exit 0
fi

# ---------------------------------------------------------------------------
# Funds
bold "Deployer: $ADMIN"
bal="$(balance "$ADMIN")"; bal="${bal:-0}"
while [ "$bal" -lt "$NEED_UGNOT" ]; do
  info "Balance $((bal/1000000)) GNOT. Need about $((NEED_UGNOT/1000000)) GNOT on $CHAIN_ID."
  info "Open https://faucet.gno.land, choose the current testnet, paste $ADMIN and request (repeat if needed)."
  (command -v open >/dev/null && open "https://faucet.gno.land") || true
  read -r -p "Press Enter after requesting from the faucet (or type 'skip' to continue anyway): " ans
  [ "$ans" = "skip" ] && break
  bal="$(balance "$ADMIN")"; bal="${bal:-0}"
done

# ---------------------------------------------------------------------------
# Build: rewrite namespace and admin
rm -rf dist && mkdir -p dist
cp -R gno/p/tapmath dist/tapmath; cp -R gno/r/tapster dist/tapster; cp -R gno/r/tab dist/tab; cp -R gno/r/lastcall dist/lastcall
find dist -type f \( -name '*.gno' -o -name 'gnomod.toml' \) -print0 | xargs -0 sed -i.bak "s#gno.land/p/tapsterns/#gno.land/p/$ADMIN/#g; s#gno.land/r/tapsterns/#gno.land/r/$ADMIN/#g"
sed -i.bak "s#var admin address = \"ADMIN_PLACEHOLDER\"#var admin address = \"$ADMIN\"#" dist/tapster/tapster.gno
find dist -name '*.bak' -delete
# Tests live in the repo; leaving them out of the upload keeps the package's
# typecheck and enable gas well under the testnet approver's limit.
find dist -name '*_test.gno' -delete
grep -q "\"$ADMIN\"" dist/tapster/tapster.gno || die "admin address was not written"
cp web/index.html dist/index.html; sed "s#TAPSTER_NAMESPACE#$ADMIN#" web/config.js > dist/config.js

# ---------------------------------------------------------------------------
# Submit
deploy() {
  local dir="$1" path="$2" s
  s="$(pkg_status "$path")"
  if [ -n "$s" ] && [ "$s" != "absent" ]; then info "$path is already on chain ($s), skipping"; return; fi
  bold "Submitting $path"
  tx addpkg -pkgpath "$path" -pkgdir "$dir" -max-deposit "$MAX_DEPOSIT" \
    -gas-fee "$ADDPKG_FEE" -gas-wanted "$ADDPKG_GAS" -broadcast -chainid "$CHAIN_ID" -remote "$RPC" "$KEY"
}
deploy dist/tapmath "$TAPMATH"
deploy dist/tapster "$TAPSTER"
deploy dist/tab "$TAB"
deploy dist/lastcall "$LASTCALL"

bold "Waiting for the testnet approver to enable the packages (usually seconds to minutes)…"
for i in $(seq 1 60); do
  a="$(pkg_status "$TAPMATH")"; b="$(pkg_status "$TAPSTER")"; c="$(pkg_status "$TAB")"; d="$(pkg_status "$LASTCALL")"
  printf "\r  tapmath=%-8s tapster=%-8s tab=%-8s lastcall=%-8s" "${a:-?}" "${b:-?}" "${c:-?}" "${d:-?}"
  [ "$a" = "live" ] && [ "$b" = "live" ] && [ "$c" = "live" ] && [ "$d" = "live" ] && break
  sleep 10
done
echo
show_status

# ---------------------------------------------------------------------------
# Become the first reporter and seed the reward pool
if [ "$(pkg_status "$TAPSTER")" = "live" ]; then
  stake="$(query vm/qeval "$TAPSTER.ReporterStake(\"$ADMIN\")" | head -1)"
  if echo "$stake" | grep -q "(0 int64)"; then
    info "Staking 5 GNOT as reporter 'Tapster Genesis'"
    tx call -pkgpath "$TAPSTER" -func Stake -args "Tapster Genesis" -send 5000000ugnot \
      -gas-fee "$GAS_FEE" -gas-wanted "$GAS_WANTED" -broadcast -chainid "$CHAIN_ID" -remote "$RPC" "$KEY"
    info "Funding the GNOT-USD reward pool with 5 GNOT"
    tx call -pkgpath "$TAPSTER" -func Fund -args "GNOT-USD" -send 5000000ugnot \
      -gas-fee "$GAS_FEE" -gas-wanted "$GAS_WANTED" -broadcast -chainid "$CHAIN_ID" -remote "$RPC" "$KEY"
  fi
fi

[ -f bot/.env ] || sed "s#^TAPSTER_REALM=.*#TAPSTER_REALM=$TAPSTER#; s#^REPORTER_KEYS=.*#REPORTER_KEYS=$KEY#" bot/.env.example > bot/.env

bold "Done."
echo "  Oracle:   $GNOWEB/r/$ADMIN/tapster/v0"
echo "  Tab demo: $GNOWEB/r/$ADMIN/tab/v0"
echo "  Last Call: $GNOWEB/r/$ADMIN/lastcall/v0"
echo "  Web app:  dist/index.html (or any host with ?ns=$ADMIN)"
echo "  Next:     ./deploy.sh reporters   then   cd bot && node reporter.mjs"
