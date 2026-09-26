# -*- mode: python ; coding: utf-8 -*-
"""Reproducible one-file release runtime for the local KnowledgeAgent."""

from PyInstaller.utils.hooks import collect_submodules, copy_metadata


hiddenimports = (
    collect_submodules("agent")
    + collect_submodules("uvicorn")
    + collect_submodules("dashscope")
    + collect_submodules("openai")
)
datas = copy_metadata("dashscope") + copy_metadata("openai")

a = Analysis(
    ["main.py"],
    pathex=[SPECPATH],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="knowledge-agent",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
)
