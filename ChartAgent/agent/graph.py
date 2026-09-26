"""SmartChart v5 LangGraph 编排：prepare → classify → overview → extract → merge → validate → mindmap_normalize → render → validate_render。"""
from typing import Any, Dict, List, Literal, Optional, TypedDict

from langgraph.graph import END, StateGraph

from .nodes import (
    classify_content,
    extract_structured,
    generate_overview,
    merge_plans,
    mindmap_normalize_node,
    prepare_transcript,
    render_chart_node,
    validate_plan,
    validate_render,
)


class ChartAgentState(TypedDict, total=False):
    request_id: str
    recording_id: str
    segments: List[Dict[str, Any]]
    summary_markdown: str
    preferences: Dict[str, Any]
    transcript_text: str
    segment_map: Dict[str, Dict[str, Any]]
    force_content_type: Optional[str]
    content_type: str
    classify_confidence: float
    classify_reason: str
    overview: Optional[str]
    chunk_plans: List[Dict[str, Any]]
    plan: Optional[Dict[str, Any]]
    html_fragment: Optional[str]
    render_config: Optional[Dict[str, Any]]
    validation_result: Optional[Dict[str, Any]]
    retry_count: int
    error_message: Optional[str]
    error_code: Optional[str]
    deadline: float
    status: Literal["success", "failed"]


def _continue_or_end(state: ChartAgentState) -> str:
    return END if state.get("status") == "failed" else "continue"


def build_chart_agent():
    builder = StateGraph(ChartAgentState)
    builder.add_node("prepare_transcript", prepare_transcript)
    builder.add_node("classify_content", classify_content)
    builder.add_node("generate_overview", generate_overview)
    builder.add_node("extract_structured", extract_structured)
    builder.add_node("merge_plans", merge_plans)
    builder.add_node("validate_plan", validate_plan)
    builder.add_node("mindmap_normalize", mindmap_normalize_node)
    builder.add_node("render_chart", render_chart_node)
    builder.add_node("validate_render", validate_render)
    builder.set_entry_point("prepare_transcript")
    builder.add_conditional_edges("prepare_transcript", _continue_or_end, {"continue": "classify_content", END: END})
    builder.add_conditional_edges("classify_content", _continue_or_end, {"continue": "generate_overview", END: END})
    builder.add_conditional_edges("generate_overview", _continue_or_end, {"continue": "extract_structured", END: END})
    builder.add_conditional_edges("extract_structured", _continue_or_end, {"continue": "merge_plans", END: END})
    builder.add_conditional_edges("merge_plans", _continue_or_end, {"continue": "validate_plan", END: END})
    builder.add_conditional_edges("validate_plan", _continue_or_end, {"continue": "mindmap_normalize", END: END})
    builder.add_conditional_edges("mindmap_normalize", _continue_or_end, {"continue": "render_chart", END: END})
    builder.add_conditional_edges("render_chart", _continue_or_end, {"continue": "validate_render", END: END})
    builder.add_edge("validate_render", END)
    return builder.compile()


chart_agent = build_chart_agent()
