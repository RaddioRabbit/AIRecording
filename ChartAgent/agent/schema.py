"""SmartChart API 契约（v5）：内容类型路由 + 统一思维导图 + 纯渲染接口 /chart/render。"""
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

ContentType = Literal["meeting", "interview", "lecture", "dialogue", "speech", "memo", "other"]
ChartType = Literal["mind_map", "highlights"]
MIND_MAP_CHART_TYPE: str = "mind_map"


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class TranscriptSegment(StrictModel):
    id: str = Field(min_length=1)
    speaker: str = ""
    startTime: float
    endTime: float
    text: str = Field(min_length=1)


class MindMapNode(StrictModel):
    id: str = Field(min_length=1)
    text: str = Field(min_length=1)
    segment_ids: List[str] = Field(default_factory=list)


class MindMapChild(MindMapNode):
    pass


class MindMapBranch(MindMapNode):
    children: List[MindMapChild] = Field(default_factory=list)


class MindMapRoot(StrictModel):
    """中心主题：无 segment_ids（extra="forbid" 保证客户端不得多传）。"""
    id: str = Field(min_length=1)
    text: str = Field(min_length=1)


class MindMapDoc(StrictModel):
    root: MindMapRoot
    branches: List[MindMapBranch] = Field(default_factory=list)


class SmartChartGenerateRequest(StrictModel):
    version: Literal["5.0"] = "5.0"
    requestId: str = Field(min_length=1)
    recordingId: str = Field(min_length=1)
    segments: List[TranscriptSegment]
    summaryMarkdown: Optional[str] = None
    forceContentType: Optional[ContentType] = None


class SmartChartGenerateResponse(StrictModel):
    version: Literal["5.0"] = "5.0"
    requestId: str
    status: Literal["success", "failed"]
    contentType: ContentType = "other"
    contentTypeDisplayName: str = "其他"
    chartType: str
    chartTypeDisplayName: str
    title: str
    htmlFragment: str
    mindMap: Optional[MindMapDoc] = None
    # 总览条文案：Swift 端重渲染 /chart/render 时需回传，避免编辑后总览条丢失
    overview: Optional[str] = None
    plan: Dict[str, Any]
    errors: List[str] = Field(default_factory=list)
    errorCode: Optional[str] = None


class SmartChartRenderRequest(StrictModel):
    """POST /chart/render 请求：编辑后的 MindMapDoc 重渲染，不调用 LLM。
    segment_ids 只校验格式（字符串数组），不与原文对照（请求不附 segments）。
    overview 为可选：Swift 重渲染时回传总览文案，避免编辑后总览条丢失。"""
    version: Literal["5.0"] = "5.0"
    requestId: str = Field(min_length=1)
    recordingId: str = Field(min_length=1)
    mindMap: MindMapDoc
    theme: str = "darkCyberpunk"
    overview: Optional[str] = None


class SmartChartRenderResponse(StrictModel):
    version: Literal["5.0"] = "5.0"
    requestId: str
    status: Literal["success", "failed"]
    htmlFragment: str = ""
    errorCode: Optional[str] = None
