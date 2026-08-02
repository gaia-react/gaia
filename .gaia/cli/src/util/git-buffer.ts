/**
 * The stdout ceiling every git-output reader in this CLI spawns under.
 *
 * Node defaults `spawnSync`/`execFileSync` to a 1 MiB `maxBuffer` and fails
 * the call with `ENOBUFS` the moment a child writes past it. That is not a
 * theoretical limit for a git command that reads history: `git log` with
 * commit bodies over this repository's own `v1.6.1..HEAD` measures ~1.25 MB,
 * so a release-time reader is already over the default.
 *
 * 64 MiB is the value each reader had independently converged on before this
 * module existed. It is a ceiling, not an allocation: `spawnSync` grows its
 * buffer to what the child actually writes, so raising it costs nothing until
 * output that large arrives, and it exists only so a large-but-legitimate read
 * completes instead of throwing.
 *
 * Not the bound for every spawn. `update/regen-regions.ts` keeps its own
 * `SPAWN_MAX_BUFFER_BYTES` at 32 MiB, because it bounds the region-digest
 * spawner rather than a history read, and the two limits answer to different
 * inputs.
 */
export const MAX_GIT_BUFFER_BYTES = 64 * 1024 * 1024;
