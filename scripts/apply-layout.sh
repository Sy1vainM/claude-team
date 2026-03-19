#!/usr/bin/env bash
# Apply optimal layout to a tmux session based on pane count.
# Rules: 1-4 panes → 1 row, 5-8 → 2 rows, 9+ → 3 rows.
#
# Usage: apply-layout.sh <session-name>

set -euo pipefail

SESSION="$1"
N=$(tmux list-panes -t "$SESSION" | wc -l | tr -d ' ')

if [ "$N" -le 1 ]; then
    exit 0
fi

if [ "$N" -le 4 ]; then
    tmux select-layout -t "$SESSION" even-horizontal
    exit 0
fi

# For 5+ panes, generate a custom layout string
LAYOUT=$(python3 -c "
import math, subprocess

n = $N
if n <= 4:
    n_rows = 1
elif n <= 8:
    n_rows = 2
else:
    n_rows = 3

# Get window dimensions
result = subprocess.run(
    ['tmux', 'display-message', '-t', '$SESSION', '-p', '#{window_width} #{window_height}'],
    capture_output=True, text=True
)
W, H = map(int, result.stdout.strip().split())

cols = math.ceil(n / n_rows)

# Build layout: rows stacked vertically, each row has panes side by side
# Account for separators: 1 char between panes
usable_h = H - (n_rows - 1)  # horizontal separators between rows

rows_parts = []
pane_id = 0

for r in range(n_rows):
    panes_in_row = min(cols, n - pane_id)
    if panes_in_row <= 0:
        break

    # Row geometry
    row_h = usable_h // n_rows if r < n_rows - 1 else usable_h - (usable_h // n_rows) * (n_rows - 1)
    y_off = r * (usable_h // n_rows + 1)  # +1 for separator

    usable_w = W - (panes_in_row - 1)  # vertical separators within row

    if panes_in_row == 1:
        rows_parts.append(f'{W}x{row_h},{0},{y_off},{pane_id}')
        pane_id += 1
    else:
        col_parts = []
        for c in range(panes_in_row):
            col_w = usable_w // panes_in_row if c < panes_in_row - 1 else usable_w - (usable_w // panes_in_row) * (panes_in_row - 1)
            x_off = c * (usable_w // panes_in_row + 1)  # +1 for separator
            col_parts.append(f'{col_w}x{row_h},{x_off},{y_off},{pane_id}')
            pane_id += 1
        row_w = W
        rows_parts.append(f'{row_w}x{row_h},{0},{y_off}' + '{' + ','.join(col_parts) + '}')

body = f'{W}x{H},0,0[' + ','.join(rows_parts) + ']'

# Compute tmux layout checksum
csum = 0
for ch in body:
    csum = (csum >> 1) + ((csum & 1) << 15)
    csum += ord(ch)
csum &= 0xffff

print(f'{csum:04x},{body}')
")

tmux select-layout -t "$SESSION" "$LAYOUT"
