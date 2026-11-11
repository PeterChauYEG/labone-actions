#!/usr/bin/env bash
# Checkout logic for the checkout-scripts composite action. Extracted into
# its own file (rather than living inline in action.yml's `run:` block) so
# checkout.test.sh can source it directly and test the retry/token logic
# against a local fake remote - see setup-node-yarn/install.sh for the
# established pattern this follows.
#
# LAB-5420: labone-actions is a PUBLIC repo, so every attempt below does a
# plain anonymous `git fetch` - no token/AUTHORIZATION header, no reliance
# on the caller's ambient GITHUB_TOKEN (scoped to the calling repo only -
# every OTHER repo 404s regardless of visibility, see LAB-2929) and no
# reliance on a caller-supplied PAT whose scope may not cover this repo
# (gamecraft's GH_PAT hit exactly that: "Repository not found" on every
# attempt despite the repo being public and the PAT working fine for
# gamecraft's own other needs - whatever scope mismatch caused that is
# irrelevant once the checkout itself doesn't need a token at all). The
# token param below is only used on the final retry, as a fallback for the
# day this repo goes private again - no existing caller needs to pass one.
set -uo pipefail

CHECKOUT_REMOTE_URL="${CHECKOUT_REMOTE_URL:-https://github.com/PeterChauYEG/labone-actions.git}"

# Single checkout attempt. $1 = target dir, $2 = 'true'/'false' whether to
# configure the token's AUTHORIZATION header before fetching, $3 = token
# (only read when $2 is 'true').
do_checkout() {
  local target="$1" use_token="$2" token="${3:-}"
  (
    set -e
    rm -rf "$target"
    git config --global --add safe.directory "$target"
    git init -q "$target"
    git -C "$target" remote add origin "$CHECKOUT_REMOTE_URL"
    if [ "$use_token" = "true" ] && [ -n "$token" ]; then
      local auth
      auth="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
      git -C "$target" config "http.https://github.com/.extraheader" "AUTHORIZATION: basic $auth"
    fi
    git -C "$target" config core.sparseCheckout true
    git -C "$target" sparse-checkout init --cone
    git -C "$target" sparse-checkout set scripts
    git -C "$target" fetch --depth=1 origin main
    git -C "$target" checkout -B main FETCH_HEAD
  )
}

# Three attempts total: two anonymous (15s then 45s backoff), and only the
# final one configures the token fallback (if any was provided). $1 =
# target dir, $2 = optional token.
checkout_with_retries() {
  local target="$1" token="${2:-}"

  if do_checkout "$target" false; then
    return 0
  fi

  echo "::warning::Anonymous checkout of labone-actions failed, retrying in 15s"
  sleep "${CHECKOUT_RETRY_SLEEP_1:-15}"
  if do_checkout "$target" false; then
    return 0
  fi

  echo "::warning::Anonymous checkout of labone-actions failed again, retrying in 45s (final attempt will use the token fallback if one was provided)"
  sleep "${CHECKOUT_RETRY_SLEEP_2:-45}"
  do_checkout "$target" true "$token"
}

# When executed directly (not sourced, as checkout.test.sh does), run the
# real checkout using the composite action's own inputs/env.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  target="${GITHUB_WORKSPACE}/${CHECKOUT_PATH}"
  checkout_with_retries "$target" "${CHECKOUT_TOKEN:-}"
fi
