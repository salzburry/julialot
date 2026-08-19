# Contract file format

One file per tumor, YAML — restricted to the subset the base-R validator parses:
two-space indentation, nesting at most three levels, `key: value` scalars,
`key:` opening a map, `- value` scalar list items, `[]` / `{}` for explicitly
empty, `none` as the explicit off-value. Full-line `#` comments only. No inline
maps, anchors, or quoted strings.

Every field below is required unless marked optional. Absence is never a
default — an axis that does not apply is written as `[]`, `{}`, `none`, or
`false`, so the contract states it was considered.

```yaml
tumor: <snake_case name>
contract_version: <integer, bumped on any rule change>
status: <baseline_extracted | draft | reviewed>

provenance:
  source: <where these rules came from>
  reviewed_by: <[] until real names/dates>
  notes: <history; what changed at each version and on whose request>

observation:
  censor_at_disenrollment: <true | false>

episodes:
  medical_day_supply: <days>
  pharmacy_missing_day_supply: <days>
  map_discon_gap_days: <days>

drug_roles:
  default_role: line_defining
  supportive_classes:   # invisible to assembly; [] if none
    - <CODE LIST CLASS>
  backbone_classes: []      # persist across lines, never advance; [] if none
  maintenance_classes: []   # extend a line, never advance; [] if none

equivalence:
  source: <substitution file, or none>
  pairs: []                 # additions as "A~B" strings

lines:
  max_lot: <integer 1..9>
  line1_start_events:       # event types that may begin line 1
    - MED
  regimen_window_days_line1: <days>
  regimen_window_days_later: <days>
  discon_confirm_days: <days | none>     # observation required AFTER a run-out
  discon_confirmed_by_return: <true | false>
  same_day_tie:             # event-type order when triggers share a day
    - <TYPE>
  end_priority:             # full ladder; must include DEATH, DISCONTINUATION, STUDY_END
    - <REASON>

advancement:
  new_agent: <true | false>
  same_regimen_gap_days: <days | none>   # none = a re-challenge never advances
  prior_line_agent_return: <new_line | joins_line>  # a prior line's agent
                                         # returning after the current line's
                                         # regimen window: splits, or folds in
  drop_based: <true | false>

event_streams: {}           # or one map per stream:
#  <NAME>:
#    claim_window_days: <days>       (optional; claim clustering)
#    merge_gap_days: <days>          (optional)
#    tandem_max_gap_days: <days>     (optional)
#    consolidation_days: <days>      (optional; regimen window when this type starts a line)
#    bridging_med_add_days: <days>   (optional)
#    induction_absorbed: <true|false> (optional; an event inside line 1's
#                                      regimen window belongs to line 1 and
#                                      neither ends it nor starts a line)
#    line_span: <regimen | single_day>
#    may_start_line1: <true | false>
#    may_start_later_lines: <true | false>

boundary_labels: {}         # or one map per label:
#  <name>:
#    from_event: <text>
#    to_event: <text>
#    sensitive_min_days: <days>      (or other *_min_days cut-points)
#    assumed: <true | false>
#    note: <text — include the re-treatment-proxy caveat>

criteria: {}                # or one map per criterion:
#  <name>:
#    enabled: <true | false>

expectations:
  note: <where this tumor's face-validity bands live, or TBD>
```

`lines.discon_confirm_days` is the wait before a run-out counts as a
discontinuation, and `none` is the explicit off — every run-out counts. Below
the window the line is censored at end of observation instead, so the two
values a tumor picks here decide how many of its lines end `DISCONTINUATION`
rather than `STUDY_END`. `discon_confirmed_by_return: true` says an observed
line-opening event after the run-out confirms it on its own, without waiting
out the window; it is meaningless with `discon_confirm_days: none` and the
validator refuses that pair.

Status semantics: `baseline_extracted` is reserved for contracts pinned to
shipped engine behavior (myeloma). `draft` means unreviewed — it must contain at
least one `TBD` or an empty `reviewed_by`, and generated deliverables must say
so. `reviewed` requires a non-empty `reviewed_by` and no `TBD` anywhere.
