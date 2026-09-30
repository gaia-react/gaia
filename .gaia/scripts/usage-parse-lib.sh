# shellcheck shell=bash
# jq programs for the usage-ledger flusher (usage-flush.sh). Sourced after
# usage-lib.sh, whose GAIA_USAGE_JQ_DEFS every program here is prefixed with.
# Defines variables only; sourcing runs no command.
#
# GAIA_USAGE_PARSE_JQ reads one file's complete lines (`jq -nR`) and prints the
# extraction as one compact JSON line, then each distinct raw gitBranch on its
# own line (the caller builds the branch map from those in bash, so
# gaia_branch_normalize stays the only normalizer). Line numbers count from 1
# at the start of the parsed range. Arguments: $roots (tree roots), $rroots
# (research roots), $startset (workflow names), $nlines (complete lines in the
# range; a trailing line past it has no newline yet and is not read).
#
# GAIA_USAGE_SEGMENT_JQ applies the high-water filter, the trailing-group
# holdback, dedup, keying, and the split-point grouping. It prints the held
# line number (or null), then the cursor row's JSON before and after its
# offset (the caller fills the byte offset of the held line in bash), then one
# row per line.

# shellcheck disable=SC2034,SC2016  # consumed by usage-flush.sh; jq source, no shell expansion
GAIA_USAGE_PARSE_JQ="${GAIA_USAGE_JQ_DEFS:-}"'
def text_of:
  if type == "string" then .
  elif type == "array" then map(if type == "object" then (.text // "" | strings) elif type == "string" then . else "" end) | join("\n")
  else "" end;
def buckets:
  {fresh_input: (.input_tokens // 0),
   cache_write_5m: (.cache_creation.ephemeral_5m_input_tokens? // 0),
   cache_write_1h: (.cache_creation.ephemeral_1h_input_tokens? // (.cache_creation_input_tokens // 0)),
   cache_read: (.cache_read_input_tokens // 0),
   output: (.output_tokens // 0)}
  | map_values(if type == "number" then . else 0 end);
def in_set($w): any($startset[]; . == $w);
reduce inputs as $line ({n: 0, usage: [], ev: []};
  .n += 1
  | if .n > $nlines then .
    else
      ($line | try fromjson catch null) as $x
      | if ($x | type) != "object" or (usage_member($x.cwd; $roots) | not) then .
        else
          .n as $n
          | ($x.message.id? // $x.uuid // null | if type == "string" then . else null end) as $id
          | ($x.timestamp | if type == "string" then . else null end) as $ts
          | (if ($x.message.usage? | type) == "object"
             then .usage += [{n: $n, id: $id, ts: $ts,
                   model: ($x.message.model | if type == "string" and . != "" then . else null end),
                   b: ($x.message.usage | buckets),
                   branch: ($x.gitBranch | if type == "string" then . else null end),
                   sid: ($x.sessionId | if type == "string" and . != "" then . else null end)}]
             else . end)
          | if $x.type == "assistant" then
              .ev += [$x.message.content[]? | objects | select(.type == "tool_use")
                | if .name == "Write" then
                    usage_research_slug(.input.file_path?; $rroots) as $s
                    | select($s != null)
                    | {n: $n, id: $id, ts: $ts, type: "research", ref: ("research:" + $s)}
                  elif .name == "Skill" then
                    (.input.skill? | strings | sub("\\A[^:]*:"; "")) as $w
                    | select(in_set($w))
                    | {n: $n, id: $id, ts: $ts, type: "start", workflow: $w}
                  else empty end]
            elif $x.type == "user" then
              .ev += [$x.message.content? | text_of
                | match("<command-name>/?([^<]*)</command-name>"; "g") | .captures[0].string
                | sub("\\A[^:]*:"; "") | select(in_set(.))
                | {n: $n, id: $id, ts: $ts, type: "start", workflow: .}]
            else . end
        end
    end)
| (del(.n) | tojson),
  ([.usage[].branch | strings | select(test("\n") | not)] | unique | .[])
'

# The holdback line is the one guards-must-fail mutation targets; keep it a
# single line so a scratch copy can disable it with one sed.
# shellcheck disable=SC2034,SC2016
GAIA_USAGE_SEGMENT_JQ="${GAIA_USAGE_JQ_DEFS:-}"'
def zb: {fresh_input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0};
def addb($b):
  {fresh_input: (.fresh_input + $b.fresh_input), cache_write_5m: (.cache_write_5m + $b.cache_write_5m),
   cache_write_1h: (.cache_write_1h + $b.cache_write_1h), cache_read: (.cache_read + $b.cache_read),
   output: (.output + $b.output)};
def fresh($seen; $hts):
  (.id == null or ($seen[.id] | not)) and ($hts == null or .ts == null or .ts >= $hts);
$ext[0] as $x
| ($hw.hw_ts | if type == "string" then . else null end) as $hts
| ($hw.hw_ids // [] | map(strings)) as $oids
| ($oids | map({key: ., value: true}) | from_entries) as $seen
| [$x.usage[] | select(fresh($seen; $hts))] as $U
| [$x.ev[] | select(.ts != null) | select(fresh($seen; $hts))] as $E
| (if ($U | length) == 0 then null else ($U[-1].id) as $L | [$U[] | select(.id == $L)][0].n end) as $a
| (if $finished then null else $a end) as $hold
| (if $hold == null then $U else [$U[] | select(.n < $hold)] end) as $CU
| (if $hold == null then $E else [$E[] | select(.n < $hold)] end) as $CE
| (($CU | map(select(.id != null)) | group_by(.id) | map(max_by(.n))) + ($CU | map(select(.id == null)))
   | sort_by(.n) | map(. + usage_key(.branch; (.sid // $fsid); $default; $bmap))) as $D
| ([$splitsraw | split("\n")[] | select(length > 0) | (try fromjson catch null) | objects
    | select(.session_id == $fsid)
    | select((.kind == "binding" and .type == "declare")
        or (.kind != "binding" and .kind != "segment" and .kind != "cursor"))
    | .ts | strings] + [$CE[].ts]) | unique as $S
| (reduce $D[] as $r ([];
    if length == 0 then [[$r]]
    else .[length - 1][-1] as $p
      | if $p.key != $r.key or $p.inherit != $r.inherit
          or ($p.ts != null and $r.ts != null and any($S[]; $p.ts < . and . <= $r.ts))
        then . + [[$r]]
        else .[length - 1] += [$r] end
    end)) as $G
| [$G[] | {schema_version: 1, kind: "segment", key: .[0].key, session_id: $fsid, inherit: .[0].inherit,
    first_ts: ([.[].ts | strings] | min), last_ts: ([.[].ts | strings] | max),
    messages: ([.[].id] | unique | length),
    by_model: (reduce .[] as $r ({}; ($r.model // "unknown") as $m | .[$m] = ((.[$m] // zb) | addb($r.b)))
      | with_entries(select(([.value[]] | add) > 0)))}] as $SEG
| [$CE | sort_by(.n)[]
    | if .type == "research"
      then {schema_version: 1, kind: "binding", type: "research", session_id: $fsid, ts, ref, source: "transcript"}
      else {schema_version: 1, kind: "binding", type: "start", session_id: $fsid, ts, workflow, source: "transcript"} end] as $BIND
| ([$D[], $CE[] | {n, id, ts}] | sort_by(.n)) as $C
| ([$C[].ts | strings] | max) as $m
| (if $hts == null then $m elif $m == null or $m <= $hts then $hts else $m end) as $nts
| ([$C[] | select($nts != null and .ts == $nts) | .id | strings]
   + (if $nts == $hts then $oids else [] end)
   + (($oids + [$C[].id | strings]) | .[-8:]) | unique) as $nids
| ($hold | tojson),
  ({schema_version: 1, kind: "cursor", session_id: $fsid, role: $role, path: $path} | tojson | .[:-1]),
  ({size: $size, hw_ts: $nts, hw_ids: $nids, ts: $now} | tojson | .[1:]),
  ($SEG[], $BIND[] | tojson)
'

# Folds cursor rows (stdin, one per line) into the cache object $c. Latest row
# wins; an unknown schema_version is skipped.
# shellcheck disable=SC2034,SC2016
GAIA_USAGE_FOLD_JQ='
def fold($c):
  reduce (inputs | try fromjson catch null | objects
      | select(.schema_version == 1 and .kind == "cursor" and (.path | type) == "string"
          and (.session_id | type) == "string" and (.role | type) == "string")) as $r ($c;
    .files[$r.path] = {session_id: $r.session_id, role: $r.role, offset: $r.offset, size: $r.size}
    | .pairs[$r.session_id + "|" + $r.role] = {hw_ts: $r.hw_ts, hw_ids: ($r.hw_ids // [])});
def base: ($c | try fromjson catch null)
  | if type == "object" and (.files | type) == "object" and (.pairs | type) == "object" then . else null end;
'
