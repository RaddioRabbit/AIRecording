"""FastAPI entry point for the local knowledge service."""

from __future__ import annotations

import inspect
import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse

from agent.answering import OpenAICompatibleChatCompletionClient, StrictAnswerService
from agent.chunker import SegmentChunker
from agent.config import KnowledgeConfig
from agent.context import EvidenceContextBuilder
from agent.embedding import DashScopeAdapter
from agent.ingestion import RecordingIngestionService
from agent.observability import log_event
from agent.retrieval import HybridRetriever
from agent.schema import (
    KnowledgeOperationResponse,
    KnowledgeQueryRequest,
    KnowledgeStatusResponse,
    KnowledgeStreamEvent,
    RecordingUpsertRequest,
    RecordingUpsertResponse,
)
from agent.store import KnowledgeStore


API_VERSION = "1.0"
SERVICE_VERSION = "1.1.0"
RETRY_INTERVAL_SECONDS = 5.0
RETRY_BATCH_SIZE = 100


class MaintenanceGate:
    """Cancellation-safe async reader/writer gate for index maintenance."""
    def __init__(self) -> None:
        self._condition = asyncio.Condition()
        self._readers = 0
        self._writer = False
        self._waiting_writers = 0

    async def _acquire_read(self) -> None:
        async with self._condition:
            while self._writer or self._waiting_writers:
                await self._condition.wait()
            self._readers += 1

    async def _release_read(self) -> None:
        async with self._condition:
            self._readers -= 1
            if self._readers == 0:
                self._condition.notify_all()

    async def _acquire_write(self) -> None:
        async with self._condition:
            self._waiting_writers += 1
            try:
                while self._writer or self._readers:
                    await self._condition.wait()
                self._writer = True
            finally:
                self._waiting_writers -= 1
                self._condition.notify_all()

    async def _release_write(self) -> None:
        async with self._condition:
            self._writer = False
            self._condition.notify_all()

    @asynccontextmanager
    async def shared(self) -> AsyncIterator[None]:
        await self._acquire_read()
        try:
            yield
        finally:
            await self._release_read()

    @asynccontextmanager
    async def exclusive(self) -> AsyncIterator[None]:
        await self._acquire_write()
        try:
            yield
        finally:
            await self._release_write()


async def _retry_worker(application: FastAPI, stop: asyncio.Event) -> None:
    """Bounded local recovery loop. It only claims due vector jobs."""
    while not stop.is_set():
        try:
            async with application.state.maintenance_gate.shared():
                await application.state.ingestion_service.retry_missing_embeddings(limit=RETRY_BATCH_SIZE)
        except asyncio.CancelledError:
            raise
        except Exception:
            log_event("embedding_retry_failed", level="error", error_code="EMBEDDING_RETRY_FAILED")
        try:
            await asyncio.wait_for(stop.wait(), timeout=RETRY_INTERVAL_SECONDS)
        except TimeoutError:
            pass


@asynccontextmanager
async def lifespan(application: FastAPI) -> AsyncIterator[None]:
    """Set up real local services only when the launcher supplied a DB path."""
    store: KnowledgeStore | None = None
    retry_stop: asyncio.Event | None = None
    retry_task: asyncio.Task[None] | None = None
    try:
        config = KnowledgeConfig.from_environment()
        store = KnowledgeStore(config.db_path)
        adapter = DashScopeAdapter(
            embedding_model=config.embedding_model,
            embedding_dimension=config.embedding_dimension,
            rerank_model=config.rerank_model,
            embedding_provider=config.embedding_provider,
            rerank_provider=config.rerank_provider,
            embedding_base_url=config.embedding_base_url,
            rerank_base_url=config.rerank_base_url,
        )
        application.state.store = store
        application.state.ingestion_service = RecordingIngestionService(
            store, adapter, SegmentChunker(
                retrieval_size=config.retrieval_chunk_size,
                retrieval_overlap=config.retrieval_chunk_overlap,
                generation_size=config.generation_chunk_size,
                generation_overlap=config.generation_chunk_overlap,
            )
        )
        application.state.retriever = HybridRetriever(store, adapter, adapter)
        application.state.context_builder = EvidenceContextBuilder(store)
        application.state.answer_service = StrictAnswerService(OpenAICompatibleChatCompletionClient())
        retry_stop = asyncio.Event()
        retry_task = asyncio.create_task(_retry_worker(application, retry_stop))
    except KeyError:
        # Health must remain available so Swift can present a setup error safely.
        pass
    try:
        yield
    finally:
        if retry_stop is not None:
            retry_stop.set()
        if retry_task is not None:
            retry_task.cancel()
            try:
                await retry_task
            except asyncio.CancelledError:
                pass
        if store is not None:
            store.close()


app = FastAPI(lifespan=lifespan)
app.state.maintenance_gate = MaintenanceGate()


@app.exception_handler(RequestValidationError)
async def request_validation_error(_: Request, __: RequestValidationError) -> JSONResponse:
    """Never reflect validation details because they may contain user transcript text."""
    return JSONResponse(status_code=422, content={"detail": "INVALID_REQUEST"})


def get_ingestion_service() -> RecordingIngestionService:
    return app.state.ingestion_service


def get_retriever() -> HybridRetriever:
    return app.state.retriever


def get_answer_service() -> Any:
    return app.state.answer_service


def get_context_builder() -> EvidenceContextBuilder:
    return app.state.context_builder


def get_store() -> KnowledgeStore:
    return app.state.store


def get_maintenance_gate() -> MaintenanceGate:
    return app.state.maintenance_gate


def _service_unavailable() -> HTTPException:
    return HTTPException(status_code=503, detail="KNOWLEDGE_UNAVAILABLE")


def _event(event: str, request_id: str, data: dict[str, Any]) -> bytes:
    envelope = KnowledgeStreamEvent(event=event, requestId=request_id, data=data)
    return f"event: {event}\ndata: {envelope.model_dump_json()}\n\n".encode("utf-8")


async def _invoke(value: Any) -> Any:
    return await value if inspect.isawaitable(value) else value


@app.get("/health")
def health() -> dict[str, str | int]:
    return {
        "status": "ok",
        "apiVersion": API_VERSION,
        "serviceVersion": SERVICE_VERSION,
        "indexVersion": 1,
    }


@app.get("/knowledge/status", response_model=KnowledgeStatusResponse)
async def knowledge_status() -> KnowledgeStatusResponse:
    try:
        async with get_maintenance_gate().shared():
            status = await asyncio.to_thread(get_store().status)
    except AttributeError as error:
        raise _service_unavailable() from error
    except Exception:
        log_event("status_failed", level="error", error_code="STATUS_FAILED")
        raise HTTPException(status_code=500, detail="STATUS_FAILED") from None
    return KnowledgeStatusResponse(
        documents=status.documents,
        chunks=status.chunks,
        pendingJobs=status.pending_jobs,
        failedJobs=status.failed_jobs,
        degraded=status.degraded,
    )


@app.put("/knowledge/recordings/{recording_id}", response_model=RecordingUpsertResponse)
async def upsert_recording(recording_id: str, payload: RecordingUpsertRequest) -> RecordingUpsertResponse:
    if recording_id != payload.recordingId:
        raise HTTPException(status_code=400, detail="RECORDING_ID_MISMATCH")
    try:
        async with get_maintenance_gate().shared():
            result = await get_ingestion_service().upsert(payload)
    except AttributeError as error:
        raise _service_unavailable() from error
    except (ValueError, KeyError):
        raise HTTPException(status_code=400, detail="INVALID_RECORDING") from None
    except Exception:
        log_event("recording_upsert_failed", level="error", recording_id=recording_id, error_code="INDEX_FAILED")
        raise HTTPException(status_code=500, detail="INDEX_FAILED") from None
    return result


@app.delete("/knowledge/recordings/{recording_id}", response_model=KnowledgeOperationResponse)
async def delete_recording(recording_id: str) -> KnowledgeOperationResponse:
    try:
        async with get_maintenance_gate().shared():
            result = get_ingestion_service().delete(recording_id)
            await _invoke(result)
    except AttributeError as error:
        raise _service_unavailable() from error
    except Exception:
        log_event("recording_delete_failed", level="error", recording_id=recording_id, error_code="DELETE_FAILED")
        raise HTTPException(status_code=500, detail="DELETE_FAILED") from None
    return KnowledgeOperationResponse(status="ok", affected=1)


@app.post("/knowledge/retry-failed", response_model=KnowledgeOperationResponse)
async def retry_failed() -> KnowledgeOperationResponse:
    try:
        async with get_maintenance_gate().shared():
            service = get_ingestion_service()
            requeue = getattr(service, "retry_failed", None)
            if requeue is None:
                await asyncio.to_thread(get_store().retry_failed_jobs)
            else:
                await _invoke(requeue())
            retry = getattr(service, "retry_missing_embeddings", None)
            affected = 0 if retry is None else await _invoke(retry())
    except AttributeError as error:
        raise _service_unavailable() from error
    except Exception:
        log_event("retry_failed", level="error", error_code="RETRY_FAILED")
        raise HTTPException(status_code=500, detail="RETRY_FAILED") from None
    return KnowledgeOperationResponse(status="ok", affected=max(0, int(affected or 0)))


@app.post("/knowledge/reset-index", response_model=KnowledgeOperationResponse)
async def reset_index() -> KnowledgeOperationResponse:
    try:
        async with get_maintenance_gate().exclusive():
            await asyncio.to_thread(get_store().reset_index)
    except AttributeError as error:
        raise _service_unavailable() from error
    except Exception:
        log_event("index_reset_failed", level="error", error_code="RESET_FAILED")
        raise HTTPException(status_code=500, detail="RESET_FAILED") from None
    return KnowledgeOperationResponse(status="ok", affected=0)


@app.post("/knowledge/query")
async def query_knowledge(request: Request, payload: KnowledgeQueryRequest) -> StreamingResponse:
    async def stream() -> AsyncIterator[bytes]:
        try:
            async with get_maintenance_gate().shared():
                request_id = str(payload.requestId)
                if await request.is_disconnected():
                    return
                yield _event("retrieval_started", request_id, {})
                if await request.is_disconnected():
                    return
                history_text = ""
                for message in reversed(payload.history):
                    if message.role == "user" and message.content.strip():
                        history_text = message.content.strip()
                        break
                retrieval = await get_retriever().retrieve(payload.query, history_text)
                if await request.is_disconnected():
                    return
                builder = get_context_builder()
                evidence = (
                    builder.build_direct(retrieval.chunks)
                    if retrieval.briefing
                    else builder.build(retrieval.chunks)
                )
                yield _event("sources", request_id, {
                    "sources": [source.model_dump(mode="json") for source in evidence.sources],
                    "strategy": retrieval.strategy,
                })
                if await request.is_disconnected():
                    return
                answer = await get_answer_service().answer(payload.query, evidence, payload.history)
                if await request.is_disconnected():
                    return
                yield _event("answer_delta", request_id, {"content": answer.content})
                yield _event("answer_completed", request_id, {
                    "content": answer.content,
                    "sources": [source.model_dump(mode="json") for source in answer.sources],
                })
        except (AttributeError, KeyError):
            yield _event("error", str(payload.requestId), {"code": "KNOWLEDGE_UNAVAILABLE"})
        except Exception:
            log_event("query_failed", level="error", correlation_id=str(payload.requestId), error_code="QUERY_FAILED")
            yield _event("error", str(payload.requestId), {"code": "QUERY_FAILED"})

    return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})
