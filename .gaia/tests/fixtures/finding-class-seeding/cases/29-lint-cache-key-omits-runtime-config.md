# 29-lint-cache-key-omits-runtime-config

**Path**: `.github/workflows/cli-tests.yml`
**Line**: 118

## Title

The block comment above the eslint cache key says the key rotates on every input that
can change a lint verdict, and one input it does not cover is read at rule runtime.

## Failure mode

The comment reads "any change that can alter a lint result rotates this key", and it is
accurate for the two inputs the writer had in view: the lockfile-pinned shared config
package, and each linted file's own content. `eslint-plugin-prettier` additionally reads
`prettier.config.mjs` at rule runtime, and that path is in neither the key nor anything
the key hashes. Editing a formatting option there leaves the key unchanged, so the job
restores a cache built under the previous options and reports green on formatting the
current options reject. A maintainer who reads the sentence and adds a new runtime-read
config file without touching the key has been told, in writing, that they do not need to.

## Verified by

Read the `key:` expression at HEAD and enumerated every path it hashes; compared against
the config files eslint resolves for this workspace via `eslint --print-config`.
`prettier.config.mjs` is resolved and is absent from the key. Edited a formatting option
in it and re-ran the job with a warm cache: green, against a tree a cold run rejects.

## Suggested fix

Either add the file to the key's hash set, which makes the sentence true, or narrow the
sentence to the inputs the key actually hashes and name the runtime-read config as a
stated limit beside it.
