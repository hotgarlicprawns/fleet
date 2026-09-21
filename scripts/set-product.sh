#!/bin/bash
# Wire the Dodo product into Fleet:  scripts/set-product.sh <product_id> <checkout_url>
#   product_id    e.g. pdt_xxxxxxxx (from the Dodo dashboard > Products)
#   checkout_url  the payment link Dodo shows for that product (copy it from the dashboard;
#                 this script deliberately does not guess the URL format)
# Optional: FLEET_LICENSE_API=https://test.dodopayments.com to point a build at test mode.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { sed -n '2,6p' "$0"; exit 1; }
case "$1" in pdt_*) ;; *) echo "product_id should look like pdt_..."; exit 1;; esac
case "$2" in https://*) ;; *) echo "checkout_url must be an https:// link"; exit 1;; esac
python3 - "$1" "$2" <<'PY'
import json, sys
p = json.load(open("product.json"))
p["productId"], p["checkoutUrl"] = sys.argv[1], sys.argv[2]
json.dump(p, open("product.json", "w"), indent=2); open("product.json", "a").write("\n")
print("product.json updated:", p["productId"], p["checkoutUrl"])
PY
echo "next: app/make-dmg.sh (rebuilds the app with the new product.json) and npm publish"
