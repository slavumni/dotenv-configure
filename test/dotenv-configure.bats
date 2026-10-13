#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../dotenv-configure.sh"

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    cd "$BATS_TEST_TMPDIR"
}

# configure [STDIN] — runs the script, feeding STDIN as answers to the prompts.
configure() {
    run "$SCRIPT" <<<"${1-}"
}

# assert_file FILE EXPECTED — byte-exact comparison of the file contents
# (EXPECTED without the trailing newline; "." keeps $(...) from stripping the final \n).
assert_file() {
    assert_equal "$(cat "$1" && printf .)" "$2"$'\n.'
}

# --- parse_line ---------------------------------------------------------------

parse() {
    source "$SCRIPT"
    parse_line "$1"
}

@test "parse: simple KEY=VALUE" {
    parse 'KEY=value'
    assert_equal "$PARSED_KEY" KEY
    assert_equal "$PARSED_VALUE" value
}

@test "parse: '=' inside value is kept" {
    parse 'DATABASE_URL=postgres://u:p@host/db?sslmode=require&a=b'
    assert_equal "$PARSED_KEY" DATABASE_URL
    assert_equal "$PARSED_VALUE" 'postgres://u:p@host/db?sslmode=require&a=b'
}

@test "parse: value starting and ending with '='" {
    parse 'TOKEN==abc=='
    assert_equal "$PARSED_KEY" TOKEN
    assert_equal "$PARSED_VALUE" '=abc=='
}

@test "parse: quoted value with spaces, '#' and '='" {
    parse 'MSG="a = b # not a comment"'
    assert_equal "$PARSED_KEY" MSG
    assert_equal "$PARSED_VALUE" '"a = b # not a comment"'
}

@test "parse: backslashes and \$ are not interpreted" {
    parse 'RAW=a\nb$HOME\\'
    assert_equal "$PARSED_VALUE" 'a\nb$HOME\\'
}

@test "parse: export prefix and spaces around key" {
    parse '  export  KEY = value'
    assert_equal "$PARSED_KEY" KEY
    assert_equal "$PARSED_VALUE" ' value'
}

@test "parse: comments, blank lines and garbage are not assignments" {
    source "$SCRIPT"
    refute parse_line '# KEY=value'
    refute parse_line ''
    refute parse_line '   '
    refute parse_line 'just text'
    refute parse_line '1KEY=value'
    refute parse_line '=value'
}

@test "is_empty_value: empty forms" {
    source "$SCRIPT"
    assert is_empty_value ''
    assert is_empty_value '   '
    assert is_empty_value '""'
    assert is_empty_value "''"
    assert is_empty_value ' # comment'
    assert is_empty_value '"" # comment'
    refute is_empty_value '0'
    refute is_empty_value '" "'
    refute is_empty_value '=value'
}

@test "is_empty_value: '#' without leading whitespace is a value, not a comment" {
    source "$SCRIPT"
    refute is_empty_value '#s3cr3t'
    refute is_empty_value '#'
    refute is_empty_value '""#x'
    refute is_empty_value '"" x'
    assert is_empty_value '  #'
    assert is_empty_value " ''  # comment"
}

@test "is_empty_value: inline comment is captured with its whitespace" {
    source "$SCRIPT"
    is_empty_value ' # get from vault'
    assert_equal "$EMPTY_COMMENT" ' # get from vault'
    is_empty_value '""   # quoted'
    assert_equal "$EMPTY_COMMENT" '   # quoted'
    is_empty_value ''
    assert_equal "$EMPTY_COMMENT" ''
}

# --- creating .env ------------------------------------------------------------

@test "fails when .env.dist is missing" {
    configure
    assert_failure 1
    assert_output --partial ".env.dist not found"
    assert [ ! -e .env ]
}

@test "creates .env from .env.dist, no backup" {
    printf '# app\nAPP_ENV=dev\nURL=http://h/?a=1&b=2\n' >.env.dist
    configure
    assert_success
    assert_file .env '# app
APP_ENV=dev
URL=http://h/?a=1&b=2'
    assert [ ! -e .env.old ]
}

@test "creates .env and asks for empty values" {
    printf 'A=1\nSECRET=\nTOKEN=""\n' >.env.dist
    configure $'s3cr=t\ntok'
    assert_success
    assert_output --partial "SECRET: "
    assert_output --partial "TOKEN: "
    assert_file .env 'A=1
SECRET=s3cr=t
TOKEN=tok'
}

# --- updating .env ------------------------------------------------------------

@test "up to date .env is not touched and no backup is created" {
    printf 'A=1\nB=2\n' >.env.dist
    printf 'B=two\nA=one\n' >.env
    configure
    assert_success
    assert_output --partial "up to date"
    assert_file .env 'B=two
A=one'
    assert [ ! -e .env.old ]
}

@test "new keys are added, existing values with '=' are kept, backup is created" {
    printf 'URL=\nA=default\nNEW=x=y\n' >.env.dist
    printf 'URL=postgres://u:p@h/db?sslmode=require\nA==weird==\n' >.env
    cp .env original
    configure
    assert_success
    assert_file .env 'URL=postgres://u:p@h/db?sslmode=require
A==weird==
NEW=x=y'
    cmp .env.old original
    assert_output --partial "Added: NEW"
}

@test "existing lines are copied verbatim (quotes, export, spaces, \$, backslashes)" {
    printf 'Q=\nE=\nS=\nR=\nNEW=1\n' >.env.dist
    cat >.env <<'EOF'
Q="a = b # c"
export E='x=y'
S = spaced
R=a\nb$HOME
EOF
    configure
    assert_success
    assert_file .env 'Q="a = b # c"
export E='\''x=y'\''
S = spaced
R=a\nb$HOME
NEW=1'
}

@test "new empty key prompts and the answer is written verbatim" {
    printf 'A=1\nPASS=\n' >.env.dist
    printf 'A=1\n' >.env
    configure 'p@ss = w0rd=="#'
    assert_success
    assert_file .env 'A=1
PASS=p@ss = w0rd=="#'
    assert_file .env.old 'A=1'
}

@test "existing empty value prompts even without new keys" {
    printf 'A=\nB=\n' >.env.dist
    printf 'A=\nB=""\n' >.env
    configure $'filled\n'
    assert_success
    assert_file .env 'A=filled
B=""'
    assert_file .env.old 'A=
B=""'
}

@test "filling an empty value keeps the export prefix" {
    printf 'A=\n' >.env.dist
    printf 'export A=\n' >.env
    configure 'v'
    assert_file .env 'export A=v'
}

@test "values starting with '#' are kept and not prompted for" {
    printf 'PASSWORD=\nCOLOR=#fff\n' >.env.dist
    printf 'PASSWORD=#s3cr3t\n' >.env
    configure 'must-not-be-used'
    assert_success
    refute_output --partial "PASSWORD: "
    refute_output --partial "COLOR: "
    assert_file .env 'PASSWORD=#s3cr3t
COLOR=#fff'
}

@test "filling an empty value keeps the inline comment" {
    printf 'API_KEY= # get from vault\nTOKEN=\n' >.env.dist
    printf 'TOKEN=""  # ask the team\n' >.env
    configure $'abc\nt=1'
    assert_success
    assert_file .env 'API_KEY=abc # get from vault
TOKEN=t=1  # ask the team'
}

@test "an empty value with an inline comment stays as is when the answer is empty" {
    printf 'API_KEY= # get from vault\n' >.env.dist
    printf 'API_KEY= # get from vault\n' >.env
    run "$SCRIPT" </dev/null
    assert_success
    assert_output --partial "API_KEY: "
    assert_file .env 'API_KEY= # get from vault'
    assert [ ! -e .env.old ]
}

@test "empty answers leave values empty and do not change .env" {
    printf 'A=\n' >.env.dist
    printf 'A=\n' >.env
    run "$SCRIPT" </dev/null
    assert_success
    assert_file .env 'A='
    assert [ ! -e .env.old ]
}

@test "keys removed from .env.dist stay only in .env.old" {
    printf 'A=\n' >.env.dist
    printf 'A=1\nOBSOLETE=x=y\n' >.env
    configure
    assert_success
    assert_file .env 'A=1'
    assert_file .env.old 'A=1
OBSOLETE=x=y'
    assert_output --partial "Removed (kept in .env.old): OBSOLETE"
}

@test "structure and comments follow .env.dist" {
    printf '# db\nDB=\n\n# commented out: OPTIONAL=1\n#OPTIONAL=1\nNEW=2\n' >.env.dist
    printf 'DB=mysql://h?x=1\nOPTIONAL=keep\n' >.env
    configure
    assert_file .env '# db
DB=mysql://h?x=1

# commented out: OPTIONAL=1
#OPTIONAL=1
NEW=2'
    grep -q '^OPTIONAL=keep$' .env.old
}

@test "duplicate keys: last value in .env wins, first in .env.dist is used" {
    printf 'A=\nA=dup\nB=1\n' >.env.dist
    printf 'A=first\nA=last\n' >.env
    configure
    assert_file .env 'A=last
B=1'
}

@test "CRLF line endings are handled" {
    printf 'A=\r\nB=x=y\r\n' >.env.dist
    printf 'A=1=2\r\n' >.env
    configure
    assert_success
    refute_output --partial "A: "
    assert_file .env 'A=1=2
B=x=y'
}

@test "last line without trailing newline is parsed" {
    printf 'A=\nB=2' >.env.dist
    printf 'A=a=b' >.env
    configure
    assert_file .env 'A=a=b
B=2'
}

@test "custom paths via --dist and --env" {
    mkdir conf
    printf 'A=1\nB=2\n' >conf/app.dist
    printf 'A=x\n' >conf/app.env
    run "$SCRIPT" --dist conf/app.dist --env conf/app.env </dev/null
    assert_success
    assert_file conf/app.env 'A=x
B=2'
    assert_file conf/app.env.old 'A=x'
}

@test "file permissions of .env are preserved" {
    printf 'A=1\nB=2\n' >.env.dist
    printf 'A=1\n' >.env
    chmod 600 .env
    configure
    assert_equal "$(ls -l .env | cut -c1-10)" "-rw-------"
    assert_equal "$(ls -l .env.old | cut -c1-10)" "-rw-------"
}
