"""Development entry point for the local knowledge service."""

import os

import uvicorn

from agent.main import API_VERSION, SERVICE_VERSION, app


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8766")))
