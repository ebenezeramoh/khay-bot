"""
XAUUSD Telegram Signal Bot
===========================
Standalone script that watches the EA log CSV and broadcasts
trade signals to a Telegram channel/group.

Also includes a /status command handler via polling.

Usage:
  pip install python-telegram-bot pandas watchdog
  python telegram_bot.py

Environment variables (set in .env or export):
  TELEGRAM_TOKEN   = your bot token from @BotFather
  TELEGRAM_CHAT_ID = your channel or group chat ID
  LOG_CSV_PATH     = path to XAUUSD_AI_Log.csv (default: ./XAUUSD_AI_Log.csv)
"""

import os
import sys
import time
import logging
import threading
import csv
from datetime import datetime
from pathlib import Path
from dotenv import load_dotenv

try:
    import pandas as pd
    from telegram import Update, Bot
    from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
except ImportError:
    print("Missing dependencies. Run:")
    print("  pip install python-telegram-bot pandas watchdog python-dotenv")
    sys.exit(1)

# ─────────────────────────────────────────────
load_dotenv()

TOKEN       = os.getenv("TELEGRAM_TOKEN",   "YOUR_BOT_TOKEN")
CHAT_ID     = os.getenv("TELEGRAM_CHAT_ID", "YOUR_CHAT_ID")
LOG_CSV     = os.getenv("LOG_CSV_PATH",     "XAUUSD_AI_Log.csv")
API_URL     = os.getenv("API_URL",          "http://localhost:8000")


def find_mt5_log_path(filename: str):
    appdata = os.getenv("APPDATA")
    if not appdata:
        return None

    base = Path(appdata) / "MetaQuotes" / "Terminal"
    if not base.exists():
        return None

    for terminal_id in base.iterdir():
        candidate = terminal_id / "MQL5" / "Files" / filename
        if candidate.exists():
            return candidate
    return None

if LOG_CSV == "XAUUSD_AI_Log.csv":
    mt5_path = find_mt5_log_path(LOG_CSV)
    if mt5_path is not None:
        LOG_CSV = str(mt5_path)
        print(f"Using MT5 log file path: {LOG_CSV}")

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(message)s",
    level=logging.INFO,
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("xauusd_bot")

bot = Bot(token=TOKEN)
# ─────────────────────────────────────────────
# Trade signal formatter
# ─────────────────────────────────────────────
def format_signal(row: dict) -> str:
    trade_type = row.get("Type", "?").upper()
    entry      = float(row.get("Entry",      0))
    sl         = float(row.get("SL",         0))
    tp         = float(row.get("TP",         0))
    lots       = float(row.get("Lots",       0))
    conf       = float(row.get("AIConfidence", 0))
    result     = row.get("Result", "OPEN")
    ts         = row.get("Time", datetime.utcnow().isoformat())

    # TP1 = 1:1, TP2 = tp (1:2)
    risk  = abs(entry - sl)
    tp1   = entry + risk  if trade_type == "BUY" else entry - risk

    emoji = "🟢" if trade_type == "BUY" else "🔴"
    flag  = "🏁" if "WIN" in result else ("❌" if "LOSS" in result else "⏳")

    return (
        f"{emoji} *XAUUSD {trade_type} SIGNAL*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━\n"
        f"🎯 Entry:        `{entry:.2f}`\n"
        f"🛑 Stop Loss:    `{sl:.2f}`\n"
        f"📍 TP1 (1:1):   `{tp1:.2f}`\n"
        f"🏆 TP2 (1:2):   `{tp:.2f}`\n"
        f"📦 Lot Size:    `{lots:.2f}`\n"
        f"🤖 AI Confidence: *{conf*100:.0f}%*\n"
        f"📊 Risk:Reward:  1:{risk and abs(tp-entry)/risk:.1f}\n"
        f"{flag} Status:      *{result}*\n"
        f"⏰ `{ts}`"
    )


def format_close(row: dict) -> str:
    result = row.get("Result", "")
    profit_str = result.replace("WIN", "").replace("LOSS", "").strip()
    try:
        profit = float(profit_str)
    except Exception:
        profit = 0.0

    won   = "WIN" in result
    emoji = "✅" if won else "❌"

    return (
        f"{emoji} *XAUUSD Trade Closed*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━\n"
        f"Result: {'WIN 🎉' if won else 'LOSS 😔'}\n"
        f"P&L:    `{profit:+.2f}`\n"
        f"⏰ `{row.get('Time', '')}`"
    )


# ─────────────────────────────────────────────
# CSV watcher
# ─────────────────────────────────────────────
last_line_count = 0

def check_new_trades():
    global last_line_count
    path = Path(LOG_CSV)
    if not path.exists():
        return

    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rows = list(csv.DictReader(f))

    if len(rows) <= last_line_count:
        return

    new_rows = rows[last_line_count:]
    last_line_count = len(rows)

    for row in new_rows:
        result = row.get("Result", "OPEN")
        try:
            if result == "OPEN":
                msg = format_signal(row)
            elif "WIN" in result or "LOSS" in result:
                msg = format_close(row)
            else:
                continue

            bot.send_message(
                chat_id=CHAT_ID,
                text=msg,
                parse_mode="Markdown",
            )
            logger.info(f"Telegram sent: {row.get('Type','?')} {result}")

        except Exception as e:
            logger.error(f"Telegram send error: {e}")


class CSVChangeHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if Path(event.src_path).name == Path(LOG_CSV).name:
            check_new_trades()


# ─────────────────────────────────────────────
# Bot command handlers
# ─────────────────────────────────────────────
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "👋 *XAUUSD AI Trading Bot*\n\n"
        "Commands:\n"
        "/status — show today's trade summary\n"
        "/stats  — show all-time stats\n"
        "/help   — help",
        parse_mode="Markdown",
    )


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    path = Path(LOG_CSV)
    if not path.exists():
        await update.message.reply_text("No trade log found yet.")
        return

    df = pd.read_csv(path)
    today = datetime.utcnow().strftime("%Y.%m.%d")
    df_today = df[df["Time"].str.startswith(today)] if "Time" in df.columns else df

    open_trades = df_today[df_today["Result"] == "OPEN"] if "Result" in df_today.columns else pd.DataFrame()
    closed = df_today[df_today["Result"].str.contains("WIN|LOSS", na=False)] if "Result" in df_today.columns else pd.DataFrame()

    wins   = closed[closed["Result"].str.contains("WIN", na=False)]
    losses = closed[closed["Result"].str.contains("LOSS", na=False)]

    msg = (
        f"📈 *Today's Summary ({today})*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━\n"
        f"Open trades:  {len(open_trades)}\n"
        f"Wins:         {len(wins)}\n"
        f"Losses:       {len(losses)}\n"
        f"Win rate:     {len(wins)/(len(wins)+len(losses))*100:.0f}%"
        if (len(wins) + len(losses)) > 0 else
        f"📈 *Today's Summary*\nNo closed trades yet today."
    )
    await update.message.reply_text(msg, parse_mode="Markdown")


async def cmd_stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    path = Path(LOG_CSV)
    if not path.exists():
        await update.message.reply_text("No trade log found.")
        return

    df = pd.read_csv(path)
    if "Result" not in df.columns:
        await update.message.reply_text("No closed trades yet.")
        return

    closed = df[df["Result"].str.contains("WIN|LOSS", na=False)]
    wins   = closed[closed["Result"].str.contains("WIN",  na=False)]
    losses = closed[closed["Result"].str.contains("LOSS", na=False)]
    total  = len(wins) + len(losses)
    wr     = len(wins) / total * 100 if total else 0

    # Rough P&L estimate
    pnl = 0.0
    for _, row in closed.iterrows():
        try:
            val = row["Result"].replace("WIN","").replace("LOSS","").strip()
            pnl += float(val)
        except Exception:
            pass

    avg_conf = df["AIConfidence"].astype(float).mean() if "AIConfidence" in df.columns else 0

    msg = (
        f"🏆 *All-Time Stats*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━\n"
        f"Total trades: {total}\n"
        f"Wins:         {len(wins)}\n"
        f"Losses:       {len(losses)}\n"
        f"Win rate:     {wr:.1f}%\n"
        f"Total P&L:    `{pnl:+.2f}`\n"
        f"Avg AI conf:  {avg_conf*100:.0f}%"
    )
    await update.message.reply_text(msg, parse_mode="Markdown")


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "📘 *Help*\n\n"
        "This bot automatically sends XAUUSD trade alerts from your MT5 EA.\n\n"
        "Each alert includes:\n"
        "• Entry price\n"
        "• Stop Loss\n"
        "• TP1 (1:1) and TP2 (1:2)\n"
        "• AI confidence score\n"
        "• Trade result when closed\n\n"
        "Setup: Add your TELEGRAM_TOKEN and CHAT_ID to .env",
        parse_mode="Markdown",
    )


# ─────────────────────────────────────────────
# Background polling thread
# ─────────────────────────────────────────────
def polling_thread():
    """Poll the CSV every 10 seconds as fallback when watchdog misses events."""
    while True:
        try:
            check_new_trades()
        except Exception as e:
            logger.error(f"Polling error: {e}")
        time.sleep(10)


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
def main():
    if TOKEN == "YOUR_BOT_TOKEN":
        print("ERROR: Set TELEGRAM_TOKEN in .env or environment variables")
        sys.exit(1)

    # File watcher
    event_handler = CSVChangeHandler()
    observer = Observer()
    watch_dir = str(Path(LOG_CSV).parent.resolve())
    observer.schedule(event_handler, watch_dir, recursive=False)
    observer.start()
    logger.info(f"Watching: {watch_dir}")

    # Background polling fallback
    t = threading.Thread(target=polling_thread, daemon=True)
    t.start()

    # Telegram bot
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler("start",  cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("stats",  cmd_stats))
    app.add_handler(CommandHandler("help",   cmd_help))

    logger.info("Telegram bot running — press Ctrl+C to stop")

    try:
        app.run_polling()
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()
