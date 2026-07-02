---
type: meta
title: 'Lint Report 2026-07-03'
created: 2026-07-03
updated: 2026-07-03
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-07-03

## #11: Wiki drift check

ℹ 1 commits behind HEAD. Run /gaia-wiki sync at next opportunity.

## #12: Dead repo-relative paths

✓ No dead repo-relative paths detected in wiki body prose.

## #13: UAT/SPEC narrative-ref drift

⚠ 111 narrative ref(s) found in instruction files / shipped extension surfaces:

- `.gaia/tests/forensics/01-redaction-roundtrip.bats:100` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:108` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:230` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:241` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:25` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:252` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:270` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:287` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:3` → comment naming specific working-doc ID
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:32` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:43` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:50` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:62` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:72` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:80` → test name prefix (UAT label)
- `.gaia/tests/forensics/01-redaction-roundtrip.bats:88` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:104` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:114` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:124` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:130` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:136` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/02-classification-evidence.bats:22` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:28` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:3` → comment naming specific working-doc ID
- `.gaia/tests/forensics/02-classification-evidence.bats:34` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:40` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:46` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:52` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:58` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:64` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:70` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:76` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:82` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:88` → test name prefix (UAT label)
- `.gaia/tests/forensics/02-classification-evidence.bats:94` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:104` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:117` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:126` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:139` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/03-strict-schema.bats:3` → comment naming specific working-doc ID
- `.gaia/tests/forensics/03-strict-schema.bats:57` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:65` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:73` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:81` → test name prefix (UAT label)
- `.gaia/tests/forensics/03-strict-schema.bats:93` → test name prefix (UAT label)
- `.gaia/tests/forensics/04-write-surface.bats:105` → test name prefix (UAT label)
- `.gaia/tests/forensics/04-write-surface.bats:127` → test name prefix (UAT label)
- `.gaia/tests/forensics/04-write-surface.bats:148` → test name prefix (UAT label)
- `.gaia/tests/forensics/04-write-surface.bats:167` → test name prefix (UAT label)
- `.gaia/tests/forensics/04-write-surface.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/04-write-surface.bats:77` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:100` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:107` → comment naming specific working-doc ID
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:145` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:155` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:162` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:4` → comment naming specific working-doc ID
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:57` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:63` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:69` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:77` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:84` → test name prefix (UAT label)
- `.gaia/tests/forensics/05-gh-invocation-shape.bats:93` → test name prefix (UAT label)
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:46` → test name prefix (UAT label)
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:53` → test name prefix (UAT label)
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:59` → test name prefix (UAT label)
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:76` → test name prefix (UAT label)
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:83` → test name prefix (UAT label)
- `.gaia/tests/forensics/06-gh-decline-saves-locally.bats:90` → test name prefix (UAT label)
- `.gaia/tests/forensics/07-gh-not-installed.bats:103` → test name prefix (UAT label)
- `.gaia/tests/forensics/07-gh-not-installed.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/07-gh-not-installed.bats:69` → test name prefix (UAT label)
- `.gaia/tests/forensics/07-gh-not-installed.bats:75` → test name prefix (UAT label)
- `.gaia/tests/forensics/07-gh-not-installed.bats:81` → test name prefix (UAT label)
- `.gaia/tests/forensics/07-gh-not-installed.bats:87` → test name prefix (UAT label)
- `.gaia/tests/forensics/07-gh-not-installed.bats:93` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:100` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:106` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:112` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:118` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:124` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:139` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/08-user-config-no-gh.bats:88` → test name prefix (UAT label)
- `.gaia/tests/forensics/08-user-config-no-gh.bats:94` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:121` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:2` → comment naming specific working-doc ID
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:54` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:60` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:66` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:72` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:78` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:84` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:91` → test name prefix (UAT label)
- `.gaia/tests/forensics/09-other-class-offers-gh.bats:97` → test name prefix (UAT label)
- `.gaia/tests/forensics/integration.md:105` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:126` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:139` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:159` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:185` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:47` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:60` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:72` → section header with UAT ID
- `.gaia/tests/forensics/integration.md:86` → section header with UAT ID
- `.gaia/tests/forensics/unit.bats:130` → test name prefix (UAT label)
- `.gaia/tests/forensics/unit.bats:150` → test name prefix (UAT label)

## #14: Orphan pages

✓ No orphan pages (every page has at least one inbound wikilink).

## #15: Frontmatter gaps

✓ All wiki pages carry the required frontmatter (type, status).

## #16: Empty sections

✓ No empty sections detected.
