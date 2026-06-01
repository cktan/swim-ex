#!/usr/bin/env python3
import sys
import os
import re
import argparse
from datetime import datetime

# Path relative to project root
# Script is in .gemini/skills/issue-tracker/scripts/issue.py
DEFAULT_BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))

ISSUE_FILES = {}
HISTORY_FILE = ""
COUNTER_FILE = ""

def update_paths(base_dir):
    global ISSUE_FILES, HISTORY_FILE, COUNTER_FILE
    base_dir = os.path.abspath(base_dir)
    ISSUE_FILES = {
        'P0': os.path.join(base_dir, 'P0.md'),
        'P1': os.path.join(base_dir, 'P1.md'),
        'P2': os.path.join(base_dir, 'P2.md'),
        'P3': os.path.join(base_dir, 'P3.md')
    }
    HISTORY_FILE = os.path.join(base_dir, 'HISTORY.md')
    COUNTER_FILE = os.path.join(base_dir, 'ISSUE_COUNTER')

# Initialize with default
update_paths(DEFAULT_BASE_DIR)

class Issue:
    def __init__(self, issue_id, title, problem, proposed_fix=None, decision=None, solution=None, priority=None):
        self.issue_id = issue_id
        self.title = title
        self.problem = problem
        self.proposed_fix = proposed_fix
        self.decision = decision
        self.solution = solution
        self.priority = priority

def get_next_id():
    ids = []
    # Scan P0-P3 and HISTORY
    files_to_scan = list(ISSUE_FILES.values()) + [HISTORY_FILE]
    
    pattern = re.compile(r'^## ISSUE (\d+) ::', re.MULTILINE)
    
    for file_path in files_to_scan:
        if os.path.exists(file_path):
            with open(file_path, 'r') as f:
                content = f.read()
                found = pattern.findall(content)
                ids.extend([int(i) for i in found])
    
    if not ids:
        return 1
    return max(ids) + 1

def parse_issues(file_path, priority=None):
    if not os.path.exists(file_path):
        return []
    with open(file_path, 'r') as f:
        content = f.read()

    # Split by ## ISSUE at the start of a line
    sections = re.split(r'^## ISSUE (?=\d+ ::)', content, flags=re.MULTILINE)
    issues = []
    for section in sections:
        section = section.strip()
        if not section: continue
        # Match "ID :: Title" at the start of the section
        match = re.match(r'(\d+) :: (.*)', section)
        if match:
            issue_id = int(match.group(1))
            title = match.group(2).split('\n')[0].strip()

            # Helper to extract fields starting at the beginning of a line
            def get_field(name, text):
                # We want to match **name:** at the start of a line
                # And stop before the next **KnownField:** at the start of a line
                known_fields = ['Problem', 'Proposed fix', 'Decision', 'Solution']
                lookahead_parts = [rf'^\*\*{f}:\*\*' for f in known_fields if f != name]
                lookahead = '|'.join(lookahead_parts)
                
                # Start searching for **name:** at start of line
                start_pattern = rf'^\*\*{name}:\*\*'
                start_match = re.search(start_pattern, text, re.MULTILINE)
                if not start_match:
                    return None
                
                start_pos = start_match.end()
                remaining_text = text[start_pos:]
                
                # Find the end of this field
                end_match = re.search(rf'\n(?:{lookahead}|---\s*$)', remaining_text, re.MULTILINE)
                if end_match:
                    return remaining_text[:end_match.start()].strip()
                else:
                    return remaining_text.strip()

            problem = get_field('Problem', section) or ""
            proposed_fix = get_field('Proposed fix', section)
            decision = get_field('Decision', section)
            solution = get_field('Solution', section)

            issues.append(Issue(issue_id, title, problem, proposed_fix, decision, solution, priority))
    return issues


def get_issue(issue_id):
    for p, f in ISSUE_FILES.items():
        issues = parse_issues(f, priority=p)
        for issue in issues:
            if issue.issue_id == issue_id:
                return issue
    
    history_issues = parse_issues(HISTORY_FILE, priority='HISTORY')
    for issue in history_issues:
        if issue.issue_id == issue_id:
            return issue
    return None

def write_p_file(priority, issues):
    file_path = ISSUE_FILES[priority]
    header = f"# swim-ex — {priority}"
    if priority == 'P0': header += " (Critical / Blocking)"
    elif priority == 'P1': header += " (High Priority)"
    elif priority == 'P2': header += " (Medium Priority)"
    elif priority == 'P3': header += " (Low Priority)"
    
    content = header + "\n\n"
    if not issues:
        if priority == 'P0':
            content += "No open critical issues.\n"
        else:
            content += "No open issues.\n"
    else:
        content += "---\n\n"
        for issue in issues:
            content += f"## ISSUE {issue.issue_id} :: {issue.title}\n\n"
            content += f"**Problem:** {issue.problem}\n\n"
            content += f"**Proposed fix:** {issue.proposed_fix}\n\n"
            content += "---\n\n"
    
    with open(file_path, 'w') as f:
        f.write(content)

def append_to_history(issue):
    with open(HISTORY_FILE, 'r') as f:
        content = f.read()
    
    new_entry = f"## ISSUE {issue.issue_id} :: {issue.title}\n"
    new_entry += f"**Decision:** {issue.decision}\n\n"
    new_entry += f"**Problem:** {issue.problem}\n\n"
    new_entry += f"**Solution:** {issue.solution}\n\n"
    new_entry += "---\n\n"
    
    parts = content.split('---\n', 1)
    if len(parts) > 1:
        updated_content = parts[0] + "---\n\n" + new_entry + parts[1]
    else:
        updated_content = content + "\n---\n\n" + new_entry
    
    with open(HISTORY_FILE, 'w') as f:
        f.write(updated_content)

def open_issue(priority, title, problem, proposed_fix):
    if priority not in ISSUE_FILES:
        print(f"Invalid priority: {priority}")
        return
    
    issue_id = get_next_id()
    
    new_issue = Issue(issue_id, title, problem, proposed_fix=proposed_fix, priority=priority)
    issues = parse_issues(ISSUE_FILES[priority], priority=priority)
    issues.insert(0, new_issue)
    write_p_file(priority, issues)
    print(f"Opened Issue {issue_id} in {priority}")

def close_issue(issue_id, decision, solution):
    target_issue = None
    target_priority = None
    
    for p, f in ISSUE_FILES.items():
        issues = parse_issues(f, priority=p)
        for i, issue in enumerate(issues):
            if issue.issue_id == issue_id:
                target_issue = issue
                target_priority = p
                issues.pop(i)
                write_p_file(p, issues)
                break
        if target_issue:
            break
    
    if not target_issue:
        print(f"Issue {issue_id} not found in open issues.")
        return
    
    target_issue.decision = f"{decision} — {datetime.now().strftime('%Y-%m-%d')}"
    target_issue.solution = solution
    append_to_history(target_issue)
    print(f"Closed Issue {issue_id}")

def move_issue(issue_id, new_priority):
    if new_priority not in ISSUE_FILES:
        print(f"Invalid priority: {new_priority}")
        return
    
    target_issue = None
    old_priority = None
    
    for p, f in ISSUE_FILES.items():
        issues = parse_issues(f, priority=p)
        for i, issue in enumerate(issues):
            if issue.issue_id == issue_id:
                target_issue = issue
                old_priority = p
                issues.pop(i)
                write_p_file(p, issues)
                break
        if target_issue:
            break
            
    if not target_issue:
        print(f"Issue {issue_id} not found in open issues.")
        return
    
    new_issues = parse_issues(ISSUE_FILES[new_priority], priority=new_priority)
    target_issue.priority = new_priority
    new_issues.insert(0, target_issue)
    write_p_file(new_priority, new_issues)
    print(f"Moved Issue {issue_id} from {old_priority} to {new_priority}")

def main():
    parser = argparse.ArgumentParser(description="Issue Manager")
    parser.add_argument('-D', '--project-dir', help="Project directory")
    
    subparsers = parser.add_subparsers(dest='command', help='Commands')
    
    # get
    get_parser = subparsers.add_parser('get', help='Get issue by ID')
    get_parser.add_argument('id', type=int, help='Issue ID')
    
    # open
    open_parser = subparsers.add_parser('open', help='Open a new issue')
    open_parser.add_argument('priority', choices=['P0', 'P1', 'P2', 'P3'], help='Priority')
    open_parser.add_argument('title', help='Issue title')
    open_parser.add_argument('problem', help='Problem description')
    open_parser.add_argument('proposed_fix', help='Proposed fix')
    
    # close
    close_parser = subparsers.add_parser('close', help='Close an issue')
    close_parser.add_argument('id', type=int, help='Issue ID')
    close_parser.add_argument('decision', help='Decision taken')
    close_parser.add_argument('solution', help='Solution description')
    
    # move
    move_parser = subparsers.add_parser('move', help='Move an issue to a new priority')
    move_parser.add_argument('id', type=int, help='Issue ID')
    move_parser.add_argument('priority', choices=['P0', 'P1', 'P2', 'P3'], help='New priority')
    
    args = parser.parse_args()
    
    if args.project_dir:
        update_paths(args.project_dir)
    
    if not os.path.exists(HISTORY_FILE):
        print(f"Error: HISTORY.md not found at {HISTORY_FILE}")
        print("Please ensure the project directory is correct.")
        sys.exit(1)
    
    if args.command == 'get':
        issue = get_issue(args.id)
        if issue:
            print(f"## ISSUE {issue.issue_id} :: {issue.title}\n")
            print(f"Priority: {issue.priority}\n")
            if issue.decision: print(f"**Decision:** {issue.decision}\n")
            print(f"**Problem:** {issue.problem}\n")
            if issue.proposed_fix: print(f"**Proposed fix:** {issue.proposed_fix}\n")
            if issue.solution: print(f"**Solution:** {issue.solution}\n")
        else:
            print(f"Issue {args.id} not found.")
            sys.exit(1)
    elif args.command == 'open':
        open_issue(args.priority, args.title, args.problem, args.proposed_fix)
    elif args.command == 'close':
        close_issue(args.id, args.decision, args.solution)
    elif args.command == 'move':
        move_issue(args.id, args.priority)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
