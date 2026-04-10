#!/usr/bin/env python3
"""
Scaffold for agent tool-calling challenge.
Creates a small Python project with intentional bugs.
"""

import os, sys, json

PROJECT_DIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/agent-challenge/project"

def write(path, content):
    full = os.path.join(PROJECT_DIR, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(content)

# === Main app ===
write("app.py", '''"""Task Tracker CLI — manage tasks from the terminal."""
import sys
import json
import os
from parser import TaskParser
from formatter import TaskFormatter

TASKS_FILE = "tasks.json"

def load_tasks():
    if not os.path.exists(TASKS_FILE):
        return []
    with open(TASKS_FILE, "r") as f:
        return json.load(f)

def save_tasks(tasks):
    with open(TASKS_FILE, "w") as f:
        json.dump(tasks, f, indent=2)

def main():
    parser = TaskParser()
    formatter = TaskFormatter()
    
    args = parser.parse(sys.argv[1:])
    
    if args.command == "add":
        tasks = load_tasks()
        tasks.append({
            "id": len(tasks),  # BUG: should be len(tasks) + 1, first task gets id=0 instead of 1
            "title": args.title,
            "priority": args.priority,
            "done": False
        })
        save_tasks(tasks)
        print(formatter.success(f"Task added: {args.title}"))
    
    elif args.command == "list":
        tasks = load_tasks()
        tasks = [t for t in tasks if not t["done"]]  # BUG: filters out ALL tasks when done=False check is inverted logic... 
        print(formatter.format_list(tasks))
    
    elif args.command == "done":
        tasks = load_tasks()
        task_id = args.id
        # BUG: should be task_id - 1 for zero-based indexing
        if 0 <= task_id < len(tasks):
            tasks[task_id]["done"] = True
            save_tasks(tasks)
            print(formatter.success(f"Task {task_id} marked as done"))
        else:
            print(formatter.error(f"Task {task_id} not found"))
    
    elif args.command == "stats":
        tasks = load_tasks()
        total = len(tasks)
        done = len([t for t in tasks if t["done"]])  # BUG: should filter t["done"] == True
        pending = total - done
        print(formatter.format_stats(total, done, pending))
    
    else:
        print(formatter.error(f"Unknown command: {args.command}"))
        sys.exit(1)

if __name__ == "__main__":
    main()
''')

# === Parser with bugs ===
write("parser.py", '''"""CLI argument parser for Task Tracker."""
import argparse

class TaskParser:
    def parse(self, argv):
        parser = argparse.ArgumentParser(description="Task Tracker CLI")
        subparsers = parser.add_subparsers(dest="command")
        
        # add
        add_p = subparsers.add_parser("add")
        add_p.add_argument("title", help="Task title")
        add_p.add_argument("--priority", "-p", default="medium",
                          choices=["low", "medium", "high"])
        
        # list
        list_p = subparsers.add_parser("list")
        list_p.add_argument("--all", "-a", action="store_true",
                           help="Show all tasks including completed")  # BUG: --all flag is parsed but never used in app.py
        # list_p.add_argument("--sort", "-s", default="id",  # BUG: missing sort flag entirely
        #                    choices=["id", "priority", "title"])
        
        # done
        done_p = subparsers.add_parser("done")
        done_p.add_argument("id", type=int, help="Task ID to mark as done")
        
        return parser.parse_args(argv)
''')

# === Formatter with bugs ===
write("formatter.py", '''"""Output formatting for Task Tracker."""
import json

class TaskFormatter:
    PRIORITY_COLORS = {
        "low": "\\033[36m",     # cyan
        "medium": "\\033[33m",   # yellow
        "high": "\\033[31m",     # red
    }
    RESET = "\\033[0m"
    
    def format_list(self, tasks):
        if not tasks:
            return self.info("No tasks found.")
        
        lines = []
        for task in tasks:
            color = self.PRIORITY_COLORS.get(task["priority"], "")
            # BUG: uses task.get("id") but first task has id=0 which is falsy
            task_id = task.get("id", "?")
            if task_id == 0:
                task_id = "?"  # BUG: this masks the real issue instead of fixing id assignment
            marker = "[x]" if task.get("done") else "[ ]"
            lines.append(f"  {marker} #{task_id} {color}{task['title']}{self.RESET} [{task['priority']}]")
        
        return "\\n".join(lines)
    
    def format_stats(self, total, done, pending):
        # BUG: done and pending are swapped in the output
        bar_len = 20
        filled = int(bar_len * done / total) if total > 0 else 0
        bar = "█" * filled + "░" * (bar_len - filled)
        return (
            f"  Tasks: {total} total | {done} done | {pending} pending\\n"
            f"  [{bar}] {int(done/total*100) if total else 0}%"
        )
    
    def success(self, msg):
        return f"\\033[32m✓ {msg}{self.RESET}"
    
    def error(self, msg):
        return f"\\033[31m✗ {msg}{self.RESET}"
    
    def info(self, msg):
        return f"\\033[36mℹ {msg}{self.RESET}"
''')

# === Test file with failing tests ===
write("test_app.py", '''"""Tests for Task Tracker CLI."""
import subprocess
import json
import os
import sys

TASKS_FILE = "tasks.json"

def run_cli(*args):
    """Run the CLI and return stdout, stderr, returncode."""
    result = subprocess.run(
        [sys.executable, "app.py"] + list(args),
        capture_output=True, text=True, cwd=os.path.dirname(__file__) or "."
    )
    return result.stdout, result.stderr, result.returncode

def cleanup():
    if os.path.exists(TASKS_FILE):
        os.remove(TASKS_FILE)

def setup_tasks():
    """Create a known set of tasks for testing."""
    cleanup()
    tasks = [
        {"id": 1, "title": "Buy groceries", "priority": "high", "done": False},
        {"id": 2, "title": "Read a book", "priority": "low", "done": True},
        {"id": 3, "title": "Write tests", "priority": "medium", "done": False},
    ]
    with open(TASKS_FILE, "w") as f:
        json.dump(tasks, f, indent=2)

# --- Tests ---

def test_add_task():
    """Test: adding a task should assign id=1, not id=0."""
    cleanup()
    out, err, rc = run_cli("add", "Test task", "-p", "high")
    assert rc == 0, f"add failed: {err}"
    with open(TASKS_FILE) as f:
        tasks = json.load(f)
    assert tasks[0]["id"] == 1, f"Expected id=1, got id={tasks[0]['id']}"
    print("  PASS: test_add_task")

def test_list_shows_pending():
    """Test: list should show pending tasks (done=False)."""
    setup_tasks()
    out, err, rc = run_cli("list")
    assert rc == 0, f"list failed: {err}"
    assert "Buy groceries" in out, f"Expected 'Buy groceries' in output, got: {out}"
    assert "Write tests" in out, f"Expected 'Write tests' in output, got: {out}"
    print("  PASS: test_list_shows_pending")

def test_list_hides_done():
    """Test: list should NOT show completed tasks."""
    setup_tasks()
    out, err, rc = run_cli("list")
    assert "Read a book" not in out, f"'Read a book' should be hidden (it's done), got: {out}"
    print("  PASS: test_list_hides_done")

def test_done_marks_task():
    """Test: done should mark a task as completed using 1-based ID."""
    setup_tasks()
    out, err, rc = run_cli("done", "1")
    assert rc == 0, f"done failed: {err}"
    with open(TASKS_FILE) as f:
        tasks = json.load(f)
    assert tasks[0]["done"] == True, f"Task 1 should be done"
    assert tasks[1]["done"] == True, f"Task 2 should still be done (unchanged)"
    assert tasks[2]["done"] == False, f"Task 3 should still be pending"
    print("  PASS: test_done_marks_task")

def test_done_not_found():
    """Test: done with invalid ID should return error."""
    setup_tasks()
    out, err, rc = run_cli("done", "99")
    assert rc != 0 or "not found" in out.lower(), f"Expected error for invalid ID, got: {out}"
    print("  PASS: test_done_not_found")

def test_stats():
    """Test: stats should show correct done/pending counts."""
    setup_tasks()
    out, err, rc = run_cli("stats")
    assert "3" in out, f"Expected total=3, got: {out}"
    # 1 done, 2 pending
    assert "1" in out, f"Expected done=1, got: {out}"
    print("  PASS: test_stats")

def test_stats_progress_bar():
    """Test: stats should show roughly 33% progress (1/3 done)."""
    setup_tasks()
    out, err, rc = run_cli("stats")
    assert "33%" in out, f"Expected 33% progress, got: {out}"
    print("  PASS: test_stats_progress_bar")

def test_task_zero_id_display():
    """Test: task with id=0 should display as #0, not as #?."""
    cleanup()
    # Manually create a task with id=0 to verify display
    with open(TASKS_FILE, "w") as f:
        json.dump([{"id": 0, "title": "Zero ID task", "priority": "medium", "done": False}], f)
    out, err, rc = run_cli("list")
    assert "#0" in out, f"Expected '#0' in output, got: {out}"
    assert "#?" not in out, f"Should not show '#?', got: {out}"
    print("  PASS: test_task_zero_id_display")

# --- Runner ---

if __name__ == "__main__":
    tests = [
        test_add_task,
        test_list_shows_pending,
        test_list_hides_done,
        test_done_marks_task,
        test_done_not_found,
        test_stats,
        test_stats_progress_bar,
        test_task_zero_id_display,
    ]
    
    passed = 0
    failed = 0
    errors = []
    
    for test in tests:
        try:
            test()
            passed += 1
        except AssertionError as e:
            failed += 1
            errors.append(f"  FAIL: {test.__name__}: {e}")
        except Exception as e:
            failed += 1
            errors.append(f"  ERROR: {test.__name__}: {type(e).__name__}: {e}")
        finally:
            cleanup()
    
    print(f"\\n{'='*50}")
    print(f"Results: {passed} passed, {failed} failed out of {len(tests)}")
    if errors:
        for e in errors:
            print(e)
    print(f"{'='*50}")
    
    sys.exit(0 if failed == 0 else 1)
''')

print(f"Scaffolded agent challenge project at {PROJECT_DIR}")
