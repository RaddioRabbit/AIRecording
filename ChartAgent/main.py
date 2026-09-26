"""ChartAgent v5 HTTP 服务：POST /chart/generate + POST /chart/render + GET /health。"""
import asyncio
import html
import os
import threading
import time
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import ValidationError

from agent.graph import ChartAgentState, chart_agent
from agent.mindmap import MindMapRenderer
from agent.nodes import _assert_render_fragment
from agent.observability import log_event, safe_error_fields
from agent.schema import (
    SmartChartGenerateRequest,
    SmartChartGenerateResponse,
    SmartChartRenderRequest,
    SmartChartRenderResponse,
)
from agent.skills import CHART_TYPE_DISPLAY_NAMES, CONTENT_TYPE_DISPLAY_NAMES

API_VERSION = "5.0"
SERVICE_VERSION = "5.0.0"
DEFAULT_TIME_BUDGET_SECONDS = 105.0
ENDPOINT_RESPONSE_RESERVE_SECONDS = 0.5
GRAPH_COMPLETION_MARGIN_SECONDS = 2.0
RENDER_ENDPOINT_BUDGET_SECONDS = 10.0

# /chart/render 进程内串行队列：纯渲染零 LLM，串行执行即可满足限流语义
_render_queue_lock = threading.Lock()

app = FastAPI(title="ChartAgent", version=SERVICE_VERSION)


def _time_budget_seconds() -> float:
    raw = os.environ.get("CHART_TIME_BUDGET_SECONDS", "")
    try:
        value = float(raw) if raw else DEFAULT_TIME_BUDGET_SECONDS
    except ValueError:
        return DEFAULT_TIME_BUDGET_SECONDS
    return value if value > 0 else DEFAULT_TIME_BUDGET_SECONDS


def _duration_ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _graph_timeout_seconds(budget_seconds: float) -> float:
    return max(0.01, budget_seconds - min(ENDPOINT_RESPONSE_RESERVE_SECONDS, budget_seconds / 2))


def _llm_configured() -> bool:
    return bool(os.environ.get("OPENAI_API_KEY") or os.environ.get("OLLAMA_MODEL"))


@app.get("/health")
async def health_check():
    return {
        "status": "ok",
        "apiVersion": API_VERSION,
        "serviceVersion": SERVICE_VERSION,
        "llmConfigured": _llm_configured(),
    }


def _error_html(message: str) -> str:
    safe_message = html.escape(message)
    return (
        '<div style="padding:24px;border-radius:12px;background:#2a1215;color:#fca5a5;'
        'font-size:14px;line-height:1.6">图表生成失败：' + safe_message + "</div>"
    )


def _failed_response(request_id: str, message: str, error_code: Optional[str] = None) -> SmartChartGenerateResponse:
    return SmartChartGenerateResponse(
        requestId=request_id,
        status="failed",
        contentType="other",
        contentTypeDisplayName="其他",
        chartType="highlights",
        chartTypeDisplayName="重点句子",
        title="生成失败",
        htmlFragment=_error_html(message),
        plan={"chartType": "highlights", "title": "生成失败", "highlightSentences": []},
        errors=[message],
        errorCode=error_code,
    )


@app.post("/chart/generate", response_model=SmartChartGenerateResponse)
async def chart_generate_endpoint(request: SmartChartGenerateRequest):
    budget_seconds = _time_budget_seconds()
    started = time.monotonic()
    graph_timeout = _graph_timeout_seconds(budget_seconds)
    work_deadline = started + graph_timeout - GRAPH_COMPLETION_MARGIN_SECONDS
    log_event("INFO", "request_received", request.requestId, request.recordingId,
              segmentCount=len(request.segments), budgetSeconds=budget_seconds,
              forceContentType=request.forceContentType)
    state: ChartAgentState = {
        "request_id": request.requestId,
        "recording_id": request.recordingId,
        "segments": [segment.model_dump() for segment in request.segments],
        "summary_markdown": request.summaryMarkdown or "",
        "preferences": {"styleTheme": "darkCyberpunk"},
        "force_content_type": request.forceContentType,
        "overview": None,
        "chunk_plans": [],
        "plan": None,
        "html_fragment": None,
        "render_config": None,
        "validation_result": None,
        "retry_count": 0,
        "error_message": None,
        "error_code": None,
        "deadline": work_deadline,
        "status": "success",
    }
    try:
        result_state = await asyncio.wait_for(
            asyncio.to_thread(chart_agent.invoke, state),
            timeout=graph_timeout,
        )
    except asyncio.TimeoutError:
        log_event("WARNING", "request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode="TIMEOUT", durationMs=_duration_ms(started))
        return _failed_response(request.requestId, "图表生成超时", "TIMEOUT")
    except Exception as error:
        log_event("ERROR", "request_finished", request.requestId, request.recordingId,
                  result="failed", durationMs=_duration_ms(started), **safe_error_fields(error))
        raise HTTPException(status_code=500, detail="图表服务内部错误") from error

    if result_state.get("status") == "failed":
        message = result_state.get("error_message") or "图表生成失败"
        log_event("WARNING", "request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode=result_state.get("error_code"), durationMs=_duration_ms(started))
        return _failed_response(request.requestId, message, result_state.get("error_code"))

    plan = result_state.get("plan") or {}
    content_type = result_state.get("content_type") or "other"
    chart_type = str(plan.get("chartType", "highlights"))
    log_event("INFO", "request_finished", request.requestId, request.recordingId,
              result="success", contentType=content_type, chartType=chart_type,
              durationMs=_duration_ms(started))
    try:
        return SmartChartGenerateResponse(
            requestId=request.requestId,
            status="success",
            contentType=content_type,
            contentTypeDisplayName=CONTENT_TYPE_DISPLAY_NAMES.get(content_type, "其他"),
            chartType=chart_type,
            chartTypeDisplayName=CHART_TYPE_DISPLAY_NAMES.get(chart_type, "重点句子"),
            title=str(plan.get("title", "")),
            htmlFragment=result_state.get("html_fragment") or "",
            mindMap=plan.get("mindMap"),
            overview=plan.get("overview"),
            plan=plan,
            errors=[],
        )
    except ValidationError as error:
        # 响应模型校验失败时降级为结构化失败响应，避免裸 500
        log_event("ERROR", "request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode="RESPONSE_SCHEMA_INVALID",
                  durationMs=_duration_ms(started), **safe_error_fields(error))
        return _failed_response(request.requestId, "图表结果校验失败", "RESPONSE_SCHEMA_INVALID")


def _render_failed_response(request_id: str, error_code: str) -> SmartChartRenderResponse:
    return SmartChartRenderResponse(requestId=request_id, status="failed", htmlFragment="", errorCode=error_code)


def _render_mindmap_sync(request: SmartChartRenderRequest) -> SmartChartRenderResponse:
    with _render_queue_lock:
        try:
            html_fragment = MindMapRenderer().render(
                request.mindMap.model_dump(), request.theme, request.mindMap.root.text,
                overview=request.overview,
            )
            _assert_render_fragment(html_fragment)
        except ValueError:
            return _render_failed_response(request.requestId, "INVALID_MINDMAP")
        except Exception as error:
            log_event("WARNING", "render_mindmap", request.requestId, request.recordingId,
                      result="failed", errorCode="RENDER_FAILED", **safe_error_fields(error))
            return _render_failed_response(request.requestId, "RENDER_FAILED")
        return SmartChartRenderResponse(
            requestId=request.requestId, status="success", htmlFragment=html_fragment
        )


@app.post("/chart/render", response_model=SmartChartRenderResponse)
async def chart_render_endpoint(request: SmartChartRenderRequest):
    """纯渲染接口：编辑后的 MindMapDoc → htmlFragment。不调用 LLM、不做分类与提取；
    segment_ids 只经 schema 校验格式（字符串数组），不与原文对照。预算 10s。"""
    started = time.monotonic()
    log_event("INFO", "render_request_received", request.requestId, request.recordingId,
              branchCount=len(request.mindMap.branches))
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(_render_mindmap_sync, request),
            timeout=RENDER_ENDPOINT_BUDGET_SECONDS,
        )
    except asyncio.TimeoutError:
        log_event("WARNING", "render_request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode="TIMEOUT", durationMs=_duration_ms(started))
        return _render_failed_response(request.requestId, "TIMEOUT")
    log_event("INFO", "render_request_finished", request.requestId, request.recordingId,
              result=result.status, durationMs=_duration_ms(started))
    return result


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8765")))
