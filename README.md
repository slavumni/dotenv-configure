# dotenv-configure

Configure dotenv file

Syncs `.env` with the `.env.dist` template:

- existing values in `.env` are kept unchanged (the line is copied verbatim);
- new keys from `.env.dist` are added to `.env`;
- the user is prompted for new empty variables and for existing empty values;
- keys that are no longer in `.env.dist` are removed from `.env` and kept only in `.env.old`;
- an existing `.env` is backed up to `.env.old` before any change.

Key order, comments and blank lines are taken from `.env.dist`.
The value is everything after the first `=`, so `URL=postgres://h/db?a=b` and `TOKEN==abc==` are parsed correctly.
`KEY=`, `KEY=""` and `KEY=''` are treated as empty.

Works on Linux and macOS with bash 3.2+ and both GNU and BusyBox coreutils
(on Alpine install bash first: `apk add bash`).

## Usage

```sh
./dotenv-configure.sh                                   # .env.dist -> .env
./dotenv-configure.sh --dist conf/app.dist --env conf/app.env
./dotenv-configure.sh < /dev/null                       # no prompts, empty values stay empty
```

Prompts are written to stderr; answers are read from stdin and written as is
(add quotes yourself if needed).

## Test

Tests use [bats-core](https://github.com/bats-core/bats-core) with the
[bats-support](https://github.com/bats-core/bats-support) and
[bats-assert](https://github.com/bats-core/bats-assert) helpers, included as git submodules:

```text
test/
    bats/                  <- submodule
    test_helper/
        bats-support/      <- submodule
        bats-assert/       <- submodule
    dotenv-configure.bats
```

```sh
git clone --recurse-submodules <repo>     # or, in an already cloned repository:
git submodule update --init --recursive

./test/bats/bin/bats test/dotenv-configure.bats
```

CI runs the tests on `ubuntu-latest` and `macos-latest` via GitHub Actions
(`.github/workflows/test.yml`).
