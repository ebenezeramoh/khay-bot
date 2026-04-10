"""
XAUUSD AI Trading Model — Training Script
==========================================
Features: EMA50, EMA200, ATR, breakout strength,
          FVG flag, candle pattern, session
Target:   Direction (BUY=1 / SELL=0)

Usage:
  pip install -r requirements.txt
  python train_model.py                  # generates ai_model.pkl + scaler.pkl
  python train_model.py --data trades.csv  # use your own CSV

Output CSVs from the MT5 EA are expected at:
  data/XAUUSD_AI_Log.csv
"""

import argparse
import os
import pickle
import warnings
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split, StratifiedKFold, cross_val_score
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import classification_report, confusion_matrix, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.utils import resample
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

warnings.filterwarnings("ignore")

FEATURE_COLS = [
    "ema50",
    "ema200",
    "atr",
    "breakout_strength",
    "fvg",
    "candle_pattern",
    "session",
    "ema_diff",          # derived: ema50 - ema200
    "price_vs_ema200",   # derived: (price - ema200) / atr
]

TARGET_COL = "direction"   # 1 = BUY, 0 = SELL / no trade


# ─────────────────────────────────────────────
# 1.  Data generation (synthetic) for demo
# ─────────────────────────────────────────────
def generate_synthetic_data(n_samples: int = 3000) -> pd.DataFrame:
    """
    Generate realistic synthetic training data.
    Replace with your MT5 EA log CSV in production.
    """
    np.random.seed(42)
    base_price = 2000.0

    ema200     = base_price + np.random.randn(n_samples).cumsum() * 0.5
    ema50      = ema200 + np.random.randn(n_samples) * 2.0
    atr        = np.abs(np.random.normal(3.0, 1.0, n_samples)) + 1.0
    fvg        = np.random.randint(0, 2, n_samples)
    candle_pat = np.random.randint(1, 11, n_samples)
    session    = np.random.randint(0, 2, n_samples)
    bk_str     = np.random.normal(0.5, 0.3, n_samples)

    # Synthetic label: trend-following with noise
    bull_bias  = ((ema50 > ema200) & (fvg == 1) & (bk_str > 0.3)).astype(int)
    noise      = np.random.rand(n_samples) < 0.25
    direction  = np.where(noise, 1 - bull_bias, bull_bias)

    df = pd.DataFrame({
        "ema50"             : ema50,
        "ema200"            : ema200,
        "atr"               : atr,
        "breakout_strength" : bk_str,
        "fvg"               : fvg,
        "candle_pattern"    : candle_pat,
        "session"           : session,
        "price"             : ema200,
        TARGET_COL          : direction,
    })
    return df


# ─────────────────────────────────────────────
# 2.  Feature engineering
# ─────────────────────────────────────────────
def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["ema_diff"]         = df["ema50"] - df["ema200"]
    df["price_vs_ema200"]  = (df.get("price", df["ema200"]) - df["ema200"]) / df["atr"].replace(0, 1)
    # Clamp extreme values
    for col in ["breakout_strength", "price_vs_ema200", "ema_diff"]:
        df[col] = df[col].clip(-10, 10)
    return df


# ─────────────────────────────────────────────
# 3.  Balance classes
# ─────────────────────────────────────────────
def balance_dataset(df: pd.DataFrame) -> pd.DataFrame:
    majority = df[df[TARGET_COL] == df[TARGET_COL].value_counts().idxmax()]
    minority = df[df[TARGET_COL] != df[TARGET_COL].value_counts().idxmax()]
    minority_up = resample(minority, replace=True, n_samples=len(majority), random_state=42)
    return pd.concat([majority, minority_up]).sample(frac=1, random_state=42)


# ─────────────────────────────────────────────
# 4.  Model training
# ─────────────────────────────────────────────
def train(data_path: str | None = None):
    print("=" * 50)
    print("  XAUUSD AI Model Training")
    print("=" * 50)

    # Load or generate data
    if data_path and os.path.exists(data_path):
        print(f"Loading data from {data_path}")
        df = pd.read_csv(data_path)
    else:
        print("No data file found — using synthetic training data")
        df = generate_synthetic_data(5000)

    print(f"Dataset shape: {df.shape}")
    print(f"Label distribution:\n{df[TARGET_COL].value_counts()}")

    df = engineer_features(df)
    df = balance_dataset(df)

    # Validate feature columns
    available = [c for c in FEATURE_COLS if c in df.columns]
    missing   = [c for c in FEATURE_COLS if c not in df.columns]
    if missing:
        print(f"Warning: missing features {missing} — they will be zeroed")
        for c in missing:
            df[c] = 0

    X = df[FEATURE_COLS].fillna(0).values
    y = df[TARGET_COL].values

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, random_state=42, stratify=y
    )

    # ── Models to compare ──────────────────
    models = {
        "RandomForest": RandomForestClassifier(
            n_estimators=300, max_depth=8, min_samples_leaf=5,
            class_weight="balanced", random_state=42, n_jobs=-1
        ),
        "GradientBoosting": GradientBoostingClassifier(
            n_estimators=200, max_depth=4, learning_rate=0.05,
            subsample=0.8, random_state=42
        ),
        "LogisticRegression": LogisticRegression(
            C=0.5, solver="lbfgs", max_iter=1000,
            class_weight="balanced", random_state=42
        ),
    }

    scaler = StandardScaler()
    X_train_sc = scaler.fit_transform(X_train)
    X_test_sc  = scaler.transform(X_test)

    best_model = None
    best_auc   = 0.0
    best_name  = ""

    for name, model in models.items():
        cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
        cv_auc = cross_val_score(model, X_train_sc, y_train,
                                 cv=cv, scoring="roc_auc").mean()
        model.fit(X_train_sc, y_train)
        y_prob = model.predict_proba(X_test_sc)[:, 1]
        test_auc = roc_auc_score(y_test, y_prob)

        print(f"\n[{name}]  CV-AUC={cv_auc:.4f}  Test-AUC={test_auc:.4f}")
        print(classification_report(y_test, model.predict(X_test_sc),
                                    target_names=["SELL", "BUY"]))

        if test_auc > best_auc:
            best_auc   = test_auc
            best_model = model
            best_name  = name

    print(f"\n✅ Best model: {best_name}  (AUC={best_auc:.4f})")

    # Confusion matrix
    y_pred = best_model.predict(X_test_sc)
    cm = confusion_matrix(y_test, y_pred)
    print(f"\nConfusion Matrix:\n{cm}")

    # Feature importance (if available)
    if hasattr(best_model, "feature_importances_"):
        fi = dict(zip(FEATURE_COLS, best_model.feature_importances_))
        fi_sorted = sorted(fi.items(), key=lambda x: x[1], reverse=True)
        print("\nFeature Importances:")
        for feat, imp in fi_sorted:
            bar = "█" * int(imp * 40)
            print(f"  {feat:<22} {imp:.4f}  {bar}")

        # Plot
        names, vals = zip(*fi_sorted)
        fig, ax = plt.subplots(figsize=(8, 5))
        ax.barh(names, vals, color="#2196F3")
        ax.set_title("Feature Importances")
        ax.set_xlabel("Importance")
        plt.tight_layout()
        plt.savefig("feature_importance.png", dpi=120)
        print("Saved: feature_importance.png")

    # ── Save model & scaler ──────────────────
    with open("ai_model.pkl",  "wb") as f:
        pickle.dump(best_model, f)
    with open("scaler.pkl", "wb") as f:
        pickle.dump(scaler, f)

    # Save feature list for API validation
    with open("feature_cols.pkl", "wb") as f:
        pickle.dump(FEATURE_COLS, f)

    print("\n✅ Saved: ai_model.pkl  scaler.pkl  feature_cols.pkl")

    # Quick calibration check
    probs = best_model.predict_proba(X_test_sc)[:, 1]
    high_conf = probs[probs >= 0.70]
    if len(high_conf):
        mask = probs >= 0.70
        acc_high = (y_pred[mask] == y_test[mask]).mean()
        print(f"\nHigh-confidence trades (≥70%): {mask.sum()} — "
              f"Accuracy={acc_high:.2%}")

    return best_model, scaler


# ─────────────────────────────────────────────
# 5.  Entry point
# ─────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train XAUUSD AI model")
    parser.add_argument("--data", type=str, default=None,
                        help="Path to training CSV")
    args = parser.parse_args()
    train(args.data)
