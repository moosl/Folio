#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh --test
logdir=$(mktemp -d)
profile="local.folio.integration.$(uuidgen)"
open -n -W --env "FOLIO_TEST_PROFILE=$profile" --stdout "$logdir/out" --stderr "$logdir/err" .build/tests/Folio.app
cat "$logdir/out" "$logdir/err"
grep -q '^Verified workspace at ' "$logdir/out"
project=$(sed -n 's/^Verified workspace at //p' "$logdir/out")
mv "$project/session-gone.swift" "$project/session-renamed.swift"
open -n -W --env "FOLIO_TEST_PROFILE=$profile" --env "FOLIO_TEST_REOPEN=$project" --stdout "$logdir/reopen" --stderr "$logdir/reopen-err" .build/tests/Folio.app
cat "$logdir/reopen" "$logdir/reopen-err"
grep -q '^Verified project relaunch$' "$logdir/reopen"
source_dir="$logdir/source-files"
mkdir "$source_dir"
source_dir=$(cd "$source_dir" && pwd -P)
cp app/Editor.swift "$source_dir/Start.swift"
open -n -W --env "FOLIO_TEST_SOURCE_DIR=$source_dir" --stdout "$logdir/sources" --stderr "$logdir/source-errors" -a "$PWD/.build/tests/Folio.app" "$source_dir/Start.swift"
cat "$logdir/sources" "$logdir/source-errors"
grep -q '^Verified .* source files' "$logdir/sources"
