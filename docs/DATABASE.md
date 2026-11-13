# Database design

The SQLite database persists company details and observed employee records. SQL views calculate headcounts, role features, candidate managers, scores, decisions and reporting summaries whenever the source rows are queried.

## Source tables

| Table | Grain | Stored fields |
|---|---|---|
| `companies` | One company | ID, name, industry and headquarters |
| `employees` | One observed person | Company and employee IDs, name, title, department, team, location and email |

`employees.company_id` joins each employee to a company. `(company_id, employee_id)` is the employee key. Neither key encodes a reporting relationship, and `companies` does not store headcount or size band.

## Views

| View | Calculation |
|---|---|
| `reporting_thresholds` | Minimum score and lead required to accept a manager |
| `reporting_rules` | Every matching rule with its score, group and one-line description |
| `reporting_ladder` | Each level's rank and the ranks it can report to |
| `company_overview` | Company details with current employee count and size band |
| `employee_role_classification` | Normalized title and team text, inferred department and seniority, and whether the team fits the title |
| `employee_reporting_features` | The settled team for each person, its parent team and the leadership rank |
| `employee_manager_candidates` | Plausible employee–manager pairs within each company |
| `employee_manager_scores` | The rule for each candidate pair, and that rule's score |
| `employee_top_manager_candidates` | Best candidate, its rule, and the runner-up's rule and score per employee |
| `employee_reporting_decisions` | Accepted manager or unresolved per employee, with the rule and a reason |
| `company_reporting_summary` | Accepted lines, unresolved people and coverage per company |
| `dataset_reporting_summary` | Reporting totals across the dataset |
| `employee_reporting_audit` | Source record, inferred manager, rule and reason together |

[`schema.sql`](../schema.sql) contains every definition. The app uses [`sql/company_predictions.sql`](../sql/company_predictions.sql), a company-scoped query generated from the same inference views. It materializes each stage once for the selected company while preserving the rules in the public views.

Candidate ranking runs entirely in SQL. `employee_manager_scores` finds the lowest rank on each person's own team path and labels that pair with a strong rule; `reporting_rules` turns the name into a score. Thirteen strong rules score 0.99 and can be accepted. Two rival rules score 0.96: they mark someone who could be the real manager, and because they sit within the margin of a strong rule they hold the line back. Three weak rules only rank the candidate shown for unresolved people. A manager is accepted when the best candidate reaches `reporting_thresholds.score_threshold` and its lead over the runner-up reaches `reporting_thresholds.margin_threshold`. A new employee can receive a decision immediately, and the new row can also change another employee's candidate ranking.

To see why one person was placed where they are:

```sql
select full_name, job_title, inferred_manager, leading_candidate, confidence, margin, decision, rule, reason
from employee_reporting_audit
where company_id = 'cmp_0004' and employee_id in ('emp_0000542', 'emp_0000543');
```

Team paths are compared with equality only, so `%` and `_` remain ordinary characters, and the parent of a team is its path with the last segment removed. Blank team labels and `N/A`, `Unknown` and `-` count as missing. A team is believed only when its path contains the department named in the job title; a path from another department is treated as missing too.

`employee_reporting_features` fills a missing team in three cases, each of which leaves one possibility: the department has a single team; exactly one manager has no team and exactly one team has no manager; exactly one team lead has no team and exactly one team has no lead. A VP/Head is placed at the top of their department, and so is the only Director of a department. `team_inferred` is 1 on every row where the team was filled in this way. When more than one team is possible the team stays empty and the person stays unresolved.

The [schema page](../templates/schema.html) shows both source tables, all views and their direct dependencies. Solid lines are foreign keys. Dashed arrows show which objects each view reads.

## Offline evaluation

[`data/employees_ground_truth.csv`](../data/employees_ground_truth.csv) contains the generated direct-manager answers. It is not imported into SQLite and is not available to the inference views. [`scripts/evaluate_sql_inference.py`](../scripts/evaluate_sql_inference.py) compares held-out SQL decisions with that file after inference finishes.

## Checks

- `pipeline/validate_dataset.py` validates source keys, company sizes, hierarchy structure and data messiness.
- `scripts/quality_checks.sql` checks table and view cardinality, score bounds, accepted decisions, leadership rank, reporting cycles, and that every scored pair names a rule.
- `scripts/check_database_views.py` checks summary consistency and query time.
- `scripts/evaluate_sql_inference.py` measures held-out precision and coverage, overall and per rule.

The loader builds a new SQLite file atomically when the source CSVs or schema change. The downloadable database is a read-only snapshot used by the browser SQL explorer.
