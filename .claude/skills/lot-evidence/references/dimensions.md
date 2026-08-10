# The 12 dimensions, and what to look for in a source

Our answer to each lives in `Jul 28/lot/validation/R/definitions.R`, cited to
the line of the engine that decides it. Read it there rather than from here —
this file is a finding aid, not a second copy, and a second copy would drift.

What follows is what each dimension *asks*, and the wording a source tends to
use when it answers. A trial rarely has a section called "line of therapy"; it
answers these in eligibility criteria, in a stratification factor, or in a
footnote to the CONSORT diagram.

| `dimension_id` | the question | where a source usually answers it |
|---|---|---|
| `sct_auto_is_a_line` | Is autologous transplant its own line, or part of the induction it follows? | eligibility ("≥1 prior line, transplant counted as..."), or a footnote defining prior therapy |
| `sct_allo_is_a_line` | Is allogeneic transplant a line? | usually an exclusion criterion rather than a definition |
| `cart_is_a_line` | Is CAR-T a line of its own, and what about bridging therapy? | eligibility in later-line trials; bridging is often explicitly *not* counted |
| `maintenance_is_a_line` | Is maintenance a line, or a continuation of the induction? | the commonest disagreement in the field. Often "induction, consolidation and maintenance count as one line" |
| `what_starts_a_new_line` | What event begins a line — a new agent, a new regimen, a restart? | definition of "prior line" or "prior regimen" in eligibility |
| `gap_ends_a_line` | Does a treatment gap end a line, and after how long? | rarely stated in trials; look to registry and real-world publications |
| `regimen_membership_window` | How long after the start may an agent join the same regimen? | almost never stated in trials — expect `unclear` |
| `substitution` | Does swapping one agent for a similar one start a new line? | "substitution within a class does not constitute a new line" or similar |
| `steroids` | Do steroids count as an agent for line purposes? | often silent; sometimes "excluding corticosteroids" |
| `dose_change` | Does a dose change or a route change start a new line? | "dose modification does not constitute a new line" |
| `line_cap` | Is there a maximum number of lines counted? | an analysis convention, not a clinical one; look in the SAP |
| `first_line_start` | What dates the first line — diagnosis, first treatment, or something else? | index date definition in a real-world study; in a trial, the definition of "newly diagnosed" |

## Reading a trial protocol for these

The prior-lines criterion is the richest source and is usually one paragraph.
It typically settles four of the twelve at once: whether transplant counts,
whether maintenance counts, what starts a line, and whether substitution does.

Two cautions.

**Eligibility is not always a definition.** "Patients must have received ≥3
prior lines" tells you the trial counted lines; it does not tell you how,
unless a footnote says. Cite the footnote, not the criterion, and record
`unclear` when there is no footnote.

**A trial's convention is scoped to that trial.** It is evidence about the
field's range, not a standard the algorithm must match. `differs` is a
finding, not a defect — record how it differs and leave the decision alone.

## Source types

`protocol`, `registry`, `publication`, `guideline` are accepted. Two are
rejected outright by the reader, and both look like citations:

* `search_summary` — a summary of a document rather than the document. Cannot
  be checked by anyone holding the source.
* `recollection` — from memory. Nothing for a reader to go to.

A registry citation needs the NCT id and the field it came from. A registry,
publication or guideline citation also needs `retrieved`, because those records
change under a stable name.
