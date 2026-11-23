#!/bin/bash
# Writes $AGENT_OFFICE_DIR/board.json: your open pull requests (and the ones merged in the last
# 24 h) with the stage each one is in. Needs the GitHub CLI (gh) logged in. Extra rows can be
# added by hand in $AGENT_OFFICE_DIR/tasks.json: [{"title":"...","stage":"waiting","note":"..."}].
set -uo pipefail
D="${AGENT_OFFICE_DIR:-$HOME/agent-office}"; mkdir -p "$D"
command -v gh >/dev/null || exit 0
# Optional $D/board.conf (shell):
#   BOARD_QUERY="base:develop"           extra GitHub search qualifiers
#   BOARD_TITLE_REGEX="MON-14(29|3[0-8])"  keep only titles that match
BOARD_QUERY=""; BOARD_TITLE_REGEX=""
[ -f "$D/board.conf" ] && . "$D/board.conf"
since=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d '1 day ago' +%Y-%m-%d)
Q='query($q:String!){search(query:$q,type:ISSUE,first:30){nodes{... on PullRequest{
  number title url isDraft reviewDecision state mergedAt repository{name}
  commits(last:1){nodes{commit{statusCheckRollup{state}}}}
  reviewThreads(first:100){nodes{isResolved}}}}}}'
fetch() { gh api graphql -f query="$Q" -f q="$1" 2>/dev/null || echo '{"data":{"search":{"nodes":[]}}}'; }
{ fetch "is:pr author:@me is:open archived:false $BOARD_QUERY sort:updated-desc"; fetch "is:pr author:@me is:merged merged:>=$since $BOARD_QUERY sort:updated-desc"; } |
jq -s --arg re "$BOARD_TITLE_REGEX" --slurpfile tasks <( [ -f "$D/tasks.json" ] && cat "$D/tasks.json" || echo '[]' ) '
  [ .[].data.search.nodes[] | select(.number != null) | select($re == "" or (.title | test($re))) |
    (.commits.nodes[0].commit.statusCheckRollup.state // "") as $ci |
    ([.reviewThreads.nodes[] | select(.isResolved | not)] | length) as $open |
    { repo: .repository.name, number: .number, title: .title,
      stage: (if .state == "MERGED" then "merged"
              elif .isDraft then "draft"
              elif ($ci == "FAILURE" or $ci == "ERROR") then "ci_red"
              elif $open > 0 then "comments"
              elif .reviewDecision == "CHANGES_REQUESTED" then "changes"
              elif ($ci == "PENDING" or $ci == "EXPECTED") then "ci_running"
              elif .reviewDecision == "APPROVED" then "ready"
              else "approval" end),
      note: (if $open > 0 then "\($open) sin resolver" else "" end) } ]
  | unique_by(.repo, .number)
  | sort_by({comments:0, ci_red:1, changes:2, ci_running:3, approval:4, ready:5, draft:6, merged:9}[.stage] // 5)
  | . + ($tasks[0] // [])
  | {updated: now | floor, items: .}' > "$D/board.json.tmp" && mv "$D/board.json.tmp" "$D/board.json"
