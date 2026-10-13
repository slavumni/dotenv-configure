#!/usr/bin/env bash
#
# dotenv-configure — syncs ENV_FILE (default: .env) with the DIST_FILE template
# (default: .env.dist); both can be set with -e/--env and -d/--dist.
# https://github.com/slavumni/dotenv-configure
#
#   * existing values in ENV_FILE are kept unchanged (the line is copied verbatim);
#   * new keys from DIST_FILE are added to ENV_FILE;
#   * the user is prompted for empty values (both new and existing ones);
#   * keys that are no longer in DIST_FILE are removed from ENV_FILE;
#   * an existing ENV_FILE is backed up to ENV_FILE.old (e.g. .env.old) before
#     it is changed.
#
# The layout (key order, comments, blank lines) is taken from DIST_FILE.
# Compatible with bash 3.2 (macOS), so associative arrays are not used.

DIST_FILE=".env.dist"
ENV_FILE=".env"

# KEY=VALUE, optionally prefixed with "export" and with spaces around the key.
# The value is everything after the first "=", so "=" inside the value is preserved.
KEY_RE='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.-]*)[[:space:]]*=(.*)$'

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d DIST_FILE] [-e ENV_FILE]

Syncs ENV_FILE (default: .env) with the DIST_FILE template (default: .env.dist).
Values for empty variables are read from stdin; prompts are written to stderr.

Options:
  -d, --dist FILE   template file (default: .env.dist)
  -e, --env FILE    target file (default: .env); backup goes to FILE.old
  -h, --help        show this help
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

# parse_line LINE
# If LINE is an assignment, sets PARSED_KEY and PARSED_VALUE (the raw value, with
# quotes and spaces exactly as in the file) and returns 0. Otherwise returns 1.
parse_line() {
    if [[ $1 =~ $KEY_RE ]]; then
        PARSED_KEY=${BASH_REMATCH[2]}
        PARSED_VALUE=${BASH_REMATCH[3]}
        return 0
    fi
    return 1
}

# is_empty_value VALUE
# Returns 0 if VALUE is empty: nothing, whitespace only, "" or '', optionally followed
# by an inline comment. As in common dotenv parsers, "#" starts a comment only after
# whitespace: "KEY= # comment" is empty, "KEY=#abc" is the value "#abc".
# Sets EMPTY_COMMENT to the inline comment with its leading whitespace (" # comment"),
# or to "" if there is none.
is_empty_value() {
    local v=$1 rest
    EMPTY_COMMENT=""
    rest=${v#"${v%%[![:space:]]*}"}
    case $rest in
        '""'* | "''"*) v=${rest:2} ;;
    esac
    # What is left must be nothing, whitespace only, or whitespace and a comment.
    rest=${v#"${v%%[![:space:]]*}"}
    if [[ -z $rest ]]; then
        return 0
    fi
    if [[ $rest == '#'* && $rest != "$v" ]]; then
        EMPTY_COMMENT=$v
        return 0
    fi
    return 1
}

# read_lines FILE — reads the file into the LINES array. Handles CRLF line endings
# and a missing newline at the end of the file.
read_lines() {
    local line
    LINES=()
    while IFS= read -r line || [[ -n $line ]]; do
        LINES+=("${line%$'\r'}")
    done <"$1"
}

# index_of KEY ARRAY_NAME — sets FOUND_INDEX and returns 0 if KEY is found.
# The array is passed by name (bash 3.2 has no namerefs), hence eval.
# shellcheck disable=SC1087  # $name is the array name inside the eval string
index_of() {
    local key=$1 name=$2 i n item
    eval "n=\${#$name[@]}"
    for ((i = 0; i < n; i++)); do
        eval "item=\${$name[i]}"
        if [[ $item == "$key" ]]; then
            FOUND_INDEX=$i
            return 0
        fi
    done
    return 1
}

# load_env FILE — fills ENV_KEYS, ENV_VALUES, ENV_LINES.
# For duplicate keys the last value wins.
load_env() {
    local i
    ENV_KEYS=()
    ENV_VALUES=()
    ENV_LINES=()
    read_lines "$1"
    for ((i = 0; i < ${#LINES[@]}; i++)); do
        parse_line "${LINES[i]}" || continue
        if index_of "$PARSED_KEY" ENV_KEYS; then
            ENV_VALUES[FOUND_INDEX]=$PARSED_VALUE
            ENV_LINES[FOUND_INDEX]=${LINES[i]}
        else
            ENV_KEYS+=("$PARSED_KEY")
            ENV_VALUES+=("$PARSED_VALUE")
            ENV_LINES+=("${LINES[i]}")
        fi
    done
}

# ask KEY — reads a value from stdin into ANSWER. Yields an empty string on EOF.
ask() {
    ANSWER=""
    printf '%s: ' "$1" >&2
    if ! IFS= read -r ANSWER; then
        printf '\n' >&2
    fi
}

# join ITEM... — "a, b, c"
join() {
    local result=$1
    shift
    while (($# > 0)); do
        result="$result, $1"
        shift
    done
    printf '%s' "$result"
}

parse_args() {
    while (($# > 0)); do
        case $1 in
            -d | --dist)
                (($# > 1)) || die "$1 requires an argument"
                DIST_FILE=$2
                shift 2
                ;;
            -e | --env)
                (($# > 1)) || die "$1 requires an argument"
                ENV_FILE=$2
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown argument: $1"
                ;;
        esac
    done
}

main() {
    set -euo pipefail
    parse_args "$@"

    local backup_file="$ENV_FILE.old"
    local env_exists=0 filled=0 i line key value
    local -a output=() seen=() added=() removed=()

    [[ -f $DIST_FILE ]] || die "$DIST_FILE not found"

    ENV_KEYS=()
    ENV_VALUES=()
    ENV_LINES=()
    if [[ -f $ENV_FILE ]]; then
        env_exists=1
        load_env "$ENV_FILE"
    fi

    read_lines "$DIST_FILE"
    for ((i = 0; i < ${#LINES[@]}; i++)); do
        line=${LINES[i]}

        if ! parse_line "$line"; then
            output+=("$line")
            continue
        fi
        key=$PARSED_KEY
        value=$PARSED_VALUE

        # Duplicate key in the template — keep only the first occurrence.
        if index_of "$key" seen; then
            continue
        fi
        seen+=("$key")

        if index_of "$key" ENV_KEYS; then
            line=${ENV_LINES[FOUND_INDEX]}
            value=${ENV_VALUES[FOUND_INDEX]}
        else
            added+=("$key")
        fi

        if is_empty_value "$value"; then
            ask "$key"
            if [[ -n $ANSWER ]]; then
                # Everything before the first "=" (key, "export", spaces) and the
                # inline comment are kept as is.
                line="${line%%=*}=$ANSWER$EMPTY_COMMENT"
                filled=$((filled + 1))
            fi
        fi

        output+=("$line")
    done

    for ((i = 0; i < ${#ENV_KEYS[@]}; i++)); do
        if ! index_of "${ENV_KEYS[i]}" seen; then
            removed+=("${ENV_KEYS[i]}")
        fi
    done

    if ((env_exists)) && ((${#added[@]} == 0 && ${#removed[@]} == 0 && filled == 0)); then
        log "$ENV_FILE is up to date"
        return 0
    fi

    if ((env_exists)); then
        cp -p "$ENV_FILE" "$backup_file"
        log "Backup: $backup_file"
    fi

    if ((${#output[@]} > 0)); then
        printf '%s\n' "${output[@]}" >"$ENV_FILE"
    else
        : >"$ENV_FILE"
    fi

    ((${#added[@]} == 0)) || log "Added: $(join "${added[@]}")"
    ((${#removed[@]} == 0)) || log "Removed (kept in $backup_file): $(join "${removed[@]}")"
    log "$ENV_FILE updated"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
