# OrgGraph

OrgGraph infers reporting lines from a flat list of employees. The hosted app is available on [GitHub Pages](https://meet2712.github.io/orggraph-python-simplified/), with a [browser SQL explorer](https://meet2712.github.io/orggraph-python-simplified/data.html) and an interactive [database diagram](https://meet2712.github.io/orggraph-python-simplified/schema.html).

The repository contains 500 generated companies and 87,160 employees. Job titles, departments, teams, locations and missing values are deliberately inconsistent so the inference runs against realistic input rather than pre-cleaned records.

## Approach

Python generates two independent datasets:

- `employees_messy.csv` contains the observed employee records used by the app.
- `employees_ground_truth.csv` contains the generated manager answers used only for offline evaluation.

SQLite stores two source tables: `companies` and `employees`. Headcount, company size, role classification, manager candidates, scores, decisions and audit fields are calculated by the views in [`schema.sql`](schema.sql). There is no persisted employee-to-manager mapping, so inserting or changing an employee immediately changes the relevant view results.

The inference is six views in a row:

1. `employee_role_classification` cleans the title text, writes out short forms such as `sr`, `mgr` and `eng`, and reads off a level (CEO, C-Suite, VP / Head, Director, Manager, Team Lead, Senior IC, ...) and a department (Engineering, Sales, ...). It also checks the team: a team path is believed only when it contains the department named in the title.
2. `employee_reporting_features` settles each person's team and adds the rank from `reporting_ladder`. A team that fits is kept. A missing or contradicted team is filled in only when one team is possible: the department has a single team, or exactly one manager has no team and exactly one team has no manager. Team leads are placed the same way.
3. `employee_manager_candidates` pairs each person with the people they could report to: leads and managers on their own team, and for managers the people one team up. People at the right level elsewhere in the department are kept as well, because one of them may be the real manager with a wrong or missing team.
4. `employee_manager_scores` finds the nearest manager on the person's own team path, meaning the lowest rank found there, and gives that pair a strong rule named after the two levels. Someone who could sit in between gets a rival rule. Everyone else gets a weak rule.
5. `employee_top_manager_candidates` keeps the best candidate and the runner-up.
6. `employee_reporting_decisions` accepts the best candidate only when its score reaches 0.98 and leads the runner-up by 0.04. Everyone else is unresolved, with the rule and a one-line reason attached.

The Flask app reads those SQL results and renders the org chart. A company-scoped query generated from the same view definitions avoids scoring all 500 companies for each page request.

## The rules

Every reporting line in the app carries one of these rule names. `select * from reporting_rules` returns the same table from the database.

| Rule | Score | Matches |
|---|---|---|
| `exec_to_ceo` | 0.99 | Executive reports to the CEO |
| `vp_to_matching_exec` | 0.99 | VP/Head reports to the executive who owns their portfolio |
| `vp_to_ceo_no_exec` | 0.99 | VP/Head reports to the CEO because no executive owns their portfolio |
| `office_to_vp` | 0.99 | IC in the executive office reports to the VP/Head of their department |
| `director_to_vp` | 0.99 | Director reports to the VP/Head of the same department |
| `manager_to_director` | 0.99 | Manager reports to the Director on the parent team |
| `manager_to_vp` | 0.99 | Manager reports to the VP/Head on the parent team |
| `next_level_up` | 0.99 | Management role reports to the next level up on the same or parent team |
| `lead_to_manager` | 0.99 | Team Lead reports to the Manager of the same team |
| `senior_to_manager` | 0.99 | Senior, Staff or Principal IC reports to the Manager of the same team |
| `junior_to_lead` | 0.99 | Junior or intermediate IC reports to the Team Lead of the same team |
| `junior_to_manager` | 0.99 | Junior or intermediate IC reports to the Manager of the same team; the team has no Team Lead |
| `untitled_to_manager` | 0.99 | No job title, but the team has one Manager and no Team Lead |
| `closer_level_elsewhere` | 0.96 | Someone at a closer level in this department is not on this team path and could be the manager |
| `untitled_colleague` | 0.96 | Someone on this team path has no job title and could be the manager |
| `same_team_only` | 0.90 | Same team, but someone closer is expected |
| `parent_team_only` | 0.85 | Higher up the team path, but someone closer is expected |
| `same_department_only` | 0.67 | Same department, team not matched |

The first thirteen are the strong rules. They are one idea written out per pair of levels: a person reports to the lowest rank above them on their own team path. `reporting_ladder` says which ranks each level can report to.

The two rival rules score 0.96. That is below the 0.98 threshold, so a rival is never accepted, and within 0.04 of a strong rule, so a rival holds the line back. This is how "a team lead with no team could be this junior's real manager" stops the junior from being attached to the manager.

The last three never create a line. They only decide which candidate is shown as "unconfirmed" for people who stay unresolved. A shared location adds 0.002 to any score as a tie-break, and two candidates on the same strong rule block each other through the 0.04 margin.

## Key decisions

- Keep the messy source values unchanged and derive normalized features in views.
- Treat people management and individual-contributor seniority as separate tracks. Senior, Staff and Principal ICs do not become managers because of title seniority.
- Vary the C-suite by company size and industry rather than assigning every executive role to every company.
- Use team paths, function, leadership level and location as visible evidence for each candidate.
- Believe a team only when it agrees with the job title. A team path from another department is treated as missing.
- Fill a missing team by elimination only, when exactly one team is possible. Nothing is guessed from a title alone.
- Accept a manager only when the top score reaches `0.98` and leads the next candidate by at least `0.04`; otherwise leave the line unresolved.
- Give every rule a name and a fixed score, so each accepted line can be traced to one row of `reporting_rules` and the results can be reported per rule.
- Keep the answer key outside the operational database so evaluation cannot influence inference.
- Use named SQL rules instead of the earlier Python logistic model. The model reached 97.7% precision at 76.6% coverage on the same held-out companies; the rules do slightly better and every decision can be explained in one sentence.

The hierarchy policy is documented in [`docs/HIERARCHY.md`](docs/HIERARCHY.md), and [`docs/DATABASE.md`](docs/DATABASE.md) describes the tables, views and checks.

## How I worked

I built the project over three days in small, focused commits. After changing the generator or `schema.sql`, I rebuilt the database, ran the tests and dataset validation, and then reran the held-out evaluation. I kept a change only when precision remained above 98% and the rest of the pipeline still behaved as expected. GitHub Actions repeats the same checks on every push and publishes the site only after they pass.

The database and inference design were primarily my work. This is my main area of expertise, and I designed roughly 95% of the data side myself, including the schema, SQL views, hierarchy rules, thresholds and evaluation approach. I used an AI coding assistant selectively for the remaining work: reviewing edge cases, suggesting alternatives and speeding up repetitive implementation. I checked every suggestion against the hierarchy policy in [`docs/HIERARCHY.md`](docs/HIERARCHY.md) and reran the evaluation before keeping it. The results in this README come from the scripts in [`scripts/`](scripts), not from manually entered figures.

I relied more heavily on AI for the frontend because that is not my primary area. It helped create the presentation layer and org-chart interactions, while I decided what the app needed to show and reviewed the result against the brief. The frontend stays deliberately thin: it displays the reporting decisions calculated in SQL rather than applying a separate hierarchy algorithm.

The review process also helped me refine two useful additions: a queryable `reporting_rules` view, so the matching policy can be read in one place, and per-rule evaluation, so a weak rule is visible instead of being hidden inside the overall precision figure.

## Measurement

The rules were worked out on companies 1–350 and scored on companies 426–500. That set contains 13,447 employees across 75 companies. SQL accepted 11,431 reporting lines; 11,400 matched the independent answer key and 31 did not. That is **99.73% precision at 85.48% coverage**. The scores for companies 426–500 were visible while these rules were being adjusted, so this is not a strictly blind test. These figures measure performance on the generated dataset and should not be treated as real-company accuracy.

Precision is correct accepted lines divided by all accepted lines. Coverage is accepted lines divided by employees who have a manager in the answer key. `scripts/evaluate_sql_inference.py` also reports both per rule; the [results page](https://meet2712.github.io/orggraph-python-simplified/results.html) shows that table. The weakest rule is `next_level_up` at 98.5% and 9 of the 13 strong rules are at 100%.

Run the checks with:

```bash
python -m unittest discover -s tests -p 'test_*.py'
python pipeline/validate_dataset.py --data-dir data
python scripts/check_database_views.py
python scripts/evaluate_sql_inference.py
```

## Run locally

Use Python 3.11 or later:

```bash
git clone https://github.com/meet2712/orggraph-python-simplified.git
cd orggraph-python-simplified
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python scripts/build_database.py
python app.py
```

Open <http://127.0.0.1:5000>. The local database is `instance/orggraph.sqlite3`. The app queries its views at request time. The GitHub Pages version is a static export and changes only when the site is rebuilt and deployed.

Regenerate the dataset with:

```bash
python pipeline/generate_dataset.py --companies 500 --min-employees 100 --max-employees 250 --seed 20261029 --output-dir data
```

## Repository map

| Path | Purpose |
|---|---|
| [`pipeline/generate_dataset.py`](pipeline/generate_dataset.py) | Generate the messy source data and independent answer key |
| [`pipeline/validate_dataset.py`](pipeline/validate_dataset.py) | Validate company size, hierarchy, keys and source messiness |
| [`schema.sql`](schema.sql) | Define the source tables and live inference views |
| [`sql/company_predictions.sql`](sql/company_predictions.sql) | Run the same inference for one company |
| [`database.py`](database.py) | Load source records and query company results |
| [`app.py`](app.py), [`templates/`](templates) | Serve the Flask pages |
| [`scripts/evaluate_sql_inference.py`](scripts/evaluate_sql_inference.py) | Compare held-out SQL decisions with the answer key |
| [`scripts/quality_checks.sql`](scripts/quality_checks.sql) | Check keys, cardinality, score bounds, decisions, rules and cycles |
| [`scripts/build_erd.py`](scripts/build_erd.py) | Build the database diagram from the SQLite schema |
| [`scripts/export_site.py`](scripts/export_site.py) | Export the app for GitHub Pages |

GitHub Actions runs the tests and publishes the static site. The browser SQL explorer uses a compressed, read-only snapshot of the same database.
