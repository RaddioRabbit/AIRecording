"""共享文本工具：归一化、溯源证据、重点句子规则、LLM JSON 解析、数字一致性。

只放纯函数，不依赖 nodes/skills，避免循环导入。
"""
import json
import re
from typing import Any, Dict, List, Optional, Sequence

_PUNCTUATION_PATTERN = re.compile(
    r"[\s，。！？；：、“”‘’（）《》〈〉【】…—·,.!?;:'\"()<>\[\]{}\\\-_~`@#$%^&*+=|/]+"
)
IMPORTANT_MARKER_PATTERN = re.compile(
    r"重要|关键|必须|需要|决定|结论|风险|问题|目标|计划|截止|提醒|注意|总结|核心|一定|务必|应该"
)
FILLER_PATTERN = re.compile(r"^(嗯|啊|呃|哦|好|好的|对|是的|行|可以|喂|哈喽|大家好)[，。！？\s]*$")
NUMBER_PATTERN = re.compile(r"\d")
NUMBER_TOKEN_PATTERN = re.compile(r"\d+(?:\.\d+)?%?")


def normalize_text(value: Optional[str]) -> str:
    """小写并去除空白与中英文标点，用于证据包含判断。"""
    if not value:
        return ""
    return _PUNCTUATION_PATTERN.sub("", str(value)).lower()


def parse_llm_json(raw: str) -> Dict[str, Any]:
    """解析 LLM 返回的 JSON（容忍 ``` 围栏），顶层必须是对象。"""
    if not raw or not raw.strip():
        raise ValueError("LLM 没有返回文本")
    text = raw.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    parsed = json.loads(text)  # JSONDecodeError 是 ValueError 子类，直接上抛
    if not isinstance(parsed, dict):
        raise ValueError("LLM JSON 顶层必须是对象")
    return parsed


def is_filler(text: str) -> bool:
    return bool(FILLER_PATTERN.match(text.strip()))


def is_highlight_sentence(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < 10:
        return False
    if is_filler(stripped):
        return False
    return bool(IMPORTANT_MARKER_PATTERN.search(stripped) or NUMBER_PATTERN.search(stripped))


def tag_highlight(text: str) -> str:
    if re.search(r"风险|问题|隐患|失败|延期", text):
        return "风险"
    if re.search(r"决定|结论|认为|判断", text):
        return "关键判断"
    if NUMBER_PATTERN.search(text):
        return "重要数据"
    if re.search(r"负责|完成|截止|跟进|落实|承诺", text):
        return "行动承诺"
    if re.search(r"因为|由于|所以|因此|导致", text):
        return "因果依据"
    return "关键要点"


def source_text(segment_ids: Sequence[str], segment_map: Dict[str, Dict[str, Any]]) -> str:
    """按给定顺序拼接片段原文。"""
    return " ".join(str(segment_map[sid].get("text", "")) for sid in segment_ids if sid in segment_map)


def text_has_evidence(
    value: Optional[str], segment_ids: Sequence[str], segment_map: Dict[str, Dict[str, Any]]
) -> bool:
    """value 归一化后必须整体出现在来源片段原文中（用于必须逐字的字段：金句/重点句子）。

    归一化会忽略标点/大小写/空白；若调用方需要数字保真，必须配合 numbers_have_evidence 使用。
    """
    normalized = normalize_text(value)
    if not normalized:
        return False
    return normalized in normalize_text(source_text(segment_ids, segment_map))


def numbers_have_evidence(
    value: Optional[str], segment_ids: Sequence[str], segment_map: Dict[str, Dict[str, Any]]
) -> bool:
    """value 中每个数字 token 都必须能在来源片段原文中找到（用于提炼类字段，允许改写但禁止编造数字）。

    边界匹配：数字前后不能再紧贴数字，避免 "5" 命中 "15" 这类误判。
    """
    source = source_text(segment_ids, segment_map)
    return all(
        re.search(r"(?<!\d)" + re.escape(token) + r"(?!\d)", source)
        for token in NUMBER_TOKEN_PATTERN.findall(value or "")
    )


def filter_known_segment_ids(
    segment_ids: Optional[Sequence[str]], segment_map: Dict[str, Dict[str, Any]]
) -> List[str]:
    """只保留真实存在的片段 id，去重并保持顺序。"""
    seen = set()
    result = []
    for sid in segment_ids or []:
        if sid in segment_map and sid not in seen:
            seen.add(sid)
            result.append(sid)
    return result


def format_mmss(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 60:02d}:{total % 60:02d}"
