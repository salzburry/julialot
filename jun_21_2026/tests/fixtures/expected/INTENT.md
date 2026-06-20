# Intended behaviour for the drafted cases (spec-expected — PENDING review)

These are **spec-expected intent** notes for the cases whose inputs are drafted,
written so reviewers can check the trace. They are **not** committed
regression-expected values: the regression baseline is generated from the
approved legacy code at the baseline Git SHA, and these spec-expected notes need
clinical + engineering dual-review before they gate anything.

## MAP001 — pharmacy simple runout
Input: one LENA fill 2020-01-01, days_supply 28.
Intended `MAP_STACKED`: one MAP; map_start 2020-01-01; map_rx_runout 2020-01-28
(= date + 28 − 1); no pushout; map_end 2020-01-28.

## MAP002 — pharmacy pushout
Input: LENA fills 2020-01-01 (28d) and 2020-01-20 (28d).
The second fill (2020-01-20) is on/before the current rx_runout (2020-01-28), so
it **pushes out**: rx_runout = 2020-01-28 + 28 = 2020-02-25.
Intended `MAP_STACKED`: one MAP; map_start 2020-01-01; map_rx_runout 2020-02-25.
(Contrast MAP003: a fill *after* rx_runout but within med_runout resets
**without** pushout.)

## SCT002 — AUTO tandem
Input: backbone BORT fill 2020-01-15 (establishes LOT1_START); two autologous SCT
procedures (CPT 38241) on 2020-03-01 and 2020-07-01 (122 days apart, < 180, no
ALLO between).
Intended `LOT1_SCT`: AUTO_DT_1 = 2020-03-01; AUTO_DT_2 = 2020-07-01;
LOT1_SCT_AUTO_TAND_FLG = 1 (valid tandem).

(CPT 38241 = autologous hematopoietic progenitor cell transplantation; used here
as an illustrative AUTO code. Real fixtures pin codes against the approved
SCT codelist during Increment 0B.)
