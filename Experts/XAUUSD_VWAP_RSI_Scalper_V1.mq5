//+------------------------------------------------------------------+
//|                            XAUUSD_VWAP_RSI_Scalper_V1.mq5        |
//|                                                                  |
//|  M5 session VWAP + RSI(14) midline-cross scalper.                |
//|                                                                  |
//|  BUY  : Close[1] > VWAP  and  RSI crosses up   through midline   |
//|  SELL : Close[1] < VWAP  and  RSI crosses down through midline   |
//|                                                                  |
//|  Every signal input is read from CLOSED bars only (index >= 1),  |
//|  so the EA does not repaint and does not use future data.        |
//|  Entry conditions are evaluated exactly once per closed M5 bar.  |
//|                                                                  |
//|  Fixed fractional risk. No martingale, grid, averaging down or   |
//|  revenge trades. The symbol is never hard-coded.                 |
//|                                                                  |
//|  Definitions: docs/XAUUSD_VWAP_RSI_Scalper_V1.md                 |
//+------------------------------------------------------------------+
#property copyright "XAUUSD_VWAP_RSI_Scalper_V1"
#property link      "https://github.com/apillanesmark62-cloud/AlgorithmBot"
#property version   "1.00"
#property description "M5 session VWAP + RSI midline cross scalper."
#property description "Fixed fractional risk - no martingale, grid, averaging or revenge trades."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Strategy ==="
input int    RSIPeriod           = 14;        // RSI period
input double RSIMidline          = 50.0;      // RSI midline
input int    SwingStrength       = 2;         // Swing strength (bars each side)
input int    SwingLookbackBars   = 100;       // Swing search depth (M5 bars)
input int    VWAPMaxLookbackBars = 400;       // VWAP scan depth (M5 bars, >= 1 day)

input group "=== Risk ==="
input double RiskPercent         = 0.25;      // Risk per trade (% of equity)
input double RiskReward          = 2.0;       // Reward : Risk ratio
input double SLBufferPoints      = 50;        // SL buffer beyond the swing (points)
input double MaxLotSize          = 1.0;       // Maximum lot size

input group "=== Trading limits ==="
input int    MaxTradesPerDay     = 5;         // Max trades per day
input double MaxDailyLossPercent = 1.5;       // Max daily loss (%)
input double MaxSpreadPoints     = 40;        // Max allowed spread (points)

input group "=== Session (BROKER / SERVER TIME!) ==="
input int    TradingSessionStart = 7;         // Session start hour (server time)
input int    TradingSessionEnd   = 21;        // Session end hour (server time)

input group "=== Execution ==="
input long   MagicNumber         = 20250818;  // Magic number
input int    MaxSlippagePoints   = 30;        // Max deviation (broker points)
input string TradeComment        = "VWAP_RSI_V1"; // Trade comment
input bool   AutoAdjustForDigits = true;      // Scale point inputs on 3/5 digit feeds

input group "=== Diagnostics ==="
input bool   LogEveryBar         = false;     // Log VWAP/RSI on every closed M5 bar

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define MAX_OPEN_POSITIONS 1                  // hard limit, per specification
#define SIGNAL_TF          PERIOD_M5          // the EA always works on M5

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   trade;

int      g_rsi_handle   = INVALID_HANDLE;
datetime g_last_bar     = 0;      // open time of the last processed M5 bar
datetime g_day_start    = 0;      // server midnight of the current day

double   g_point        = 0.0;
int      g_digits       = 0;
double   g_pt_scale     = 1.0;    // input point -> broker point factor
double   g_vol_min      = 0.0;
double   g_vol_max      = 0.0;
double   g_vol_step     = 0.0;
int      g_vol_digits   = 2;
int      g_stops_level  = 0;

int      g_trades_today = 0;
double   g_daily_pl_pct = 0.0;

bool     g_init_ok      = false;

//+------------------------------------------------------------------+
//| Logging helpers                                                  |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   Print(msg);
  }

void Reject(const string reason)
  {
   Print("Trade rejected. Reason: "+reason);
  }

//+------------------------------------------------------------------+
//| Convert an input "point" value into a real price distance        |
//+------------------------------------------------------------------+
double Pts(const double points)
  {
   return(points*g_pt_scale*g_point);
  }

//+------------------------------------------------------------------+
//| Current spread in broker points                                  |
//+------------------------------------------------------------------+
double SpreadPoints()
  {
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0 || g_point<=0.0)
      return(1e9);
   return((ask-bid)/g_point);
  }

//+------------------------------------------------------------------+
//| Number of decimals implied by the broker volume step             |
//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   if(step<=0.0)
      return(2);
   for(int d=0; d<=8; d++)
     {
      double scaled = step*MathPow(10.0,(double)d);
      if(MathAbs(scaled-MathRound(scaled))<1e-8)
         return(d);
     }
   return(2);
  }

//+------------------------------------------------------------------+
//| Cache symbol properties                                          |
//+------------------------------------------------------------------+
bool RefreshSymbolInfo()
  {
   g_point      = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits     = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_vol_min    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_vol_max    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_vol_step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_stops_level= (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   g_vol_digits = VolumeDigits(g_vol_step);

   g_pt_scale = 1.0;
   if(AutoAdjustForDigits && (g_digits==3 || g_digits==5))
      g_pt_scale = 10.0;

   if(g_point<=0.0 || g_vol_step<=0.0)
     {
      Log("Init error: invalid symbol properties (point / volume step).");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!RefreshSymbolInfo())
      return(INIT_FAILED);

   if(RSIPeriod<2)
     {
      Log("Init error: RSIPeriod must be >= 2.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(RSIMidline<=0.0 || RSIMidline>=100.0)
     {
      Log("Init error: RSIMidline must be between 0 and 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(SwingStrength<1)
     {
      Log("Init error: SwingStrength must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(SwingLookbackBars < SwingStrength*2+5)
     {
      Log("Init error: SwingLookbackBars is too small for SwingStrength.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(VWAPMaxLookbackBars < 50)
     {
      Log("Init error: VWAPMaxLookbackBars must be >= 50.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(RiskPercent<=0.0 || RiskReward<=0.0 || MaxLotSize<=0.0)
     {
      Log("Init error: RiskPercent, RiskReward and MaxLotSize must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(TradingSessionStart<0 || TradingSessionStart>23
      || TradingSessionEnd<0 || TradingSessionEnd>23)
     {
      Log("Init error: session hours must be between 0 and 23.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_rsi_handle = iRSI(_Symbol,SIGNAL_TF,RSIPeriod,PRICE_CLOSE);
   if(g_rsi_handle==INVALID_HANDLE)
     {
      Log("Init error: could not create the RSI indicator handle, error "
          +IntegerToString(GetLastError()));
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints((ulong)(MaxSlippagePoints<1 ? 1 : MaxSlippagePoints));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   g_last_bar = 0;
   UpdateDailyStats();

   g_init_ok = true;

   Log("=================================================================");
   Log("XAUUSD_VWAP_RSI_Scalper_V1 initialised on "+_Symbol+" (signals on M5)");
   Log(StringFormat("Point scaling: digits=%d point=%s scale=%.0f  => 1 input point = %s price",
                    g_digits,DoubleToString(g_point,g_digits),g_pt_scale,
                    DoubleToString(Pts(1.0),g_digits)));
   Log("  SLBufferPoints  "+DoubleToString(SLBufferPoints,0)+" pts = "
       +DoubleToString(Pts(SLBufferPoints),g_digits));
   Log("  MaxSpreadPoints "+DoubleToString(MaxSpreadPoints,0)+" pts = "
       +DoubleToString(Pts(MaxSpreadPoints),g_digits));
   Log(StringFormat("Volume: min=%s max=%s step=%s",
                    DoubleToString(g_vol_min,g_vol_digits),
                    DoubleToString(g_vol_max,g_vol_digits),
                    DoubleToString(g_vol_step,g_vol_digits)));
   Log(StringFormat("RSI(%d) midline %.1f | R:R %.2f | risk %.2f%% | max %d trades/day",
                    RSIPeriod,RSIMidline,RiskReward,RiskPercent,MaxTradesPerDay));
   Log(StringFormat("Current server time: %s  (session filter %d:00-%d:00 server)",
                    TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
                    TradingSessionStart,TradingSessionEnd));
   Log("Session hours and the VWAP daily reset both use BROKER/SERVER time.");
   Log("=================================================================");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_rsi_handle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_rsi_handle);
      g_rsi_handle = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Definition 7: new-candle detection                               |
//|                                                                  |
//| The open time of the forming M5 bar changes exactly when the     |
//| previous bar closes, so this returns true once per closed bar.   |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol,SIGNAL_TF,0);
   if(t==0 || t==g_last_bar)
      return(false);
   g_last_bar = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| Definition 1: session VWAP over the closed bars of the current   |
//| server day.                                                      |
//|                                                                  |
//|   TypicalPrice = (H + L + C) / 3                                 |
//|   VWAP = SUM(TypicalPrice * TickVolume) / SUM(TickVolume)        |
//|                                                                  |
//| The sum runs from bar 1 back to the first bar of the current     |
//| server date; the day rolls over automatically because the whole  |
//| sum is rebuilt on every new bar. Bar 0 is never included.        |
//+------------------------------------------------------------------+
bool ComputeSessionVWAP(double &vwap,int &bars_used,double &last_close)
  {
   vwap       = 0.0;
   bars_used  = 0;
   last_close = 0.0;

   MqlRates r[];
   ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol,SIGNAL_TF,0,VWAPMaxLookbackBars,r);
   if(copied<2)
      return(false);

   MqlDateTime ref;
   TimeToStruct(r[1].time,ref);

   double sum_pv  = 0.0;
   double sum_vol = 0.0;
   int    n       = 0;

   for(int i=1; i<copied; i++)
     {
      MqlDateTime bt;
      TimeToStruct(r[i].time,bt);
      if(bt.day!=ref.day || bt.mon!=ref.mon || bt.year!=ref.year)
         break;                                   // start of the current day reached

      double tp  = (r[i].high+r[i].low+r[i].close)/3.0;
      double vol = (double)r[i].tick_volume;
      if(vol<=0.0)
         vol = 1.0;                               // a dead bar must not zero the sum

      sum_pv  += tp*vol;
      sum_vol += vol;
      n++;
     }

   if(n<=0 || sum_vol<=0.0)
      return(false);

   vwap       = sum_pv/sum_vol;
   bars_used  = n;
   last_close = r[1].close;
   return(true);
  }

//+------------------------------------------------------------------+
//| Definition 2: RSI on the two most recent CLOSED bars             |
//|   curr = bar 1, prev = bar 2                                     |
//+------------------------------------------------------------------+
bool GetRSI(double &prev,double &curr)
  {
   prev = 0.0;
   curr = 0.0;

   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(g_rsi_handle,0,0,3,buf)<3)
      return(false);

   curr = buf[1];
   prev = buf[2];
   return(curr>0.0 && prev>0.0);
  }

//+------------------------------------------------------------------+
//| Definitions 3/4: most recent CONFIRMED M5 swing.                 |
//|                                                                  |
//| A pivot needs SwingStrength bars on BOTH sides. Requiring        |
//| i >= SwingStrength+1 forces the bars to the right of the pivot   |
//| to be closed bars, so no future candle is ever consulted.        |
//+------------------------------------------------------------------+
bool FindConfirmedSwing(const bool want_high,double &level,datetime &when)
  {
   level = 0.0;
   when  = 0;

   MqlRates r[];
   ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol,SIGNAL_TF,0,SwingLookbackBars,r);
   if(copied < SwingStrength*2+3)
      return(false);

   for(int i=SwingStrength+1; i<copied-SwingStrength; i++)
     {
      bool ok = true;
      for(int k=1; k<=SwingStrength && ok; k++)
        {
         if(want_high)
           {
            if(r[i+k].high >= r[i].high) ok = false;
            if(r[i-k].high >= r[i].high) ok = false;
           }
         else
           {
            if(r[i+k].low <= r[i].low) ok = false;
            if(r[i-k].low <= r[i].low) ok = false;
           }
        }
      if(!ok)
         continue;

      level = (want_high ? r[i].high : r[i].low);
      when  = r[i].time;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Session filter (server time, wrap-around supported)              |
//+------------------------------------------------------------------+
bool InTradingSession()
  {
   if(TradingSessionStart==TradingSessionEnd)
      return(true);                                   // 24 hours

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);

   if(TradingSessionStart<TradingSessionEnd)
      return(dt.hour>=TradingSessionStart && dt.hour<TradingSessionEnd);
   return(dt.hour>=TradingSessionStart || dt.hour<TradingSessionEnd);
  }

//+------------------------------------------------------------------+
//| Count this EA's open positions                                   |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Definition 6: daily trade count and daily P/L, rebuilt from      |
//| deal history so both survive a terminal restart.                 |
//+------------------------------------------------------------------+
void UpdateDailyStats()
  {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now,dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime day_start = StructToTime(dt);

   if(day_start!=g_day_start)
     {
      g_day_start = day_start;
      Log("New trading day: "+TimeToString(day_start,TIME_DATE)
          +" - daily counters reset.");
     }

   int    trades   = 0;
   double realized = 0.0;

   if(HistorySelect(day_start,now+1))
     {
      int total = HistoryDealsTotal();
      for(int i=0; i<total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket==0)
            continue;
         if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)
            continue;
         if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber)
            continue;

         long type = HistoryDealGetInteger(ticket,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
            continue;

         if(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN)
            trades++;

         realized += HistoryDealGetDouble(ticket,DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket,DEAL_SWAP)
                     + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
        }
     }

   double floating = 0.0;
   int positions = PositionsTotal();
   for(int i=0; i<positions; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      floating += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double day_start_bal = balance-realized;
   if(day_start_bal<=0.0)
      day_start_bal = (balance>1.0 ? balance : 1.0);

   g_trades_today = trades;
   g_daily_pl_pct = (realized+floating)/day_start_bal*100.0;
  }

//+------------------------------------------------------------------+
//| All non-signal gates. Returns "" when a trade may be opened.     |
//+------------------------------------------------------------------+
string TradingHaltReason()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return("terminal trading is disabled");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return("EA trading is disabled");
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return("account trading is disabled");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return("expert trading is disabled on this account");

   long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY)
      return("symbol trading is disabled");

   if(CountOpenPositions()>=MAX_OPEN_POSITIONS)
      return("a position with this magic number is already open");
   if(MaxTradesPerDay>0 && g_trades_today>=MaxTradesPerDay)
      return(StringFormat("daily trade limit reached (%d of %d)",
                          g_trades_today,MaxTradesPerDay));
   if(MaxDailyLossPercent>0.0 && g_daily_pl_pct<=-MathAbs(MaxDailyLossPercent))
      return(StringFormat("daily loss limit reached (%.2f%%, limit %.2f%%)",
                          g_daily_pl_pct,-MathAbs(MaxDailyLossPercent)));
   if(!InTradingSession())
      return("outside the trading session");

   double sp = SpreadPoints();
   if(sp>MaxSpreadPoints*g_pt_scale)
      return(StringFormat("spread too high (%.0f > %.0f broker points)",
                          sp,MaxSpreadPoints*g_pt_scale));

   return("");
  }

//+------------------------------------------------------------------+
//| Minimum stop distance the broker will accept                     |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   double stops  = (double)g_stops_level*g_point;
   double freeze = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
   double spread = SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double d = (stops>freeze ? stops : freeze);
   double m = spread+g_point;
   return(d>m ? d : m);
  }

//+------------------------------------------------------------------+
//| Normalize a volume to the broker's step and limits               |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   if(g_vol_step<=0.0)
      return(0.0);
   lots = MathFloor(lots/g_vol_step+1e-8)*g_vol_step;
   if(lots>g_vol_max)
      lots = g_vol_max;
   if(lots>MaxLotSize)
      lots = MathFloor(MaxLotSize/g_vol_step+1e-8)*g_vol_step;
   return(NormalizeDouble(lots,g_vol_digits));
  }

//+------------------------------------------------------------------+
//| Definition 5: position size from equity, risk % and the real     |
//| stop distance. Never a function of previous results.             |
//+------------------------------------------------------------------+
double CalculateLotSize(const double entry,const double sl)
  {
   double sl_distance = MathAbs(entry-sl);
   if(sl_distance<=0.0)
     {
      Reject("stop distance is zero");
      return(0.0);
     }

   double tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value<=0.0)
      tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0 || tick_value<=0.0)
     {
      Reject("broker tick size / tick value unavailable");
      return(0.0);
     }

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity*RiskPercent/100.0;
   if(risk_money<=0.0)
     {
      Reject("computed risk amount is zero");
      return(0.0);
     }

   double loss_per_lot = (sl_distance/tick_size)*tick_value;
   if(loss_per_lot<=0.0)
     {
      Reject("computed loss per lot is zero");
      return(0.0);
     }

   double lots = NormalizeLots(risk_money/loss_per_lot);

   if(lots<g_vol_min)
     {
      Reject(StringFormat("risk-correct volume %s is below the broker minimum %s "
                          "(stop %.0f points at %.2f%% risk) - not rounding up",
                          DoubleToString(lots,g_vol_digits),
                          DoubleToString(g_vol_min,g_vol_digits),
                          sl_distance/g_point,RiskPercent));
      return(0.0);
     }
   if(lots>g_vol_max)
     {
      Reject("computed volume exceeds the broker maximum");
      return(0.0);
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| Margin validation                                                |
//+------------------------------------------------------------------+
bool MarginIsSufficient(const ENUM_ORDER_TYPE type,const double lots,const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type,_Symbol,lots,price,margin))
     {
      Reject("OrderCalcMargin failed, error "+IntegerToString(GetLastError()));
      return(false);
     }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin>free_margin)
     {
      Reject(StringFormat("insufficient margin (need %.2f, free %.2f)",margin,free_margin));
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Build, validate and send the order                               |
//+------------------------------------------------------------------+
bool OpenPosition(const bool is_buy)
  {
   // ---- gates -----------------------------------------------------------
   string halt = TradingHaltReason();
   if(halt!="")
     {
      Reject(halt);
      return(false);
     }

   long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(is_buy && mode==SYMBOL_TRADE_MODE_SHORTONLY)
     {
      Reject("symbol is short-only");
      return(false);
     }
   if(!is_buy && mode==SYMBOL_TRADE_MODE_LONGONLY)
     {
      Reject("symbol is long-only");
      return(false);
     }

   // ---- stop loss from the most recent confirmed swing -------------------
   double swing = 0.0;
   datetime swing_time = 0;
   if(!FindConfirmedSwing(!is_buy,swing,swing_time))
     {
      Reject(StringFormat("no confirmed M5 swing %s found within %d bars",
                          is_buy ? "low" : "high",SwingLookbackBars));
      return(false);
     }

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
     {
      Reject("no valid market prices");
      return(false);
     }

   double entry  = NormalizeDouble(is_buy ? ask : bid,g_digits);
   double buffer = Pts(SLBufferPoints);
   double sl     = NormalizeDouble(is_buy ? swing-buffer : swing+buffer,g_digits);

   if((is_buy && sl>=entry) || (!is_buy && sl<=entry))
     {
      Reject(StringFormat("the most recent confirmed swing (%s) is on the wrong "
                          "side of the entry (%s)",
                          DoubleToString(swing,g_digits),
                          DoubleToString(entry,g_digits)));
      return(false);
     }

   double risk     = MathAbs(entry-sl);
   double min_dist = MinStopDistance();
   if(risk<min_dist)
     {
      Reject(StringFormat("stop distance %s is below the broker minimum %s",
                          DoubleToString(risk,g_digits),
                          DoubleToString(min_dist,g_digits)));
      return(false);
     }

   double tp = NormalizeDouble(is_buy ? entry+risk*RiskReward
                                      : entry-risk*RiskReward,g_digits);
   if((is_buy && (tp<=entry || (tp-entry)<min_dist))
      || (!is_buy && (tp>=entry || (entry-tp)<min_dist)))
     {
      Reject("take profit distance is invalid");
      return(false);
     }

   double lots = CalculateLotSize(entry,sl);
   if(lots<=0.0)
      return(false);                       // CalculateLotSize already logged why

   if(!MarginIsSufficient(is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,lots,entry))
      return(false);

   // ---- send ------------------------------------------------------------
   bool sent = (is_buy ? trade.Buy(lots,_Symbol,0.0,sl,tp,TradeComment)
                       : trade.Sell(lots,_Symbol,0.0,sl,tp,TradeComment));
   uint code = trade.ResultRetcode();

   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL
                && code!=TRADE_RETCODE_PLACED))
     {
      Log(StringFormat("%s order FAILED. Retcode=%d (%s) LastError=%d",
                       is_buy ? "BUY" : "SELL",
                       (int)code,trade.ResultRetcodeDescription(),GetLastError()));
      return(false);
     }

   double fill = trade.ResultPrice();
   if(fill<=0.0)
      fill = entry;

   Log("-----------------------------------------------------------------");
   Log(StringFormat("Trade opened: %s %s",is_buy ? "BUY" : "SELL",_Symbol));
   Log("  Volume     : "+DoubleToString(lots,g_vol_digits));
   Log("  Entry      : "+DoubleToString(fill,g_digits));
   Log("  Stop loss  : "+DoubleToString(sl,g_digits)
       +"  (swing "+DoubleToString(swing,g_digits)
       +" at "+TimeToString(swing_time,TIME_DATE|TIME_MINUTES)
       +", buffer "+DoubleToString(SLBufferPoints,0)+" pts)");
   Log("  Take profit: "+DoubleToString(tp,g_digits)
       +"  (R:R "+DoubleToString(RiskReward,2)+")");
   Log(StringFormat("  Risk       : %.2f%% of equity | risk distance %.0f points",
                    RiskPercent,risk/g_point));
   Log(StringFormat("  Trade %d of %d today | daily P/L %.2f%%",
                    g_trades_today+1,MaxTradesPerDay,g_daily_pl_pct));
   Log("-----------------------------------------------------------------");

   return(true);
  }

//+------------------------------------------------------------------+
//| Evaluated exactly once per newly closed M5 candle                |
//+------------------------------------------------------------------+
void ProcessNewBar()
  {
   UpdateDailyStats();

   double vwap = 0.0, last_close = 0.0;
   int    vwap_bars = 0;
   if(!ComputeSessionVWAP(vwap,vwap_bars,last_close))
     {
      if(LogEveryBar)
         Log("Session VWAP not available yet (waiting for closed bars in this day).");
      return;
     }

   double rsi_prev = 0.0, rsi_curr = 0.0;
   if(!GetRSI(rsi_prev,rsi_curr))
     {
      if(LogEveryBar)
         Log("RSI not available yet (indicator still warming up).");
      return;
     }

   if(LogEveryBar)
      Log(StringFormat("Bar %s | Close: %s | VWAP: %s (%d bars) | RSI: %.2f -> %.2f",
                       TimeToString(iTime(_Symbol,SIGNAL_TF,1),TIME_DATE|TIME_MINUTES),
                       DoubleToString(last_close,g_digits),
                       DoubleToString(vwap,g_digits),vwap_bars,
                       rsi_prev,rsi_curr));

   bool cross_up   = (rsi_prev<=RSIMidline && rsi_curr>RSIMidline);
   bool cross_down = (rsi_prev>=RSIMidline && rsi_curr<RSIMidline);

   bool buy_signal  = (last_close>vwap && cross_up);
   bool sell_signal = (last_close<vwap && cross_down);

   if(!buy_signal && !sell_signal)
      return;

   Log("-----------------------------------------------------------------");
   Log(StringFormat("%s signal detected on the M5 candle closed at %s",
                    buy_signal ? "BUY" : "SELL",
                    TimeToString(iTime(_Symbol,SIGNAL_TF,1),TIME_DATE|TIME_MINUTES)));
   Log("  VWAP: "+DoubleToString(vwap,g_digits)
       +"  (session VWAP over "+IntegerToString(vwap_bars)+" closed M5 bars)");
   Log("  Close: "+DoubleToString(last_close,g_digits)
       +(buy_signal ? "  (above VWAP)" : "  (below VWAP)"));
   Log(StringFormat("  RSI: %.2f -> %.2f  (%s through the %.1f midline)",
                    rsi_prev,rsi_curr,
                    buy_signal ? "crossed up" : "crossed down",RSIMidline));
   Log(StringFormat("  Spread: %.0f broker points | trades today %d/%d | daily P/L %.2f%%",
                    SpreadPoints(),g_trades_today,MaxTradesPerDay,g_daily_pl_pct));

   OpenPosition(buy_signal);
  }

//+------------------------------------------------------------------+
//| OnTick - all work is gated behind the new-bar check              |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_init_ok)
      return;
   if(!IsNewBar())
      return;

   ProcessNewBar();
  }
//+------------------------------------------------------------------+
