"""SmartChart v5 流水线节点。

prepare_transcript → classify_content → generate_overview → extract_structured
→ merge_plans → validate_plan → mindmap_normalize → render_chart → validate_render

分工：skill 负责类型内逻辑（提示词/校验/渲染），本模块负责编排、时间预算与并发。
"""
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Tuple

from . import classifier
from .classifier import CONTENT_TYPES
from .llm_client import LLMError, MIN_REMAINING_SECONDS, call_llm
from .observability import log_event, safe_error_fields
from .overview import build_overview_prompt, parse_overview
from .mindmap import MindMapRenderer
from .schema import MIND_MAP_CHART_TYPE
from .skills import SKILLS, skill_for_chart_type
from .skills.base import CONTENT_TYPE_DISPLAY_NAMES, BaseSkill
from .textutils import parse_llm_json as _parse_json

CHUNK_CHARACTER_BUDGET = 12000
EXTRACTION_CONCURRENCY = 4
ROUTE_RESERVED_SECONDS = 25.0
REPAIR_MIN_SECONDS = 12.0
CLASSIFY_RESERVED_SECONDS = 10.0
OVERVIEW_RESERVED_SECONDS = 15.0


# ---------- 基础工具 ----------

def _fail(state: Dict[str, Any], message: str, error_code: Optional[str] = None) -> Dict[str, Any]:
    state["status"] = "failed"
    state["error_message"] = message
    if error_code:
        state["error_code"] = error_code
    return state


def _elapsed_ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _remaining_budget(state: Dict[str, Any]) -> float:
    deadline = state.get("deadline")
    if deadline is None:
        return float("inf")
    return deadline - time.monotonic()


def _extraction_concurrency() -> int:
    raw = os.environ.get("CHART_EXTRACTION_CONCURRENCY", "")
    try:
        value = int(raw) if raw else EXTRACTION_CONCURRENCY
    except ValueError:
        return EXTRACTION_CONCURRENCY
    return max(1, min(value, EXTRACTION_CONCURRENCY))


def _extraction_deadline(request_deadline: Optional[float]) -> Optional[float]:
    if request_deadline is None:
        return None
    return request_deadline - ROUTE_RESERVED_SECONDS


def _call_llm(prompt: str, temperature: float, deadline: Optional[float] = None) -> str:
    if deadline is None:
        return call_llm(prompt, temperature=temperature)
    return call_llm(prompt, temperature=temperature, deadline=deadline)


def _chunk_segments(
    segments: List[Dict[str, Any]], budget: int = CHUNK_CHARACTER_BUDGET
) -> List[List[Dict[str, Any]]]:
    """按片段边界贪心分块，单块字符预算 budget；超大单片段独立成块。"""
    chunks: List[List[Dict[str, Any]]] = []
    current: List[Dict[str, Any]] = []
    current_size = 0
    for segment in segments:
        size = len(json.dumps(segment, ensure_ascii=False))
        if current and current_size + size > budget:
            chunks.append(current)
            current, current_size = [], 0
        current.append(segment)
        current_size += size
    if current:
        chunks.append(current)
    return chunks


def _deduplicated(values: List[str]) -> List[str]:
    return list(dict.fromkeys(values))


def _skill_for_state(state: Dict[str, Any]) -> BaseSkill:
    return SKILLS.get(state.get("content_type") or "other") or SKILLS["other"]


# ---------- 节点 ----------

def prepare_transcript(state: Dict[str, Any]) -> Dict[str, Any]:
    started = time.monotonic()
    segments = [s for s in state.get("segments", []) if str(s.get("text", "")).strip()]
    if not segments:
        return _fail(state, "没有完整转录")
    state["segments"] = segments
    transcript_text = "\n".join(f"[{s['id']}] {s.get('speaker', '')}: {s['text']}" for s in segments)
    if len(transcript_text) < 30:
        return _fail(state, "转录内容过短且没有重点句子")
    state["transcript_text"] = transcript_text
    state["segment_map"] = {s["id"]: s for s in segments}
    state["status"] = "success"
    log_event("INFO", "prepare_transcript", state.get("request_id"), state.get("recording_id"),
              segmentCount=len(segments), elapsedMs=_elapsed_ms(started))
    return state


def classify_content(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    forced = state.get("force_content_type")
    if forced in CONTENT_TYPES:
        state["content_type"] = forced
        state["classify_confidence"] = 1.0
        state["classify_reason"] = "forced"
        log_event("INFO", "classify_content", state.get("request_id"), state.get("recording_id"),
                  contentType=forced, confidence=1.0, forced=True, elapsedMs=_elapsed_ms(started))
        return state
    # 打桩桥接：测试统一 patch 本模块的 call_llm，而 classifier 持有自己的模块级引用。
    # 调用期间把 classifier.call_llm 临时绑定到本模块当前引用，结束即恢复；
    # 生产环境下两侧本就是同一个函数，绑定是幂等的。
    original_classifier_llm = classifier.call_llm
    classifier.call_llm = call_llm
    try:
        deadline = state.get("deadline")
        classify_deadline = (
            min(deadline, time.monotonic() + CLASSIFY_RESERVED_SECONDS) if deadline is not None else None
        )
        content_type, confidence, reason = classifier.classify_content(
            state.get("segments", []), state.get("transcript_text", ""), deadline=classify_deadline
        )
    finally:
        classifier.call_llm = original_classifier_llm
    state["content_type"] = content_type
    state["classify_confidence"] = confidence
    state["classify_reason"] = reason
    log_event("INFO", "classify_content", state.get("request_id"), state.get("recording_id"),
              contentType=content_type, confidence=round(confidence, 3),
              elapsedMs=_elapsed_ms(started))
    return state


def generate_overview(state: Dict[str, Any]) -> Dict[str, Any]:
    """全局总览：一段话概括整段录音。失败/超时/低质 → overview=None，不阻塞主流程。"""
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    state["overview"] = None
    try:
        deadline = state.get("deadline")
        overview_deadline = (
            min(deadline, time.monotonic() + OVERVIEW_RESERVED_SECONDS) if deadline is not None else None
        )
        type_name = CONTENT_TYPE_DISPLAY_NAMES.get(state.get("content_type") or "other", "其他")
        raw = _call_llm(
            build_overview_prompt(state.get("transcript_text", ""), type_name),
            temperature=0.3,
            deadline=overview_deadline,
        )
        state["overview"] = parse_overview(raw)
    except Exception as error:
        log_event("WARNING", "generate_overview", state.get("request_id"), state.get("recording_id"),
                  result="skipped", **safe_error_fields(error))
    log_event("INFO", "generate_overview", state.get("request_id"), state.get("recording_id"),
              hasOverview=state["overview"] is not None, elapsedMs=_elapsed_ms(started))
    return state


def _extract_chunk_plan(
    skill: BaseSkill,
    chunk_index: int,
    chunk: List[Dict[str, Any]],
    chunk_count: int,
    deadline: Optional[float],
    request_id: Optional[str],
    recording_id: Optional[str],
) -> Tuple[int, Optional[Dict[str, Any]], Optional[BaseException]]:
    try:
        raw = _parse_json(_call_llm(skill.extraction_prompt(chunk), temperature=0.2, deadline=deadline))
        return chunk_index, skill.normalize(raw, chunk), None
    except Exception as error:
        log_event("WARNING", "extract_chunk", request_id, recording_id,
                  chunkIndex=chunk_index, chunkCount=chunk_count, result="failed", **safe_error_fields(error))
        return chunk_index, None, error


def extract_structured(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    skill = _skill_for_state(state)
    segments = state.get("segments", [])
    if not skill.uses_llm_extraction:
        state["chunk_plans"] = [skill.extract_deterministic(segments)]
        log_event("INFO", "extract_structured", state.get("request_id"), state.get("recording_id"),
                  contentType=skill.content_type, chunks=0, elapsedMs=_elapsed_ms(started))
        return state
    chunks = _chunk_segments(segments)
    concurrency = _extraction_concurrency()
    extraction_deadline = _extraction_deadline(state.get("deadline"))
    chunk_count = len(chunks)
    collected: List[Tuple[int, Dict[str, Any]]] = []
    failed_chunks = 0
    for wave_start in range(0, chunk_count, concurrency):
        if extraction_deadline is not None and extraction_deadline - time.monotonic() < MIN_REMAINING_SECONDS:
            log_event("WARNING", "extract_chunk", state.get("request_id"), state.get("recording_id"),
                      result="skipped_low_budget", remainingChunks=chunk_count - wave_start)
            break
        wave = chunks[wave_start:wave_start + concurrency]
        with ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix="chart-extract") as executor:
            futures = [
                executor.submit(
                    _extract_chunk_plan, skill, wave_start + offset, chunk, chunk_count,
                    extraction_deadline, state.get("request_id"), state.get("recording_id"),
                )
                for offset, chunk in enumerate(wave)
            ]
            for future in as_completed(futures):
                index, plan, error = future.result()
                if error is not None or plan is None:
                    failed_chunks += 1
                else:
                    collected.append((index, plan))
    state["chunk_plans"] = [plan for index, plan in sorted(collected, key=lambda item: item[0])]
    log_event("INFO", "extract_structured", state.get("request_id"), state.get("recording_id"),
              contentType=skill.content_type, chunks=chunk_count, failedChunks=failed_chunks,
              elapsedMs=_elapsed_ms(started))
    return state


def merge_plans(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed" or state.get("plan"):
        return state
    started = time.monotonic()
    skill = _skill_for_state(state)
    merged = skill.merge(state.get("chunk_plans", []))
    if skill.is_empty(merged):
        return _degrade_to_highlights(state, "extraction_empty")
    state["plan"] = merged
    log_event("INFO", "merge_plans", state.get("request_id"), state.get("recording_id"),
              contentType=skill.content_type, elapsedMs=_elapsed_ms(started))
    return state


def _degrade_to_highlights(state: Dict[str, Any], reason: str) -> Dict[str, Any]:
    plan = SKILLS["other"].extract_deterministic(state.get("segments", []))
    if not plan.get("highlightSentences"):
        return _fail(state, "没有可用的重点句子，无法生成图表")
    state["plan"] = plan
    state["validation_result"] = {"passed": False, "degraded": True, "reason": reason}
    state["status"] = "success"
    log_event("WARNING", "degrade_to_highlights", state.get("request_id"), state.get("recording_id"), reason=reason)
    return state


def validate_plan(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    plan = state.get("plan")
    if not plan:
        return _degrade_to_highlights(state, "plan_missing")
    started = time.monotonic()
    skill = skill_for_chart_type(str(plan.get("chartType", "highlights")))
    segment_map = state.get("segment_map", {})
    errors = skill.validate(plan, segment_map)
    if errors and state.get("retry_count", 0) < 1:
        state["retry_count"] = 1
        if _remaining_budget(state) >= REPAIR_MIN_SECONDS:
            repaired: Optional[Dict[str, Any]] = None
            try:
                repaired_raw = _parse_json(_call_llm(
                    skill.repair_prompt(plan, errors, state.get("segments", [])),
                    temperature=0.0,
                    deadline=state.get("deadline"),
                ))
                candidate = skill.normalize(repaired_raw, state.get("segments", []))
                retry_errors = skill.validate(candidate, segment_map)
                if not retry_errors:
                    repaired = candidate
                else:
                    errors = retry_errors
            except Exception as error:
                log_event("WARNING", "repair_plan", state.get("request_id"), state.get("recording_id"),
                          result="failed", **safe_error_fields(error))
            if repaired is not None:
                state["plan"] = repaired
                state["validation_result"] = {"passed": True, "repaired": True}
                log_event("INFO", "validate_plan", state.get("request_id"), state.get("recording_id"),
                          result="repaired", elapsedMs=_elapsed_ms(started))
                return state
        else:
            log_event("WARNING", "repair_plan", state.get("request_id"), state.get("recording_id"),
                      result="skipped_low_budget")
    if not errors:
        previous = state.get("validation_result") or {}
        result: Dict[str, Any] = {"passed": True}
        if previous.get("degraded"):
            result["degraded"] = True
            result["reason"] = previous.get("reason")
        state["validation_result"] = result
        log_event("INFO", "validate_plan", state.get("request_id"), state.get("recording_id"),
                  result="passed", elapsedMs=_elapsed_ms(started))
        return state
    fallback = skill.fallback(plan, segment_map)
    if fallback is not None and not skill.is_empty(fallback):
        state["plan"] = fallback
        state["validation_result"] = {"passed": False, "errors": errors, "degraded": True, "reason": "skill_fallback"}
        log_event("WARNING", "validate_plan", state.get("request_id"), state.get("recording_id"),
                  result="skill_fallback", elapsedMs=_elapsed_ms(started))
        return state
    return _degrade_to_highlights(state, "validation_failed")


def mindmap_normalize_node(state: Dict[str, Any]) -> Dict[str, Any]:
    """plan → MindMapDoc 归一化：六种类型统一出 mind_map；other/highlights 原样放行。
    归一化结果分支数为 0 → 降级 highlights（设计文档 §7.3）。"""
    if state.get("status") == "failed":
        return state
    plan = state.get("plan")
    if not plan:
        return _degrade_to_highlights(state, "plan_missing")
    if str(plan.get("chartType", "highlights")) == "highlights":
        return state
    started = time.monotonic()
    skill = _skill_for_state(state)
    doc = skill.to_mindmap(plan)
    if doc is None or not doc.get("branches"):
        return _degrade_to_highlights(state, "mindmap_empty")
    plan["chartType"] = MIND_MAP_CHART_TYPE
    plan["mindMap"] = doc
    state["plan"] = plan
    log_event("INFO", "mindmap_normalize", state.get("request_id"), state.get("recording_id"),
              contentType=state.get("content_type"), branchCount=len(doc.get("branches", [])),
              elapsedMs=_elapsed_ms(started))
    return state


def _assert_render_fragment(html: str) -> None:
    """渲染产物结构校验（validate_render 节点与 /chart/render 端点共用）；不通过抛 ValueError。"""
    if not html.strip():
        raise ValueError("渲染结果为空")
    if "data-segment-ids" not in html:
        raise ValueError("渲染结果缺少 data-segment-ids")
    if html.count("<div") != html.count("</div>"):
        raise ValueError("渲染结果 div 标签不平衡")


def render_chart_node(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    plan = state.get("plan") or {}
    theme = state.get("preferences", {}).get("styleTheme", "darkCyberpunk")
    chart_type = str(plan.get("chartType", "highlights"))
    try:
        if chart_type == MIND_MAP_CHART_TYPE:
            if state.get("overview"):
                plan["overview"] = state["overview"]
                state["plan"] = plan
            state["html_fragment"] = MindMapRenderer().render(
                plan.get("mindMap") or {"root": {"id": "root", "text": str(plan.get("title", ""))}, "branches": []},
                theme,
                str(plan.get("title", "")),
                overview=state.get("overview"),
            )
        else:
            if state.get("overview"):
                plan["overview"] = state["overview"]
                state["plan"] = plan
            skill = skill_for_chart_type(chart_type)
            state["html_fragment"] = skill.render(plan, theme, str(plan.get("title", "")))
        state["render_config"] = {"cssFramework": "smartchart-v5"}
    except Exception as error:
        log_event("ERROR", "render", state.get("request_id"), state.get("recording_id"), **safe_error_fields(error))
        return _fail(state, f"图表渲染失败：{error}")
    log_event("INFO", "render", state.get("request_id"), state.get("recording_id"),
              chartType=chart_type, elapsedMs=_elapsed_ms(started))
    return state


def validate_render(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    try:
        _assert_render_fragment(state.get("html_fragment") or "")
    except ValueError as error:
        state["validation_result"] = {"passed": False, "errors": [str(error)]}
        return _fail(state, str(error))
    state["status"] = "success"
    return state
