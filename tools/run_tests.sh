#!/usr/bin/env bash
# Run every tests/test_*.gd headless and report which ones fail.
#   tools/run_tests.sh                      # all tests
#   tools/run_tests.sh tests/test_hen.gd    # some of them
# GODOT (default: godot) is the Godot binary; TEST_TIMEOUT (default: 300) the seconds allowed per test.
#
# A test passes when Godot exits with 0 and prints a "… OK" line, with no SCRIPT ERROR. The exit code
# alone isn't enough: a failed assert() leaves Godot running instead of quitting, hence the timeout.
# Assets must have been imported once: godot --headless --path . --import
set -u
cd "$(dirname "$0")/.."

godot=${GODOT:-godot}
limit=${TEST_TIMEOUT:-300}
tests=("$@")
[ ${#tests[@]} -eq 0 ] && tests=(tests/test_*.gd)

log=$(mktemp)
trap 'rm -f "$log"' EXIT
failed=()
for t in "${tests[@]}"; do
	start=$SECONDS
	timeout "$limit" "$godot" --headless --path . -s "$t" >"$log" 2>&1
	rc=$?
	took=$((SECONDS - start))
	if [ $rc -eq 0 ] && grep -qE '^[A-Z][A-Z ]* OK\b' "$log" && ! grep -q 'SCRIPT ERROR' "$log"; then
		echo "PASS $t (${took}s)"
	else
		[ $rc -eq 124 ] && why="timed out after ${limit}s" || why="exit code $rc"
		echo "FAIL $t ($why, ${took}s)"
		sed 's/^/    /' "$log"
		failed+=("$t")
	fi
done

echo
if [ ${#failed[@]} -gt 0 ]; then
	echo "${#failed[@]} of ${#tests[@]} tests failed: ${failed[*]}"
	exit 1
fi
echo "All ${#tests[@]} tests passed"
