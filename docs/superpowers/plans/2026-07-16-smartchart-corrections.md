# SmartChart Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SmartChart reliably choose one content-appropriate view from the full transcript, keep every displayed fact traceable, provide a safe deterministic renderer, and complete the confirmed Swift interaction.

**Architecture:** Keep the existing Swift client → local FastAPI service boundary. Move the ChartPlan contract into a dedicated Python schema module, chunk transcripts at segment boundaries, use the LLM for candidate extraction and one global plan, validate before rendering, and deterministically fall back to one highlights container. Swift remains responsible for service lifecycle, display, regeneration, and seeking to the earliest source segment.

**Tech Stack:** Swift 5.9/SwiftUI/WebKit/XCTest, Python 3, FastAPI, Pydantic, LangGraph, Jinja2, unittest.

---

### Task 1: Lock down the Python runtime regressions

**Files:**
- Create: `ChartAgent/tests/__init__.py`
- Create: `ChartAgent/tests/test_smartchart.py`
- Modify: `ChartAgent/agent/graph.py`
- Modify: `ChartAgent/agent/templates.py`

- [x] **Step 1: Write failing graph and renderer tests**

Add tests that invoke the compiled graph with a stub LLM, render every allowed `visualizationKind`, render a null numeric value, and assert highlights use one outer `.sc-card`.

- [x] **Step 2: Verify RED**

Run: `PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest ChartAgent.tests.test_smartchart -v`

Expected: failures for the wrong graph callback, `plan.items`, null numeric values, and multiple highlight cards.

- [x] **Step 3: Apply the minimal runtime fixes**

Register `render_chart_node`; use bracket access for dict keys; render null/negative quantitative values safely; render relations instead of inventing adjacency; make highlights one container with sentence rows.

- [x] **Step 4: Verify GREEN**

Run the same unittest command and require all Task 1 tests to pass.

### Task 2: Enforce the ChartPlan trust boundary

**Files:**
- Create: `ChartAgent/agent/schema.py`
- Modify: `ChartAgent/agent/nodes.py`
- Modify: `ChartAgent/main.py`
- Test: `ChartAgent/tests/test_smartchart.py`

- [x] **Step 1: Write failing schema and provenance tests**

Cover unknown/empty segment IDs, forged highlight text, forged numbers and units, missing relation endpoints/evidence, invalid kinds/confidence/extra fields, and invalid LLM JSON followed by one repair attempt.

- [x] **Step 2: Verify RED**

Run the focused unittest class and confirm the current validator accepts the forged plans.

- [x] **Step 3: Add the strict schema and validator**

Define Pydantic models with forbidden extra fields, literal kinds, bounded confidence, and `default_factory`. Validate each factual element against its referenced transcript before rendering. On invalid LLM output, request one correction; on a second failure, build highlights deterministically from original segments.

- [x] **Step 4: Fix failure-state flow**

End the graph immediately after an invalid/short transcript or unavailable LLM. Do not let render validation overwrite failure, and do not retry deterministic rendering through the LLM route.

- [x] **Step 5: Verify GREEN**

Run the provenance/schema/failure tests and require all to pass.

### Task 3: Make routing use the complete recording without fabricating structure

**Files:**
- Modify: `ChartAgent/agent/nodes.py`
- Test: `ChartAgent/tests/test_smartchart.py`

- [x] **Step 1: Write failing routing fixtures**

Cover a >12k transcript whose decisive relation appears after segment 20, three dated events, an unsupported comparison, an unsupported causal chain, and an unstructured recording that must become highlights.

- [x] **Step 2: Verify RED**

Confirm the current code skips the LLM for long input and routes dates to quantitative.

- [x] **Step 3: Implement segment-boundary chunking and global routing**

Chunk without splitting segments, call candidate extraction for every chunk, merge the full candidate catalogue, and perform one global LLM route. Exclude date/time tokens from numeric candidates. Remove rule builders that assign benefit/cost or “导致” without evidence.

- [x] **Step 4: Verify GREEN**

Run all Python tests and require the late-segment evidence and provenance IDs in the final plan.

### Task 4: Secure deterministic HTML rendering

**Files:**
- Modify: `ChartAgent/agent/templates.py`
- Modify: `AIRecording/Views/ChartWebView.swift`
- Test: `ChartAgent/tests/test_smartchart.py`

- [x] **Step 1: Write a failing injection test**

Inject script tags, event attributes, quotes, and fake segment IDs into title/labels/speaker/raw values and assert they are escaped.

- [x] **Step 2: Verify RED**

Confirm executable markup currently appears in output.

- [x] **Step 3: Enable escaping and constrain WebView**

Use Jinja autoescape, add a restrictive CSP, prevent external navigation, update HTML only when content changes, update the callback on SwiftUI refresh, and remove the script message handler on dismantle.

- [x] **Step 4: Verify GREEN**

Run injection tests and Swift build.

### Task 5: Complete the Swift API and confirmed interaction

**Files:**
- Modify: `AIRecording/Services/ChartSkill.swift`
- Modify: `AIRecording/Services/HTTPChartSkill.swift`
- Modify: `AIRecording/Services/ChartServiceManager.swift`
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`
- Modify: `AIRecording/Views/RecordingDetailView.swift`
- Modify: `AIRecording/Views/ChartPanelView.swift`
- Modify: `Package.swift`
- Test: `Tests/AIRecordingTests/SmartChartTests.swift`

- [x] **Step 1: Write failing Swift tests**

Test failed-response error preservation, v3 health compatibility, earliest-source selection, response decoding, and bundled ChartAgent resource lookup.

- [x] **Step 2: Verify RED**

Run: `swift test --filter SmartChartTests`

- [x] **Step 3: Fix client/service behavior**

Keep `generationFailed` distinct from decoding errors; validate health `apiVersion`; inherit the parent environment when adding service variables; avoid a standalone panel request with empty segments; bundle ChartAgent resources.

- [x] **Step 4: Fix the UI contract**

Show “重新生成” after success, seek to the earliest referenced segment, visibly highlight the matching transcript row, and keep invalid IDs as a no-op.

- [x] **Step 5: Verify GREEN**

Run the focused Swift tests and require all to pass.

### Task 6: Full verification and cleanup

**Files:**
- Verify all modified files and remove generated caches only.

- [x] **Step 1: Run Python tests**

Run: `PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest discover -s ChartAgent/tests -v`

- [x] **Step 2: Run Python syntax compilation**

Run: `/opt/anaconda3/bin/python3 -m py_compile ChartAgent/main.py ChartAgent/agent/*.py`

- [x] **Step 3: Run Swift tests and build**

Run: `swift test` and `swift build`.

- [x] **Step 4: Audit the requirements**

Check the implementation against `docs/SmartChart-ContentFirst-Design.md`, especially one-view output, full-transcript routing, provenance, one highlights card, regeneration, and earliest-source seeking.

- [x] **Step 5: Clean generated files**

Delete only `__pycache__` and test cache files created during this execution, then verify `git status --short` contains only intended source/test/document changes and the user's existing files.
