#!/usr/bin/env bash
# gen-usage-stores.sh: seeded, byte-reproducible synthetic usage ledger.
#
# usage: gen-usage-stores.sh <months> <outdir> [--seed <n>] [--scale <fraction>]
#
# Writes usage.jsonl, links.jsonl, cost.jsonl and probes.json into <outdir>.
# The shape follows the readout's measured ledger: per month about 150 new
# branch keys, 700 sessions, 4,191 segments, 625 bindings, 3,155 cursor rows,
# 60 merged PRs and 480 cost rows. Defaults: seed 89, scale 1. --scale shrinks
# every per-month count proportionally (floor 1) for a fast smoke run.
#
# probes.json carries typical_pr, widest_pr, the probe set (every probe a
# {pr, key, raw, category, expect} object), initiative_roots, and the byte
# offset `cut` of each store where the final day starts (a line boundary), so
# the rows of the final day are a byte suffix of each store.
#
# The `interval` probe's key is a branch whose spec or plan root owns the
# segments a closed start-binding interval attributes: no interval can name a
# branch directly, so the interval shows up as spend under the root `pr` prints.
# The `no_spend` probe's window holds no segment, so its figures read zero.
#
# Reproducibility: one awk program with its own Park-Miller generator, integer
# arithmetic below 2^53 and 32-bit-safe printf conversions, and no rand(),
# srand(), or strftime(), whose results differ between awk implementations. Set
# GAIA_PERF_AWK to run another awk binary. Rows are ordered by timestamp.
#
# Maintainer tooling, release-excluded with the rest of .gaia/tests.

set -euo pipefail

# 2026-10-01T00:00:00Z. A fixed end keeps equal arguments byte-identical.
BASE_END_EPOCH=1790812800

usage() {
  cat <<'EOF'
usage: gen-usage-stores.sh <months> <outdir> [--seed <n>] [--scale <fraction>]
  <months>   whole months of history to generate (a month is 30 days)
  <outdir>   written: usage.jsonl links.jsonl cost.jsonl probes.json
  --seed     generator seed, a non-negative integer (default 89)
  --scale    fraction in (0, 1] shrinking every per-month count (default 1)
EOF
}

die() {
  printf 'gen-usage-stores: %s\n' "$*" >&2
  exit 2
}

months="" outdir="" seed=89 scale=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --seed | --scale)
      [ $# -ge 2 ] || die "$1 needs a value"
      if [ "$1" = --seed ]; then seed="$2"; else scale="$2"; fi
      shift 2 ;;
    -*) usage >&2; die "unknown flag $1" ;;
    *)
      if [ -z "$months" ]; then months="$1"
      elif [ -z "$outdir" ]; then outdir="$1"
      else usage >&2; die "unexpected argument $1"; fi
      shift ;;
  esac
done
[ -n "$months" ] && [ -n "$outdir" ] || { usage >&2; die "months and outdir are required"; }
[[ "$months" =~ ^[1-9][0-9]{0,2}$ ]] || die "months must be a whole number from 1 to 999"
[[ "$seed" =~ ^[0-9]{1,15}$ ]] || die "--seed must be a non-negative integer"
[[ "$scale" =~ ^[0-9]*\.?[0-9]+$ ]] || die "--scale must be a decimal in (0, 1]"
awk_bin="${GAIA_PERF_AWK:-awk}"
LC_ALL=C "$awk_bin" -v s="$scale" 'BEGIN { exit !(s > 0 && s <= 1) }' || die "--scale must be a decimal in (0, 1]"

mkdir -p "$outdir"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gen-usage-stores.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

IFS= read -r -d '' GEN_PROGRAM <<'AWK' || true
function rnd(n) {
  SEED = (16807 * SEED) % 2147483647
  return int((SEED - 1) * n / 2147483646)
}
function rr(a, b) { return a + rnd(b - a + 1) }
function cnt(n, fr,   v) {
  v = int(n * fr * SCALE + 0.5)
  return v < 1 ? 1 : v
}

# Civil date from epoch seconds (Hinnant), so no strftime is needed.
function civ(sec,   z, sod, era, doe, yoe, doy, mp) {
  z = int(sec / 86400)
  sod = sec - z * 86400
  z += 719468
  era = int(z / 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  CY = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  CD = doy - int((153 * mp + 2) / 5) + 1
  CM = mp < 10 ? mp + 3 : mp - 9
  if (CM <= 2) CY++
  CH = int(sod / 3600)
  CN = int((sod - CH * 3600) / 60)
  CS = sod - CH * 3600 - CN * 60
}
function iso(sec, ms) {
  civ(sec)
  if (ms < 0) return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", CY, CM, CD, CH, CN, CS)
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", CY, CM, CD, CH, CN, CS, ms)
}
function stamp(sec,   v) {
  civ(sec)
  return sprintf("%04d%02d%02dT%02d%02d%02dZ", CY, CM, CD, CH, CN, CS)
}

# Every row leaves here as <store letter><13-digit sort key><TAB><json>; the
# wrapper sorts on that prefix and strips it.
function out(st, sec, ms, json) {
  if (ms < 0) ms = 0
  printf "%s%010d%03d\t%s\n", st, sec, ms, json
}

function sid(   a, b, c, d, e, f, g, h) {
  a = rnd(65536); b = rnd(65536); c = rnd(65536); d = rnd(65536)
  e = rnd(65536); f = rnd(65536); g = rnd(65536); h = rnd(65536)
  return sprintf("%04x%04x-%04x-%04x-%04x-%04x%04x%04x", a, b, c, d, e, f, g, h)
}
function msgid(   a, b, c, d) {
  a = rnd(4096); b = rnd(4096); c = rnd(4096); d = rnd(4096)
  return "msg_011C" CH5[a] CH5[b] CH5[c] CH5[d]
}
function hwids(   i, s, m) {
  s = ""
  for (i = 0; i < 8; i++) { m = msgid(); s = s (i ? "," : "") "\"" m "\"" }
  return "[" s "]"
}
function mval(   a, b, c, d, e, h) {
  a = rnd(401); h = rnd(2); b = h ? rnd(90001) : 0
  c = rnd(120001); d = rr(10000, 3000000); e = rr(100, 30000)
  return sprintf("{\"fresh_input\":%d,\"cache_write_5m\":%d,\"cache_write_1h\":%d,\"cache_read\":%d,\"output\":%d}", a, b, c, d, e)
}
# Sets BMV to the first model's value object, returns the by_model object.
function bmodels(n,   i, j, s) {
  i = rnd(4)
  BMV = mval()
  s = "{\"" MD[i] "\":" BMV
  if (n == 2) {
    j = (i + 1 + rnd(3)) % 4
    s = s ",\"" MD[j] "\":" mval()
  }
  return s "}"
}
function dollars(   a, b) {
  a = rnd(20); b = rnd(1000000)
  return sprintf("%d.%06d", a, b)
}
function nmodels(   v) { v = rnd(5); return v == 0 ? 2 : 1 }

function segrow(key, s, inh, t, ms, t2, ms2,   n, nm, bm) {
  n = rr(1, 40)
  nm = nmodels()
  bm = bmodels(nm)
  out("u", t, ms, "{\"schema_version\":1,\"kind\":\"segment\",\"key\":\"" key "\",\"session_id\":\"" s "\",\"inherit\":" (inh ? "true" : "false") ",\"first_ts\":\"" iso(t, ms) "\",\"last_ts\":\"" iso(t2, ms2) "\",\"messages\":" n ",\"by_model\":" bm "}")
}
# One segment of ~10 minutes at second t.
function pseg(key, s, inh, t,   ms, ms2) {
  ms = rnd(1000); ms2 = rnd(1000)
  segrow(key, s, inh, t, ms, t + 600, ms2)
}
function binding_start(s, t, wf) {
  out("u", t, 0, "{\"schema_version\":1,\"kind\":\"binding\",\"type\":\"start\",\"session_id\":\"" s "\",\"ts\":\"" iso(t, 0) "\",\"workflow\":\"" wf "\",\"source\":\"transcript\"}")
}
function binding_research(s, t, ref) {
  out("u", t, 0, "{\"schema_version\":1,\"kind\":\"binding\",\"type\":\"research\",\"session_id\":\"" s "\",\"ts\":\"" iso(t, 0) "\",\"ref\":\"" ref "\",\"source\":\"transcript\"}")
}
function binding_declare(s, t, ref) {
  out("u", t, 0, "{\"schema_version\":1,\"kind\":\"binding\",\"type\":\"declare\",\"session_id\":\"" s "\",\"ts\":\"" iso(t, -1) "\",\"ref\":\"" ref "\",\"source\":\"declare-command\",\"invoking_session_id\":\"" s "\",\"sidechain\":false}")
}
function cursorrow(s, t,   r, role, path, off, ms, a, b, c, d) {
  r = rnd(10)
  ms = rnd(1000)
  if (r < 3) {
    role = "main"
    path = "/Users/dev/.claude/projects/-Users-dev-repo/" s ".jsonl"
  } else {
    a = rnd(65536); b = rnd(65536); c = rnd(65536); d = rnd(4096)
    role = sprintf("subagents/agent-a%04x%04x%04x%03x.jsonl", a, b, c, d)
    path = "/Users/dev/.claude/projects/-Users-dev-repo/" s "/" role
  }
  off = rr(10000, 3000000)
  out("u", t, ms, "{\"schema_version\":1,\"kind\":\"cursor\",\"session_id\":\"" s "\",\"role\":\"" role "\",\"path\":\"" path "\",\"offset\":" off ",\"size\":" off ",\"hw_ts\":\"" iso(t, ms) "\",\"hw_ids\":" hwids() ",\"ts\":\"" iso(t, -1) "\"}")
}
# ex is a pre-formatted run of members, no braces and no trailing comma.
function costrow(kind, s, te, ex, gb, cwd,   bm, dl, nb) {
  bm = bmodels(1)
  dl = dollars()
  out("c", te, 0, "{\"schema_version\":1,\"kind\":\"" kind "\"," ex ",\"plan_slug\":null,\"session_id\":\"" s "\",\"buckets\":{\"fresh_input\":1,\"cache_write\":2,\"cache_read\":3,\"output\":4},\"total\":10,\"by_model\":" bm ",\"by_agent_type\":{\"main\":" BMV ",\"general-purpose\":" BMV "},\"dollars\":" dl ",\"rate_table_id\":\"sha256:6d17ab141d05c333\",\"partial\":false,\"started_at\":\"" iso(te - 900, 0) "\",\"ended_at\":\"" iso(te, 0) "\",\"duration_seconds\":900,\"duration_available\":true,\"git_branch\":\"" gb "\",\"project\":\"sha256:e8a9fc325f102fc0\",\"seq\":0,\"final\":true,\"ts\":\"" iso(te, -1) "\",\"session_cwd\":\"" cwd "\",\"source\":\"orchestrator\"}")
}
function cost_plain(kind, s, te, ex, gb) { costrow(kind, s, te, ex, gb, "/Users/dev/repo") }
function wtname(b,   g) {
  g = b
  gsub(/\//, "+", g)
  return "worktree-" g
}

function edge(child, parent, src, t, sess,   sv) {
  sv = sess == "" ? "null" : "\"" sess "\""
  out("l", t, 0, "{\"schema_version\":1,\"kind\":\"edge\",\"child\":\"" child "\",\"parent\":\"" parent "\",\"source\":\"" src "\",\"ts\":\"" iso(t, -1) "\",\"session_id\":" sv ",\"sidechain\":false}")
}
function mergerow(pr, key, t, sess,   sv) {
  sv = sess == "" ? "null" : "\"" sess "\""
  out("l", t, 0, "{\"schema_version\":1,\"kind\":\"merge\",\"pr\":" pr ",\"key\":\"" key "\",\"merged_at\":\"" iso(t, -1) "\",\"source\":\"gh-pr-merge\",\"ts\":\"" iso(t, -1) "\",\"session_id\":" sv "}")
}
function unlinkrow(child, parent, t) {
  out("l", t, 0, "{\"schema_version\":1,\"kind\":\"unlink\",\"child\":\"" child "\",\"parent\":\"" parent "\",\"source\":\"link-command\",\"ts\":\"" iso(t, -1) "\",\"session_id\":null,\"sidechain\":false}")
}
# A PR's rows: the create edge, the merge row, and the merge edge.
function prrows(pr, key, tc, tm, sess) {
  edge("pr:" pr, key, "gh-pr-create", tc, sess)
  mergerow(pr, key, tm, sess)
  edge("pr:" pr, key, "gh-pr-merge", tm, sess)
}

function newbranch(t0, len,   r, b, k, sl, t) {
  r = rnd(100)
  if (r < 45) {
    ISS++
    k = rnd(5)
    b = "debt/" ISS "-" SLG[k]
    k = rnd(10)
    if (k == 0) { ISS++; b = "debt/" (ISS - 1) "-" ISS "-batch" }
  } else if (r < 60) {
    SPN++
    k = rnd(4)
    b = sprintf("plan/spec-%03d-%s", SPN, SLP[k])
    SPO[++NSPO] = SPN
  } else if (r < 65) {
    PLN++
    b = sprintf("plan/plan-%03d-x", PLN)
  } else if (r < 80) {
    ISS++
    k = rnd(3); sl = rnd(3)
    b = TY1[k] "/" ISS "-" SLA[sl]
  } else if (r < 88) {
    t = t0 + rnd(len)
    civ(t)
    b = sprintf("chore/task-%04d-%02d-%02d-%02d%02d", CY, CM, CD, CH, CN)
  } else if (r < 93) {
    SPN++
    k = rnd(2)
    b = sprintf("spec-%03d-%s", SPN, SLF[k])
  } else {
    k = rnd(3); sl = rnd(1000001)
    b = "feat/" SLW[k] "-" sl
  }
  ACT[++AN] = b
}
function actpick(   lo) {
  lo = AN > 300 ? AN - 299 : 1
  return ACT[lo + rnd(AN - lo + 1)]
}

# One stretch of history [t0, t0 + len) holding fr of a month's activity.
function gen_period(t0, len, fr,   tend, nb, i, ns, nseg, nbs, nbr, nbd, nclosed, nextra, nm, j, k, n, s, t, t2, sbr, key, inh, r, wf, te, b, gb, pr, tc, tm, tw, kind, ex, run, ncur, nlin, sp, ms, ms2, base, nsl) {
  tend = t0 + len
  nb = cnt(150, fr)
  for (i = 0; i < nb; i++) newbranch(t0, len)
  ns = cnt(700, fr)
  split("", S); split("", PER); split("", SL); split("", SFT)
  for (i = 0; i < ns; i++) { S[i] = sid(); PER[i] = 0 }
  nseg = cnt(4191, fr)
  for (i = 0; i < nseg; i++) { k = rnd(ns); PER[k]++ }
  nsl = 0
  for (i = 0; i < ns; i++) {
    n = PER[i]
    if (n == 0) continue
    s = S[i]
    k = len - n * 1500
    if (k < 0) k = 0
    t = t0 + rnd(k + 1)
    r = rnd(10)
    sbr = r < 6 ? actpick() : ""
    SL[++nsl] = i
    for (j = 0; j < n; j++) {
      k = rr(20, 1800)
      t += k
      k = rr(5, 900)
      t2 = t + k
      if (t2 >= tend) t2 = tend - 1
      if (t > t2) t = t2
      if (j == 0) SFT[i] = t
      r = rnd(100)
      inh = r < 6
      r = rnd(100)
      if (inh) key = "session:" s
      else if (sbr != "" && r < 85) key = "branch:" sbr
      else key = "session:" s
      ms = rnd(1000); ms2 = rnd(1000)
      segrow(key, s, inh, t, ms, t2, ms2)
      t = t2
    }
  }
  nbs = cnt(280, fr); nbr = cnt(270, fr); nbd = cnt(75, fr)
  nclosed = 0
  for (i = 0; i < nbs; i++) {
    k = 1 + rnd(nsl); s = S[SL[k]]; base = SFT[SL[k]]
    t = base - rnd(601)
    if (t < t0) t = t0
    wf = WF[rnd(6)]
    binding_start(s, t, wf)
    r = rnd(100)
    if (r < 85) {
      te = t + rr(300, 5400)
      if (te >= tend) te = tend - 1
      nclosed++
      if (wf == "gaia-spec") {
        SPN++
        cost_plain("spec", s, te, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", SPN), "main")
      } else if (wf == "gaia-plan") {
        k = rnd(21)
        k = SPN - k
        if (k < 101) k = 101
        cost_plain("plan", s, te, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", k), "main")
      } else {
        RUNI++
        run = sprintf("%s-%s-%04x", wf, stamp(te), RUNI)
        ex = "\"spec_id\":null,\"plan_id\":null,\"command\":\"" wf "\",\"run_id\":\"" run "\""
        r = rnd(10)
        if (wf == "gaia-debt" && r < 7) {
          PRN++
          ex = ex ",\"github\":{\"type\":\"pr\",\"number\":" PRN ",\"repo\":\"x/y\"}"
        }
        cost_plain("command", s, te, ex, "main")
      }
    }
  }
  for (i = 0; i < nbr; i++) {
    k = 1 + rnd(nsl); s = S[SL[k]]; base = SFT[SL[k]]
    t = base - rnd(601)
    if (t < t0) t = t0
    r = rnd(1000)
    if (r < 110) b = "research:wide-a"
    else if (r < 165) b = "research:wide-b"
    else { k = rnd(401); b = "research:topic-" k }
    binding_research(s, t, b)
  }
  for (i = 0; i < nbd; i++) {
    k = 1 + rnd(nsl); s = S[SL[k]]; base = SFT[SL[k]]
    t = base - rnd(601)
    if (t < t0) t = t0
    r = rnd(2)
    k = rnd(101)
    b = (r ? "research" : "init") ":slug-" k
    binding_declare(s, t, b)
  }
  ncur = cnt(3155, fr)
  for (i = 0; i < ncur; i++) {
    s = S[rnd(ns)]
    t = t0 + rnd(len)
    cursorrow(s, t)
  }
  nextra = cnt(480, fr) - nclosed
  for (i = 0; i < nextra; i++) {
    s = S[rnd(ns)]
    te = t0 + rnd(len)
    r = rnd(100)
    if (r < 55) {
      b = actpick()
      k = rnd(10)
      gb = k < 3 ? wtname(b) : b
      k = rnd(31)
      k = SPN - k
      if (k < 101) k = 101
      cost_plain("execute", s, te, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", k), gb)
    } else if (r < 75) {
      b = actpick()
      cost_plain("review", s, te, "\"spec_id\":null,\"plan_id\":null", b)
    } else {
      RUNI++
      run = sprintf("gaia-wiki-%s-%04x", stamp(te), RUNI)
      cost_plain("command", s, te, "\"spec_id\":null,\"plan_id\":null,\"command\":\"gaia-wiki\",\"run_id\":\"" run "\"", "main")
    }
  }
  nm = cnt(60, fr)
  for (j = 0; j < nm; j++) {
    b = actpick()
    PRN++; pr = PRN
    tc = t0 + rnd(len)
    k = rr(1, 72)
    tm = tc + k * 3600
    if (tm >= tend) tm = tend - 1
    if (tc > tm) tc = tm
    s = S[rnd(ns)]
    prrows(pr, "branch:" b, tc, tm, s)
    if (j % 6 == 0) tw = "research:wide-a"
    else if (j % 12 == 1) tw = "research:wide-b"
    else tw = ""
    if (tw != "") {
      k = rnd(3600)
      t = tm + k
      if (t >= tend) t = tend - 1
      edge("branch:" b, tw, "link-command", t, "")
      WIDEN[tw]++
    }
  }
  nlin = cnt(10, fr)
  for (i = 0; i < nlin; i++) {
    t = t0 + rnd(len)
    sp = NSPO > 0 ? SPO[1 + rnd(NSPO)] : 101
    k = rnd(401)
    edge(sprintf("spec:SPEC-%03d", sp), "research:topic-" k, "spec-frontmatter", t, "")
  }
  nlin = cnt(2, fr)
  for (i = 0; i < nlin; i++) {
    t = t0 + rnd(len)
    b = actpick()
    unlinkrow("branch:" b, "issue:1", t)
  }
}

function addprobe(pr, key, raw, cat, expect,   kj, rj) {
  kj = key == "" ? "null" : "\"" key "\""
  rj = raw == "" ? "null" : "\"" raw "\""
  PROBES = PROBES (NPROBE ? ",\n" : "") "  {\"pr\":" pr ",\"key\":" kj ",\"raw\":" rj ",\"category\":\"" cat "\",\"expect\":{" expect "}}"
  NPROBE++
}

# The probe structures, built around the day that starts at d0. Eight
# categories land in every set; the final set also carries the cursor probe and
# names the typical, widest, and initiative probes.
function pset(d0, fin, planvar,   I, K, s, s2, pr, pra, prb, sr, R, N, P, E, ref, k, t) {
  I = PI++
  K = "debt/" I "-first"
  s = sid()
  PRN++; pr = PRN
  pseg("branch:" K, s, 0, d0 + 3600)
  pseg("branch:" K, s, 0, d0 + 7200)
  pseg("branch:" K, s, 0, d0 + 10800)
  pseg("branch:" K, s, 0, d0 + 25200)
  prrows(pr, "branch:" K, d0 + 1800, d0 + 21600, s)
  addprobe(pr, "branch:" K, "worktree-debt+" I "-first", "first_merge", "\"merges\":1")
  if (fin) { TYPICAL = pr; ISSUE_ROOT = "issue:" I }

  I = PI++
  K = "fix/" I "-repeat"
  s = sid(); s2 = sid()
  PRN++; pra = PRN
  PRN++; prb = PRN
  pseg("branch:" K, s, 0, d0 - 180000)
  pseg("branch:" K, s, 0, d0 - 176400)
  prrows(pra, "branch:" K, d0 - 259200, d0 - 172800, s)
  pseg("branch:" K, s2, 0, d0 + 7200)
  pseg("branch:" K, s2, 0, d0 + 10800)
  prrows(prb, "branch:" K, d0 + 3600, d0 + 32400, s2)
  addprobe(pra, "branch:" K, K, "repeat_merge", "\"merges\":2")
  addprobe(prb, "branch:" K, K, "repeat_merge", "\"merges\":2")

  I = PI++
  K = "debt/" I "-multi"
  R = "research:multi-" I
  s = sid(); sr = sid()
  PRN++; pr = PRN
  binding_research(sr, d0 + 1800, R)
  pseg("session:" sr, sr, 0, d0 + 3000)
  pseg("branch:" K, s, 0, d0 + 3600)
  pseg("branch:" K, s, 0, d0 + 7200)
  edge("branch:" K, R, "link-command", d0 + 1800, "")
  prrows(pr, "branch:" K, d0 + 1800, d0 + 28800, s)
  addprobe(pr, "branch:" K, K, "multi_root", "\"roots_min\":2")
  if (fin) RESEARCH_ROOT = R

  I = PI++
  K = "feat/" I "-inherit"
  s = sid()
  PRN++; pr = PRN
  pseg("branch:" K, s, 0, d0 + 3600)
  pseg("session:" s, s, 1, d0 + 7200)
  pseg("branch:" K, s, 0, d0 + 10800)
  prrows(pr, "branch:" K, d0 + 1800, d0 + 28800, s)
  addprobe(pr, "branch:" K, K, "inherit", "\"inherit\":true")

  N = PN++
  P = sid(); E = sid()
  PRN++; pr = PRN
  if (planvar) {
    K = sprintf("plan/plan-%03d-int", N)
    ref = sprintf("plan:PLAN-%03d", N)
    binding_start(P, d0 + 1800, "gaia-plan")
    cost_plain("plan", P, d0 + 7200, sprintf("\"spec_id\":null,\"plan_id\":\"PLAN-%03d\"", N), "main")
  } else {
    K = sprintf("plan/spec-%03d-int", N)
    ref = sprintf("spec:SPEC-%03d", N)
    binding_start(P, d0 + 1800, "gaia-spec")
    cost_plain("spec", P, d0 + 7200, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", N), "main")
  }
  pseg("session:" P, P, 0, d0 + 2400)
  pseg("session:" P, P, 0, d0 + 3600)
  pseg("branch:" K, E, 0, d0 + 10800)
  pseg("branch:" K, E, 0, d0 + 14400)
  prrows(pr, "branch:" K, d0 + 9000, d0 + 32400, E)
  addprobe(pr, "branch:" K, K, "interval", "\"interval\":true")
  if (fin) SPEC_ROOT = ref

  I = PI++
  K = "docs/" I "-nospend"
  s = sid()
  PRN++; pr = PRN
  prrows(pr, "branch:" K, d0 + 1800, d0 + 21600, s)
  addprobe(pr, "branch:" K, K, "no_spend", "\"no_spend\":true")

  I = PI++
  K = "debt/" I "-wide"
  s = sid()
  PRN++; pr = PRN
  pseg("branch:" K, s, 0, d0 + 3600)
  pseg("branch:" K, s, 0, d0 + 7200)
  edge("branch:" K, "research:wide-a", "link-command", d0 + 1800, "")
  WIDEN["research:wide-a"]++
  prrows(pr, "branch:" K, d0 + 1800, d0 + 28800, s)
  addprobe(pr, "branch:" K, K, "wide_root", "\"roots_min\":1")
  if (fin) WIDEST = pr

  if (fin) {
    K = "fix/cursor-drift"
    s = sid()
    PRN++; pr = PRN
    pseg("branch:" K, s, 0, d0 + 3600)
    pseg("branch:" K, s, 0, d0 + 7200)
    costrow("execute", s, d0 + 7500, "\"spec_id\":null,\"plan_id\":null", K, "/Users/dev/{\\\"schema_version\\\":1,\\\"kind\\\":\\\"cursor\\\",\\\"x\\\":1}")
    out("u", d0 + 7600, 0, "{\"kind\":\"cursor\",\"schema_version\":1,\"session_id\":\"" s "\",\"role\":\"main\",\"path\":\"/Users/dev/.claude/projects/-Users-dev-repo/" s ".jsonl\",\"offset\":4096,\"size\":4096,\"hw_ts\":\"" iso(d0 + 7600, 0) "\",\"hw_ids\":[],\"ts\":\"" iso(d0 + 7600, -1) "\"}")
    prrows(pr, "branch:" K, d0 + 1800, d0 + 28800, s)
    addprobe(pr, "branch:" K, K, "cursor_adversarial", "\"nonzero\":true")
  }
}

BEGIN {
  SEED = (seed0 % 2147483646) + 1
  for (i = 0; i < 16; i++) rnd(2)
  SCALE = scale + 0
  split("claude-opus-5-5 claude-sonnet-5-5 claude-haiku-4-5 claude-opus-4-8", MD, " ")
  for (i = 1; i <= 4; i++) MD[i - 1] = MD[i]
  split("gaia-spec gaia-plan gaia-debt gaia-wiki gaia-audit update-deps", WFT, " ")
  for (i = 1; i <= 6; i++) WF[i - 1] = WFT[i]
  split("fix-x guard lint docs quote", SGT, " ")
  for (i = 1; i <= 5; i++) SLG[i - 1] = SGT[i]
  split("cost usage ledger ui", SPT, " ")
  for (i = 1; i <= 4; i++) SLP[i - 1] = SPT[i]
  split("fix feat chore", TYT, " ")
  for (i = 1; i <= 3; i++) TY1[i - 1] = TYT[i]
  split("a bb ccc", SAT, " ")
  for (i = 1; i <= 3; i++) SLA[i - 1] = SAT[i]
  split("foo bar", SFT2, " ")
  for (i = 1; i <= 2; i++) SLF[i - 1] = SFT2[i]
  split("widget page hook", SWT, " ")
  for (i = 1; i <= 3; i++) SLW[i - 1] = SWT[i]
  ALPHA = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz0123456789"
  for (i = 0; i < 4096; i++) {
    c = ""
    for (j = 0; j < 5; j++) { k = rnd(length(ALPHA)); c = c substr(ALPHA, k + 1, 1) }
    CH5[i] = c
  }
  ISS = 3000; SPN = 100; PLN = 10; PRN = 5000; RUNI = 0; AN = 0; NSPO = 0
  PI = 90001; PN = 901; NPROBE = 0; PROBES = ""
  DAY = 86400
  END_T = base_end + 0
  START_T = END_T - 30 * months * DAY
  for (m = 0; m < months - 1; m++) gen_period(START_T + m * 30 * DAY, 30 * DAY, 1)
  gen_period(START_T + (months - 1) * 30 * DAY, 29 * DAY, 29 / 30)
  gen_period(END_T - DAY, DAY, 1 / 30)

  # The first segment of the ledger, so the earliest-spend probe sits inside
  # the coverage window by construction.
  s = sid()
  pseg("session:" s, s, 0, START_T + 120)
  I = PI++
  K = "fix/" I "-early"
  s = sid()
  PRN++; pr = PRN
  pseg("branch:" K, s, 0, START_T + 7200)
  pseg("branch:" K, s, 0, START_T + 10800)
  prrows(pr, "branch:" K, START_T + 14400, START_T + 3 * DAY, s)
  addprobe(pr, "branch:" K, K, "lower_bound", "\"lower_bound\":true")

  pset(START_T + 8 * DAY, 0, 0)
  pset(START_T + int(months * 15) * DAY, 0, 1)
  pset(END_T - DAY, 1, 0)

  addprobe(7777777, "", "", "unresolvable", "\"unresolvable\":true")

  printf "{\"typical_pr\":%d,\"widest_pr\":%d,\"probes\":[\n%s\n],\"initiative_roots\":{\"research\":\"%s\",\"issue\":\"%s\",\"spec\":\"%s\"},\"cut\":__CUT__}\n", TYPICAL, WIDEST, PROBES, RESEARCH_ROOT, ISSUE_ROOT, SPEC_ROOT > pfile
  close(pfile)
}
AWK

IFS= read -r -d '' SPLIT_PROGRAM <<'AWK' || true
BEGIN {
  f["u"] = ufile; f["l"] = lfile; f["c"] = cfile
  ck = cutkey ""
}
{
  st = substr($0, 1, 1)
  key = substr($0, 2, 13)
  line = substr($0, 16)
  if (!(st in cut) && (key "") >= ck) cut[st] = bytes[st] + 0
  print line > f[st]
  bytes[st] += length(line) + 1
}
END {
  for (st in f) {
    close(f[st])
    if (!(st in cut)) cut[st] = bytes[st] + 0
  }
  printf "%d %d %d\n", cut["u"], cut["l"], cut["c"] > cutfile
  close(cutfile)
}
AWK

: >"$outdir/usage.jsonl"
: >"$outdir/links.jsonl"
: >"$outdir/cost.jsonl"
cut_key="$(printf '%010d000' $((BASE_END_EPOCH - 86400)))"

LC_ALL=C "$awk_bin" -v months="$months" -v seed0="$seed" -v scale="$scale" -v base_end="$BASE_END_EPOCH" \
  -v pfile="$tmp/probes.frag" "$GEN_PROGRAM" |
  LC_ALL=C sort -s -k1,1 |
  LC_ALL=C "$awk_bin" -v ufile="$outdir/usage.jsonl" -v lfile="$outdir/links.jsonl" -v cfile="$outdir/cost.jsonl" \
    -v cutkey="$cut_key" -v cutfile="$tmp/cuts" "$SPLIT_PROGRAM"

read -r cut_u cut_l cut_c <"$tmp/cuts"
frag="$(cat "$tmp/probes.frag")"
cut_json="{\"u\":$cut_u,\"l\":$cut_l,\"c\":$cut_c}"
printf '%s\n' "${frag/__CUT__/$cut_json}" >"$outdir/probes.json"
