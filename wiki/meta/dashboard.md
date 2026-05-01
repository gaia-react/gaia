---
type: meta
title: 'Dashboard'
created: 2026-04-26
updated: 2026-05-01
tags: [meta, dashboard]
status: active
---

# Wiki Dashboard

## Recent Activity

```dataview
TABLE type, status, updated FROM "wiki" SORT updated DESC LIMIT 15
```

## Seed Pages (Need Development)

```dataview
LIST FROM "wiki" WHERE status = "seed" SORT updated ASC
```

## Pages Not Updated in 30+ Days

```dataview
TABLE updated, type FROM "wiki" WHERE date(updated) <= date(today) - dur(30 days) SORT updated ASC LIMIT 20
```

## Pages by Domain

```dataview
TABLE length(rows) AS "Count" FROM "wiki" GROUP BY type SORT length(rows) DESC
```

## Large Pages (over 100 lines)

```dataview
TABLE type, updated FROM "wiki" WHERE file.size > 5000 SORT file.size DESC
```
