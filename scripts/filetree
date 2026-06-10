#!/usr/bin/env bash
# filetree.sh — generate ASCII file trees for READMEs
#
# Usage:
#   filetree.sh [OPTIONS] [DIR]
#
#   DIR defaults to "." if not provided.
#   Walks DIR recursively with find and renders an ASCII tree.
#
# Options:
#   -s, --style STYLE          Tree style: unicode (default), ascii, compact
#   -e, --exclude-dirs DIRS    Colon-separated extra dirs to exclude
#   -h, --help                 Show this help
#
# Default excluded dirs: .git .venv venv node_modules __pycache__ .DS_Store
#
# Examples:
#   filetree.sh
#   filetree.sh src/
#   filetree.sh --style ascii .
#   filetree.sh --exclude-dirs dist:build src/

set -eu

STYLE="unicode"
DIR="."
EXTRA_EXCLUDES=""
TEE="" LAST="" PIPE="" BLANK=""
LEVELS_OUT=""

DEFAULT_EXCLUDES=".git .venv venv node_modules __pycache__ .DS_Store dist .idea .mypy_cache .pytest_cache .tox"

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,2\}//'
  exit 0
}

die() {
  echo "filetree: $*" >&2
  exit 1
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--style)
        [ -n "${2:-}" ] || die "option $1 requires an argument"
        STYLE="$2"; shift 2 ;;
      -e|--exclude-dirs)
        [ -n "${2:-}" ] || die "option $1 requires an argument"
        EXTRA_EXCLUDES="$2"; shift 2 ;;
      -h|--help) usage ;;
      -*) die "unknown option: $1" ;;
      *) DIR="$1"; shift ;;
    esac
  done
}

set_style_chars() {
  case "$STYLE" in
    unicode) TEE="├── "; LAST="└── "; PIPE="│   "; BLANK="    " ;;
    ascii)   TEE="+-- ";  LAST="\`-- "; PIPE="|   ";  BLANK="    " ;;
    compact) TEE="  ";    LAST="  ";    PIPE="  ";    BLANK="  "   ;;
    *) die "unknown style '$STYLE'. Choose: unicode, ascii, compact" ;;
  esac
}

build_find_args() {
  # Build prune arguments for find from default + extra excludes
  local all_excludes="$DEFAULT_EXCLUDES"
  if [ -n "$EXTRA_EXCLUDES" ]; then
    # Replace colons with spaces
    local extra
    extra=$(printf '%s' "$EXTRA_EXCLUDES" | tr ':' ' ')
    all_excludes="$all_excludes $extra"
  fi

  FIND_PRUNE_ARGS=""
  local first=1
  for d in $all_excludes; do
    if [ $first -eq 1 ]; then
      FIND_PRUNE_ARGS="-name $d"
      first=0
    else
      FIND_PRUNE_ARGS="$FIND_PRUNE_ARGS -o -name $d"
    fi
  done
}

collect_paths() {
  # Use find to list all paths under DIR, stripping the DIR prefix
  local prune_expr="( $FIND_PRUNE_ARGS ) -prune"

  # shellcheck disable=SC2086
  find "$DIR" $prune_expr -o -print | sort | while IFS= read -r path; do
    # Strip leading DIR prefix and possible trailing slash
    local rel
    rel="${path#$DIR}"
    rel="${rel#/}"
    [ -z "$rel" ] && continue
    printf '%s\n' "$rel"
  done
}

# Convert a slash-delimited path to indented form (depth = slash count)
path_to_indent() {
  # Count slashes to determine depth
  local path="$1"
  local depth
  depth=$(printf '%s' "$path" | tr -cd '/' | wc -c)
  # Children of DIR root start at level 1
  depth=$((depth + 1))
  local name="${path##*/}"
  # Indent: 2 spaces per level
  local indent=""
  local i=0
  while [ $i -lt "$depth" ]; do
    indent="$indent  "
    i=$((i + 1))
  done
  printf '%s%s\n' "$indent" "$name"
}

render_tree() {
  # Read indented lines from stdin, render as tree
  # We store all lines in a temp file to allow two-pass processing
  local tmpfile
  tmpfile=$(mktemp)
  # Ensure cleanup on exit
  trap 'rm -f "$tmpfile"' EXIT INT TERM

  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$tmpfile"
  done

  # Count lines
  local n
  n=$(wc -l < "$tmpfile" | tr -d ' ')

  [ "$n" -eq 0 ] && { rm -f "$tmpfile"; return; }

  # Read all lines and indents into indexed storage via awk
  # We use awk for portability instead of bash arrays with namerefs
  awk -v tee="$TEE" -v last="$LAST" -v pipe="$PIPE" -v blank="$BLANK" '
  BEGIN { count = 0 }
  {
    line = $0
    # Measure leading spaces
    stripped = line
    sub(/^[[:space:]]+/, "", stripped)
    indent = length(line) - length(stripped)
    # Normalize to 2-space steps
    level = int(indent / 2)
    lines[count] = stripped
    levels[count] = level
    count++
  }
  END {
    for (i = 0; i < count; i++) {
      cur = levels[i]
      name = lines[i]

      if (cur == 0) {
        print name
        continue
      }

      prefix = ""
      for (d = 0; d < cur; d++) {
        # Is there a sibling at depth d after position i?
        open = 0
        for (j = i + 1; j < count; j++) {
          if (levels[j] < d) break
          if (levels[j] == d) { open = 1; break }
        }
        prefix = prefix (open ? pipe : blank)
      }

      # Is this the last sibling at cur level?
      is_last = 1
      for (j = i + 1; j < count; j++) {
        if (levels[j] < cur) break
        if (levels[j] == cur) { is_last = 0; break }
      }

      prefix = prefix (is_last ? last : tee)
      print prefix name
    }
  }
  ' "$tmpfile"

  rm -f "$tmpfile"
  trap - EXIT INT TERM
}

main() {
  parse_args "$@"

  [ -d "$DIR" ] || die "directory not found: $DIR"

  set_style_chars
  build_find_args

  # Print root dir name
  printf '%s\n' "$DIR"

  collect_paths | while IFS= read -r rel; do
    path_to_indent "$rel"
  done | render_tree
}

main "$@"
