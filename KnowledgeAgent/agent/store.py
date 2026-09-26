"""SQLite persistence for the local recording knowledge index."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, replace
from functools import wraps
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence

import numpy as np

from agent.chunker import KnowledgeChunk
from agent.schema import RecordingUpsertRequest


RETRY_DELAYS_SECONDS = (5, 30, 120)
EMBEDDING_LEASE_SECONDS = 60


def _serialized(method):
    """Keep a shared SQLite connection transaction-safe across FastAPI threads."""
    @wraps(method)
    def wrapped(self: "KnowledgeStore", *args, **kwargs):
        with self._connection_lock:
            return method(self, *args, **kwargs)
    return wrapped


@dataclass(frozen=True)
class StoredChunk:
    id: str
    recording_id: str
    role: str
    content: str
    chunk_index: int
    parent_id: str | None
    segment_ids: tuple[str, ...]
    start_time: float | None
    end_time: float | None
    speaker_id: str | None
    speaker_name: str | None
    enabled: bool
    embedding: bytes | None
    embedding_dimension: int | None
    lease_id: str | None = None


@dataclass(frozen=True)
class SearchHit:
    chunk: StoredChunk
    score: float


@dataclass(frozen=True)
class StoreStatus:
    documents: int
    chunks: int
    pending_jobs: int
    failed_jobs: int = 0
    degraded: bool = False


class KnowledgeStore:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._connection_lock = threading.RLock()
        self.connection: sqlite3.Connection
        self.initialize()

    @_serialized
    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        # FastAPI's synchronous endpoints run in a worker thread. Access is still
        # serialized by each transaction, but the connection must be portable.
        self.connection = sqlite3.connect(self.path, check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.executescript("""
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                recording_id TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                summary_hash TEXT NOT NULL,
                index_version INTEGER NOT NULL,
                title TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS documents_recording ON documents(recording_id);
            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT NOT NULL,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                recording_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('generation', 'retrieval', 'summary_route')),
                content TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                parent_id TEXT,
                segment_ids TEXT NOT NULL,
                start_time REAL,
                end_time REAL,
                speaker_id TEXT,
                speaker_name TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                embedding BLOB,
                embedding_dimension INTEGER,
                PRIMARY KEY (document_id, id)
            );
            CREATE INDEX IF NOT EXISTS chunks_recording ON chunks(recording_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
                chunk_id UNINDEXED, document_id UNINDEXED, content, recording_id UNINDEXED, role UNINDEXED
            );
            CREATE TABLE IF NOT EXISTS sync_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recording_id TEXT NOT NULL,
                chunk_id TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                error_code TEXT,
                next_retry_at REAL,
                lease_until REAL,
                lease_id TEXT,
                UNIQUE(recording_id, chunk_id)
            );
            CREATE TABLE IF NOT EXISTS recording_versions (
                recording_id TEXT PRIMARY KEY,
                version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS recording_tombstones (
                recording_id TEXT PRIMARY KEY
            );
        """)
        columns = {row[1] for row in self.connection.execute("PRAGMA table_info(sync_jobs)")}
        if "next_retry_at" not in columns:
            self.connection.execute("ALTER TABLE sync_jobs ADD COLUMN next_retry_at REAL")
        if "lease_until" not in columns:
            self.connection.execute("ALTER TABLE sync_jobs ADD COLUMN lease_until REAL")
        if "lease_id" not in columns:
            self.connection.execute("ALTER TABLE sync_jobs ADD COLUMN lease_id TEXT")
        self.connection.commit()
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    @_serialized
    def get_document_hashes(self, recording_id: str) -> tuple[str, str, int] | None:
        row = self.connection.execute(
            "SELECT content_hash, summary_hash, index_version FROM documents "
            "WHERE recording_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", (recording_id,)
        ).fetchone()
        return None if row is None else (row["content_hash"], row["summary_hash"], row["index_version"])

    @_serialized
    def recording_version(self, recording_id: str) -> int:
        row = self.connection.execute(
            "SELECT version FROM recording_versions WHERE recording_id = ?", (recording_id,)
        ).fetchone()
        return 0 if row is None else int(row["version"])

    @_serialized
    def is_recording_deleted(self, recording_id: str) -> bool:
        return self.connection.execute(
            "SELECT 1 FROM recording_tombstones WHERE recording_id = ?", (recording_id,)
        ).fetchone() is not None

    def _normalised_vector(self, value: np.ndarray | None) -> tuple[bytes | None, int | None]:
        if value is None:
            return None, None
        vector = np.asarray(value, dtype=np.float32).reshape(-1)
        if vector.size == 0 or not np.isfinite(vector).all():
            return None, None
        norm = float(np.linalg.norm(vector))
        if not np.isfinite(norm) or norm == 0:
            return None, None
        vector = vector / norm
        return vector.tobytes(), int(vector.size)

    def _insert_chunks(self, document_id: str, request: RecordingUpsertRequest,
                       chunks: Sequence[KnowledgeChunk], embeddings: Mapping[str, np.ndarray | None]) -> None:
        failure_time = time.time()
        for chunk in chunks:
            vector, dimension = self._normalised_vector(embeddings.get(chunk.id)) if chunk.role in (
                "retrieval", "summary_route"
            ) else (None, None)
            self.connection.execute(
                "INSERT INTO chunks (id, document_id, recording_id, role, content, chunk_index, parent_id, "
                "segment_ids, start_time, end_time, speaker_id, speaker_name, embedding, embedding_dimension) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (chunk.id, document_id, request.recordingId, chunk.role, chunk.content, chunk.chunk_index,
                 chunk.parent_id, json.dumps(chunk.segment_ids), chunk.start_time, chunk.end_time,
                 chunk.speaker_id, chunk.speaker_name, vector, dimension),
            )
            if chunk.role in ("retrieval", "summary_route"):
                self.connection.execute(
                    "INSERT INTO chunk_fts (chunk_id, document_id, content, recording_id, role) VALUES (?, ?, ?, ?, ?)",
                    (chunk.id, document_id, chunk.content, request.recordingId, chunk.role),
                )
            if chunk.role in ("retrieval", "summary_route") and chunk.id in embeddings and vector is None:
                self.connection.execute(
                    "INSERT OR IGNORE INTO sync_jobs (recording_id, chunk_id) VALUES (?, ?)",
                    (request.recordingId, chunk.id),
                )
                self._record_embedding_failure(
                    request.recordingId, chunk.id, "EMBEDDING_UNAVAILABLE", failure_time, require_lease=False
                )

    @_serialized
    def replace_recording(self, request: RecordingUpsertRequest, chunks: Sequence[KnowledgeChunk],
                          embeddings: Mapping[str, np.ndarray | None]) -> None:
        new_document_id = uuid.uuid4().hex
        self.connection.execute("BEGIN")
        try:
            self.connection.execute(
                "INSERT INTO documents (id, recording_id, content_hash, summary_hash, index_version, title, recorded_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (new_document_id, request.recordingId, request.contentHash, request.summaryHash,
                 request.indexVersion, request.title, request.recordedAt.astimezone(timezone.utc).isoformat()),
            )
            # Jobs describe the current document version.  The deletion is transactional,
            # so a failed replacement restores the old recovery work as well.
            self.connection.execute("DELETE FROM sync_jobs WHERE recording_id = ?", (request.recordingId,))
            self._insert_chunks(new_document_id, request, chunks, embeddings)
            old_ids = [row[0] for row in self.connection.execute(
                "SELECT id FROM documents WHERE recording_id = ? AND id != ?", (request.recordingId, new_document_id)
            )]
            if old_ids:
                placeholders = ",".join("?" for _ in old_ids)
                self.connection.execute(f"DELETE FROM chunk_fts WHERE document_id IN ({placeholders})", old_ids)
                self.connection.execute(f"DELETE FROM documents WHERE id IN ({placeholders})", old_ids)
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise

    @_serialized
    def replace_summary(self, request: RecordingUpsertRequest, chunks: Sequence[KnowledgeChunk],
                        embeddings: Mapping[str, np.ndarray | None]) -> None:
        self.connection.execute("BEGIN")
        try:
            document = self._current_document_id(request.recordingId)
            if document is None:
                raise KeyError(request.recordingId)
            self.connection.execute(
                "DELETE FROM sync_jobs WHERE recording_id = ? AND chunk_id IN "
                "(SELECT id FROM chunks WHERE document_id = ? AND role = 'summary_route')",
                (request.recordingId, document),
            )
            self.connection.execute(
                "DELETE FROM chunk_fts WHERE document_id = ? AND role = 'summary_route'", (document,)
            )
            self.connection.execute("DELETE FROM chunks WHERE document_id = ? AND role = 'summary_route'", (document,))
            self._insert_chunks(document, request, chunks, embeddings)
            self.connection.execute(
                "UPDATE documents SET summary_hash = ?, title = ?, recorded_at = ? WHERE id = ?",
                (request.summaryHash, request.title, request.recordedAt.astimezone(timezone.utc).isoformat(), document),
            )
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise

    def _current_document_id(self, recording_id: str) -> str | None:
        row = self.connection.execute(
            "SELECT id FROM documents WHERE recording_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", (recording_id,)
        ).fetchone()
        return None if row is None else str(row[0])

    @_serialized
    def delete_recording(self, recording_id: str) -> None:
        self.connection.execute("BEGIN")
        try:
            self.connection.execute(
                "INSERT INTO recording_versions (recording_id, version) VALUES (?, 1) "
                "ON CONFLICT(recording_id) DO UPDATE SET version = version + 1",
                (recording_id,),
            )
            self.connection.execute(
                "INSERT OR IGNORE INTO recording_tombstones (recording_id) VALUES (?)", (recording_id,)
            )
            self.connection.execute("DELETE FROM chunk_fts WHERE recording_id = ?", (recording_id,))
            self.connection.execute("DELETE FROM sync_jobs WHERE recording_id = ?", (recording_id,))
            self.connection.execute("DELETE FROM documents WHERE recording_id = ?", (recording_id,))
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise

    @_serialized
    def chunks_for_recording(self, recording_id: str) -> list[StoredChunk]:
        rows = self.connection.execute(
            "SELECT * FROM chunks WHERE recording_id = ? AND enabled = 1 ORDER BY role, chunk_index", (recording_id,)
        ).fetchall()
        return [self._stored_chunk(row) for row in rows]

    @_serialized
    def search_fts(self, query: str, roles: tuple[str, ...], limit: int,
                   recording_ids: tuple[str, ...] = ()) -> list[SearchHit]:
        return self._search_fts_rows(query, roles, limit, recording_ids)

    def _search_fts_rows(self, query: str, roles: tuple[str, ...], limit: int,
                         recording_ids: tuple[str, ...]) -> list[SearchHit]:
        if not query.strip() or not roles or limit <= 0:
            return []
        role_clause = ",".join("?" for _ in roles)
        filters = [f"c.role IN ({role_clause})", "c.enabled = 1"]
        parameters: list[object] = [query, *roles]
        if recording_ids:
            recording_clause = ",".join("?" for _ in recording_ids)
            filters.append(f"c.recording_id IN ({recording_clause})")
            parameters.extend(recording_ids)
        parameters.append(limit)
        try:
            rows = self.connection.execute(
                "SELECT c.*, bm25(chunk_fts) AS rank FROM chunk_fts "
                "JOIN chunks c ON c.id = chunk_fts.chunk_id AND c.document_id = chunk_fts.document_id "
                f"WHERE chunk_fts MATCH ? AND {' AND '.join(filters)} ORDER BY rank ASC, c.id ASC LIMIT ?",
                parameters,
            ).fetchall()
        except sqlite3.OperationalError:
            return []
        return [SearchHit(self._stored_chunk(row), -float(row["rank"])) for row in rows]

    @_serialized
    def search_vector(self, vector: np.ndarray, roles: tuple[str, ...], limit: int,
                      recording_ids: tuple[str, ...] = ()) -> list[SearchHit]:
        return self._search_vector_rows(vector, roles, limit, recording_ids)

    def _search_vector_rows(self, vector: np.ndarray, roles: tuple[str, ...], limit: int,
                            recording_ids: tuple[str, ...]) -> list[SearchHit]:
        if not roles or limit <= 0:
            return []
        try:
            query_vector = np.asarray(vector, dtype=np.float32).reshape(-1)
        except (TypeError, ValueError):
            return []
        if query_vector.size == 0 or not np.isfinite(query_vector).all():
            return []
        norm = float(np.linalg.norm(query_vector))
        if not np.isfinite(norm) or norm == 0:
            return []
        query_vector = query_vector / norm
        role_clause = ",".join("?" for _ in roles)
        filters = [f"role IN ({role_clause})", "enabled = 1", "embedding IS NOT NULL", "embedding_dimension = ?"]
        parameters: list[object] = [*roles, int(query_vector.size)]
        if recording_ids:
            recording_clause = ",".join("?" for _ in recording_ids)
            filters.append(f"recording_id IN ({recording_clause})")
            parameters.extend(recording_ids)
        rows = self.connection.execute(
            f"SELECT * FROM chunks WHERE {' AND '.join(filters)} ORDER BY id ASC", parameters
        ).fetchall()
        chunks: list[StoredChunk] = []
        vectors: list[np.ndarray] = []
        for row in rows:
            stored = self._stored_chunk(row)
            candidate = np.frombuffer(stored.embedding, dtype=np.float32)
            if candidate.size != query_vector.size or not np.isfinite(candidate).all():
                continue
            chunks.append(stored)
            vectors.append(candidate)
        if not vectors:
            return []
        scores = np.vstack(vectors) @ query_vector
        order = np.argsort(-scores, kind="stable")[:limit]
        return [SearchHit(chunks[int(index)], float(scores[int(index)])) for index in order]

    @_serialized
    def generation_parents(self, parent_ids: Sequence[str]) -> dict[str, StoredChunk]:
        return self._fetch_generation_parents(parent_ids)

    def _fetch_generation_parents(self, parent_ids: Sequence[str]) -> dict[str, StoredChunk]:
        unique = tuple(dict.fromkeys(parent_ids))
        if not unique:
            return {}
        placeholders = ",".join("?" for _ in unique)
        rows = self.connection.execute(
            f"SELECT * FROM chunks WHERE id IN ({placeholders}) AND role = 'generation' AND enabled = 1", unique
        ).fetchall()
        return {chunk.id: chunk for chunk in (self._stored_chunk(row) for row in rows)}

    @_serialized
    def recording_ids_by_recency(self, order: str, limit: int) -> tuple[str, ...]:
        """Recording ids by calendar date; recorded_at is UTC ISO text so lexical order is chronological."""
        if limit <= 0 or order not in ("asc", "desc"):
            return ()
        direction = "DESC" if order == "desc" else "ASC"
        rows = self.connection.execute(
            f"SELECT recording_id FROM documents "
            f"ORDER BY recorded_at {direction}, created_at {direction}, rowid {direction} LIMIT ?",
            (limit,),
        ).fetchall()
        return tuple(dict.fromkeys(str(row["recording_id"]) for row in rows))

    @_serialized
    def sample_generation_parents(self, recording_ids: tuple[str, ...],
                                  per_recording: int) -> list[StoredChunk]:
        """Evenly sample generation parents per recording; the first chunk is always included."""
        if not recording_ids or per_recording <= 0:
            return []
        sampled: list[StoredChunk] = []
        for recording_id in recording_ids:
            rows = self.connection.execute(
                "SELECT * FROM chunks WHERE recording_id = ? AND role = 'generation' AND enabled = 1 "
                "ORDER BY chunk_index ASC, id ASC", (recording_id,),
            ).fetchall()
            total = len(rows)
            if total == 0:
                continue
            if total <= per_recording:
                indices = range(total)
            else:
                step = total / per_recording
                indices = sorted({min(total - 1, int(index * step)) for index in range(per_recording)})
            sampled.extend(self._stored_chunk(rows[index]) for index in indices)
        return sampled

    @_serialized
    def documents_meta(self, recording_ids: tuple[str, ...]) -> dict[str, tuple[str, str]]:
        """Latest title and LOCAL calendar date (YYYY-MM-DD) per recording id."""
        if not recording_ids:
            return {}
        placeholders = ",".join("?" for _ in recording_ids)
        rows = self.connection.execute(
            f"SELECT recording_id, title, recorded_at FROM documents "
            f"WHERE recording_id IN ({placeholders}) ORDER BY created_at DESC, rowid DESC",
            tuple(recording_ids),
        ).fetchall()
        meta: dict[str, tuple[str, str]] = {}
        for row in rows:
            local_date = datetime.fromisoformat(str(row["recorded_at"])).astimezone().strftime("%Y-%m-%d")
            meta.setdefault(str(row["recording_id"]), (str(row["title"]), local_date))
        return meta

    def _stored_chunk(self, row: sqlite3.Row) -> StoredChunk:
        return StoredChunk(
            id=row["id"], recording_id=row["recording_id"], role=row["role"], content=row["content"],
            chunk_index=row["chunk_index"], parent_id=row["parent_id"], segment_ids=tuple(json.loads(row["segment_ids"])),
            start_time=row["start_time"], end_time=row["end_time"], speaker_id=row["speaker_id"],
            speaker_name=row["speaker_name"], enabled=bool(row["enabled"]), embedding=row["embedding"],
            embedding_dimension=row["embedding_dimension"],
        )

    @_serialized
    def list_missing_embedding_chunks(self, limit: int = 100, now: float | None = None) -> list[StoredChunk]:
        retry_filter = ""
        parameters: list[object] = []
        if now is not None:
            retry_filter = " AND (sync_jobs.next_retry_at IS NULL OR sync_jobs.next_retry_at <= ?)"
            parameters.append(now)
        rows = self.connection.execute(
            "SELECT chunks.* FROM chunks JOIN sync_jobs ON chunks.id = sync_jobs.chunk_id "
            "AND chunks.recording_id = sync_jobs.recording_id WHERE sync_jobs.status = 'pending' "
            f"{retry_filter} ORDER BY sync_jobs.id LIMIT ?", (*parameters, limit),
        ).fetchall()
        return [self._stored_chunk(row) for row in rows]

    @_serialized
    def claim_due_embedding_chunks(self, limit: int = 100, now: float | None = None,
                                   lease_seconds: int = EMBEDDING_LEASE_SECONDS) -> list[StoredChunk]:
        """Atomically lease due jobs so concurrent recovery passes cannot duplicate calls."""
        current_time = time.time() if now is None else now
        self.connection.execute("BEGIN")
        try:
            self.connection.execute(
                "UPDATE sync_jobs SET status = 'pending', lease_until = NULL, lease_id = NULL "
                "WHERE status = 'leased' AND lease_until <= ?", (current_time,)
            )
            rows = self.connection.execute(
                "SELECT chunks.* FROM chunks JOIN sync_jobs ON chunks.id = sync_jobs.chunk_id "
                "AND chunks.recording_id = sync_jobs.recording_id WHERE sync_jobs.status = 'pending' "
                "AND (sync_jobs.next_retry_at IS NULL OR sync_jobs.next_retry_at <= ?) "
                "ORDER BY sync_jobs.id LIMIT ?", (current_time, limit),
            ).fetchall()
            claimed = [self._stored_chunk(row) for row in rows]
            claimed_with_leases: list[StoredChunk] = []
            for chunk in claimed:
                lease_id = uuid.uuid4().hex
                self.connection.execute(
                    "UPDATE sync_jobs SET status = 'leased', lease_until = ?, lease_id = ? "
                    "WHERE recording_id = ? AND chunk_id = ? AND status = 'pending'",
                    (current_time + max(1, lease_seconds), lease_id, chunk.recording_id, chunk.id),
                )
                claimed_with_leases.append(replace(chunk, lease_id=lease_id))
            self.connection.commit()
            return claimed_with_leases
        except Exception:
            self.connection.rollback()
            raise

    def _record_embedding_failure(self, recording_id: str, chunk_id: str, error_code: str,
                                  now: float, *, require_lease: bool, lease_id: str | None = None) -> int:
        row = self.connection.execute(
            "SELECT attempts, status, lease_id FROM sync_jobs WHERE recording_id = ? AND chunk_id = ?",
            (recording_id, chunk_id),
        ).fetchone()
        if row is None or (require_lease and (row["status"] != "leased" or row["lease_id"] != lease_id)):
            return 0
        attempts = int(row["attempts"]) + 1
        delay = RETRY_DELAYS_SECONDS[min(attempts - 1, len(RETRY_DELAYS_SECONDS) - 1)]
        status = "failed" if attempts > len(RETRY_DELAYS_SECONDS) else "pending"
        self.connection.execute(
            "UPDATE sync_jobs SET attempts = ?, status = ?, error_code = ?, next_retry_at = ?, lease_until = NULL, lease_id = NULL "
            "WHERE recording_id = ? AND chunk_id = ?" + (" AND lease_id = ?" if require_lease else ""),
            ((attempts, status, error_code, now + delay, recording_id, chunk_id, lease_id)
             if require_lease else (attempts, status, error_code, now + delay, recording_id, chunk_id)),
        )
        return attempts

    @_serialized
    def mark_embedding_failure(self, recording_id: str, chunk_id: str, error_code: str,
                               now: float) -> int:
        """Schedule provider-only retries without storing transcript payloads in jobs."""
        attempts = self._record_embedding_failure(recording_id, chunk_id, error_code, now, require_lease=False)
        self.connection.commit()
        return attempts

    @_serialized
    def mark_claimed_embedding_failure(self, recording_id: str, chunk_id: str, lease_id: str,
                                       error_code: str, now: float) -> int:
        attempts = self._record_embedding_failure(
            recording_id, chunk_id, error_code, now, require_lease=True, lease_id=lease_id
        )
        self.connection.commit()
        return attempts

    @_serialized
    def release_embedding_claim(self, recording_id: str, chunk_id: str, lease_id: str) -> bool:
        """Return only this worker's lease without consuming a retry attempt."""
        result = self.connection.execute(
            "UPDATE sync_jobs SET status = 'pending', lease_until = NULL, lease_id = NULL "
            "WHERE recording_id = ? AND chunk_id = ? AND status = 'leased' AND lease_id = ?",
            (recording_id, chunk_id, lease_id),
        )
        self.connection.commit()
        return bool(result.rowcount)

    @_serialized
    def complete_embedding(self, recording_id: str, chunk_id: str, embedding: np.ndarray,
                           lease_id: str | None = None) -> bool:
        vector, dimension = self._normalised_vector(embedding)
        if vector is None or dimension is None:
            return False
        self.connection.execute("BEGIN")
        try:
            result = self.connection.execute(
                "UPDATE chunks SET embedding = ?, embedding_dimension = ? WHERE recording_id = ? AND id = ? "
                "AND role IN ('retrieval', 'summary_route') AND EXISTS ("
                "SELECT 1 FROM sync_jobs WHERE recording_id = ? AND chunk_id = ? AND status = 'leased' "
                "AND lease_id = ?)",
                (vector, dimension, recording_id, chunk_id, recording_id, chunk_id, lease_id),
            )
            if result.rowcount:
                self.connection.execute(
                    "DELETE FROM sync_jobs WHERE recording_id = ? AND chunk_id = ? AND status = 'leased' AND lease_id = ?",
                    (recording_id, chunk_id, lease_id),
                )
            self.connection.commit()
            return bool(result.rowcount)
        except Exception:
            self.connection.rollback()
            raise

    @_serialized
    def retry_failed_jobs(self) -> int:
        result = self.connection.execute(
            "UPDATE sync_jobs SET status = 'pending', attempts = 0, error_code = NULL, next_retry_at = NULL, "
            "lease_until = NULL, lease_id = NULL "
            "WHERE status = 'failed'"
        )
        self.connection.commit()
        return max(0, result.rowcount)

    @property
    def backup_path(self) -> Path:
        return self.path.parent / "knowledge.sqlite.backup"

    @_serialized
    def backup_database(self, connection: sqlite3.Connection, backup_path: Path) -> None:
        """Copy only to the fixed sibling backup path, never a caller-selected path."""
        if backup_path != self.backup_path:
            raise ValueError("unsafe backup path")
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        with sqlite3.connect(backup_path) as destination:
            connection.backup(destination)
        try:
            os.chmod(backup_path, 0o600)
        except OSError:
            pass

    @_serialized
    def reset_index(self) -> None:
        """Reset atomically enough to restore the last known index on setup failure."""
        backup_path = self.backup_path
        self.backup_database(self.connection, backup_path)
        self.connection.close()
        try:
            for candidate in (self.path, self.path.with_name(self.path.name + "-wal"),
                              self.path.with_name(self.path.name + "-shm")):
                if candidate.exists():
                    candidate.unlink()
            self.initialize()
        except Exception:
            try:
                if hasattr(self, "connection"):
                    self.connection.close()
            except (AttributeError, sqlite3.Error):
                pass
            for candidate in (self.path, self.path.with_name(self.path.name + "-wal"),
                              self.path.with_name(self.path.name + "-shm")):
                if candidate.exists():
                    candidate.unlink()
            self.connection = sqlite3.connect(self.path, check_same_thread=False)
            with sqlite3.connect(backup_path) as source:
                source.backup(self.connection)
            self.connection.row_factory = sqlite3.Row
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA foreign_keys=ON")
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
            raise

    @_serialized
    def status(self) -> StoreStatus:
        documents = self.connection.execute("SELECT count(*) FROM documents").fetchone()[0]
        chunks = self.connection.execute("SELECT count(*) FROM chunks WHERE enabled = 1").fetchone()[0]
        pending = self.connection.execute(
            "SELECT count(*) FROM sync_jobs WHERE status IN ('pending', 'leased')"
        ).fetchone()[0]
        failed = self.connection.execute("SELECT count(*) FROM sync_jobs WHERE status = 'failed'").fetchone()[0]
        return StoreStatus(documents, chunks, pending, failed, pending > 0)

    @_serialized
    def close(self) -> None:
        self.connection.close()
