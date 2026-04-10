"""
XAUUSD AI Prediction API
========================
FastAPI server that loads ai_model.pkl and serves predictions.

Endpoints:
  POST /predict   — main prediction endpoint for MT5 EA
  GET  /health    — health check
  GET  /metrics   — recent prediction stats

Run locally:
  uvicorn predict_api:app --host 0.0.0.0 --port 8000 --reload

Deploy on Render/Railway: see README.md
"""

import os
import pickle
import logging
import time
from datetime import datetime
from collections import deque
from typing import Optional

import numpy as np
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, validator

# ─────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("xauusd_api")

# ─────────────────────────────────────────────
# Feature definition (must match train_model.py)
# ─────────────────────────────────────────────
FEATURE_COLS = [
    "ema50",
    "ema200",
    "atr",
    "breakout_strength",
    "fvg",
    "candle_pattern",
    "session",
    "ema_diff",
    "price_vs_ema200",
]

# ─────────────────────────────────────────────
# App setup
# ─────────────────────────────────────────────
app = FastAPI(
    title="XAUUSD AI Trading API",
    description="Smart Money + AI prediction server for Gold M15",
    version="2.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─────────────────────────────────────────────
# Model loading
# ─────────────────────────────────────────────
MODEL_PATH  = os.getenv("MODEL_PATH",  "ai_model.pkl")
SCALER_PATH = os.getenv("SCALER_PATH", "scaler.pkl")

model  = None
scaler = None

def load_artifacts():
    global model, scaler
    try:
        with open(MODEL_PATH, "rb") as f:
            model = pickle.load(f)
        logger.info(f"Model loaded from {MODEL_PATH}")
    except FileNotFoundError:
        logger.warning(f"{MODEL_PATH} not found — run train_model.py first")
        model = None

    try:
        with open(SCALER_PATH, "rb") as f:
            scaler = pickle.load(f)
        logger.info(f"Scaler loaded from {SCALER_PATH}")
    except FileNotFoundError:
        logger.warning(f"{SCALER_PATH} not found")
        scaler = None

load_artifacts()

# ─────────────────────────────────────────────
# Recent prediction log (in-memory ring buffer)
# ─────────────────────────────────────────────
recent_preds: deque = deque(maxlen=200)

# ─────────────────────────────────────────────
# Request / Response schemas
# ─────────────────────────────────────────────
class PredictRequest(BaseModel):
    ema50:              float  = Field(...,  description="EMA 50 value (M15)")
    ema200:             float  = Field(...,  description="EMA 200 value (M15)")
    atr:                float  = Field(...,  description="ATR(14) value")
    breakout_strength:  float  = Field(0.0, description="Breakout magnitude in ATR units")
    fvg:                int    = Field(0,   description="FVG present: 1=yes, 0=no")
    candle_pattern:     int    = Field(5,   description="Candle body ratio encoded 1–10")
    session:            int    = Field(1,   description="Active session: 1=yes, 0=no")
    direction:          int    = Field(1,   description="Proposed direction: 1=BUY, -1=SELL")
    price:              Optional[float] = Field(None, description="Current bid/ask price")
    symbol:             Optional[str]   = Field("XAUUSD", description="Symbol")
    timestamp:          Optional[str]   = Field(None, description="ISO timestamp from MT5")

    @validator("fvg")
    def fvg_binary(cls, v):
        return int(bool(v))

    @validator("atr")
    def atr_positive(cls, v):
        if v <= 0:
            raise ValueError("ATR must be positive")
        return v


class PredictResponse(BaseModel):
    confidence: float
    decision:   str
    direction:  int
    model_ver:  str = "2.0"
    timestamp:  str


# ─────────────────────────────────────────────
# Feature engineering helper (mirrors training)
# ─────────────────────────────────────────────
def build_feature_vector(req: PredictRequest) -> np.ndarray:
    price = req.price if req.price else req.ema200
    ema_diff        = req.ema50 - req.ema200
    price_vs_ema200 = (price - req.ema200) / max(req.atr, 1e-6)

    vector = [
        req.ema50,
        req.ema200,
        req.atr,
        req.breakout_strength,
        req.fvg,
        req.candle_pattern,
        req.session,
        np.clip(ema_diff,        -10, 10),
        np.clip(price_vs_ema200, -10, 10),
    ]
    return np.array(vector, dtype=np.float32).reshape(1, -1)


# ─────────────────────────────────────────────
# Middleware: request timing
# ─────────────────────────────────────────────
@app.middleware("http")
async def add_timing(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = (time.perf_counter() - start) * 1000
    response.headers["X-Process-Time-Ms"] = f"{elapsed:.1f}"
    return response


# ─────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────
@app.get("/health")
def health():
    return {
        "status":     "ok",
        "model_loaded": model is not None,
        "scaler_loaded": scaler is not None,
        "timestamp":  datetime.utcnow().isoformat(),
    }


@app.get("/metrics")
def metrics():
    if not recent_preds:
        return {"message": "No predictions yet"}

    confs = [p["confidence"] for p in recent_preds]
    buys  = sum(1 for p in recent_preds if p["decision"] == "BUY")
    sells = sum(1 for p in recent_preds if p["decision"] == "SELL")
    return {
        "total_predictions": len(recent_preds),
        "buy_count":   buys,
        "sell_count":  sells,
        "avg_confidence": round(float(np.mean(confs)), 4),
        "max_confidence": round(float(np.max(confs)), 4),
        "min_confidence": round(float(np.min(confs)), 4),
        "high_conf_trades": sum(1 for c in confs if c >= 0.70),
        "last_prediction":  recent_preds[-1],
    }


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    if model is None or scaler is None:
        raise HTTPException(
            status_code=503,
            detail="Model not loaded. Run train_model.py and restart the API."
        )

    try:
        X = build_feature_vector(req)
        X_sc = scaler.transform(X)

        # Probability of BUY (class 1)
        prob = model.predict_proba(X_sc)[0]
        buy_prob  = float(prob[1]) if len(prob) > 1 else float(prob[0])
        sell_prob = 1.0 - buy_prob

        # Apply direction weighting
        # If MT5 proposes BUY, use buy_prob; if SELL, use sell_prob
        if req.direction == 1:
            confidence = buy_prob
            decision   = "BUY" if buy_prob >= 0.5 else "NO_TRADE"
        else:
            confidence = sell_prob
            decision   = "SELL" if sell_prob >= 0.5 else "NO_TRADE"

        # Clip to valid range
        confidence = round(min(max(confidence, 0.0), 1.0), 4)

        now = datetime.utcnow().isoformat()

        # Log prediction
        entry = {
            "timestamp":  now,
            "symbol":     req.symbol,
            "direction":  req.direction,
            "confidence": confidence,
            "decision":   decision,
            "ema_diff":   round(req.ema50 - req.ema200, 4),
            "atr":        round(req.atr, 4),
            "fvg":        req.fvg,
        }
        recent_preds.append(entry)
        logger.info(f"PRED | {req.symbol} | dir={req.direction} | "
                    f"conf={confidence:.4f} | dec={decision}")

        return PredictResponse(
            confidence=confidence,
            decision=decision,
            direction=req.direction,
            timestamp=now,
        )

    except Exception as exc:
        logger.error(f"Prediction error: {exc}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/reload-model")
def reload_model():
    """Reload model artifacts without restarting (useful after retraining)."""
    load_artifacts()
    return {"status": "reloaded", "model_loaded": model is not None}


# ─────────────────────────────────────────────
# Main (for local run)
# ─────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8000))
    uvicorn.run("predict_api:app", host="0.0.0.0", port=port, reload=True)
