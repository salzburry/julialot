---
name: lot-contracts
description: >
  Author, review, validate, and apply per-tumor lines-of-therapy (LOT) contracts —
  the governed rule sets that make the claims-based LOT algorithm in `Jul 28/lot/engine/`
  portable across tumors. Use this skill whenever the user mentions lines of therapy,
  LOT rules, or line counting for ANY tumor (myeloma, ovarian, prostate, SCLC, or a
  new indication); asks how the LOT algorithm would handle a tumor-specific concept
  (platinum sensitivity, PFI/TFI, ADT backbone, re-challenge, maintenance, drug
  roles); wants to port, configure, or generalize the LOT engine; or wants to add,
  change, or question a tumor's LOT rule set — even if they don't say "contract".
---

# LOT contracts

A **contract** is one tumor's complete lines-of-therapy rule set, written as a file
in `contracts/`. The engine's discipline extends here: a different rule set is a
different algorithm, so every axis is explicit, every change is versioned, and
nothing defaults silently.

## Current engine status — read this first

The engine in `Jul 28/lot/engine/` does **not** read these contract files yet. It reads
`config.csv`/environment settings, and its rule *shapes* are partly hardcoded for
myeloma. The contracts are the governed specification of what each tumor's run
means — today they drive design, review, and Q&A; the planned refactor makes the
engine consume them directly. Never imply a contract axis is already a runtime
switch unless `references/rule-shapes.md` marks that shape `implemented`.

The myeloma contract (`contracts/multiple_myeloma.yaml`) is extracted from the
code and pinned by the validator to the engine's shipped defaults — it is the
acceptance baseline. When engine work lands, byte-identical myeloma output is the
test that the kernel didn't move.

## The pieces

| Read | When |
|---|---|
| `references/kernel.md` | you need how the engine actually works — episodes (MAP), event streams, line assembly, the end ladder |
| `references/rule-shapes.md` | you need the vocabulary contracts are written in: drug roles, advancement predicates, event streams, equivalence classes, boundary labels — and each shape's implementation status |
| `references/interview.md` | you are drafting or completing a contract and need the clinical questions, each mapped to a contract field |
| `contracts/_schema.md` | you need the file format, field by field |
| `contracts/*.yaml` | the contracts themselves — the single source of truth for a tumor's rules |

## Workflows

### Answering "how does LOT handle X for tumor Y"

Read that tumor's contract plus `kernel.md`; answer from the contract and cite the
field (for example `advancement.same_regimen_gap_days`). If the contract says
`TBD`, the answer is "undecided, pending clinical review" — that is a real answer;
do not fill the gap from general knowledge. If the tumor has no contract, say so
and offer to draft one.

### Drafting a contract for a new tumor

1. Read `references/interview.md` and `contracts/_schema.md`.
2. Work through the interview with the user. Every axis gets an explicit value —
   including explicit "none" (an empty `event_streams: {}` is a statement, not an
   omission). Where the user cannot answer, write a `TBD:` entry naming what is
   needed and from whom.
3. Literature-conventional values (a 6-month platinum-free interval, a 90-day
   treatment-free interval) may be proposed, but always with `assumed: true` and a
   note — a convention is a starting point for sign-off, never a decision made on
   the study team's behalf. Never mark a contract `reviewed` yourself.
4. Set `status: draft`, `contract_version: 1`, fill `provenance`.
5. Run the validator (below). Fix what it names.

### Changing an existing contract

A changed axis is a changed algorithm. Bump `contract_version`, record what
changed and on whose request in `provenance.notes`, and keep `status` honest — a
reviewed contract that changes becomes `draft` again unless the change itself is
signed off. Run the validator.

### Supporting the engine refactor

When implementing engine support for a shape, read `rule-shapes.md` for where the
shape's prototype lives in `Jul 28/lot/engine/` (the melphalan rule is the gap-advancement
prototype; the SCT machinery is the event-stream prototype). The myeloma-baseline
acceptance rule applies to every kernel change.

## Validation

After touching any contract:

```
Rscript .claude/skills/lot-contracts/scripts/validate_contracts.R
```

Base R only. It checks structure and coherence (roles are from the taxonomy and
disjoint; a gap threshold only with the gap rule on; the end ladder is a
permutation of known reasons; a return cannot confirm a discontinuation where
every run-out already counts; drafts carry their TBDs; reviewed contracts carry a
reviewer), and pins the myeloma contract to the engine's shipped defaults.
`--selftest` proves the checks can fail.

**The pin reads the engine.** It parses `CONTRACT` out of `build_lot.R` and
compares field by field, and every engine setting must be either bound to a
contract field or named in `NOT_AN_AXIS` with a reason — so a setting added to
the engine with no decision recorded fails this script. It used to be a
hand-written copy of the engine's values, which is a different thing: three
settings were added to `CONTRACT` and the contract validated clean throughout,
because nothing here had ever read the engine.

The repository's merge gate runs both this and `--selftest`, via
`validation/hygiene/lot_contract_binding.R`. Before that suite existed the
validator was not run by anything, so a live pin would still have sat there
unexecuted.

## House rules

- **Predicates vs labels.** What counts a line (assembly-time) and what classifies
  a boundary (PFI/TFI categories, computed afterwards) are separate layers. Never
  let a label silently change line counting.
- **The re-treatment caveat travels.** In claims, recurrence and progression are
  observable only as re-treatment; interval labels are proxies. Any clinical
  deliverable built from a contract states this.
- **Contracts are the source.** If a chat answer and a contract file disagree, the
  file wins — fix the file or the answer, never let them drift.
