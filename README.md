# XAUUSD AI Smart Money Trading System
## Complete Setup & Operations Guide

---

## 📦 What's Included

| File | Purpose |
|------|---------|
| `XAUUSD_AI_EA.mq5` | MetaTrader 5 Expert Advisor |
| `train_model.py` | AI model training script |
| `predict_api.py` | FastAPI prediction server |
| `telegram_bot.py` | Telegram signal broadcaster |
| `requirements.txt` | Python dependencies |
| `render.yaml` | Cloud deployment config |

---

## 🏗️ ARCHITECTURE OVERVIEW

```
MT5 EA (MQL5)
     │
     │  POST /predict  (JSON via WebRequest)
     ▼
Python FastAPI Server (Render/Railway/VPS)
     │
     │  confidence + decision
     ▼
Trade Execution ──► Telegram Signal
     │
     ▼
CSV Log ──► Retrain AI
```

---

## PART 1: PYTHON AI SERVER

### Step 1 — Install Python 3.10+

```bash
python --version   # must be 3.10 or higher
```

### Step 2 — Install dependencies

```bash
cd xauusd_ai_system
pip install -r requirements.txt
```

### Step 3 — Train the model

```bash
# First run: uses synthetic data (demo)
python train_model.py

# After collecting real MT5 data:
python train_model.py --data XAUUSD_AI_Log.csv
```

This generates:
- `ai_model.pkl` — trained classifier
- `scaler.pkl`   — feature normalizer
- `feature_importance.png` — feature analysis chart

### Step 4 — Run the API locally

```bash
uvicorn predict_api:app --host 0.0.0.0 --port 8000 --reload
```

Test it:
```bash
curl -X POST http://localhost:8000/predict \
  -H "Content-Type: application/json" \
  -d '{
    "ema50": 2045.5,
    "ema200": 2030.2,
    "atr": 3.5,
    "breakout_strength": 0.8,
    "fvg": 1,
    "candle_pattern": 7,
    "session": 1,
    "direction": 1
  }'
```

Expected response:
```json
{
  "confidence": 0.83,
  "decision": "BUY",
  "direction": 1,
  "model_ver": "2.0",
  "timestamp": "2024-01-15T09:30:00"
}
```

---

## PART 2: CLOUD DEPLOYMENT (Render.com)

### Option A — Render (recommended, free tier available)

1. Push your code to a GitHub repository
2. Go to [render.com](https://render.com) → New Web Service
3. Connect your GitHub repo
4. Settings:
   - **Build Command:** `pip install -r requirements.txt && python train_model.py`
   - **Start Command:** `uvicorn predict_api:app --host 0.0.0.0 --port $PORT`
   - **Environment:** Python 3
5. Deploy — you'll get a URL like: `https://xauusd-ai-api.onrender.com`

> ⚠️ Free tier spins down after 15 min inactivity. Upgrade to Starter ($7/mo) for always-on.

### Option B — Railway

1. Go to [railway.app](https://railway.app) → New Project → Deploy from GitHub
2. Add environment variables in the Railway dashboard
3. Railway auto-detects Python and uses `requirements.txt`
4. Add a `Procfile`:
```
web: uvicorn predict_api:app --host 0.0.0.0 --port $PORT
```

### Option C — VPS (DigitalOcean / Hetzner)

```bash
# On your server
git clone your-repo
cd xauusd_ai_system
pip install -r requirements.txt
python train_model.py

# Run with systemd service (recommended for production)
sudo nano /etc/systemd/system/xauusd-api.service
```

```ini
[Unit]
Description=XAUUSD AI API
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/xauusd_ai_system
ExecStart=/usr/bin/uvicorn predict_api:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable xauusd-api
sudo systemctl start xauusd-api
```

---

## PART 3: MT5 EXPERT ADVISOR SETUP

### Step 1 — Copy EA file

Copy `XAUUSD_AI_EA.mq5` to:
```
C:\Users\YourName\AppData\Roaming\MetaQuotes\Terminal\<ID>\MQL5\Experts\
```

Or in MT5: **File → Open Data Folder → MQL5 → Experts**

### Step 2 — Compile

1. Open MetaEditor (F4 in MT5)
2. Open the EA file
3. Press F7 to compile
4. Fix any errors (usually just the include path)

### Step 3 — Allow WebRequest

**CRITICAL — EA cannot call the API without this:**

1. MT5 → Tools → Options → Expert Advisors
2. ✅ Check "Allow WebRequest for listed URL"
3. Add your API URL: `https://your-api.onrender.com`
4. Also add: `https://api.telegram.org`

### Step 4 — Attach EA to chart

1. Open XAUUSD M15 chart
2. Drag EA from Navigator to chart
3. Configure parameters:

| Parameter | Value |
|-----------|-------|
| InpAPIURL | Your deployed API URL + `/predict` |
| InpTelegramToken | Your bot token |
| InpTelegramChatID | Your chat ID |
| InpRiskPercent | 1.0 (1% per trade) |
| InpMaxTradesPerDay | 2 |
| InpMinAIConfidence | 0.70 |

4. ✅ Enable "Allow live trading" in EA properties

---

## PART 4: TELEGRAM BOT SETUP

### Create bot with @BotFather

1. Open Telegram → search `@BotFather`
2. Send `/newbot`
3. Choose a name and username
4. Copy the **token**

### Get your Chat ID

1. Add your bot to a group or channel
2. Send any message
3. Visit: `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. Find `"chat":{"id": -XXXXXXXXX}` — that's your Chat ID

### Configure .env file

```bash
# Create .env in the project root
TELEGRAM_TOKEN=7234567890:AAFxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TELEGRAM_CHAT_ID=-1001234567890
LOG_CSV_PATH=XAUUSD_AI_Log.csv
API_URL=https://your-api.onrender.com
```

### Run the bot

```bash
python telegram_bot.py
```

The bot watches the EA log CSV and forwards signals automatically.

---

## PART 5: BACKTESTING GUIDE

### MT5 Strategy Tester

1. MT5 → View → Strategy Tester (Ctrl+R)
2. Expert: XAUUSD_AI_EA
3. Symbol: XAUUSD
4. Timeframe: M15
5. Date range: last 6–12 months
6. Model: Every tick (most accurate)
7. Optimization: checked

> **Note:** WebRequest and Telegram don't work in backtest — AI decisions will be skipped (trades won't execute). To backtest with AI, replace the `CallAIAPI()` function with a static return during backtesting using `#ifdef TESTER`.

### Python Backtesting (alternative)

Install `backtesting.py` and replay the strategy logic in Python against historical data from MT5 or a broker feed.

---

## PART 6: RETRAINING THE AI

After accumulating 200+ real trades:

```bash
# Copy MT5 log from:
# C:\Users\...\MQL5\Files\XAUUSD_AI_Log.csv

python train_model.py --data XAUUSD_AI_Log.csv
```

Then reload the model without restarting:
```bash
curl -X POST https://your-api.onrender.com/reload-model
```

---

## PART 7: OPTIMIZATION TIPS FOR XAUUSD

### ATR Threshold
- During London session: ATR(14) typically 3–8 points on M15
- Recommended threshold: 2.5 points minimum

### Session Timing (UTC)
- **London:** 07:00–12:00 UTC (best volatility)
- **New York:** 13:00–17:00 UTC (overlap with London 13:00–16:00 is ideal)
- Avoid 21:00–06:00 UTC (Asian session, low Gold volatility)

### Spread Management
- Typical XAUUSD spread: 15–30 points
- Set `InpMaxSpread = 40` as maximum
- Spread spikes at news events — EA automatically skips these

### Risk Management Tips
- Start with 0.5% risk until you validate live performance
- Scale to 1–2% only after 50+ trades with positive expectancy
- Never risk more than 2% on any single trade
- Use TP1 partial close to secure profits early

### FVG Best Practices
- Fresh FVGs (< 20 bars old) work best
- Combine FVG with S/R flip for highest probability
- FVG + Last Kiss + trend = highest confluence setups

---

## PART 8: MONITORING & ALERTS

### API Health Check

```bash
curl https://your-api.onrender.com/health
```

### Recent Prediction Stats

```bash
curl https://your-api.onrender.com/metrics
```

### Telegram Bot Commands

| Command | Description |
|---------|-------------|
| `/start` | Welcome + command list |
| `/status` | Today's trade summary |
| `/stats` | All-time performance |
| `/help` | Help guide |

---

## ⚠️ RISK DISCLAIMER

This software is for educational purposes. Live trading involves significant financial risk. Always:
- Test thoroughly on a demo account first (minimum 3 months)
- Never risk capital you cannot afford to lose
- Past performance does not guarantee future results
- The AI model requires sufficient quality training data

---

## 🐛 TROUBLESHOOTING

| Problem | Solution |
|---------|----------|
| `WebRequest error 4060` | Enable WebRequest in MT5 Options and add URL |
| `Model not loaded` | Run `python train_model.py` and restart API |
| `Telegram not sending` | Check token, chat ID, and WebRequest URL added |
| `No trades executing` | Check session filter, ATR threshold, spread |
| `Low AI confidence` | Retrain with more real trade data |
| API `503` | Model files missing — run train_model.py |

---

*System Version 2.0 | XAUUSD M15 Smart Money AI*
