# A ready-to-run prompt for the trial-definition comparison

The one of the three proposed validation tasks that is not already built. The
other two exist: `R/benchmarks.R` and `R/sensitivity.R` cover the quantitative
framework including its face-validity checks, and `R/vignettes.R` holds 21 edge
cases covering every scenario the proposal names. This one is 72 empty rows.

Run it once per source, not once for all six. A prompt that asks for IMWG and
five trials in one pass produces six answers of the quality of the worst one,
and there is no way to tell afterwards which was which.

---

## The prompt

> You are filling one source's column of a governed evidence grid for a
> multiple myeloma lines-of-therapy algorithm. Use the `lot-evidence` skill.
>
> **Source:** <NCT id, or the IMWG consensus reference>
> **source_id to use:** <`trial_1`..`trial_5`, or `IMWG_consensus`>
>
> Read `Jul 28/lot/validation/R/definitions.R` for the twelve dimensions and
> what our algorithm does about each. Then read the source and answer, for each
> of the twelve, how *that source* operationalises it.
>
> For each dimension produce one CSV row with these columns:
> `dimension_id, source_id, source_type, citation, retrieved, answer,
> concordance, notes`
>
> Rules, all of which the grid's reader enforces — a run that breaks one stops
> and names the row:
>
> * `source_type` is `protocol`, `registry`, `publication` or `guideline`.
>   `search_summary` and `recollection` are rejected: a summary of a document
>   is not a document, and neither can be checked by someone holding the
>   source.
> * `citation` is required whenever `answer` is filled, and must be specific
>   enough to reopen — section, table or field, not just a title. A registry
>   citation needs the NCT id and the field.
> * `retrieved` is required for a registry, publication or guideline, because
>   those records change under a stable name.
> * `concordance` is `agrees`, `differs` or `unclear` against our answer.
>
> **`unclear` is the expected answer for several of the twelve and is a real
> finding.** A trial that requires "≥3 prior lines" without defining a line is
> telling you something true about the field. Do not resolve it by inferring
> what they probably meant — cite where the document declines to say, and mark
> it `unclear`.
>
> Where the source `differs`, say how in `notes`, concretely and in its terms:
> "counts tandem transplant as one line", not "stricter than ours".
>
> Do not change anything in `Jul 28/lot/engine/`. Whether to follow a source
> that differs is a study-team decision, not part of this task.
>
> Output the twelve rows as CSV. Then append them to
> `Jul 28/lot/validation/definitions_sources.csv`, replacing that source's
> existing blank rows rather than adding duplicates, and run:
>
> ```
> Rscript .claude/skills/lot-evidence/scripts/check_grids.R
> ```
>
> Report what it says. If it refuses, fix the citation or empty the cell —
> never remove or weaken the guard.

---

## What good output looks like

Not twelve confident answers. A realistic column for a single phase III trial
is a handful of `agrees`, one or two `differs` with a specific mechanism, and
several `unclear` — because most trial protocols settle the transplant and
maintenance questions and are silent on gaps, membership windows and dose
changes.

A column that comes back twelve-for-twelve answered, with no `unclear`, is the
result to distrust. The prior-lines criterion is usually one paragraph, and one
paragraph does not settle twelve questions.

## Why the constraint is the point, for the use-case write-up

The grid was scaffolded and guarded before anything was asked of a model: the
columns say what a citation has to contain, and the reader refuses an answer
without one, a rejected source type, a registry with no retrieval date, and a
comparability claim with no basis. So the output is checkable by someone who
never saw the prompt.

That is the transferable part. The task is not "compare these definitions" —
it is "fill this schema, which will reject you if you cannot support a cell".
An empty cell costs nothing; a plausible unsourced one gets quoted and cannot
be chased. Building the refusal first is what makes the extraction safe to
delegate.
