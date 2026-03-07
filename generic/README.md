# Generic LOT (Lines of Therapy) Algorithm Framework

A reusable, cancer-type-agnostic framework for computing Lines of Therapy (LOT)
from claims data. Configure once per disease/indication via YAML — no code changes needed.

## Architecture

```
generic/
├── README.md                    # This file
├── lot_engine.R                 # Core LOT engine (disease-agnostic)
├── map_algorithm.R              # MAP (Medication Available Period) state machine
├── lot_config_schema.R          # Config loader + validator
├── configs/
│   ├── mm_lot_config.yaml       # Multiple Myeloma example config
│   └── sample_onc_config.yaml   # Sample oncology config (illustrative)
└── run_lot.R                    # Entry point: load config → run pipeline
```

## How It Works

The LOT algorithm has a universal structure across cancer types:

1. **Medication Claims Pull** — Identify relevant drug claims using disease-specific code lists
2. **MAP Algorithm** — Build Medication Available Periods using pushout/runout logic
3. **LOT Assignment** — Assign lines of therapy based on induction windows,
   regimen changes, and discontinuation gaps
4. **Procedure Events** (optional) — Detect procedures that end/interrupt lines
   (e.g., SCT in MM, surgery in solid tumors)

### What's Generic (Code)
- MAP state machine (pushout/runout/gap logic)
- LOT line numbering and regimen tracking
- Discontinuation detection
- Add-medication / regimen-change detection
- Pipeline orchestration and QC

### What's Configurable (YAML)
- Drug code lists (NDC, HCPCS, J-codes) and rollup mappings
- Drug classes and abbreviations
- Induction window duration
- MAP gap threshold
- Discontinuation gap threshold
- Which drug classes to exclude from line-start logic (e.g., steroids)
- Permissible substitutions
- Line-ending procedures and their detection rules
- Maintenance therapy rules

## Quick Start

```r
source("generic/run_lot.R")

# Run LOT analysis with a disease-specific config
run_generic_lot(
  config_path = "generic/configs/mm_lot_config.yaml",
  con = my_databricks_connection,
  cohort_table = "my_schema.ELIG_COH_FINAL"
)
```

## Adding a New Disease/Indication

1. Copy `configs/sample_onc_config.yaml`
2. Fill in your disease-specific drug codes, classes, and rules
3. Run `run_generic_lot()` with your config path
4. No R code changes needed for standard LOT patterns

## Design Principles

- **Separation of concerns**: Algorithm logic in R, disease knowledge in YAML
- **Same MAP core**: The pushout/runout state machine is identical across diseases
- **Extensible**: Hook functions for disease-specific post-processing
- **Backwards compatible**: The MM-specific code in `R/lot_program.R` is untouched
