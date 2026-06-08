# Personal Habit System

**A longitudinal scoring & analytics data project for self-assessment.  Uses a relational db, and a versioned, deterministic scoring engine over first-party time-series data.**

PHS turns a daily self-assessment across four domains into a reproducible composite score (0–20). It's a personal project, but the engineering is the point: a hand-designed SQLAlchemy schema with Alembic migrations, an applicability engine that decides what's expected each day, and metric definitions that are **versioned** so historical results stay comparable when the rules change.  Each score reproduces deterministically from its inputs and the rule version in force.

> This repository documents the **system** — schema, scoring logic, and API. It contains no personal daily records.  The tracked items are described at the category level.

---

## Why this is worth a look (the engineering, in one screen)

- **Self-collected longitudinal data** — daily observations since 2026-04-18 and growing, including a migrated markdown-journal era ingested into the model. Real time-series, not a static download.
- **15-table normalized model** — clean separation of *catalogs* (what can be tracked) from *events* (what happened), so the schema scales as items are added, renamed, or retired.
- **Two independent versioning systems** — Alembic migrations version the **schema**; a `rule_version` registry versions the **scoring rules**. Catalog membership is itself versioned (`rule_version_first` / `rule_version_last` on each activity).
- **Deterministic, reproducible scoring** — each day's score is stamped with the rule version that produced it; re-scoring is idempotent and auditable. History never changes when the rules evolve (SCD/bitemporal thinking applied to *metrics*).
- **Dynamic applicability engine** — completion rates are measured against what was actually expected that day (daily / weekday / day-of-week via a bitmask, with holiday shifting and per-day exceptions).
- **Stateful subsystems** — a multi-level streak engine with domain floors and a weighted-draw reward pool, both event-sourced.

---

## Architecture

```
Daily input ─► FastAPI service ─► SQLAlchemy ORM ─► SQLite
   (markdown era ─► ingest/parse ─► day_score_legacy)         (Alembic-migrated schema)
                                          │
                                          ▼
                    Deterministic scoring engine
        reads active rule_version + applicability rules
        writes day_score (stamped with rule_version_id)
                                          │
                       ┌──────────────────┼───────────────────┐
                       ▼                  ▼                   ▼
                 streak engine      reward draws        BI layer (Tableau)
```

**Stack:** Python · FastAPI · SQLAlchemy · Alembic · SQLite · SQL.

---

## Data model

Core scored model (the full schema also includes the streak, reward, and migration subsystems described below):

```
erDiagram
    rule_version ||--o{ day            : "governs"
    rule_version ||--o{ day_score      : "stamps"
    rule_version ||--o{ activity       : "scopes (first/last)"
    day        ||--|| day_score        : "scored as"
    day        ||--o{ time_block       : "~34 slots/day"
    day        ||--o{ activity_check   : "records"
    day        ||--o{ activity_hide    : "per-day exception"
    day        ||--o{ food_check       : "records"
    day        ||--o{ food_log_entry   : "logs"
    day        ||--o{ streak_event     : "emits"
    activity            ||--o{ activity_check : "evaluated in"
    activity            ||--o{ activity_hide  : "hidden in"
    food_checklist_item ||--o{ food_check     : "evaluated in"
    reward_pool_item    ||--o{ reward_draw    : "drawn from"

    day {
        date    date PK
        int     dow
        int     rule_version_id FK
        bool    food_nsa
        bool    food_logged
        bool    food_clean
        int     energy "nullable, 0-100"
        bool    energy_unavailable
        text    journal_text
        text    notes
        str     data_quality
    }
    day_score {
        date    date PK_FK
        int     rule_version_id FK
        float   score_time
        float   score_food
        float   score_physiology
        float   score_responsibilities
        float   score_avg "composite 0-20"
        int     streak_l1_after
        int     streak_l2_after
        int     streak_l3_after
        str     domain_floor_hit "NONE|SOFT|HARD"
        ts      computed_at
    }
    time_block {
        int     id PK
        date    date FK
        int     slot "0-33, 04:00-20:30"
        str     planned
        str     actual
        str     block_type "TP|MB|V|CU|NONE"
    }
    activity {
        int     id PK
        str     key UK
        str     domain "PHYSIOLOGY|RESPONSIBILITIES"
        str     display_name
        str     applicability "DAILY|WEEKDAY|DOW"
        int     dow_mask "bitmask"
        int     rule_version_first FK
        int     rule_version_last FK "nullable"
        bool    holiday_shift_to_next_workday
        bool    active
    }
    activity_check {
        date    date PK_FK
        int     activity_id PK_FK
        bool    checked
    }
    food_checklist_item {
        int     id PK
        str     key UK
        str     display_name
        bool    is_optional
    }
    rule_version {
        int     id PK
        str     version_key UK
        date    effective_from
        date    effective_to "nullable"
        str     summary
    }
```

**Table groups (15 personal-discipline tables):**

- **Spine & scores** — `day`, `day_score`, `day_score_legacy` (migrated markdown era).
- **Time** — `time_block` (one row per 30-min slot, with planned vs. actual text and a typed tag).
- **Activities (Physiology + Responsibilities)** — `activity` (catalog, versioned membership), `activity_check` (daily completion), `activity_hide` (per-day applicability exceptions).
- **Food** — three scored flags live on `day`; `food_checklist_item` / `food_check` add a granular component checklist, and `food_log_entry` is the free-text log.
- **Streaks & rewards** — `streak_event` (ADVANCE/RESET log), `reward_pool_item` (weighted, leveled pool), `reward_draw` (draws + re-roll lineage).
- **Governance & lineage** — `rule_version` (scoring registry), `ingest_run` (ingestion pipeline log), Alembic `alembic_version`.

---

## Scoring model

All four domains normalize to **0–20**; the composite (`score_avg`) is their mean.

| Domain | Inputs | Formula |
|---|---|---|
| **Time** | 34 × 30-min blocks (04:00–20:30), each typed | `Σ(points) / 68 × 20`, where TP = +2, MB = +1, V = −1, CU = −1, NONE = 0 (max 34 × 2 = 68) |
| **Food** | 3 binary flags on `day` | `NSA(10) + logged(5) + clean(5)` → 0–20 |
| **Physiology** | 15 activity items (domain = PHYSIOLOGY) | `completed / applicable × 20` |
| **Responsibilities** | 30 activity items (11 daily + 11 weekday + 8 day-of-week) | `completed / applicable × 20` |
| **Composite** | the four domain scores | `mean(...)` → 0–20 |

---

## Applicability engine (the dynamic denominator)

Completion-rate domains are only fair if "applicable" is computed correctly per day. Each `activity` carries:

- **`applicability`** — `DAILY`, `WEEKDAY`, or `DOW`.
- **`dow_mask`** — a bitmask selecting which weekdays a `DOW` item applies to.
- **`holiday_shift_to_next_workday`** — shifts an item off a holiday to the next workday.
- **`activity_hide`** — a per-day override removing an item from that day's applicable set.

So a Tuesday and a Saturday have genuinely different denominators, and completion rate is always measured against what was actually expected — not a fixed total.

---

## Versioning & reproducibility (the centerpiece)

Most personal trackers overwrite their rules, silently rewriting the meaning of every historical number. PHS versions everything:

- **Scoring rules** — the `rule_version` registry records each rule set with an `effective_from`/`effective_to` window and a changelog. This backup already holds **three real, dated versions** (e.g., a graduated physiology bonus replacing a flat perfect-day bonus; later item additions/renames with the scoring formula held constant).
- **Score provenance** — every `day_score` is stamped with the `rule_version_id` that produced it, so a day scored under v2 stays a v2 score forever.
- **Catalog membership** — each `activity` is bounded by `rule_version_first`/`rule_version_last`, so the *set* of tracked items is itself versioned.
- **Schema** — Alembic migrations version the database structure independently of the scoring rules.

Because scoring is a pure function of `(events, rule_version, applicability)`, any day can be **re-derived deterministically** and audited against the logic that was live when it was recorded. The payoff is **historical comparability**: trend lines mean the same thing across the whole series, and every rule change is explicit, dated, and reversible.

---

## Streaks, rewards & data lineage

- **Streak engine** — three streak levels tracked as snapshots on `day_score` (`streak_l1/2/3_after`), with per-domain floors (`domain_floor_hit` = NONE/SOFT/HARD) driving `ADVANCE`/`RESET` events in `streak_event`.
- **Reward engine** — a leveled, weighted `reward_pool_item` pool (experience / cash-deposit / time-grant / spending-allowance kinds) with `reward_draw` recording draws and re-roll lineage on streak unlocks.
- **Migration & ingest** — an earlier markdown-journal era was parsed into `day_score_legacy` (with source and parse timestamps) via an ingest pipeline (`ingest_run`), before the move to first-class structured capture.

---

## Data quality & integrity

- **Determinism / idempotency** — re-running the scorer over unchanged inputs yields identical output.
- **Referential integrity** — composite keys on event tables (`(date, activity_id)`, `(date, item_id)`) make duplicate or orphan events structurally impossible; foreign keys tie events to both the day and the catalog.
- **Dynamic denominators** — completion rates use day-specific applicable sets, avoiding inflated/deflated scores on partial-applicability days.
- **Auditability** — `computed_at` plus the rule-version stamp trace every score to its inputs and logic; `data_quality` flags days with degraded input.

---

## What the data supports analytically

- Rolling domain and composite trends (3 / 7 / 14-day) with sparklines
- Time-block heatmap (hour-of-day × date, by block type) — behavior structure at a glance
- Day-of-week patterns by domain
- Activity completion rates by domain and cadence
- Streak lifecycle (advance / reset) and floor events over time

*(A companion Tableau Public dashboard visualizes a scrubbed, aggregate view.)*

---

## Tech stack

`Python` · `FastAPI` · `SQLAlchemy` · `Alembic` · `SQLite` · `SQL` · relational modeling · versioned metric definitions · deterministic scoring

---

## Notes

This repository documents the system — schema, scoring logic, applicability rules, and API. It excludes personal daily records; item-level detail is described only at the category level. Design goals: reproducibility, historical comparability, and a clean separation between what is tracked and what is computed.
