#!/bin/bash
# Focus the first empty workspace for a monitor.
#
# Prefers workspaces that Hyprland workspace rules assign to that monitor
# (e.g. 4-6 on the second screen); falls back to the lowest free id that
# isn't assigned to another monitor.
#
# Usage: new-workspace.sh <monitor-name> [--print]

monitor="$1"
[[ -z $monitor ]] && monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')

target=$(jq -rn \
  --arg mon "$monitor" \
  --argjson monitors "$(hyprctl monitors -j)" \
  --argjson rules "$(hyprctl workspacerules -j)" \
  --argjson workspaces "$(hyprctl workspaces -j)" '
  def owner: . as $m | if startswith("desc:") then (($monitors | map(select("desc:" + .description == $m)) | .[0].name) // $m) else $m end;
    ($rules
      | map(select(.workspaceString | test("^[0-9]+$")) | { id: (.workspaceString | tonumber), mon: (.monitor // "" | owner) })) as $assigned
  | ($workspaces | map({ key: (.id | tostring), value: . }) | from_entries) as $ws
  | def free(id): ($ws[id | tostring]) as $w | ($w == null) or ($w.windows == 0 and $w.monitor == $mon);
    ([$assigned[] | select(.mon == $mon) | .id] | sort | map(select(free(.))) | .[0])
    // ([range(1; 100)] | map(select(. as $id | free($id) and ([$assigned[] | select(.id == $id and .mon != $mon and .mon != "")] | length == 0))) | .[0])
    // empty
')

[[ -z $target ]] && exit 1
[[ $2 == --print ]] && { echo "$target"; exit 0; }

hyprctl dispatch "hl.dsp.focus({ monitor = \"$monitor\" })" >/dev/null
hyprctl dispatch "hl.dsp.focus({ workspace = \"$target\" })" >/dev/null
