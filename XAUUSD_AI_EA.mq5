//+------------------------------------------------------------------+
//|                    XAUUSD AI Smart Money EA                      |
//|          Strategy: Last Kiss + FVG + AI Filter + Telegram        |
//|                     Timeframe: M15 / H1                          |
//+------------------------------------------------------------------+
#property copyright "AI Trading System"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Arrays\ArrayDouble.mqh>

//--- Input Parameters
input group "=== API & TELEGRAM ==="
input string   InpAPIURL          = "http://localhost:8000/predict"; // Python API URL
input string   InpTelegramToken   = "8361968688:AAH9hec3w4ok9bm7D7HZUY4RzEu5fZgd8Oo";   // Telegram Bot Token
input string   InpTelegramChatID  = "7607518514";     // Telegram Chat ID

input group "=== RISK MANAGEMENT ==="
input double   InpRiskPercent      = 1.0;   // Risk % per trade
input double   InpMinRR            = 2.0;   // Minimum Risk:Reward
input double   InpATRMultSL        = 1.5;   // SL = ATR * multiplier
input double   InpBufferPoints     = 5.0;   // SL buffer in points
input double   InpTP1Ratio         = 1.0;   // TP1 ratio (1:1)
input double   InpTP2Ratio         = 2.0;   // TP2 ratio (1:2)
input double   InpTP1ClosePercent  = 50.0;  // % to close at TP1
input double   InpTP2ClosePercent  = 30.0;  // % to close at TP2

input group "=== FILTERS ==="
input double   InpMinAIConfidence  = 0.70;  // Min AI Confidence
input double   InpATRThreshold     = 1.5;   // Min ATR (points)
input double   InpMaxSpread        = 30.0;  // Max allowed spread (points)
input int      InpMaxTradesPerDay  = 2;     // Max trades per day

input group "=== STRATEGY SETTINGS ==="
input int      InpSwingLookback    = 30;    // Swing high/low lookback
input int      InpBreakoutBars     = 3;     // Bars to confirm breakout
input double   InpBodyRatio        = 0.60;  // Min body/range ratio for breakout candle
input int      InpFVGLookback      = 10;    // FVG scan lookback

input group "=== EMA SETTINGS ==="
input int      InpEMA50Period      = 50;    // EMA 50 period (M15)
input int      InpEMA200Period     = 200;   // EMA 200 period (M15)
input int      InpH1EMA200Period   = 200;   // EMA 200 period (H1)

input group "=== SESSION FILTER ==="
input int      InpLondonOpen       = 8;     // London open hour (UTC)
input int      InpLondonClose      = 12;    // London close hour (UTC)
input int      InpNYOpen           = 13;    // New York open hour (UTC)
input int      InpNYClose          = 17;    // New York close hour (UTC)

input group "=== VISUAL ==="
input bool     InpDrawLevels       = true;  // Draw S/R levels
input bool     InpDrawFVG          = true;  // Draw FVG zones
input bool     InpShowPanel        = true;  // Show info panel

//--- Global Variables
CTrade         trade;
CPositionInfo  posInfo;

int            ema50Handle, ema200Handle, h1ema200Handle, atrHandle;
double         ema50[], ema200[], h1ema200[], atrBuffer[];

datetime       lastBarTime       = 0;
int            tradesToday       = 0;
datetime       lastTradeDate     = 0;
double         currentSL         = 0;
double         currentTP1        = 0;
double         currentTP2        = 0;

// Swing levels
double         swingHigh         = 0;
double         swingLow          = 0;
bool           breakoutBull      = false;
bool           breakoutBear      = false;
bool           retestDone        = false;

// FVG tracking
struct FVGZone {
   double top;
   double bottom;
   bool   isBullish;
   bool   isFilled;
   datetime time;
};
FVGZone fvgZones[50];
int     fvgCount = 0;

// Log file
int logFile = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Init indicators
   ema50Handle    = iMA(_Symbol, PERIOD_M15, InpEMA50Period,  0, MODE_EMA, PRICE_CLOSE);
   ema200Handle   = iMA(_Symbol, PERIOD_M15, InpEMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   h1ema200Handle = iMA(_Symbol, PERIOD_H1,  InpH1EMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle      = iATR(_Symbol, PERIOD_M15, 14);

   if(ema50Handle==INVALID_HANDLE || ema200Handle==INVALID_HANDLE ||
      h1ema200Handle==INVALID_HANDLE || atrHandle==INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   ArraySetAsSeries(ema50,     true);
   ArraySetAsSeries(ema200,    true);
   ArraySetAsSeries(h1ema200,  true);
   ArraySetAsSeries(atrBuffer, true);

   // Init trade object
   trade.SetExpertMagicNumber(202401);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Open log file
   logFile = FileOpen("XAUUSD_AI_Log.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(logFile != INVALID_HANDLE)
      FileWrite(logFile, "Time,Symbol,Type,Entry,SL,TP,Lots,AIConfidence,Decision,Result");

   // Draw panel
   if(InpShowPanel) DrawInfoPanel("Initializing...", "---", 0.0);

   Print("XAUUSD AI EA Initialized");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(ema50Handle);
   IndicatorRelease(ema200Handle);
   IndicatorRelease(h1ema200Handle);
   IndicatorRelease(atrHandle);

   if(logFile != INVALID_HANDLE) FileClose(logFile);

   ObjectsDeleteAll(0, "EA_");
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only run on new bar
   datetime currentBar = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Refresh indicator buffers
   if(!RefreshBuffers()) return;

   // Reset daily counter
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   MqlDateTime lastDt;
   TimeToStruct(lastTradeDate, lastDt);
   if(dt.day != lastDt.day) tradesToday = 0;

   // Scan and update FVG zones
   ScanFVGZones();
   MarkFilledFVGs();

   // Trail existing positions
   ManageOpenPositions();

   // Check if we can trade
   if(!CanTrade()) {
      UpdatePanel();
      return;
   }

   // Detect swing levels
   DetectSwingLevels();

   // Check for breakout
   CheckBreakout();

   // Check for retest (Last Kiss)
   int tradeDir = CheckRetest();
   if(tradeDir == 0) {
      UpdatePanel();
      return;
   }

   // Check FVG alignment
   bool fvgOK = HasAlignedFVG(tradeDir);
   if(!fvgOK) {
      UpdatePanel();
      return;
   }

   // Check candlestick confirmation
   bool candleOK = CheckCandleConfirmation(tradeDir);
   if(!candleOK) {
      UpdatePanel();
      return;
   }

   // Check multi-timeframe trend
   if(!CheckTrendAlignment(tradeDir)) {
      UpdatePanel();
      return;
   }

   // Call AI API
   double aiConf = 0.0;
   string aiDecision = "";
   if(!CallAIAPI(tradeDir, aiConf, aiDecision)) {
      Print("AI API call failed — skipping trade");
      UpdatePanel();
      return;
   }

   if(aiConf < InpMinAIConfidence) {
      Print("AI confidence too low: ", aiConf);
      UpdatePanel();
      return;
   }

   // Execute trade
   ExecuteTrade(tradeDir, aiConf, aiDecision);
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Refresh all indicator buffers                                    |
//+------------------------------------------------------------------+
bool RefreshBuffers()
{
   if(CopyBuffer(ema50Handle,    0, 0, 5, ema50)     < 5) return false;
   if(CopyBuffer(ema200Handle,   0, 0, 5, ema200)    < 5) return false;
   if(CopyBuffer(h1ema200Handle, 0, 0, 3, h1ema200)  < 3) return false;
   if(CopyBuffer(atrHandle,      0, 0, 5, atrBuffer) < 5) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Can we place a new trade?                                        |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Max trades per day
   if(tradesToday >= InpMaxTradesPerDay) return false;

   // Already have open position on this symbol
   if(PositionSelect(_Symbol)) return false;

   // Session filter
   if(!IsActiveSession()) return false;

   // Spread filter
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(spread > InpMaxSpread * _Point) return false;

   // ATR filter
   if(atrBuffer[1] < InpATRThreshold * _Point) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Session filter: London + NY only                                 |
//+------------------------------------------------------------------+
bool IsActiveSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool london = (h >= InpLondonOpen && h < InpLondonClose);
   bool ny     = (h >= InpNYOpen     && h < InpNYClose);
   return london || ny;
}

//+------------------------------------------------------------------+
//| Detect swing highs and lows                                      |
//+------------------------------------------------------------------+
void DetectSwingLevels()
{
   double highBuf[], lowBuf[];
   ArraySetAsSeries(highBuf, true);
   ArraySetAsSeries(lowBuf,  true);
   CopyHigh(_Symbol, PERIOD_M15, 1, InpSwingLookback, highBuf);
   CopyLow (_Symbol, PERIOD_M15, 1, InpSwingLookback, lowBuf);

   swingHigh = highBuf[ArrayMaximum(highBuf)];
   swingLow  = lowBuf [ArrayMinimum(lowBuf)];

   if(InpDrawLevels)
   {
      DrawHorizontalLine("EA_SwingHigh", swingHigh, clrDodgerBlue, STYLE_DASH);
      DrawHorizontalLine("EA_SwingLow",  swingLow,  clrOrangeRed,  STYLE_DASH);
   }
}

//+------------------------------------------------------------------+
//| Detect breakout of swing level                                   |
//+------------------------------------------------------------------+
void CheckBreakout()
{
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double open1  = iOpen (_Symbol, PERIOD_M15, 1);
   double high1  = iHigh (_Symbol, PERIOD_M15, 1);
   double low1   = iLow  (_Symbol, PERIOD_M15, 1);
   double range  = high1 - low1;
   double body   = MathAbs(close1 - open1);

   if(range <= 0) return;

   // Bullish breakout: close above swing high with strong body
   if(close1 > swingHigh && (body / range) >= InpBodyRatio)
   {
      breakoutBull = true;
      breakoutBear = false;
      retestDone   = false;
      Print("Bullish breakout detected at ", swingHigh);
   }
   // Bearish breakout: close below swing low with strong body
   else if(close1 < swingLow && (body / range) >= InpBodyRatio)
   {
      breakoutBear = true;
      breakoutBull = false;
      retestDone   = false;
      Print("Bearish breakout detected at ", swingLow);
   }
}

//+------------------------------------------------------------------+
//| Check for Last Kiss retest                                       |
//| Returns: 1=BUY, -1=SELL, 0=none                                 |
//+------------------------------------------------------------------+
int CheckRetest()
{
   if(!breakoutBull && !breakoutBear) return 0;
   if(retestDone) return 0;

   double high1 = iHigh(_Symbol, PERIOD_M15, 1);
   double low1  = iLow (_Symbol, PERIOD_M15, 1);
   double close1= iClose(_Symbol, PERIOD_M15, 1);
   double atr   = atrBuffer[1];
   double tol   = atr * 0.3; // tolerance zone

   if(breakoutBull)
   {
      // Price comes back to test former resistance (now support)
      if(low1 <= swingHigh + tol && low1 >= swingHigh - tol && close1 > swingHigh)
      {
         retestDone = true;
         Print("Last Kiss BUY retest at ", swingHigh);
         return 1; // BUY
      }
   }

   if(breakoutBear)
   {
      // Price comes back to test former support (now resistance)
      if(high1 >= swingLow - tol && high1 <= swingLow + tol && close1 < swingLow)
      {
         retestDone = true;
         Print("Last Kiss SELL retest at ", swingLow);
         return -1; // SELL
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Scan for FVG zones                                               |
//+------------------------------------------------------------------+
void ScanFVGZones()
{
   fvgCount = 0;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);
   CopyHigh(_Symbol, PERIOD_M15, 1, InpFVGLookback + 2, high);
   CopyLow (_Symbol, PERIOD_M15, 1, InpFVGLookback + 2, low);

   for(int i = 1; i <= InpFVGLookback && fvgCount < 50; i++)
   {
      // Bullish FVG: low[0] > high[2]  (gap between candle 0 and candle 2)
      if(low[i-1] > high[i+1])
      {
         fvgZones[fvgCount].top      = low[i-1];
         fvgZones[fvgCount].bottom   = high[i+1];
         fvgZones[fvgCount].isBullish= true;
         fvgZones[fvgCount].isFilled = false;
         fvgZones[fvgCount].time     = iTime(_Symbol, PERIOD_M15, i);
         fvgCount++;
      }
      // Bearish FVG: high[0] < low[2]
      else if(high[i-1] < low[i+1])
      {
         fvgZones[fvgCount].top      = low[i+1];
         fvgZones[fvgCount].bottom   = high[i-1];
         fvgZones[fvgCount].isBullish= false;
         fvgZones[fvgCount].isFilled = false;
         fvgZones[fvgCount].time     = iTime(_Symbol, PERIOD_M15, i);
         fvgCount++;
      }
   }

   if(InpDrawFVG) DrawFVGZones();
}

//+------------------------------------------------------------------+
//| Mark FVGs that have been filled                                  |
//+------------------------------------------------------------------+
void MarkFilledFVGs()
{
   double currentHigh = iHigh(_Symbol, PERIOD_M15, 1);
   double currentLow  = iLow (_Symbol, PERIOD_M15, 1);

   for(int i = 0; i < fvgCount; i++)
   {
      if(fvgZones[i].isFilled) continue;
      // If price has entered the gap zone, mark as filled
      if(currentHigh >= fvgZones[i].bottom && currentLow <= fvgZones[i].top)
         fvgZones[i].isFilled = true;
   }
}

//+------------------------------------------------------------------+
//| Check if there is an aligned FVG for the given direction         |
//+------------------------------------------------------------------+
bool HasAlignedFVG(int dir)
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < fvgCount; i++)
   {
      if(fvgZones[i].isFilled) continue;

      bool dirMatch = (dir == 1 && fvgZones[i].isBullish) ||
                      (dir ==-1 && !fvgZones[i].isBullish);

      if(!dirMatch) continue;

      // Price should be near or inside FVG zone
      double midFVG = (fvgZones[i].top + fvgZones[i].bottom) / 2.0;
      double atr    = atrBuffer[1];
      if(MathAbs(currentPrice - midFVG) < atr * 1.5)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check candlestick confirmation pattern                           |
//+------------------------------------------------------------------+
bool CheckCandleConfirmation(int dir)
{
   double open1  = iOpen (_Symbol, PERIOD_M15, 1);
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double high1  = iHigh (_Symbol, PERIOD_M15, 1);
   double low1   = iLow  (_Symbol, PERIOD_M15, 1);

   double open2  = iOpen (_Symbol, PERIOD_M15, 2);
   double close2 = iClose(_Symbol, PERIOD_M15, 2);
   double high2  = iHigh (_Symbol, PERIOD_M15, 2);
   double low2   = iLow  (_Symbol, PERIOD_M15, 2);

   double body1  = MathAbs(close1 - open1);
   double range1 = high1 - low1;
   double body2  = MathAbs(close2 - open2);

   if(range1 <= 0) return false;

   // BUY patterns
   if(dir == 1)
   {
      // Bullish engulfing
      bool engulf = (close1 > open1) && (close2 < open2) && 
                    (close1 > open2) && (open1 < close2);
      // Pin bar (bullish rejection)
      double lowerWick = MathMin(open1, close1) - low1;
      bool pinBar = (lowerWick > body1 * 2.0) && (close1 > open1) && 
                    (body1 / range1 > 0.2);

      return engulf || pinBar;
   }

   // SELL patterns
   if(dir == -1)
   {
      // Bearish engulfing
      bool engulf = (close1 < open1) && (close2 > open2) &&
                    (close1 < open2) && (open1 > close2);
      // Pin bar (bearish rejection)
      double upperWick = high1 - MathMax(open1, close1);
      bool pinBar = (upperWick > body1 * 2.0) && (close1 < open1) &&
                    (body1 / range1 > 0.2);

      return engulf || pinBar;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Multi-timeframe trend alignment check                            |
//+------------------------------------------------------------------+
bool CheckTrendAlignment(int dir)
{
   double price    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // H1 bias (200 EMA)
   bool h1Bull = (price > h1ema200[0]);
   bool h1Bear = (price < h1ema200[0]);

   // M15 trend
   bool m15Bull = (price > ema200[0]) && (ema50[0] > ema200[0]);
   bool m15Bear = (price < ema200[0]) && (ema50[0] < ema200[0]);

   if(dir == 1)  return h1Bull && m15Bull;
   if(dir == -1) return h1Bear && m15Bear;
   return false;
}

//+------------------------------------------------------------------+
//| Call Python AI API                                               |
//+------------------------------------------------------------------+
bool CallAIAPI(int dir, double &confidence, string &decision)
{
   double price    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr      = atrBuffer[1];
   double brkStr   = (dir == 1) ? (price - swingHigh) / atr : (swingLow - price) / atr;
   int    session  = IsActiveSession() ? 1 : 0;

   // Encode candle pattern
   double open1  = iOpen (_Symbol, PERIOD_M15, 1);
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double high1  = iHigh (_Symbol, PERIOD_M15, 1);
   double low1   = iLow  (_Symbol, PERIOD_M15, 1);
   double body1  = MathAbs(close1 - open1);
   double range1 = high1 - low1;
   int    candleEnc = (range1 > 0) ? (int)(body1 / range1 * 10) : 5;

   // Build JSON payload
   string json = StringFormat(
      "{\"ema50\":%.5f,\"ema200\":%.5f,\"atr\":%.5f,"
      "\"breakout_strength\":%.4f,\"fvg\":1,"
      "\"candle_pattern\":%d,\"session\":%d,\"direction\":%d}",
      ema50[0], ema200[0], atr, brkStr, candleEnc, session, dir
   );

   // HTTP headers
   string headers = "Content-Type: application/json\r\n";
   char   postData[], result[];
   string resultHeaders;
   StringToCharArray(json, postData, 0, StringLen(json));

   int timeout = 5000; // 5 seconds
   int res = WebRequest("POST", InpAPIURL, headers, timeout, postData, result, resultHeaders);

   if(res == -1)
   {
      int err = GetLastError();
      Print("WebRequest failed, error: ", err,
            " — Check: Tools > Options > Expert Advisors > Allow WebRequest, add URL: ", InpAPIURL);
      return false;
   }

   // Parse response
   string response = CharArrayToString(result);
   Print("AI Response: ", response);

   // Extract confidence
   int confPos = StringFind(response, "\"confidence\":");
   if(confPos >= 0)
   {
      string sub = StringSubstr(response, confPos + 13, 10);
      confidence = StringToDouble(sub);
   }

   // Extract decision
   int decPos = StringFind(response, "\"decision\":\"");
   if(decPos >= 0)
   {
      string sub = StringSubstr(response, decPos + 12, 10);
      int endQ = StringFind(sub, "\"");
      if(endQ > 0) decision = StringSubstr(sub, 0, endQ);
      else         decision = (dir == 1) ? "BUY" : "SELL";
   }

   return (confidence > 0);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk %                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   if(slPoints <= 0) return 0.01;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lotSize = riskAmount / (slPoints / tickSize * tickValue);
   lotSize = MathFloor(lotSize / stepLot) * stepLot;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   return lotSize;
}

//+------------------------------------------------------------------+
//| Execute trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(int dir, double aiConf, string aiDecision)
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr   = atrBuffer[1];
   double entry = (dir == 1) ? ask : bid;
   double sl, tp1, tp2;

   if(dir == 1)
   {
      sl  = entry - atr * InpATRMultSL - InpBufferPoints * _Point;
      tp1 = entry + (entry - sl) * InpTP1Ratio;
      tp2 = entry + (entry - sl) * InpTP2Ratio;
   }
   else
   {
      sl  = entry + atr * InpATRMultSL + InpBufferPoints * _Point;
      tp1 = entry - (sl - entry) * InpTP1Ratio;
      tp2 = entry - (sl - entry) * InpTP2Ratio;
   }

   double slPoints = MathAbs(entry - sl) / _Point;
   double lots     = CalculateLotSize(slPoints);

   if(lots <= 0) return;

   // Split order: 80% for main, will manage partials via trailing
   bool opened = false;
   if(dir == 1)
      opened = trade.Buy(lots, _Symbol, ask, sl, tp2, "AI_BUY");
   else
      opened = trade.Sell(lots, _Symbol, bid, sl, tp2, "AI_SELL");

   if(opened)
   {
      tradesToday++;
      lastTradeDate = TimeCurrent();
      currentSL     = sl;
      currentTP1    = tp1;
      currentTP2    = tp2;

      string typeStr = (dir == 1) ? "BUY" : "SELL";
      Print("Trade executed: ", typeStr, " Lots:", lots, " Entry:", entry,
            " SL:", sl, " TP:", tp2, " AI:", aiConf);

      // Log to CSV
      if(logFile != INVALID_HANDLE)
         FileWrite(logFile, TimeToString(TimeCurrent()), _Symbol, typeStr,
                   entry, sl, tp2, lots, aiConf, aiDecision, "OPEN");

      // Send Telegram signal
      SendTelegramSignal(typeStr, entry, sl, tp1, tp2, aiConf);

      // Reset breakout flags
      breakoutBull = false;
      breakoutBear = false;
      retestDone   = false;
   }
   else
   {
      Print("Trade failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Manage open positions (trailing stop + partial close)           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!PositionSelect(_Symbol)) return;

   double posType   = PositionGetInteger(POSITION_TYPE);
   double posOpen   = PositionGetDouble(POSITION_PRICE_OPEN);
   double posSL     = PositionGetDouble(POSITION_SL);
   double posTP     = PositionGetDouble(POSITION_TP);
   double posVol    = PositionGetDouble(POSITION_VOLUME);
   double posProfit = PositionGetDouble(POSITION_PROFIT);
   ulong  posTicket = PositionGetInteger(POSITION_TICKET);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr = atrBuffer[1];

   // TP1 partial close at 1:1
   if(currentTP1 > 0 && posVol > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
   {
      bool tp1Hit = (posType == POSITION_TYPE_BUY  && bid >= currentTP1) ||
                    (posType == POSITION_TYPE_SELL && ask <= currentTP1);

      if(tp1Hit)
      {
         double closeVol = NormalizeDouble(posVol * InpTP1ClosePercent / 100.0,
                                           (int)-MathLog10(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)));
         closeVol = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), closeVol);
         if(closeVol < posVol)
         {
            trade.PositionClosePartial(posTicket, closeVol);
            currentTP1 = 0; // prevent re-trigger
            // Move SL to breakeven
            if(posType == POSITION_TYPE_BUY)
               trade.PositionModify(posTicket, posOpen + 2 * _Point, posTP);
            else
               trade.PositionModify(posTicket, posOpen - 2 * _Point, posTP);
            Print("TP1 partial close executed");
         }
      }
   }

   // Trailing stop (ATR-based) for remainder
   if(posType == POSITION_TYPE_BUY)
   {
      double newSL = bid - atr * 1.2;
      if(newSL > posSL + _Point)
         trade.PositionModify(posTicket, NormalizeDouble(newSL, _Digits), posTP);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double newSL = ask + atr * 1.2;
      if(newSL < posSL - _Point)
         trade.PositionModify(posTicket, NormalizeDouble(newSL, _Digits), posTP);
   }
}

//+------------------------------------------------------------------+
//| Send Telegram signal                                             |
//+------------------------------------------------------------------+
void SendTelegramSignal(string type, double entry, double sl, 
                         double tp1, double tp2, double aiConf)
{
   string msg = StringFormat(
      "📊 *XAUUSD TRADE SIGNAL*\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "🔹 Type: *%s*\n"
      "🎯 Entry: `%.2f`\n"
      "🛑 Stop Loss: `%.2f`\n"
      "✅ TP1 (1:1): `%.2f`\n"
      "🏆 TP2 (1:2): `%.2f`\n"
      "🤖 AI Confidence: *%.0f%%*\n"
      "⏰ Time: %s",
      type, entry, sl, tp1, tp2,
      aiConf * 100.0,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES)
   );

   // URL-encode message
   string encodedMsg = "";
   for(int i = 0; i < StringLen(msg); i++)
   {
      ushort c = StringGetCharacter(msg, i);
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
         encodedMsg += CharToString((uchar)c);
      else
         encodedMsg += StringFormat("%%%02X", c);
   }

   string url = StringFormat(
      "https://api.telegram.org/bot%s/sendMessage?chat_id=%s&text=%s&parse_mode=Markdown",
      InpTelegramToken, InpTelegramChatID, encodedMsg
   );

   char req[], res[];
   string respHeaders;
   int code = WebRequest("GET", url, "", 5000, req, res, respHeaders);

   if(code == 200)
      Print("Telegram signal sent");
   else
      Print("Telegram failed, code: ", code);
}

//+------------------------------------------------------------------+
//| Draw FVG zones on chart                                          |
//+------------------------------------------------------------------+
void DrawFVGZones()
{
   // Remove old FVG objects
   ObjectsDeleteAll(0, "EA_FVG_");

   datetime timeNow = TimeCurrent();
   datetime timeFuture = timeNow + PeriodSeconds(PERIOD_M15) * 20;

   for(int i = 0; i < fvgCount; i++)
   {
      if(fvgZones[i].isFilled) continue;

      string name   = StringFormat("EA_FVG_%d", i);
      color  clr    = fvgZones[i].isBullish ? clrLightGreen : clrLightCoral;
      string label  = fvgZones[i].isBullish ? "Bull FVG" : "Bear FVG";

      ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                   fvgZones[i].time, fvgZones[i].top,
                   timeFuture,       fvgZones[i].bottom);
      ObjectSetInteger(0, name, OBJPROP_COLOR,   clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE,   STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,   1);
      ObjectSetInteger(0, name, OBJPROP_FILL,    true);
      ObjectSetInteger(0, name, OBJPROP_BACK,    true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, name, OBJPROP_TOOLTIP, label);
   }
}

//+------------------------------------------------------------------+
//| Draw horizontal line                                             |
//+------------------------------------------------------------------+
void DrawHorizontalLine(string name, double price, color clr, ENUM_LINE_STYLE style)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble (0, name, OBJPROP_PRICE,  price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,  clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,  style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,  1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Draw info panel                                                  |
//+------------------------------------------------------------------+
void DrawInfoPanel(string trend, string signal, double aiConf)
{
   string info = StringFormat(
      "XAUUSD AI EA v2.0\n"
      "────────────────\n"
      "Trend:   %s\n"
      "Signal:  %s\n"
      "AI Conf: %.0f%%\n"
      "Trades:  %d/%d today\n"
      "EMA50:   %.2f\n"
      "EMA200:  %.2f\n"
      "ATR:     %.2f\n"
      "Session: %s",
      trend, signal, aiConf * 100,
      tradesToday, InpMaxTradesPerDay,
      (ArraySize(ema50)  > 0 ? ema50[0]  : 0),
      (ArraySize(ema200) > 0 ? ema200[0] : 0),
      (ArraySize(atrBuffer) > 0 ? atrBuffer[1] / _Point : 0),
      IsActiveSession() ? "ACTIVE ✅" : "CLOSED ❌"
   );
   Comment(info);
}

//+------------------------------------------------------------------+
//| Update panel with current state                                  |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!InpShowPanel) return;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string trend = "NEUTRAL";
   if(ArraySize(ema200) > 0)
   {
      if(price > ema200[0] && ArraySize(ema50) > 0 && ema50[0] > ema200[0])
         trend = "BULLISH 📈";
      else if(price < ema200[0] && ArraySize(ema50) > 0 && ema50[0] < ema200[0])
         trend = "BEARISH 📉";
   }

   string sig = (breakoutBull ? "BULL BREAK" : (breakoutBear ? "BEAR BREAK" : "WAITING"));
   DrawInfoPanel(trend, sig, 0.0);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - log closed trades                           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
      {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            string res    = profit >= 0 ? "WIN" : "LOSS";
            if(logFile != INVALID_HANDLE)
               FileWrite(logFile, TimeToString(TimeCurrent()), _Symbol, "CLOSE",
                         0, 0, 0, 0, 0, "", res + StringFormat(" %.2f", profit));
         }
      }
   }
}
//+------------------------------------------------------------------+
