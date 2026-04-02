import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.routes import analytics, health, invoices, jobs, upload
from app.utils.logging import get_logger, setup_logging

log = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    try:
        get_settings()
    except Exception as e:
        log.warning("Config validation warning on startup: %s", e)
    yield


def create_app() -> FastAPI:
    fe = os.environ.get("FRONTEND_URL", "http://localhost:5173").rstrip("/")
    origins = {
        fe,
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    }
    if "localhost" in fe:
        origins.add(fe.replace("localhost", "127.0.0.1"))
    if "127.0.0.1" in fe:
        origins.add(fe.replace("127.0.0.1", "localhost"))

    app = FastAPI(title="Invoice Extraction API", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=sorted(origins),
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(Exception)
    async def unhandled(_: Request, exc: Exception) -> JSONResponse:
        log.exception("Unhandled error: %s", exc)
        return JSONResponse(status_code=500, content={"detail": "Internal server error"})

    @app.exception_handler(RequestValidationError)
    async def validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(status_code=422, content={"detail": exc.errors()})

    app.include_router(health.router)
    app.include_router(upload.router)
    app.include_router(invoices.router)
    app.include_router(jobs.router)
    app.include_router(analytics.router)
    return app


app = create_app()
