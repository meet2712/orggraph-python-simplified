pragma foreign_keys = on;

-- Only observed source records are stored. Every other object below is a
-- read-only view, recalculated when an employee is inserted or changed.
create table companies (
    company_id TEXT primary key,
    company_name TEXT not null,
    industry TEXT not null,
    headquarters TEXT not null
);

create table employees (
    company_id TEXT not null references companies(company_id),
    employee_id TEXT not null,
    full_name TEXT not null,
    job_title TEXT not null,
    raw_department TEXT not null,
    raw_team TEXT not null,
    location TEXT not null,
    work_email TEXT not null,
    primary key (company_id, employee_id)
);

create index employees_by_company_team on employees(company_id, raw_team);

-- Central thresholds used by every reporting decision.
create view reporting_thresholds as
select 0.98 as score_threshold, 0.04 as margin_threshold;

create view company_overview as
select c.company_id, c.company_name, c.industry,
       case when count(e.employee_id) < 130 then 'Small'
            when count(e.employee_id) < 180 then 'Growth'
            else 'Mid-market' end as size_band,
       count(e.employee_id) as employee_count, c.headquarters
from companies c left join employees e using(company_id)
group by c.company_id;

-- The seniority ladder. A person can report to any rank from reports_to_from
-- to reports_to_upto; the lowest of those found on their team path is taken.
create view reporting_ladder as
with ladder(inferred_level, inferred_rank, reports_to_from, reports_to_upto) as (values
    ('CEO',                    10, null, null),
    ('C-Suite',                 9,   10,   10),
    ('VP / Head',               8,    9,   10),
    ('Senior Director',         7,    8,    8),
    ('Director',                6,    7,    8),
    ('Senior Manager',          5,    6,    8),
    ('Manager',                 4,    5,    8),
    ('Team Lead / Supervisor',  3,    4,    4),
    ('Principal / Staff IC',    2,    4,    4),
    ('Senior IC',               2,    4,    4),
    ('Individual Contributor',  1,    3,    4),
    ('Junior IC',               0,    3,    4),
    ('Unknown',              null,    3,    4)
)
select * from ladder;

-- Classify each observed role. Normalize title and team text inside this view;
-- the original employee row stays untouched and answer-key fields never enter.
create view employee_role_classification as
with tidy as materialized (
    select e.company_id, e.employee_id, e.location,
           ' ' || trim(replace(replace(replace(replace(replace(replace(replace(
               replace(replace(replace(replace(lower(e.job_title),
                 'manger', 'manager'), 'enginering', 'engineering'),
                 'analtyics', 'analytics'), 'securty', 'security'),
               '.', ' '), ',', ' '), '-', ' '), '/', ' '),
               '  ', ' '), '  ', ' '), '  ', ' ')) || ' ' as title_words,
           lower(trim(replace(replace(replace(e.raw_team, '  ', ' '),
               ' / ', '/'), ' /', '/'))) as team_words,
           lower(trim(e.raw_department)) as department_text
    from employees e
),
text as materialized (
    select company_id, employee_id, location, department_text,
           -- short forms written out once, so each pattern below is needed once
           replace(replace(replace(replace(replace(replace(title_words,
               ' sr ', ' senior '), ' jr ', ' junior '), ' mgr ', ' manager '),
               ' eng ', ' engineering '), ' ops ', ' operations '),
               ' cust ', ' customer ') as title_text,
           case when team_words not in ('', 'n/a', 'unknown', '-') then team_words end
             as team_path
    from tidy
),
labels as materialized (
    select t.*,
           -- the title without seniority words: "senior product manager" -> "product manager"
           replace(replace(replace(replace(title_text, ' junior ', ' '), ' senior ', ' '),
               ' staff ', ' '), ' principal ', ' ') as role_text,
           case
             when title_text like '% chief %' or title_text like ' cpo %'
               or trim(title_text) in ('ceo','cto','cro','coo','cpo','cmo','cdo','cfo','ciso','cio','cco')
               then 'Executive'
             when title_text like '% quality %' or title_text like '% qa %'
               then 'Engineering'
             when title_text like '% marketing %' or title_text like '% mktg %'
               or title_text like '% growth %' or title_text like '% demand gen %'
               or title_text like '% demand generation %' then 'Marketing'
             when title_text like '% security %' or title_text like '% infosec %'
               or title_text like '% grc %' then 'Security'
             when title_text like '% product engineering %' then 'Engineering'
             when title_text like '% product %' or title_text like '% ux %'
               or title_text like '% design %' then 'Product'
             when title_text like '% customer success %' or title_text like '% support %'
               or title_text like '% onboarding %' then 'Customer Success'
             when title_text like '% people %' or title_text like '% human resources %'
               or title_text like '% hr %' or title_text like '% talent %' then 'People'
             when title_text like '% operations %' or title_text like '% program %'
               then 'Operations'
             when title_text like '% sales %' or title_text like '% revenue %'
               or title_text like '% account %' or title_text like '% partnership %'
               or title_text like '% partnerships %'
               or title_text like '% business development %' then 'Sales'
             when title_text like '% finance %' or title_text like '% financial %'
               or title_text like '% accounting %' or title_text like '% fp&a %'
               then 'Finance'
             when title_text like '% legal %' or title_text like '% counsel %'
               or title_text like '% compliance %' or title_text like '% contracts %'
               then 'Legal'
             when title_text like '% data %' or title_text like '% analytics %'
               or title_text like '% analyst %' or title_text like '% machine learning %'
               or title_text like '% bi %' then 'Data & Analytics'
             when title_text like '% information technology %' or title_text like '% it %'
               or title_text like '% infrastructure %' or title_text like '% network %'
               or title_text like '% systems administrator %' or title_text like '% helpdesk %'
               or title_text like '% help desk %' then 'IT'
             when title_text like '% engineer %' or title_text like '% engineering %'
               or title_text like '% developer %' or title_text like '% software %'
               or title_text like '% technology %' or title_text like '% core services %'
               then 'Engineering'
           end as title_department,
           -- the department named inside the team path, if any
           case
             when '/' || team_path || '/' like '%/engineering/%' then 'Engineering'
             when '/' || team_path || '/' like '%/sales/%' then 'Sales'
             when '/' || team_path || '/' like '%/customer success/%' then 'Customer Success'
             when '/' || team_path || '/' like '%/product/%' then 'Product'
             when '/' || team_path || '/' like '%/marketing/%' then 'Marketing'
             when '/' || team_path || '/' like '%/data & analytics/%' then 'Data & Analytics'
             when '/' || team_path || '/' like '%/finance/%' then 'Finance'
             when '/' || team_path || '/' like '%/security/%' then 'Security'
             when '/' || team_path || '/' like '%/it/%' then 'IT'
             when '/' || team_path || '/' like '%/legal/%' then 'Legal'
             when '/' || team_path || '/' like '%/operations/%' then 'Operations'
             when '/' || team_path || '/' like '%/people/%' then 'People'
           end as team_department,
           case
             when department_text in ('eng','engineering','tech','software','r&d') then 'Engineering'
             when department_text in ('ops','operations','bizops','business ops') then 'Operations'
             when department_text in ('hr','people','people ops','people & culture') then 'People'
             when department_text in ('mktg','marketing','growth','demand gen') then 'Marketing'
             when department_text in ('sales','revenue','commercial','gtm') then 'Sales'
             when department_text in ('data','analytics','bi','data/ai','data & analytics')
               then 'Data & Analytics'
             when department_text in ('cs','customer success','cx','cust success','client success')
               then 'Customer Success'
             when department_text in ('fin','finance','accounting') then 'Finance'
             when department_text in ('prod','product','product & design') then 'Product'
             when department_text in ('security','infosec','cyber','grc') then 'Security'
             when department_text in ('legal','compliance','risk & legal') then 'Legal'
             when department_text in ('it','information technology','info tech','infrastructure')
               then 'IT'
             when department_text = 'executive' then 'Executive'
           end as listed_department
    from text t
)
select company_id, employee_id, location, team_path, title_text,
       case
         -- no title: only the top-level team identifies anyone, and that is the CEO
         when title_text = '  ' then case when team_path = 'company' then 'CEO' else 'Unknown' end
         when title_text like '% chief executive officer %' or title_text = ' ceo ' then 'CEO'
         when title_text like '% chief %' or title_text like ' cpo %'
           or trim(title_text) in ('cto','cro','coo','cpo','cmo','cdo','cfo','ciso','cio','cco')
           or title_text like '% general counsel %' then 'C-Suite'
         when title_text like '% vice president %' or title_text like '% vp %'
           or title_text like ' head %' then 'VP / Head'
         when title_text like '% senior director %' then 'Senior Director'
         when title_text like '% director %' then 'Director'
         when title_text like '% team lead %' or title_text like '% supervisor %'
           then 'Team Lead / Supervisor'
         -- Product, Account and Customer Success Managers are ICs, not people managers.
         when role_text not like ' product manager %' and role_text not like ' account manager %'
              and role_text not like ' customer success manager %'
              and (title_text like '% manager %' or title_text = ' program lead ')
           then case when title_text like ' senior %' then 'Senior Manager' else 'Manager' end
         when title_text like ' staff %' or title_text like ' principal %'
           or title_text like ' lead %' or title_text like '% lead ' then 'Principal / Staff IC'
         when title_text like ' senior %' then 'Senior IC'
         when title_text like ' junior %' then 'Junior IC'
         else 'Individual Contributor'
       end as inferred_level,
       -- The title names the department; without one the team path does,
       -- and the department column is the last resort.
       coalesce(title_department, team_department, listed_department, 'Unclassified')
         as inferred_department,
       -- A team is believed when its path contains the department named in the title.
       -- With no department in the title there is nothing to check it against.
       team_path is not null
         and (title_department is null
              or '/' || team_path || '/' like '%/' || lower(title_department) || '/%')
         as team_fits,
       -- the part of the company a C-suite title looks after
       case when title_text like '% chief technology %' or title_text like '% chief product %'
              or trim(title_text) in ('cto','cio','cdo','ciso') then 'Technology'
            when title_text like '% chief revenue %' or trim(title_text) in ('cro','cmo')
              then 'Revenue'
            when title_text like '% chief operating %' or title_text = ' coo ' then 'Operations'
            when title_text like '% chief financial %' or title_text = ' cfo ' then 'Finance & Risk'
            when title_text like '% chief people %' or title_text like ' cpo people %' then 'People'
       end as executive_portfolio,
       department_text = 'executive' as executive_office
from labels;

-- Settle each person's team and add the rank. The observed team is kept when it
-- fits. A missing or contradicted team is filled in only when one team is possible.
create view employee_reporting_features as
with roles as materialized (select * from employee_role_classification),
seen as materialized (
    select r.*, l.inferred_rank, l.reports_to_from, l.reports_to_upto,
           -- a non-manager who sits in the executive office
           r.executive_office and l.inferred_rank <= 3 as office_ic,
           case when r.inferred_level = 'CEO' then 'company'
                when r.inferred_level = 'C-Suite'
                  then coalesce('company/' || lower(r.executive_portfolio), r.team_path)
                when r.executive_office then case when l.inferred_rank is null then r.team_path end
                when r.team_fits then r.team_path end as seen_team,
           -- the path down to the department, e.g. company/technology/engineering
           case when r.team_fits and not r.executive_office then
                substr(r.team_path, 1, nullif(instr('/' || r.team_path || '/',
                    '/' || lower(r.inferred_department) || '/'), 0)
                    + length(r.inferred_department) - 1)
           end as seen_root
    from roles r
    join reporting_ladder l using (inferred_level)
),
teams as (
    select company_id, inferred_department, seen_team,
           coalesce(sum(inferred_rank <= 3), 0) as staff,
           sum(inferred_level = 'Manager') as managers,
           sum(inferred_level = 'Team Lead / Supervisor') as leads
    from seen where seen_team is not null
    group by company_id, inferred_department, seen_team
),
gaps as (
    -- per department: each column names a team only when exactly one team qualifies
    select company_id, inferred_department,
           case when sum(staff + managers > 0) = 1
                then max(case when staff + managers > 0 then seen_team end) end as only_team,
           case when sum(managers = 0 and staff >= 2) = 1
                then max(case when managers = 0 and staff >= 2 then seen_team end)
                end as team_without_manager,
           case when sum(leads = 0 and staff >= 2) = 1
                then max(case when leads = 0 and staff >= 2 then seen_team end)
                end as team_without_lead
    from teams
    group by company_id, inferred_department
),
departments as (
    select company_id, inferred_department,
           min(seen_root) as department_root,
           sum(inferred_level = 'Director') as directors,
           sum(inferred_level = 'Senior Manager') as senior_managers,
           sum(inferred_level = 'Manager' and seen_team is null) as managers_without_team,
           sum(inferred_level = 'Team Lead / Supervisor' and seen_team is null)
             as leads_without_team
    from seen
    group by company_id, inferred_department
),
placed as materialized (
    select s.*,
           case when s.office_ic then d.department_root
                when s.inferred_level = 'VP / Head' then coalesce(d.department_root, s.seen_team)
                when s.seen_team is not null then s.seen_team
                when s.inferred_department = 'Unclassified' then null
                when s.inferred_level = 'Director' and d.directors = 1 then d.department_root
                when s.inferred_level = 'Senior Manager' and d.senior_managers = 1
                     and d.directors = 1 then d.department_root
                when s.inferred_level = 'Manager' and d.managers_without_team = 1
                  then g.team_without_manager
                when s.inferred_level = 'Team Lead / Supervisor' and d.leads_without_team = 1
                  then g.team_without_lead
                when s.inferred_rank <= 2 then g.only_team
           end as settled_team
    from seen s
    join departments d using (company_id, inferred_department)
    left join gaps g using (company_id, inferred_department)
)
select company_id, employee_id, location, title_text, inferred_level,
       inferred_department, executive_portfolio, inferred_rank,
       settled_team as team_path,
       -- the path one level up: drop the last segment
       rtrim(rtrim(settled_team, replace(settled_team, '/', '')), '/') as parent_team,
       settled_team is not null and seen_team is not settled_team as team_inferred,
       -- an IC in the executive office works for the head of their department
       case when office_ic then 8 else reports_to_from end as reports_to_from,
       case when office_ic then 8 else reports_to_upto end as reports_to_upto
from placed;

-- The shortlist. A candidate holds a rank the person can report to and sits on
-- the person's team path. People elsewhere in the same department are kept too,
-- because one of them may be the real manager with a wrong or missing team.
create view employee_manager_candidates as
with features as materialized (select * from employee_reporting_features),
-- only leads, managers and people without a title can be on a shortlist
seniors as materialized (
    select * from features where inferred_rank >= 3 or inferred_rank is null
)
select r.company_id, r.employee_id, c.employee_id as candidate_id,
       r.inferred_level as report_level, c.inferred_level as candidate_level,
       r.reports_to_from, c.inferred_rank as candidate_rank,
       r.team_path as report_team, c.team_path as candidate_team,
       case when c.team_path = r.team_path then 'same_team'
            when c.team_path = r.parent_team and r.inferred_rank >= 4 then 'parent_team'
            when c.inferred_level = 'CEO' then 'parent_team'
            else 'same_department' end as team_relation,
       case when r.location <> '' and r.location = c.location then 1 else 0 end
         as same_location
from features r
join seniors c on c.company_id = r.company_id
where r.employee_id <> c.employee_id and r.inferred_level <> 'CEO'
  and (c.inferred_rank between r.reports_to_from and r.reports_to_upto
       or c.inferred_rank is null)
  and (
      c.team_path = r.team_path
      -- staff stay on their own team; managers also look one team up
      or (c.team_path = r.parent_team and r.inferred_rank >= 4)
      or c.inferred_level = 'CEO'
      -- Elsewhere in the department: anyone above a manager, or above staff
      -- when one of the two has no settled team.
      or (c.inferred_rank is not null
          and (r.inferred_rank >= 4 or r.team_path is null or c.team_path is null)
          and c.inferred_department = r.inferred_department
          and r.inferred_department <> 'Unclassified')
      -- an executive nobody can place could own any VP
      or (c.team_path is null and c.inferred_department = 'Executive'
          and r.inferred_level = 'VP / Head')
  );

-- Every way a pair can be labelled, with the score it earns. Rules at or above
-- score_threshold can be accepted. Rival rules sit just below it: they mark
-- someone who could be the real manager and hold the line back.
create view reporting_rules as
with rules(rule, score, rule_group, description) as (values
    ('exec_to_ceo',            0.99, 'executive', 'Executive reports to the CEO'),
    ('vp_to_matching_exec',    0.99, 'executive', 'VP/Head reports to the executive who owns their portfolio'),
    ('vp_to_ceo_no_exec',      0.99, 'executive', 'VP/Head reports to the CEO because no executive owns their portfolio'),
    ('office_to_vp',           0.99, 'executive', 'IC in the executive office reports to the VP/Head of their department'),
    ('director_to_vp',         0.99, 'ladder',    'Director reports to the VP/Head of the same department'),
    ('manager_to_director',    0.99, 'ladder',    'Manager reports to the Director on the parent team'),
    ('manager_to_vp',          0.99, 'ladder',    'Manager reports to the VP/Head on the parent team'),
    ('next_level_up',          0.99, 'ladder',    'Management role reports to the next level up on the same or parent team'),
    ('lead_to_manager',        0.99, 'team',      'Team Lead reports to the Manager of the same team'),
    ('senior_to_manager',      0.99, 'team',      'Senior, Staff or Principal IC reports to the Manager of the same team'),
    ('junior_to_lead',         0.99, 'team',      'Junior or intermediate IC reports to the Team Lead of the same team'),
    ('junior_to_manager',      0.99, 'team',      'Junior or intermediate IC reports to the Manager of the same team; the team has no Team Lead'),
    ('untitled_to_manager',    0.99, 'team',      'No job title, but the team has one Manager and no Team Lead'),
    ('closer_level_elsewhere', 0.96, 'rival',     'someone at a closer level in this department is not on this team path and could be the manager'),
    ('untitled_colleague',     0.96, 'rival',     'someone on this team path has no job title and could be the manager'),
    ('same_team_only',         0.90, 'weak',      'same team, but someone closer is expected'),
    ('parent_team_only',       0.85, 'weak',      'higher up the team path, but someone closer is expected'),
    ('same_department_only',   0.67, 'weak',      'same department, team not matched')
)
select * from rules;

-- Label every pair. The nearest manager on the person's own path gets a strong
-- rule named after the two levels; everyone else gets a rival or a weak rule.
create view employee_manager_scores as
with pairs as materialized (
    select m.*,
           -- the lowest rank found on this person's own team path
           min(case when team_relation <> 'same_department' then candidate_rank end)
               over (partition by company_id, employee_id) as nearest_rank
    from employee_manager_candidates m
),
matched as materialized (
    select company_id, employee_id, candidate_id, candidate_rank, candidate_team, same_location,
       case
         when team_relation <> 'same_department' and candidate_rank = nearest_rank then
           case
             when report_level = 'C-Suite' then 'exec_to_ceo'
             when report_level = 'VP / Head' and candidate_level = 'C-Suite'
               then 'vp_to_matching_exec'
             when report_level = 'VP / Head' then 'vp_to_ceo_no_exec'
             when candidate_level = 'VP / Head' then
               case report_level when 'Manager' then 'manager_to_vp'
                                 when 'Director' then 'director_to_vp'
                                 when 'Senior Director' then 'director_to_vp'
                                 when 'Senior Manager' then 'next_level_up'
                                 else 'office_to_vp' end
             when report_level = 'Manager' and candidate_level = 'Director'
               then 'manager_to_director'
             when candidate_rank >= 5 then 'next_level_up'
             when report_level = 'Team Lead / Supervisor' then 'lead_to_manager'
             when report_level in ('Senior IC','Principal / Staff IC') then 'senior_to_manager'
             -- without a title the person could be on either track, so a lead settles nothing
             when report_level = 'Unknown' then
               case when candidate_level = 'Manager' then 'untitled_to_manager'
                    else 'same_team_only' end
             when candidate_level = 'Manager' then 'junior_to_manager'
             else 'junior_to_lead' end
         -- From here on: people who could sit between this person and the nearest manager.
         when candidate_rank is null then
           case when nearest_rank is null or nearest_rank > reports_to_from
                then 'untitled_colleague' else 'same_team_only' end
         when team_relation = 'same_department' then
           case when candidate_rank < nearest_rank then 'closer_level_elsewhere'
                else 'same_department_only' end
         when team_relation = 'same_team' then 'same_team_only'
         else 'parent_team_only' end as rule
    from pairs
)
select matched.company_id, matched.employee_id, matched.candidate_id,
       matched.candidate_rank, matched.candidate_team, matched.rule,
       rules.score + case when matched.same_location = 1 then 0.002 else 0 end
         as evidence_score
from matched left join reporting_rules rules using (rule);

-- Best and second-best per employee; the gap between them is the margin.
create view employee_top_manager_candidates as
with ranked as (
    select company_id, employee_id, candidate_id, rule, evidence_score,
           row_number() over (
               partition by company_id, employee_id
               order by evidence_score desc, candidate_rank asc, candidate_id
           ) as position
    from employee_manager_scores
)
select e.company_id, e.employee_id,
       max(case when r.position = 1 then r.candidate_id end) as best_candidate_id,
       max(case when r.position = 1 then r.rule end) as best_rule,
       max(case when r.position = 1 then r.evidence_score end) as best_score,
       max(case when r.position = 2 then r.rule end) as second_rule,
       max(case when r.position = 2 then r.evidence_score end) as second_score
from employees e
left join ranked r on r.company_id = e.company_id and r.employee_id = e.employee_id
     and r.position <= 2
group by e.company_id, e.employee_id;

-- Accept the best candidate only when the score clears the threshold and the
-- runner-up is clearly behind. Everyone else stays unresolved, with a reason.
create view employee_reporting_decisions as
with scored as (
    select e.company_id, e.employee_id, f.inferred_level,
           t.best_candidate_id as candidate_id, t.best_rule as rule, t.second_rule,
           round(coalesce(t.best_score, 0.0), 4) as confidence,
           round(max(0.0, coalesce(t.best_score, 0.0) -
                    coalesce(t.second_score, 0.0)), 4) as margin
    from employees e
    join employee_role_classification f using(company_id, employee_id)
    join employee_top_manager_candidates t using(company_id, employee_id)
)
select company_id, employee_id,
       case when inferred_level <> 'CEO' and confidence >= s.score_threshold
                  and margin >= s.margin_threshold then candidate_id end as accepted_manager_id,
       candidate_id as best_candidate_id,
       min(1.0, confidence) as confidence, margin,
       case when inferred_level = 'CEO' then 'company_root'
            when confidence >= s.score_threshold and margin >= s.margin_threshold then 'accepted'
            else 'unresolved' end as decision,
       scored.rule,
       case when inferred_level = 'CEO' then 'CEO is the company root'
            when candidate_id is null then 'Nobody in a management role shares this team or department'
            when confidence >= s.score_threshold and margin >= s.margin_threshold then r.description
            when confidence < s.score_threshold then 'Only weak evidence: ' || r.description
            when runner_up.rule_group = 'rival' then 'Held back: ' || runner_up.description
            else 'Two candidates fit equally well: '
                 || lower(substr(r.description, 1, 1)) || substr(r.description, 2)
            end as reason
from scored
cross join reporting_thresholds s
left join reporting_rules r on r.rule = scored.rule
left join reporting_rules runner_up on runner_up.rule = scored.second_rule;

create view company_reporting_summary as
select p.company_id,
       sum(p.decision = 'accepted') as resolved_count,
       sum(p.decision = 'unresolved') as unresolved_count,
       round(1.0 * sum(p.decision = 'accepted') /
             max(sum(p.decision <> 'company_root'), 1), 4) as coverage,
       round(coalesce(avg(case when p.decision = 'accepted'
             then p.confidence end), 0), 4) as average_confidence
from employee_reporting_decisions p group by p.company_id;

create view dataset_reporting_summary as
select count(distinct company_id) as company_count,
       count(*) as employee_count,
       sum(decision = 'accepted') as accepted_count,
       sum(decision = 'unresolved') as unresolved_count,
       round(coalesce(avg(case when decision = 'accepted'
             then confidence end), 0), 4) as average_resolved_confidence
from employee_reporting_decisions;

-- One row per person with the raw record, what was inferred, who was chosen
-- and why. This is the view to query when a reporting line looks wrong.
create view employee_reporting_audit as
select e.company_id, e.employee_id, e.full_name, e.job_title,
       e.raw_department, e.raw_team, e.location,
       f.inferred_department, f.inferred_level, f.team_path, f.team_inferred,
       p.accepted_manager_id, manager.full_name as inferred_manager,
       p.best_candidate_id, candidate.full_name as leading_candidate,
       p.confidence, p.margin, p.decision, p.rule, p.reason,
       s.score_threshold, s.margin_threshold
from employee_reporting_decisions p
join employees e using(company_id, employee_id)
join employee_reporting_features f using(company_id, employee_id)
cross join reporting_thresholds s
left join employees manager on manager.company_id = p.company_id
      and manager.employee_id = p.accepted_manager_id
left join employees candidate on candidate.company_id = p.company_id
      and candidate.employee_id = p.best_candidate_id;
