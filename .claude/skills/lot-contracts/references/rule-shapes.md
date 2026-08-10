# The rule-shape library

Tumors differ in rule *shapes*, not just thresholds. A contract composes these
shapes with its parameters. Each shape below states what it is, the contract
fields that carry it, and its **engine status** — be precise about status when
answering users: `implemented` (the engine does this today), `prototype` (exists
for one case; generalizing is designed but not built), `specified` (contracts can
express it; the engine cannot run it yet).

## 1. Drug roles — status: partially implemented

What a drug *is* to line assembly. The taxonomy:

| Role | Meaning | Engine today |
|---|---|---|
| `line_defining` | starts lines, joins regimens, its runout ends lines | implemented (the default for every listed drug) |
| `supportive` | invisible to assembly entirely | implemented for exactly one hardcoded class (`STEROID`) |
| `backbone` | recorded in outputs, persists across lines, never starts/advances/ends one — prostate's ADT | specified only |
| `maintenance` | may extend a line it belongs to, never advances one — PARP/bev in ovarian | specified only (myeloma's `contains_mtx_reg` is a descriptive flag, not a role) |

Contract fields: `drug_roles.default_role`, `drug_roles.supportive_classes`,
`drug_roles.backbone_classes`, `drug_roles.maintenance_classes` — assigned by
code-list *class*, because drug identity already lives in the code list.
Coherence: a class carries one role.

Why it matters: without `backbone`, an ADT refill after a line ends would
trigger a spurious new line — the exact failure the steroid rule prevents for
myeloma, needed generally.

## 2. Advancement predicates — status: mixed

What counts a new line, chosen as a set:

- `new_agent` — a non-equivalent, non-supportive drug's episode after the line
  end. **Implemented**; this is the engine's core rule.
- `same_regimen_gap_days` — a fresh episode of the *same* regimen after ≥ X days
  advances the line (re-challenge). **Prototype**: the pinned-off melphalan rule
  (`R/melp_rule.R`) is exactly this shape for one drug at 180 days. Ovarian's
  platinum re-challenge and SCLC's sensitive relapse need it generally. Engine
  default without it: a base-drug refill stretches the line without bound.
- `drop_based` — losing a drug from a combination advances. **Specified only**;
  the engine never advances on a drop.

Contract fields: `advancement.new_agent`, `advancement.same_regimen_gap_days`
(`none` = off), `advancement.drop_based`.

## 3. Typed event streams — status: implemented for SCT, generalizable

Non-drug events that can start lines, end lines, or both, each with grouping
rules, windows, and a priority order. Myeloma instantiates three (AUTO with
14-day clustering / 60-day merge / 180-day tandem; ALLO as single-day lines;
CAR-T with 45-day consolidation and bridging). A solid tumor's chemoRT or
surgery stream is the same machinery with different codes and windows. Empty
streams no-op — but today's loaders require the SCT code list present and
non-empty, so "no streams" needs a real switch, not an empty file.

Contract fields: `event_streams.<NAME>.*`, plus `lines.line1_start_events` and
`lines.same_day_tie` / `lines.end_priority` for how streams rank.

## 4. Equivalence classes — status: implemented

Drugs that count as "the same" for regimen-change purposes. Implemented as
biosimilar pairs via `permissible_subs.csv`; carboplatin ↔ cisplatin as "the
same platinum" is the identical shape. Contract fields: `equivalence.source`,
`equivalence.pairs` (additions beyond the file, as `A~B` strings).

## 5. Boundary labels — status: specified only

Classifications computed *between* assembled lines, after assembly:
platinum-free interval, treatment-free interval, sensitive/resistant categories.
They never change line counting — that separation is a house rule. In claims,
recurrence/progression is observable only as re-treatment, so these labels are
proxies and every deliverable says so.

Contract fields: `boundary_labels.<name>.{from_event, to_event, *_min_days,
assumed, note}`.

## 6. Windows, caps, ladder — status: implemented

`lines.regimen_window_days_*`, `lines.max_lot`, `lines.end_priority`,
`episodes.*`, `observation.censor_at_disenrollment` — all real settings today,
governed by the engine's CONTRACT mechanism. A tumor's parameter set is a
contract in exactly that sense.

## Applying the library — the three worked cases

| Tumor | Composed from | New kernel machinery |
|---|---|---|
| Ovarian | gap advancement (~183 d, assumed) · `maintenance` role · platinum equivalence · PFI label | none |
| Prostate | `backbone` role for ADT · existing new-agent advancement · optional state label | none |
| SCLC | gap advancement at 90 d · re-challenge counted as new line · TFI label · possibly a chemoRT stream | none |
