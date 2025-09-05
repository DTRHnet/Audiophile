from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.staticfiles import StaticFiles

from .db import Base, engine


APP_DIR = Path(__file__).resolve().parent
SERVER_DIR = APP_DIR.parent
STATIC_DIR = SERVER_DIR / "static"
DATA_DIR = SERVER_DIR / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)


def create_app() -> FastAPI:
    application = FastAPI(
        title="Audiophile Server",
        version=os.getenv("APP_VERSION", "0.1.0"),
        openapi_url="/v1/openapi.json",
        docs_url="/v1/docs",
        redoc_url="/v1/redoc",
    )

    # CORS for local development and self-hosted clients
    application.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @application.on_event("startup")
    def on_startup() -> None:
        Base.metadata.create_all(bind=engine)

    # Routers
    from .routers.sessions import router as sessions_router
    from .routers.uploads import router as uploads_router
    from .routers.transcripts import router as transcripts_router

    application.include_router(sessions_router, prefix="/v1", tags=["sessions"])
    application.include_router(uploads_router, prefix="/v1", tags=["uploads"])
    application.include_router(transcripts_router, prefix="/v1", tags=["transcripts"])

    # Serve static web client at /app
    if STATIC_DIR.exists():
        application.mount("/app", StaticFiles(directory=str(STATIC_DIR), html=True), name="app")

    @application.get("/v1/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return application


app = create_app()

