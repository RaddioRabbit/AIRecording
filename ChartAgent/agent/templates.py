"""Deterministic, escaped HTML renderers for validated SmartChart plans."""

from jinja2 import DictLoader, Environment


DARK_CSS = """
:root {
  --bg: #0F0F1A; --card: #1E1E2E; --card-hover: #252538; --border: #33334D;
  --text: #E2E8F0; --text-secondary: #94A3B8; --cyan: #22D3EE;
  --purple: #8B5CF6; --orange: #F59E0B; --green: #34C759; --red: #FF3B30;
  --blue: #3B82F6; --radius: 12px; --shadow: 0 8px 24px rgba(0,0,0,.3);
  --font-main: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: var(--bg); color: var(--text); font-family: var(--font-main); padding: 20px; }
.smartchart-container { background: var(--bg); padding: 16px; border-radius: var(--radius); }
.smartchart-title { font-size: 20px; font-weight: 700; margin-bottom: 16px; }
.smartchart-kind-badge {
  display: inline-block; font-size: 11px; font-weight: 600; letter-spacing: .05em;
  padding: 4px 10px; border-radius: 999px; background: rgba(34,211,238,.1);
  color: var(--cyan); border: 1px solid rgba(34,211,238,.2); margin-bottom: 16px;
}
.sc-card {
  background: var(--card); border: 1px solid var(--border); border-radius: var(--radius);
  padding: 14px; margin-bottom: 12px; box-shadow: var(--shadow);
}
[data-segment-ids] { cursor: pointer; }
[data-segment-ids]:hover { border-color: rgba(34,211,238,.45); }
.sc-label { font-size: 14px; line-height: 1.55; color: var(--text); }
.sc-meta { font-size: 11px; color: var(--text-secondary); margin-top: 8px; }
.sc-tag {
  display: inline-block; font-size: 10px; font-weight: 600; padding: 2px 8px;
  border-radius: 999px; background: rgba(139,92,246,.15); color: var(--purple); margin-right: 6px;
}
.sc-highlight-row { padding: 12px 2px; border-bottom: 1px solid var(--border); }
.sc-highlight-row:last-child { border-bottom: 0; }
.sc-empty { color: var(--text-secondary); text-align: center; padding: 40px; }
.sc-truncate-note{color:#64748b;font-size:12px;text-align:center;padding:6px}
.sc-overview{background:#232742;border-left:3px solid #7aa2ff;color:#c6cbe0;font-size:13px;line-height:1.7;padding:10px 14px;border-radius:0 8px 8px 0;margin-bottom:14px}
"""


_BASE_TEMPLATE = """
<style>{{ dark_css | safe }}</style>
<div class="smartchart-container">
  {% if title %}<div class="smartchart-title">{{ title }}</div>{% endif %}
  <div class="smartchart-kind-badge">{{ kind_display_name }}</div>
  {% if plan.overview %}<div class="sc-overview">{{ plan.overview }}</div>{% endif %}
  {% block chart_content %}{% endblock %}
</div>
"""

BASE_TEMPLATE = _BASE_TEMPLATE  # 公开别名：skill 模板通过 {% extends "base.html.j2" %} 继承

_HIGHLIGHTS_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
{% if plan['highlightSentences'] %}
<div class="sc-card">
  {% for sentence in plan['highlightSentences'] %}
  <div class="sc-highlight-row" data-segment-ids="{{ sentence['segmentId'] }}">
    <div class="sc-label">{{ sentence['text'] }}</div>
    <div class="sc-meta">
      <span class="sc-tag">{{ sentence['tag'] }}</span>
      <span>{{ sentence['speaker'] }} · {{ "%02d:%02d"|format((sentence['startTime'] // 60)|int, (sentence['startTime'] % 60)|int) }}</span>
    </div>
  </div>
  {% endfor %}
</div>
{% else %}<div class="sc-empty">没有提取到重点句子</div>{% endif %}
{% if plan['truncatedCount'] %}<div class="sc-truncate-note">还有 {{ plan['truncatedCount'] }} 条重点句子未展示</div>{% endif %}
{% endblock %}
"""

_TEMPLATES = {
    "base.html.j2": _BASE_TEMPLATE,
    "highlights.html.j2": _HIGHLIGHTS_TEMPLATE,
}

_JINJA_ENV = Environment(loader=DictLoader(_TEMPLATES), autoescape=True)


def render_highlights(plan: dict, theme: str, title: str = "") -> str:
    """重点句子图表的公共渲染入口（other skill 与全局兜底共用）。"""
    template = _JINJA_ENV.get_template("highlights.html.j2")
    return template.render(
        plan=plan,
        theme=theme,
        title=title or plan.get("title", "重点句子"),
        kind_display_name="重点句子",
        dark_css=DARK_CSS,
    )
