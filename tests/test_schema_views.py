"""SQL view behaviour on hand-built rows."""

from pathlib import Path
import re
import sqlite3
import unittest
import xml.etree.ElementTree as ET

from scripts.build_erd import build_diagram, view_dependencies
from scripts.build_company_query import company_query

ROOT = Path(__file__).resolve().parents[1]
ENGINEERING = 'Company / Technology / Engineering'


class SchemaViewTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.addCleanup(self.db.close)
        self.db.executescript((ROOT / 'schema.sql').read_text())
        self.db.execute("insert into companies values ('example', 'Example', 'Software', 'London')")

    def add(self, name, title, team, department='Engineering'):
        self.db.execute('insert into employees values (?,?,?,?,?,?,?,?)',
                        ('example', name, name, title, department, team, 'London', ''))

    def prediction(self, employee_id):
        return self.db.execute('select accepted_manager_id, decision from employee_reporting_decisions where employee_id=?',
                               (employee_id,)).fetchone()

    def decision(self, employee_id):
        return self.db.execute('select accepted_manager_id, rule, reason from employee_reporting_decisions where employee_id=?',
                               (employee_id,)).fetchone()

    def team(self, employee_id):
        return self.db.execute('select team_path, team_inferred from employee_reporting_features where employee_id=?',
                               (employee_id,)).fetchone()

    def test_shortlist_keeps_people_without_manager_candidates(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('unassigned', 'Senior Engineer', '')
        shortlist = self.db.execute('select * from employee_top_manager_candidates order by employee_id').fetchall()
        self.assertEqual(shortlist, [('example', 'ceo', None, None, None, None, None),
                                     ('example', 'unassigned', None, None, None, None, None)])
        self.assertEqual(self.prediction('unassigned'), (None, 'unresolved'))
        self.assertEqual(self.prediction('ceo'), (None, 'company_root'))

    def test_every_rule_named_in_the_scores_view_is_in_the_rule_table(self):
        sql = (ROOT / 'schema.sql').read_text()
        scores = sql[sql.index('create view employee_manager_scores'):sql.index('create view employee_top_manager_candidates')]
        named = set(re.findall(r"(?:then|else) '([a-z_]+)'", scores))
        rules = {row[0] for row in self.db.execute('select rule from reporting_rules')}
        self.assertEqual(named, rules)
        strong = {row[0] for row in self.db.execute(
            'select rule from reporting_rules, reporting_thresholds where score >= score_threshold')}
        self.assertEqual(len(strong), 13)
        # A rival has to sit within the margin of every strong rule, or it holds nothing back.
        gap = self.db.execute("""
            select min(strong.score) - min(rival.score) < margin_threshold
            from reporting_rules strong, reporting_rules rival, reporting_thresholds
            where strong.score >= score_threshold and rival.rule_group = 'rival'
        """).fetchone()[0]
        self.assertEqual(gap, 1)

    def test_decisions_carry_the_rule_and_a_readable_reason(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('cto', 'CTO', 'Company / Technology')
        self.add('manager', 'Engineering Manager', ENGINEERING + ' / Platform')
        self.add('senior', 'Senior Engineer', ENGINEERING + ' / Platform')
        self.add('junior', 'Junior Engineer', ENGINEERING + ' / Platform')
        self.add('alone', 'Senior Engineer', ENGINEERING + ' / Mobile')
        self.assertEqual(self.decision('cto'), ('ceo', 'exec_to_ceo', 'Executive reports to the CEO'))
        self.assertEqual(self.decision('senior')[:2], ('manager', 'senior_to_manager'))
        self.assertEqual(self.decision('junior')[:2], ('manager', 'junior_to_manager'))
        self.assertEqual(self.decision('alone'),
                         (None, None, 'Nobody in a management role shares this team or department'))
        self.assertEqual(self.decision('ceo'), (None, None, 'CEO is the company root'))
        audit = self.db.execute("select rule, reason from employee_reporting_audit where employee_id = 'senior'").fetchone()
        self.assertEqual(audit[0], 'senior_to_manager')
        # A lead with no team takes the one team that lacks a lead.
        self.add('lead', 'Platform Engineering Team Lead', '')
        self.assertEqual(self.decision('junior')[:2], ('lead', 'junior_to_lead'))
        # With two such teams the lead could belong to either, so the junior is held back.
        self.add('mobile_two', 'Senior Engineer', ENGINEERING + ' / Mobile')
        accepted, rule, reason = self.decision('junior')
        self.assertEqual((accepted, rule), (None, 'junior_to_manager'))
        self.assertTrue(reason.startswith('Held back: '))
        self.assertEqual(self.decision('senior')[:2], ('manager', 'senior_to_manager'))

    def test_a_vp_never_attaches_to_an_executive_with_a_different_portfolio(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('cfo', 'Chief Financial Officer', 'Company / Technology')
        self.add('vp', 'VP of Engineering', ENGINEERING)
        # The CFO sits on the parent team path, but owns Finance, so the VP goes to the CEO.
        self.assertEqual(self.prediction('vp'), ('ceo', 'accepted'))
        self.add('unknown', '', 'Company / Technology')
        self.assertEqual(self.prediction('vp'), (None, 'unresolved'))

    def test_company_query_is_built_from_current_view_rules(self):
        self.assertEqual((ROOT / 'sql/company_predictions.sql').read_text(), company_query())

    def test_analyst_keeps_its_specific_function(self):
        for index, (title, expected) in enumerate([
            ('Product Analyst', 'Product'), ('Operations Analyst', 'Operations'),
            ('Financial Analyst', 'Finance'), ('FP&A Analyst', 'Finance'),
            ('Data Analyst', 'Data & Analytics'), ('Network Engineer', 'IT'),
            ('Cust Success Mgr', 'Customer Success'), ('GRC Analyst', 'Security'),
            ('Contracts Specialist', 'Legal'), ('Core Services Team Lead', 'Engineering'),
        ]):
            self.add(f'person_{index}', title, '', department='')
            actual = self.db.execute('select inferred_department from employee_reporting_features where employee_id=?',
                                     (f'person_{index}',)).fetchone()[0]
            self.assertEqual(actual, expected, title)

    def test_manager_in_the_title_does_not_always_mean_people_manager(self):
        for index, (title, expected) in enumerate([
            ('Product Manager', 'Individual Contributor'), ('Sr. Product Mgr', 'Senior IC'),
            ('Customer Success Manager - Sydney', 'Individual Contributor'),
            ('Staff Account Manager', 'Principal / Staff IC'),
            ('Group Product Manager', 'Manager'), ('Enterprise Customer Success Mgr', 'Manager'),
            ('Senior Engineering Manager', 'Senior Manager'), ('Senior Manager', 'Senior Manager'),
            ('', 'Unknown'),
        ]):
            self.add(f'person_{index}', title, '')
            actual = self.db.execute('select inferred_level from employee_role_classification where employee_id=?',
                                     (f'person_{index}',)).fetchone()[0]
            self.assertEqual(actual, expected, title)

    def test_a_team_from_another_department_is_ignored(self):
        self.add('sales_manager', 'Enterprise Sales Manager', 'Company / Revenue / Sales / Enterprise')
        self.add('engineer', 'Senior Backend Engineer', 'Company / Revenue / Sales / Enterprise')
        self.assertEqual(self.team('engineer'), (None, 0))
        self.assertEqual(self.prediction('engineer'), (None, 'unresolved'))
        # Engineering has one team, so that is where the engineer belongs.
        self.add('manager', 'Engineering Manager', ENGINEERING + ' / Platform')
        self.assertEqual(self.team('engineer'), ('company/technology/engineering/platform', 1))
        self.assertEqual(self.prediction('engineer'), ('manager', 'accepted'))

    def test_missing_team_is_not_guessed_between_two_teams(self):
        self.add('first_manager', 'Software Development Manager', ENGINEERING + ' / Platform')
        self.add('second_manager', 'Software Development Manager', ENGINEERING + ' / Applications')
        self.add('missing_team', 'Senior Backend Engineer', '')
        self.add('known_team', 'Senior Frontend Engineer', ENGINEERING + ' / Platform')
        self.assertEqual(self.prediction('missing_team'), (None, 'unresolved'))
        self.assertEqual(self.prediction('known_team'), ('first_manager', 'accepted'))

    def test_filled_in_team_still_respects_the_lead_layer(self):
        team = 'Company / Technology / Data & Analytics / Data Platform'
        self.add('manager', 'Data Engineering Manager', team)
        self.add('lead', 'Data & Analytics Team Lead', team)
        self.add('junior', 'Junior Data Engineer', '')
        self.add('senior', 'Senior Data Engineer', '')
        self.assertEqual(self.prediction('junior'), ('lead', 'accepted'))
        self.assertEqual(self.prediction('senior'), ('manager', 'accepted'))
        self.db.execute("update employees set raw_team='' where employee_id='lead'")
        self.assertEqual(self.prediction('junior'), (None, 'unresolved'))
        self.assertEqual(self.prediction('senior'), ('manager', 'accepted'))

    def test_a_manager_without_a_team_takes_the_one_team_without_a_manager(self):
        self.add('platform_manager', 'Engineering Manager', ENGINEERING + ' / Platform')
        self.add('platform_senior', 'Senior Engineer', ENGINEERING + ' / Platform')
        self.add('mobile_senior', 'Senior Engineer', ENGINEERING + ' / Mobile')
        self.add('mobile_engineer', 'Software Engineer', ENGINEERING + ' / Mobile')
        self.add('teamless', 'Software Development Manager', 'N/A')
        self.assertEqual(self.team('teamless'), ('company/technology/engineering/mobile', 1))
        self.assertEqual(self.prediction('mobile_senior'), ('teamless', 'accepted'))
        self.assertEqual(self.prediction('mobile_engineer'), ('teamless', 'accepted'))
        self.assertEqual(self.prediction('platform_senior'), ('platform_manager', 'accepted'))
        # Two managers without a team: there is no way to tell which one owns Mobile.
        self.add('also_teamless', 'Engineering Manager', '')
        self.assertEqual(self.team('teamless'), (None, 0))
        self.assertEqual(self.prediction('mobile_senior'), (None, 'unresolved'))

    def test_two_managers_on_one_team_stay_open(self):
        team = 'Company / Revenue / Marketing / Growth'
        self.add('first', 'Growth Marketing Manager', team)
        self.add('second', 'Growth Marketing Manager', team)
        self.add('report', 'Senior Growth Marketer', team)
        accepted, rule, reason = self.decision('report')
        self.assertEqual((accepted, rule), (None, 'senior_to_manager'))
        self.assertTrue(reason.startswith('Two candidates fit equally well: '))

    def test_a_person_without_a_title_is_placed_only_under_a_lone_manager(self):
        team = ENGINEERING + ' / Quality'
        self.add('manager', 'QA Manager', team)
        self.add('blank', '', team)
        self.assertEqual(self.decision('blank')[:2], ('manager', 'untitled_to_manager'))
        # The untitled person could be a lead, so a junior on the team is held back.
        self.add('junior', 'Junior QA Engineer', team)
        self.assertEqual(self.prediction('junior'), (None, 'unresolved'))
        self.assertTrue(self.decision('junior')[2].startswith('Held back: '))
        # With a lead on the team, a missing title could mean either track.
        self.add('lead', 'QA Team Lead', team)
        self.assertEqual(self.prediction('blank'), (None, 'unresolved'))
        self.assertEqual(self.prediction('junior'), ('lead', 'accepted'))

    def test_executive_office_ic_reports_to_the_head_of_the_department(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('vp', 'VP of Sales', 'Company / Revenue / Sales', department='Sales')
        self.add('director', 'Director of Sales', 'Company / Revenue / Sales', department='Sales')
        self.add('principal', 'Principal Sales Strategist', 'Company / Revenue', department='Executive')
        self.assertEqual(self.decision('principal')[:2], ('vp', 'office_to_vp'))
        self.assertEqual(self.decision('director')[:2], ('vp', 'director_to_vp'))

    def test_untitled_person_on_the_company_team_is_the_ceo(self):
        self.add('boss', '', 'Company', department='Executive')
        self.add('cto', 'CTO', '', department='Executive')
        self.assertEqual(self.prediction('boss'), (None, 'company_root'))
        self.assertEqual(self.decision('cto')[:2], ('boss', 'exec_to_ceo'))

    def test_a_level_is_skipped_only_when_nobody_holds_it(self):
        self.add('vp', 'VP of Engineering', ENGINEERING)
        self.add('manager', 'Engineering Manager', ENGINEERING + ' / Platform')
        self.assertEqual(self.decision('manager')[:2], ('vp', 'manager_to_vp'))
        # The only director of the department sits at its top, whatever the team column says.
        self.add('director', 'Director of Engineering', '')
        self.assertEqual(self.decision('manager')[:2], ('director', 'manager_to_director'))
        self.assertEqual(self.decision('director')[:2], ('vp', 'director_to_vp'))
        # Two directors without a team: either could own Platform.
        self.add('other_director', 'Director of Quality', '')
        self.assertEqual(self.prediction('manager'), (None, 'unresolved'))
        self.assertTrue(self.decision('manager')[2].startswith('Held back: '))

    def test_executive_title_recovers_missing_team_without_guessing_between_peers(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('cto', 'CTO', '')
        self.add('vp', 'VP Engineering', ENGINEERING)
        self.assertEqual(self.prediction('vp'), ('cto', 'accepted'))
        self.add('second_cto', 'Chief Technology Officer', '')
        self.assertEqual(self.prediction('vp'), (None, 'unresolved'))

    def test_a_missing_executive_title_blocks_a_ceo_shortcut(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('vp', 'VP Engineering', ENGINEERING)
        self.assertEqual(self.prediction('vp'), ('ceo', 'accepted'))
        self.add('unknown', '', 'Company / Technology', department='Executive')
        self.assertEqual(self.prediction('vp'), (None, 'unresolved'))
        self.db.execute("update employees set raw_team='' where employee_id='unknown'")
        self.assertEqual(self.prediction('vp'), (None, 'unresolved'))

    def test_two_known_teams_are_never_bridged(self):
        self.add('manager', 'QA Manager', ENGINEERING + ' / First')
        self.add('report', 'Senior QA Engineer', ENGINEERING + ' / Second')
        self.assertEqual(self.prediction('report'), (None, 'unresolved'))

    def test_source_keys_and_cross_company_rows_are_not_matching_features(self):
        self.db.execute("insert into companies values ('other', 'Other', 'Software', 'London')")
        self.db.execute("insert into employees values ('other','manager','Manager','QA Manager','Engineering','Company / Engineering / Quality','London','')")
        self.add('report', 'Senior QA Engineer', '')
        self.assertEqual(self.prediction('report'), (None, 'unresolved'))

    def relation(self, employee_id):
        return self.db.execute('select candidate_id, team_relation from employee_manager_candidates where employee_id=?',
                               (employee_id,)).fetchone()

    def test_team_underscores_do_not_match_another_team(self):
        self.add('director', 'Director of Engineering', 'Company / Engineering / Sales_Ops')
        self.add('manager', 'Engineering Manager', 'Company / Engineering / SalesXOps / Platform')
        self.assertEqual(self.relation('manager'), ('director', 'same_department'))
        self.assertEqual(self.prediction('manager'), (None, 'unresolved'))

    def test_team_percent_does_not_match_another_team(self):
        self.add('director', 'Director of Engineering', 'Company / Engineering / 100%')
        self.add('manager', 'Engineering Manager', 'Company / Engineering / 1000 / Platform')
        self.assertEqual(self.relation('manager'), ('director', 'same_department'))
        self.assertEqual(self.prediction('manager'), (None, 'unresolved'))

    def test_literal_parent_team_still_matches(self):
        self.add('director', 'Director of Engineering', 'Company / Engineering / 100%_Ops')
        self.add('manager', 'Engineering Manager', 'Company / Engineering / 100%_Ops / Platform')
        self.assertEqual(self.relation('manager'), ('director', 'parent_team'))
        self.assertEqual(self.decision('manager')[:2], ('director', 'manager_to_director'))

    def test_missing_team_labels_are_not_matching_evidence(self):
        for index, team in enumerate(['', '-', 'n/a', 'unknown']):
            self.add(f'manager_{index}', 'Engineering Manager', team)
            self.add(f'report_{index}', 'Senior Engineer', team)
        relations = {row[0] for row in self.db.execute('select team_relation from employee_manager_candidates')}
        self.assertEqual(relations, {'same_department'})
        accepted = self.db.execute("select count(*) from employee_reporting_decisions where decision = 'accepted'").fetchone()[0]
        self.assertEqual(accepted, 0)

    def test_missing_team_is_filled_only_while_one_team_exists(self):
        self.add('qa_manager', 'QA Manager', ENGINEERING + ' / Quality')
        self.add('qa_report', 'Junior QA Engineer', '')
        self.add('security_manager', 'Security Engineering Manager', 'Company / Technology / Security / Security Engineering')
        self.add('security_report', 'Security Engineer', 'n/a')

        query = (ROOT / 'sql/company_predictions.sql').read_text()
        def decision(sql):
            return self.db.execute(sql, {'company_id': 'example'}).fetchall()

        self.assertEqual(self.prediction('qa_report'), ('qa_manager', 'accepted'))
        self.assertEqual(self.prediction('security_report'), ('security_manager', 'accepted'))
        self.assertEqual(sorted(decision(query)), sorted(self.db.execute('select * from employee_reporting_decisions').fetchall()))

        self.add('second_qa_manager', 'QA Engineering Manager', ENGINEERING + ' / Reliability')
        self.assertEqual(self.prediction('qa_report'), (None, 'unresolved'))
        self.assertEqual(self.prediction('security_report'), ('security_manager', 'accepted'))
        self.assertEqual(sorted(decision(query)), sorted(self.db.execute('select * from employee_reporting_decisions').fetchall()))

    def test_company_query_and_public_views_agree(self):
        self.add('ceo', 'CEO', 'Company')
        self.add('manager', 'Engineering Manager', 'Company / Engineering / 100%_Ops')
        self.add('report', 'Senior Engineer', 'Company / Engineering / 100%_Ops')
        self.add('other', 'Senior Engineer', 'Company / Engineering / 1000')
        scoped = self.db.execute((ROOT / 'sql/company_predictions.sql').read_text(), {'company_id': 'example'}).fetchall()
        public = self.db.execute('select * from employee_reporting_decisions').fetchall()
        self.assertEqual(sorted(scoped, key=repr), sorted(public, key=repr))
        self.assertEqual(self.prediction('report'), ('manager', 'accepted'))

    def test_queries_leave_the_observed_rows_unchanged(self):
        self.add('manager', '  Engineering Mgr. ', ' Company / Engineering / 100%_Ops ')
        self.add('report', 'Senior Engineer', 'Company / Engineering / 100%_Ops')
        before = self.db.execute('select * from employees order by employee_id').fetchall()
        self.db.execute('select * from employee_reporting_audit').fetchall()
        self.assertEqual(before, self.db.execute('select * from employees order by employee_id').fetchall())
        self.assertEqual(self.prediction('report'), ('manager', 'accepted'))

    def test_diagram_includes_every_object_column_and_direct_input(self):
        import json
        build_diagram()
        metadata = json.loads((ROOT / 'public/database-schema.json').read_text())
        objects = {row[0] for row in self.db.execute("select name from sqlite_master where type in ('table','view')")}
        svg = ET.parse(ROOT / 'public/database-erd.svg').getroot()
        ns = {'s': 'http://www.w3.org/2000/svg'}
        entities = {group.attrib['data-name']: group for group in svg.findall('s:g', ns)
                    if group.attrib.get('class') == 'entity'}
        self.assertEqual(objects, set(entities))
        self.assertEqual(len(metadata['tables']), 2)
        self.assertEqual(len(metadata['views']), 13)
        for name, group in entities.items():
            fields = [node.text for node in group.findall('s:text', ns) if node.attrib.get('class') == 'column']
            expected = [row[1] for row in self.db.execute(f'pragma table_info("{name}")')]
            self.assertEqual(fields, expected, name)
        dependencies = view_dependencies(metadata['tables'], metadata['views'])
        actual = {(edge.attrib['data-parent'], edge.attrib['data-child']) for edge in svg.findall('s:path', ns) if edge.attrib.get('data-kind') == 'view-input'}
        self.assertEqual(actual, {(parent, child) for child, parents in dependencies.items() for parent in parents})
        self.assertIn(('employee_top_manager_candidates', 'employee_reporting_decisions'), actual)
        self.assertIn(('employee_reporting_decisions', 'employee_reporting_audit'), actual)
        self.assertIn(('reporting_ladder', 'employee_reporting_features'), actual)
        self.assertNotIn(('scored', 'employee_reporting_decisions'), actual)
