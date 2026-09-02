#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from explicit section lists and return what the renderer
# produced, so every category badge is asserted through the real template.
# Unused sections default to [] so a test names only the rows it cares about.
render() {  # <home> [--underway <json>] [--landed <json>] [--charted <json>] [--more <n>] [--warning-more <n>]
  local home=$1 underway='[]' landed='[]' charted='[]' more=0 warning_more=0 data="$1/payload.json"
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --underway) underway=$2 ;;
      --landed) landed=$2 ;;
      --charted) charted=$2 ;;
      --more) more=$2 ;;
      --warning-more) warning_more=$2 ;;
      *) fail "render: unknown option $1" ;;
    esac
    shift 2
  done
  jq -n --argjson underway "$underway" --argjson landed "$landed" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:$landed,
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" --charted '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" --charted '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" --charted '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" --charted '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' --warning-more 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_gated_and_actionable_queued_work_badge_differently() {
  local home out
  home=$(make_home queued-categories)
  out=$(render "$home" --charted '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' --more 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and ([.charted[1].badges[] | .text] == ["ready"])
      and ([.charted[1].badges[] | .tone] == ["online"])
  ' >/dev/null || fail "gated and actionable queued work did not badge differently: $out"
  pass "held work reads as waiting while ungated dispatchable work reads as ready"
}

test_every_queued_row_carries_exactly_one_category_badge() {
  local home out
  home=$(make_home queued-coverage)
  out=$(render "$home" --charted '[
    {"id":"held-no-reason","repo":"sample","title":"Held without a reason","reason":"","dispatchable":false},
    {"id":"held-with-reason","repo":"sample","title":"Held with a reason","reason":"after the freeze","dispatchable":false,"kind":"queued"},
    {"id":"actionable","repo":"sample","title":"Actionable","reason":"","dispatchable":true,"kind":"queued"}
  ]')
  printf '%s' "$out" | jq -e '
    (.charted | length) == 3
      and all(.charted[]; (.badges | length) == 1)
      and ([.charted[0].badges[] | .text] == ["waiting"])
      and ([.charted[0].badges[] | .tone] == ["warn"])
      and ([.charted[1].badges[] | .text] == ["waiting"])
      and ([.charted[2].badges[] | .text] == ["ready"])
  ' >/dev/null || fail "a queued row rendered without exactly one category badge: $out"
  pass "every queued row badges ready or waiting, including a held row with no reason"
}

test_a_merged_pr_reads_differently_from_another_finished_deliverable() {
  local home out
  home=$(make_home landed-categories)
  out=$(render "$home" --landed '[
    {"id":"shipped","repo":"sample","what":"Shipped the fix","owner":"crew","pr_url":"https://github.com/o/r/pull/42"},
    {"id":"probed","repo":"sample","what":"Investigated the outage","owner":"scout"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.landed | length) == 2
      and (.landed[0] | .title == "Shipped the fix"
        and [.badges[] | .text] == ["merged PR"] and .hasPr == true)
      and (.landed[1] | .title == "Investigated the outage"
        and [.badges[] | .text] == ["completed"] and .hasPr == false)
  ' >/dev/null || fail "a merged PR did not read differently from a finished investigation: $out"
  pass "a landed merged PR badges merged PR while a finished investigation badges completed"
}

test_underway_rows_badge_their_current_state() {
  local home out
  home=$(make_home underway-state)
  out=$(render "$home" --underway '[
    {"id":"one","repo":"sample","state":"working","doing":"Building the feature","kind":"ship"},
    {"id":"two","repo":"sample","state":"validating","doing":"Watching PR checks","kind":"ship"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.underway | length) == 2
      and ([.underway[0].badges[] | .text] == ["working"])
      and ([.underway[0].badges[] | .tone] == ["online"])
      and ([.underway[1].badges[] | .text] == ["validating"])
      and ([.underway[1].badges[] | .tone] == ["info"])
  ' >/dev/null || fail "underway rows did not badge their distinct current states: $out"
  pass "underway rows badge active work and validation/monitoring distinctly"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_gated_and_actionable_queued_work_badge_differently
test_every_queued_row_carries_exactly_one_category_badge
test_a_merged_pr_reads_differently_from_another_finished_deliverable
test_underway_rows_badge_their_current_state
