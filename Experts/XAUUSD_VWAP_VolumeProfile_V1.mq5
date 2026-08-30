//+------------------------------------------------------------------+
//|                        XAUUSD_VWAP_VolumeProfile_V1.mq5          |
//|                                                                  |
//|  EDUCATIONAL BACKTESTING EA                                      |
//|                                                                  |
//|  M5 rejection of daily volume-profile levels (POC / VAH / VAL)   |
//|  in the direction of session VWAP, with M15 VWAP as context.     |
//|                                                                  |
//|  NON-REPAINTING BY CONSTRUCTION:                                 |
//|    - every decision input is read from CLOSED bars (index >= 1)  |
//|    - the only shift-0 call reads the forming bar's OPEN TIME to  |
//|      detect a bar rollover, never its prices or volume           |
//|    - the volume profile is rebuilt each bar from the bars that   |
//|      had already closed at that moment, so it grows through the  |
//|      day and can never contain a future candle                   |
//|    - signals are evaluated exactly once per closed M5 candle     |
//|                                                                  |
//|  Fixed fractional risk. No martingale, grid or averaging down.   |
//|  No RSI, FVG, liquidity or order-block logic.                    |
//|                                                                  |
//|  Definitions: docs/XAUUSD_VWAP_VolumeProfile_V1.md               |
//+------------------------------------------------------------------+
#property copyright "XAUUSD_VWAP_VolumeProfile_V1"
#property link      "https://github.com/apillanesmark62-cloud/AlgorithmBot"
#property version   "2.11"
#property description "Educational M5 EA: session VWAP + daily volume profile (POC/VAH/VAL) rejection."
#property description "Non-repainting, closed-bar only. Fixed fractional risk."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Timeframes ==="
input ENUM_TIMEFRAMES SignalTF    = PERIOD_M5;   // signal timeframe
input ENUM_TIMEFRAMES ContextTF   = PERIOD_M15;  // higher-timeframe VWAP context

input group "=== Volume profile ==="
input int    ProfileDays          = 1;        // Days included in the profile (1 = today)
input int    ProfileRows          = 100;      // Number of price bins
input double ValueAreaPercent     = 70.0;     // Value area (% of total volume)
input int    ProfileMaxBars       = 600;      // signal-TF bars scanned when building the profile
input bool   ExcludeSignalBarFromProfile = true; // Build levels from bars BEFORE the signal candle

//--- V2.00 strategy modes
enum ENUM_VP_MODE
  {
   VP_MODE_USER   = 0,   // reject the edge = fade it; no rejection = trade the break
   VP_MODE_TREND  = 1    // v1 behaviour: buy/sell the level as S/R in the VWAP direction
  };

enum ENUM_TARGET_MODE
  {
   TARGET_RR       = 0,  // fixed Reward:Risk
   TARGET_POC      = 1,  // POC (falls back to RR when POC is the wrong side / too near)
   TARGET_OPPOSITE = 2   // opposite value-area edge
  };

input group "=== Signal ==="
input ENUM_VP_MODE StrategyMode   = VP_MODE_USER; // which rule to trade
input double LevelTolerancePoints = 30;       // Level interaction tolerance (points)
input bool   UseRejectionTrades   = true;     // fade the edge when it rejects
input bool   UseAcceptanceTrades  = true;     // trade the break when it does NOT reject
input double AcceptanceBufferPoints = 30;     // how far beyond the edge counts as accepted
input bool   UsePOCEntries        = false;    // also take rejections at the POC
input bool   PreferEdgeLevels     = true;     // VAH/VAL win over POC when both are in play
input bool   UseVWAPDirectionFilter = false;  // require close on the VWAP side of the trade
input bool   UseM15Filter         = false;    // Require M15 close to agree with M15 VWAP

input group "=== Targets ==="
input ENUM_TARGET_MODE TargetMode = TARGET_POC; // where rejection trades aim
input double MinTargetRR          = 1.0;      // level target must be >= this many R, else use RR

input group "=== Risk ==="
input double RiskPercent          = 0.25;     // Risk per trade (% of equity)
input double RiskReward           = 2.0;      // Reward : Risk ratio
input double SLBufferPoints       = 50;       // SL buffer beyond the rejection candle (points)
input double MaxLotSize           = 1.0;      // Maximum lot size

input group "=== Daily protection ==="
input int    MaxTradesPerDay      = 5;        // Max trades per day
input double MaxDailyLossPercent  = 1.5;      // Max daily loss (%)
input int    MaxOpenPositions     = 1;        // Max simultaneous positions
input double MaxSpreadPoints      = 40;       // Max allowed spread (points)

input group "=== Session (BROKER / SERVER TIME!) ==="
input int    TradingSessionStart  = 7;        // Session start hour (server time)
input int    TradingSessionEnd    = 21;       // Session end hour (server time)

input group "=== Execution ==="
input long   MagicNumber          = 20250819; // Magic number
input int    MaxSlippagePoints    = 30;       // Max deviation (broker points)
input string TradeComment         = "VWAP_VP_V1"; // Trade comment
input bool   AutoAdjustForDigits  = true;     // Scale point inputs on 3/5 digit feeds

input group "=== Diagnostics ==="
input bool   LogEveryBar          = false;    // Log VWAP/POC/VAH/VAL every closed M5 bar

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
// V1.10: the timeframes were hardcoded to M5/M15. Testing has shown the
// spread is ~21% of an M5 stop but only ~3% of an H1 stop, so the ability
// to run this on H1 matters more than any parameter in the file.
#define SIGNAL_TF   SignalTF
#define CONTEXT_TF  ContextTF

//+------------------------------------------------------------------+
//| Result of one volume-profile build (scalars only)                |
//+------------------------------------------------------------------+
struct ProfileResult
  {
   bool   valid;
   double range_low;
   double range_high;
   double bin_size;
   double total_volume;
   int    bars_used;
   int    poc_bin;
   int    va_low_bin;
   int    va_high_bin;
   double poc;
   double vah;
   double val;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   trade;

double   g_bins[];                 // accumulated volume per price bin

datetime g_last_bar     = 0;       // open time of the last processed M5 bar
datetime g_day_start    = 0;       // server midnight of the current day

double   g_point        = 0.0;
int      g_digits       = 0;
double   g_pt_scale     = 1.0;
double   g_vol_min      = 0.0;
double   g_vol_max      = 0.0;
double   g_vol_step     = 0.0;
int      g_vol_digits   = 2;
int      g_stops_level  = 0;

int      g_trades_today = 0;
double   g_daily_pl_pct = 0.0;

bool     g_init_ok      = false;

//--- V1.10 per-LEVEL attribution (diagnostics only, never read by a decision)
#define LVL_POC 0
#define LVL_VAH 1
#define LVL_VAL 2
//--- V2.00: attribution is per (level x kind): index = level*2 + (accept?1:0)
#define BUCKETS 6
string  lvlName[BUCKETS];
long    lvlSignals[BUCKETS], lvlTrades[BUCKETS], lvlWins[BUCKETS], lvlLosses[BUCKETS];
long    lvlBlocked[BUCKETS];
double  lvlGrossWin[BUCKETS], lvlGrossLoss[BUCKETS];

ulong   g_ticket    = 0;      // open position being tracked
int     g_posLevel  = -1;     // which level produced it

//--- funnel counters
long cBars=0, cSession=0, cDaily=0, cLoss=0, cOpenPos=0, cSpread=0;
long cVwapNA=0, cProfNA=0, cBiasNone=0, cM15=0, cNoLevel=0, cNoReject=0;
long cSigLong=0, cSigShort=0, cOpened=0, cRejected=0;
//--- V2.10: why a signal never became a position
long hOpenPos=0, hDayCap=0, hDayLoss=0, hSession=0, hSpread=0;
//--- V2.11: signals lost to the broker minimum lot, and how wide their stops were
long   hMinLot=0;
double hMinLotStopSum=0.0, hMinLotStopMax=0.0;
double hTakenStopSum=0.0;

//+------------------------------------------------------------------+
//| Logging helpers                                                  |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   Print(msg);
  }

void Reject(const string reason)
  {
   Print("Trade rejected: "+reason);
  }

//+------------------------------------------------------------------+
//| Input "points" -> real price distance                            |
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
//| Server midnight of a given time                                  |
//+------------------------------------------------------------------+
datetime DayStartOf(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t,d);
   d.hour = 0;
   d.min  = 0;
   d.sec  = 0;
   return(StructToTime(d));
  }

//+------------------------------------------------------------------+
//| Decimals implied by the broker volume step                       |
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
   g_point       = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits      = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_vol_min     = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_vol_max     = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_vol_step    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_stops_level = (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   g_vol_digits  = VolumeDigits(g_vol_step);

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

   if(ProfileDays<1)
     {
      Log("Init error: ProfileDays must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(ProfileRows<10 || ProfileRows>5000)
     {
      Log("Init error: ProfileRows must be between 10 and 5000.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(ValueAreaPercent<=0.0 || ValueAreaPercent>100.0)
     {
      Log("Init error: ValueAreaPercent must be between 0 and 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(ProfileMaxBars<100)
     {
      Log("Init error: ProfileMaxBars must be >= 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(RiskPercent<=0.0 || RiskReward<=0.0 || MaxLotSize<=0.0)
     {
      Log("Init error: RiskPercent, RiskReward and MaxLotSize must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(MaxOpenPositions<1)
     {
      Log("Init error: MaxOpenPositions must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(TradingSessionStart<0 || TradingSessionStart>23
      || TradingSessionEnd<0 || TradingSessionEnd>23)
     {
      Log("Init error: session hours must be between 0 and 23.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(ArrayResize(g_bins,ProfileRows)!=ProfileRows)
     {
      Log("Init error: could not allocate the volume-profile bins.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints((ulong)(MaxSlippagePoints<1 ? 1 : MaxSlippagePoints));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   // V2.11: the attribution counters are reset EXACTLY ONCE, here. They used
   // to be reset inside BuildProfile(), which runs on every closed bar, so
   // every bucket read zero at the end of every run no matter what traded.
   lvlName[0]="POC_REJECT"; lvlName[1]="POC_ACCEPT";
   lvlName[2]="VAH_REJECT"; lvlName[3]="VAH_ACCEPT";
   lvlName[4]="VAL_REJECT"; lvlName[5]="VAL_ACCEPT";
   ArrayInitialize(lvlSignals,0); ArrayInitialize(lvlTrades,0);
   ArrayInitialize(lvlBlocked,0);
   ArrayInitialize(lvlWins,0);    ArrayInitialize(lvlLosses,0);
   ArrayInitialize(lvlGrossWin,0.0); ArrayInitialize(lvlGrossLoss,0.0);

   g_last_bar = 0;
   UpdateDailyStats();

   g_init_ok = true;

   Log("=================================================================");
   Log("XAUUSD_VWAP_VolumeProfile_V1 initialised on "+_Symbol+" (signals on M5)");
   Log(StringFormat("Point scaling: digits=%d point=%s scale=%.0f  => 1 input point = %s price",
                    g_digits,DoubleToString(g_point,g_digits),g_pt_scale,
                    DoubleToString(Pts(1.0),g_digits)));
   Log("  LevelTolerancePoints "+DoubleToString(LevelTolerancePoints,0)+" pts = "
       +DoubleToString(Pts(LevelTolerancePoints),g_digits));
   Log("  SLBufferPoints       "+DoubleToString(SLBufferPoints,0)+" pts = "
       +DoubleToString(Pts(SLBufferPoints),g_digits));
   Log("  MaxSpreadPoints      "+DoubleToString(MaxSpreadPoints,0)+" pts = "
       +DoubleToString(Pts(MaxSpreadPoints),g_digits));
   Log(StringFormat("Profile: %d day(s), %d rows, value area %.1f%%, signal bar %s",
                    ProfileDays,ProfileRows,ValueAreaPercent,
                    ExcludeSignalBarFromProfile ? "EXCLUDED" : "included"));
   Log(StringFormat("M15 context filter: %s",UseM15Filter ? "ON" : "OFF"));
   Log(StringFormat("Volume: min=%s max=%s step=%s",
                    DoubleToString(g_vol_min,g_vol_digits),
                    DoubleToString(g_vol_max,g_vol_digits),
                    DoubleToString(g_vol_step,g_vol_digits)));
   Log(StringFormat("Risk %.2f%% | R:R %.2f | max %d trades/day | max daily loss %.2f%%",
                    RiskPercent,RiskReward,MaxTradesPerDay,MaxDailyLossPercent));
   Log(StringFormat("Current server time: %s  (session filter %d:00-%d:00 server)",
                    TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
                    TradingSessionStart,TradingSessionEnd));
   Log("Session hours, the VWAP reset and the profile day all use BROKER/SERVER time.");
   Log("=================================================================");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintSummary();
   ArrayFree(g_bins);
  }

//+------------------------------------------------------------------+
//| Definition 13: new M5 candle detection                           |
//|                                                                  |
//| The forming bar's OPEN TIME changes exactly when the previous    |
//| bar closes. No price or volume of bar 0 is ever read.            |
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
//| Definitions 1 + 2: session VWAP over the closed bars of the      |
//| current server day on the requested timeframe.                   |
//|                                                                  |
//|   TypicalPrice = (H + L + C) / 3                                 |
//|   VWAP = SUM(TypicalPrice * TickVolume) / SUM(TickVolume)        |
//|                                                                  |
//| The scan stops at the first bar of a different server date, so   |
//| the daily reset is automatic and needs no stored state.          |
//+------------------------------------------------------------------+
bool ComputeSessionVWAP(const ENUM_TIMEFRAMES tf,const int max_bars,
                        double &vwap,int &bars_used,double &last_close)
  {
   vwap       = 0.0;
   bars_used  = 0;
   last_close = 0.0;

   MqlRates r[];
   ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol,tf,0,max_bars,r);
   if(copied<2)
      return(false);

   datetime ref_day = DayStartOf(r[1].time);

   double sum_pv  = 0.0;
   double sum_vol = 0.0;
   int    n       = 0;

   for(int i=1; i<copied; i++)
     {
      if(DayStartOf(r[i].time)!=ref_day)
         break;                                    // start of the session reached

      double tp  = (r[i].high+r[i].low+r[i].close)/3.0;
      double vol = (double)r[i].tick_volume;
      if(vol<=0.0)
         vol = 1.0;                                // a dead bar must not zero the sum

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
//| Definition 3: bin index of a price, clamped into the profile     |
//+------------------------------------------------------------------+
int BinIndex(const double price,const double range_low,const double bin_size)
  {
   if(bin_size<=0.0)
      return(0);
   int b = (int)MathFloor((price-range_low)/bin_size);
   if(b<0)
      b = 0;
   if(b>ProfileRows-1)
      b = ProfileRows-1;
   return(b);
  }

double BinLowPrice(const double range_low,const double bin_size,const int b)
  {
   return(range_low+bin_size*(double)b);
  }

double BinHighPrice(const double range_low,const double bin_size,const int b)
  {
   return(range_low+bin_size*(double)(b+1));
  }

double BinMidPrice(const double range_low,const double bin_size,const int b)
  {
   return(range_low+bin_size*((double)b+0.5));
  }

//+------------------------------------------------------------------+
//| Definitions 3-8: build the daily volume profile and derive       |
//| POC, VAH and VAL.                                                |
//|                                                                  |
//| LOOK-AHEAD SAFETY: the scan starts at bar 1 (or bar 2 when       |
//| ExcludeSignalBarFromProfile is on) and walks BACKWARDS only, so  |
//| the profile can only ever contain candles that had already       |
//| closed when the signal is evaluated. It is rebuilt from scratch  |
//| on every new bar, so it grows through the trading day and is     |
//| never today's finished profile applied retroactively.            |
//+------------------------------------------------------------------+
bool BuildProfile(ProfileResult &vp)
  {
   vp.valid        = false;
   vp.range_low    = 0.0;
   vp.range_high   = 0.0;
   vp.bin_size     = 0.0;
   vp.total_volume = 0.0;
   vp.bars_used    = 0;
   vp.poc_bin      = 0;
   vp.va_low_bin   = 0;
   vp.va_high_bin  = 0;
   vp.poc          = 0.0;
   vp.vah          = 0.0;
   vp.val          = 0.0;

   MqlRates r[];
   ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol,SIGNAL_TF,0,ProfileMaxBars,r);
   if(copied<3)
      return(false);

   int first = (ExcludeSignalBarFromProfile ? 2 : 1);
   if(copied<=first)
      return(false);

   // the profile window is anchored on the SIGNAL bar's server day
   datetime ref_day   = DayStartOf(r[1].time);
   datetime last_day  = ref_day;
   int      days_seen = 1;

   // ---- pass 1: the price range of the window --------------------------
   double range_low  = 0.0;
   double range_high = 0.0;
   int    n          = 0;
   int    last_index = first-1;

   for(int i=first; i<copied; i++)
     {
      datetime bd = DayStartOf(r[i].time);
      if(bd>ref_day)
         continue;                                  // defensive, should not happen
      if(bd!=last_day)
        {
         days_seen++;
         if(days_seen>ProfileDays)
            break;
         last_day = bd;
        }

      if(n==0)
        {
         range_low  = r[i].low;
         range_high = r[i].high;
        }
      else
        {
         if(r[i].low<range_low)   range_low  = r[i].low;
         if(r[i].high>range_high) range_high = r[i].high;
        }
      n++;
      last_index = i;
     }

   if(n<2)
      return(false);                                // not enough data yet today

   double bin_size = (range_high-range_low)/(double)ProfileRows;
   if(bin_size<=0.0)
      return(false);                                // flat window, no profile

   // ---- pass 2: definition 4, allocate tick volume to bins -------------
   ArrayInitialize(g_bins,0.0);
   double total = 0.0;

   for(int i=first; i<=last_index; i++)
     {
      datetime bd = DayStartOf(r[i].time);
      if(bd>ref_day)
         continue;

      double vol = (double)r[i].tick_volume;
      if(vol<=0.0)
         vol = 1.0;

      int b_low  = BinIndex(r[i].low,range_low,bin_size);
      int b_high = BinIndex(r[i].high,range_low,bin_size);
      if(b_high<b_low)
        {
         int swap = b_low;
         b_low  = b_high;
         b_high = swap;
        }

      int    spanned = b_high-b_low+1;
      double share   = vol/(double)spanned;

      for(int b=b_low; b<=b_high; b++)
         g_bins[b] += share;

      total += vol;
     }

   if(total<=0.0)
      return(false);

   // ---- definition 5: POC (lowest bin index wins a tie) ----------------
   int    poc_bin = 0;
   double poc_vol = g_bins[0];
   for(int b=1; b<ProfileRows; b++)
     {
      if(g_bins[b]>poc_vol)
        {
         poc_vol = g_bins[b];
         poc_bin = b;
        }
     }

   // ---- definition 6: value area, single-bin expansion from the POC ----
   double target = total*ValueAreaPercent/100.0;
   double acc    = g_bins[poc_bin];
   int    up     = poc_bin+1;
   int    down   = poc_bin-1;
   int    va_hi  = poc_bin;
   int    va_lo  = poc_bin;

   while(acc<target && (up<ProfileRows || down>=0))
     {
      double v_up   = (up<ProfileRows ? g_bins[up]   : -1.0);
      double v_down = (down>=0        ? g_bins[down] : -1.0);

      if(v_up>=v_down && up<ProfileRows)            // a tie resolves upward
        {
         acc  += g_bins[up];
         va_hi = up;
         up++;
        }
      else
         if(down>=0)
           {
            acc  += g_bins[down];
            va_lo = down;
            down--;
           }
         else
            break;
     }

   vp.valid        = true;
   vp.range_low    = range_low;
   vp.range_high   = range_high;
   vp.bin_size     = bin_size;
   vp.total_volume = total;
   vp.bars_used    = n;
   vp.poc_bin      = poc_bin;
   vp.va_low_bin   = va_lo;
   vp.va_high_bin  = va_hi;
   vp.poc          = BinMidPrice(range_low,bin_size,poc_bin);   // definition 5
   vp.vah          = BinHighPrice(range_low,bin_size,va_hi);    // definition 7
   vp.val          = BinLowPrice(range_low,bin_size,va_lo);     // definition 8
   return(true);
  }

//+------------------------------------------------------------------+
//| Session filter (server time, wrap-around supported)              |
//+------------------------------------------------------------------+
bool InTradingSession()
  {
   if(TradingSessionStart==TradingSessionEnd)
      return(true);                                 // 24 hours

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
//| Definition 12: daily trade count and daily P/L, rebuilt from     |
//| deal history so both are correct after a restart.                |
//+------------------------------------------------------------------+
void UpdateDailyStats()
  {
   datetime now       = TimeCurrent();
   datetime day_start = DayStartOf(now);

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
   double start_bal = balance-realized;
   if(start_bal<=0.0)
      start_bal = (balance>1.0 ? balance : 1.0);

   g_trades_today = trades;
   g_daily_pl_pct = (realized+floating)/start_bal*100.0;
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

   if(CountOpenPositions()>=MaxOpenPositions)
     {
      hOpenPos++;
      return("a position with this magic number is already open");
     }
   if(MaxTradesPerDay>0 && g_trades_today>=MaxTradesPerDay)
     {
      hDayCap++;
      return(StringFormat("daily trade limit reached (%d of %d)",
                          g_trades_today,MaxTradesPerDay));
     }
   if(MaxDailyLossPercent>0.0 && g_daily_pl_pct<=-MathAbs(MaxDailyLossPercent))
     {
      hDayLoss++;
      return(StringFormat("daily loss limit reached (%.2f%%, limit %.2f%%)",
                          g_daily_pl_pct,-MathAbs(MaxDailyLossPercent)));
     }
   if(!InTradingSession())
     {
      hSession++;
      return("outside the trading session");
     }

   double sp = SpreadPoints();
   if(sp>MaxSpreadPoints*g_pt_scale)
     {
      hSpread++;
      return(StringFormat("spread too high (%.0f > %.0f broker points)",
                          sp,MaxSpreadPoints*g_pt_scale));
     }

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
//| Definition 14: dynamic position sizing.                          |
//| Reads equity, RiskPercent and the real stop distance only -      |
//| never previous results.                                          |
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
      // The risk cap is doing its job, but these skips are NOT random: they
      // remove every setup with a wide stop, so what survives is a biased
      // sample of unusually tight signal candles. Counted so the bias is
      // visible in the summary instead of hiding in the trade count.
      hMinLot++;
      double sl_pts = sl_distance/g_point;
      hMinLotStopSum += sl_pts;
      if(sl_pts>hMinLotStopMax) hMinLotStopMax = sl_pts;
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
   hTakenStopSum += sl_distance/g_point;
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
//|                                                                  |
//| candle_low / candle_high are the rejection candle's extremes;    |
//| the stop sits beyond them by SLBufferPoints.                     |
//+------------------------------------------------------------------+
bool OpenPosition(const bool is_long,const double candle_low,const double candle_high,
                  const double level,const string level_name,const double target_price,
                  const int bucket)
  {
   string halt = TradingHaltReason();
   if(halt!="")
     {
      Reject(halt);
      return(false);
     }

   long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(is_long && mode==SYMBOL_TRADE_MODE_SHORTONLY)
     {
      Reject("symbol is short-only");
      return(false);
     }
   if(!is_long && mode==SYMBOL_TRADE_MODE_LONGONLY)
     {
      Reject("symbol is long-only");
      return(false);
     }

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
     {
      Reject("no valid market prices");
      return(false);
     }

   double entry  = NormalizeDouble(is_long ? ask : bid,g_digits);
   double buffer = Pts(SLBufferPoints);
   double sl     = NormalizeDouble(is_long ? candle_low-buffer
                                           : candle_high+buffer,g_digits);

   if((is_long && sl>=entry) || (!is_long && sl<=entry))
     {
      Reject(StringFormat("stop %s is on the wrong side of the entry %s "
                          "(price moved through the rejection candle)",
                          DoubleToString(sl,g_digits),
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

   // V2.00: a level target (POC / opposite VA edge) is used when it lies on
   // the correct side AND is worth at least MinTargetRR; otherwise fall back
   // to the fixed Reward:Risk so a target 0.2R away can never be taken.
   double tp = is_long ? entry+risk*RiskReward : entry-risk*RiskReward;
   if(target_price>0.0)
     {
      bool side_ok = (is_long ? target_price>entry : target_price<entry);
      double tgt_rr = (side_ok && risk>0.0 ? MathAbs(target_price-entry)/risk : 0.0);
      if(side_ok && tgt_rr>=MinTargetRR)
         tp = target_price;
     }
   tp = NormalizeDouble(tp,g_digits);
   if((is_long && (tp<=entry || (tp-entry)<min_dist))
      || (!is_long && (tp>=entry || (entry-tp)<min_dist)))
     {
      Reject("take profit distance is invalid");
      return(false);
     }

   double lots = CalculateLotSize(entry,sl);
   if(lots<=0.0)
      return(false);                                // already logged the reason

   if(!MarginIsSufficient(is_long ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,lots,entry))
      return(false);

   bool sent = (is_long ? trade.Buy(lots,_Symbol,0.0,sl,tp,level_name)
                        : trade.Sell(lots,_Symbol,0.0,sl,tp,level_name));
   uint code = trade.ResultRetcode();

   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL
                && code!=TRADE_RETCODE_PLACED))
     {
      Log(StringFormat("%s order FAILED. Retcode=%d (%s) LastError=%d",
                       is_long ? "BUY" : "SELL",
                       (int)code,trade.ResultRetcodeDescription(),GetLastError()));
      return(false);
     }

   double fill = trade.ResultPrice();
   if(fill<=0.0)
      fill = entry;

   // V1.10: remember the ticket so the result can be attributed to its level
   g_ticket = 0;
   for(int i=PositionsTotal()-1;i>=0;--i)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
        { g_ticket = tk; break; }
     }
   // V2.10: the bucket is armed HERE, not at signal time. A signal that is
   // blocked while an earlier position is still open used to overwrite
   // g_posLevel, so that position's result was credited to the wrong level.
   g_posLevel = bucket;
   if(bucket>=0 && bucket<BUCKETS) lvlTrades[bucket]++;
   cOpened++;

   Log("-----------------------------------------------------------------");
   Log(StringFormat("Trade opened: %s %s at %s",
                    is_long ? "BUY" : "SELL",_Symbol,DoubleToString(fill,g_digits)));
   Log("  Volume      : "+DoubleToString(lots,g_vol_digits));
   Log("  VP level    : "+level_name+" = "+DoubleToString(level,g_digits));
   Log("  Stop loss   : "+DoubleToString(sl,g_digits)
       +"  (rejection candle "+(is_long ? "low " : "high ")
       +DoubleToString(is_long ? candle_low : candle_high,g_digits)
       +" +/- "+DoubleToString(SLBufferPoints,0)+" pts)");
   Log("  Take profit : "+DoubleToString(tp,g_digits)
       +"  (R:R "+DoubleToString(RiskReward,2)+")");
   Log(StringFormat("  Risk        : %.2f%% of equity | risk distance %.0f points",
                    RiskPercent,risk/g_point));
   Log(StringFormat("  Trade %d of %d today | daily P/L %.2f%%",
                    g_trades_today+1,MaxTradesPerDay,g_daily_pl_pct));
   Log("-----------------------------------------------------------------");

   return(true);
  }

//+------------------------------------------------------------------+
//| Definition 9: does level L interact with the closed candle?      |
//| The level must lie inside the candle's range widened by the      |
//| tolerance on both sides.                                         |
//+------------------------------------------------------------------+
bool LevelInteracts(const double level,const double c_low,const double c_high,
                    const double tol)
  {
   return(level>=c_low-tol && level<=c_high+tol);
  }

//+------------------------------------------------------------------+
//| Evaluated exactly once per newly closed M5 candle                |
//+------------------------------------------------------------------+
void ProcessNewBar()
  {
   cBars++;
   UpdateDailyStats();

   // ---- the closed signal candle ---------------------------------------
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,SIGNAL_TF,0,3,r)<3)
      return;

   double c_open  = r[1].open;
   double c_high  = r[1].high;
   double c_low   = r[1].low;
   double c_close = r[1].close;
   datetime c_time = r[1].time;

   // ---- session VWAP ----------------------------------------------------
   double vwap = 0.0, vwap_close = 0.0;
   int    vwap_bars = 0;
   if(!ComputeSessionVWAP(SIGNAL_TF,ProfileMaxBars,vwap,vwap_bars,vwap_close))
     {
      cVwapNA++;
      if(LogEveryBar)
         Log("Session VWAP not available yet (no closed bars in this day).");
      return;
     }

   // ---- volume profile --------------------------------------------------
   ProfileResult vp;
   if(!BuildProfile(vp) || !vp.valid)
     {
      cProfNA++;
      if(LogEveryBar)
         Log("Volume profile not available yet (too few closed bars in the window).");
      return;
     }

   // ---- VWAP bias (used for logging, and only as a FILTER if asked) -----
   string bias = "NONE";
   if(c_close>vwap) bias = "BULLISH";
   if(c_close<vwap) bias = "BEARISH";

   if(LogEveryBar)
     {
      Log(StringFormat("Bar %s | price = %s | VWAP bias = %s",
                       TimeToString(c_time,TIME_DATE|TIME_MINUTES),
                       DoubleToString(c_close,g_digits),bias));
      Log(StringFormat("  VWAP = %s (%d bars) | POC = %s | VAH = %s | VAL = %s "
                       "| profile bars = %d",
                       DoubleToString(vwap,g_digits),vwap_bars,
                       DoubleToString(vp.poc,g_digits),
                       DoubleToString(vp.vah,g_digits),
                       DoubleToString(vp.val,g_digits),
                       vp.bars_used));
     }

   // ---- candle quality + optional VWAP-side filter ----------------------
   bool bull_body = (c_close>c_open);
   bool bear_body = (c_close<c_open);
   bool vwap_bull = (!UseVWAPDirectionFilter || c_close>vwap);
   bool vwap_bear = (!UseVWAPDirectionFilter || c_close<vwap);
   bool bull_ok   = bull_body && vwap_bull;
   bool bear_ok   = bear_body && vwap_bear;

   // ---- which value-area level is in play -------------------------------
   double tol    = Pts(LevelTolerancePoints);
   double accbuf = Pts(AcceptanceBufferPoints);

   double levels[3];
   levels[LVL_POC] = vp.poc;
   levels[LVL_VAH] = vp.vah;
   levels[LVL_VAL] = vp.val;

   // V2.10: the POC sits in the middle of the value area, which is exactly
   // where price spends most of its time, so a plain nearest-level search
   // hands almost every signal to the POC and the VAH/VAL rule never gets
   // tested. With PreferEdgeLevels the edges are searched first and the POC
   // is only considered when neither edge is in play.
   int    best = -1;
   double best_dist = 0.0;
   for(int pass=0; pass<2; pass++)
     {
      for(int k=0; k<3; k++)
        {
         bool is_poc = (k==LVL_POC);
         if(is_poc && !UsePOCEntries)
            continue;
         if(PreferEdgeLevels && (is_poc ? pass==0 : pass==1))
            continue;
         if(!LevelInteracts(levels[k],c_low,c_high,tol))
            continue;
         double dist = MathAbs(c_close-levels[k]);
         if(best<0 || dist<best_dist)
           {
            best = k;
            best_dist = dist;
           }
        }
      if(best>=0 || !PreferEdgeLevels)
         break;
     }

   if(best<0)
     {
      cNoLevel++;
      return;                                      // no level in play, no trade
     }

   double level = levels[best];

   // ---- REJECTION or ACCEPTANCE ----------------------------------------
   // USER mode, exactly as described:
   //   VAH tagged and closed back BELOW it        -> rejection  -> SELL
   //   VAH closed clearly ABOVE it (accepted)     -> breakout   -> BUY
   //   VAL is the mirror.
   // The two are mutually exclusive: the acceptance buffer leaves a dead
   // zone just beyond the edge where neither fires.
   bool want_long = false;
   bool is_accept = false;
   bool have      = false;

   if(StrategyMode==VP_MODE_USER)
     {
      if(UseRejectionTrades)
        {
         if(best==LVL_VAH && c_high>=level-tol && c_close<level && bear_ok)
           { want_long=false; is_accept=false; have=true; }
         else if(best==LVL_VAL && c_low<=level+tol && c_close>level && bull_ok)
           { want_long=true;  is_accept=false; have=true; }
         else if(best==LVL_POC)
           {
            if(c_low<=level+tol && c_close>level && bull_ok)
              { want_long=true;  is_accept=false; have=true; }
            else if(c_high>=level-tol && c_close<level && bear_ok)
              { want_long=false; is_accept=false; have=true; }
           }
        }

      if(!have && UseAcceptanceTrades)
        {
         if(best==LVL_VAH && c_close>level+accbuf && bull_ok)
           { want_long=true;  is_accept=true; have=true; }
         else if(best==LVL_VAL && c_close<level-accbuf && bear_ok)
           { want_long=false; is_accept=true; have=true; }
        }
     }
   else
     {
      // VP_MODE_TREND - the v1 rule, kept so the two can be compared
      if(bias=="NONE") { cBiasNone++; return; }
      want_long = (bias=="BULLISH");
      bool rejection = want_long
            ? (c_low<=level+tol  && c_close>level && bull_body && c_close>vwap)
            : (c_high>=level-tol && c_close<level && bear_body && c_close<vwap);
      if(rejection) { is_accept=false; have=true; }
     }

   if(!have)
     {
      cNoReject++;
      if(LogEveryBar)
         Log("  level in play but neither a rejection nor an acceptance close");
      return;
     }

   // ---- optional higher-timeframe agreement -----------------------------
   if(UseM15Filter)
     {
      double m15_vwap = 0.0, m15_close = 0.0;
      int    m15_bars = 0;
      if(!ComputeSessionVWAP(CONTEXT_TF,300,m15_vwap,m15_bars,m15_close))
         return;
      bool m15_bull = (m15_close>m15_vwap);
      bool m15_bear = (m15_close<m15_vwap);
      if((want_long && !m15_bull) || (!want_long && !m15_bear))
        {
         cM15++;
         return;
        }
     }

   // ---- attribution bucket: level x kind --------------------------------
   int bucket = best*2 + (is_accept ? 1 : 0);
   lvlSignals[bucket]++;
   string lname = lvlName[bucket];

   // ---- target ----------------------------------------------------------
   // Level targets only make sense for rejection trades (fading back into
   // value). A breakout has no level ahead of it, so it always uses R:R.
   double target = 0.0;
   if(!is_accept && TargetMode!=TARGET_RR)
     {
      if(TargetMode==TARGET_POC && best!=LVL_POC)
         target = vp.poc;
      else
         target = want_long ? vp.vah : vp.val;   // opposite edge
     }

   // ---- signal ----------------------------------------------------------
   Log("-----------------------------------------------------------------");
   Log(StringFormat("%s signal | %s | candle closed %s",
                    want_long ? "BUY" : "SELL", lname,
                    TimeToString(c_time,TIME_DATE|TIME_MINUTES)));
   Log("  POC = "+DoubleToString(vp.poc,g_digits)
       +" | VAH = "+DoubleToString(vp.vah,g_digits)
       +" | VAL = "+DoubleToString(vp.val,g_digits)
       +" | VWAP = "+DoubleToString(vwap,g_digits));
   Log(StringFormat("  level %s = %s   candle O %s H %s L %s C %s",
                    lname,DoubleToString(level,g_digits),
                    DoubleToString(c_open,g_digits),
                    DoubleToString(c_high,g_digits),
                    DoubleToString(c_low,g_digits),
                    DoubleToString(c_close,g_digits)));
   Log("  target = "+(target>0.0 ? DoubleToString(target,g_digits)
                                 : "R:R "+DoubleToString(RiskReward,2)));
   Log(StringFormat("  Spread = %.0f pts | trades today %d/%d | daily P/L %.2f%%",
                    SpreadPoints(),g_trades_today,MaxTradesPerDay,g_daily_pl_pct));

   if(want_long) cSigLong++; else cSigShort++;
   if(!OpenPosition(want_long,c_low,c_high,level,lname,target,bucket))
     {
      cRejected++;
      lvlBlocked[bucket]++;
     }
  }

//+------------------------------------------------------------------+
//| V1.10: attribute a closed position to the level that produced it |
//+------------------------------------------------------------------+
void SettleClosedPosition()
  {
   if(g_ticket==0)
      return;
   if(PositionSelectByTicket(g_ticket))
      return;                                   // still open

   double pl = 0.0;
   if(HistorySelectByPosition(g_ticket))
     {
      int n = HistoryDealsTotal();
      for(int i=0;i<n;i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk==0) continue;
         pl += HistoryDealGetDouble(tk,DEAL_PROFIT)
             + HistoryDealGetDouble(tk,DEAL_SWAP)
             + HistoryDealGetDouble(tk,DEAL_COMMISSION);
        }
     }

   int lv = g_posLevel;
   if(lv>=0 && lv<BUCKETS)
     {
      if(pl>=0.0) { lvlWins[lv]++;   lvlGrossWin[lv]  += pl;  }
      else        { lvlLosses[lv]++; lvlGrossLoss[lv] += -pl; }
      Log("Closed "+lvlName[lv]+" trade | P/L="+DoubleToString(pl,2));
     }

   g_ticket   = 0;
   g_posLevel = -1;
  }

//+------------------------------------------------------------------+
//| V1.10: end-of-run funnel + per-level attribution                 |
//+------------------------------------------------------------------+
void PrintSummary()
  {
   Print("========== VWAP + VOLUME PROFILE : PER-LEVEL ATTRIBUTION ==========");
   // V2.10: echo the whole configuration. A journal block that does not say
   // which switches were on cannot be compared against another run.
   Print("Signal TF = ",EnumToString(SignalTF),
         "   Context TF = ",EnumToString(ContextTF),
         "   ProfileDays = ",ProfileDays,
         "   Rows = ",ProfileRows,
         "   VA% = ",DoubleToString(ValueAreaPercent,1),
         "   ExcludeSignalBar = ",ExcludeSignalBarFromProfile);
   Print("Mode = ",EnumToString(StrategyMode),
         "   Rejection = ",UseRejectionTrades,
         "   Acceptance = ",UseAcceptanceTrades,
         "   POC entries = ",UsePOCEntries,
         "   PreferEdges = ",PreferEdgeLevels);
   Print("Tolerance = ",DoubleToString(LevelTolerancePoints,0)," pts",
         "   AcceptBuffer = ",DoubleToString(AcceptanceBufferPoints,0)," pts",
         "   VWAP filter = ",UseVWAPDirectionFilter,
         "   HTF filter = ",UseM15Filter);
   Print("Target = ",EnumToString(TargetMode),
         "   MinTargetRR = ",DoubleToString(MinTargetRR,2),
         "   R:R = ",DoubleToString(RiskReward,2),
         "   SL buffer = ",DoubleToString(SLBufferPoints,0)," pts");
   Print("Risk% = ",DoubleToString(RiskPercent,2),
         "   MaxTrades/day = ",MaxTradesPerDay,
         "   MaxOpenPos = ",MaxOpenPositions,
         "   MaxDailyLoss% = ",DoubleToString(MaxDailyLossPercent,2),
         "   MaxSpread = ",DoubleToString(MaxSpreadPoints,0)," pts");
   Print("Session = ",TradingSessionStart,":00 -> ",TradingSessionEnd,
         ":00 server time");
   Print("-------------------------------------------------------------------");
   for(int i=0;i<BUCKETS;i++)
     {
      long closed = lvlWins[i]+lvlLosses[i];
      double pf   = (lvlGrossLoss[i]>0.0 ? lvlGrossWin[i]/lvlGrossLoss[i] : 0.0);
      double wr   = (closed>0 ? 100.0*lvlWins[i]/closed : 0.0);
      double net  = lvlGrossWin[i]-lvlGrossLoss[i];
      Print(lvlName[i],
            " | signals=",lvlSignals[i],
            " blocked=",lvlBlocked[i],
            " trades=",lvlTrades[i],
            " closed=",closed,
            " win%=",DoubleToString(wr,1),
            " PF=",DoubleToString(pf,2),
            " net=",DoubleToString(net,2));
     }
   Print("-------------------------------------------------------------------");
   Print("Bars evaluated            : ",cBars);
   Print("  VWAP not available      : ",cVwapNA);
   Print("  profile not available   : ",cProfNA);
   Print("  price sitting on VWAP   : ",cBiasNone);
   Print("  higher-TF context vetoed: ",cM15);
   Print("  no level interaction    : ",cNoLevel);
   Print("  level touched, NO reject: ",cNoReject);
   Print("  LONG signals            : ",cSigLong);
   Print("  SHORT signals           : ",cSigShort);
   Print("  blocked at execution    : ",cRejected);
   Print("    position already open : ",hOpenPos);
   Print("    daily trade cap       : ",hDayCap);
   Print("    daily loss limit      : ",hDayLoss);
   Print("    outside session       : ",hSession);
   Print("    spread too wide       : ",hSpread);
   Print("    below broker min lot  : ",hMinLot);
   Print("  POSITIONS OPENED        : ",cOpened);
   Print("-------------------------------------------------------------------");
   if(hMinLot>0)
     {
      Print("-------------------------------------------------------------------");
      Print("SELECTION BIAS WARNING");
      Print("  ",hMinLot," signal(s) were skipped because the risk-correct lot");
      Print("  fell below the broker minimum. Those skips are not random - they");
      Print("  remove the WIDEST stops, so the trades that did open are a biased");
      Print("  sample of unusually tight signal candles.");
      Print("  avg stop, skipped : ",
            DoubleToString(hMinLotStopSum/(double)hMinLot,0)," points");
      Print("  max stop, skipped : ",DoubleToString(hMinLotStopMax,0)," points");
      if(cOpened>0)
         Print("  avg stop, taken   : ",
               DoubleToString(hTakenStopSum/(double)cOpened,0)," points");
      Print("  FIX: raise the tester's initial deposit (or the live account) so");
      Print("  that ",DoubleToString(RiskPercent,2),"% covers these stops at the minimum lot.");
      Print("  Do NOT fix it by raising RiskPercent - that changes the strategy.");
     }
   Print("-------------------------------------------------------------------");
   Print("Signal totals must reconcile: sum of per-bucket signals = LONG +");
   Print("SHORT signals, and sum of per-bucket trades = POSITIONS OPENED.");
   Print("-------------------------------------------------------------------");
   Print("READ THIS: a level with few closed trades proves nothing however");
   Print("good its PF looks. Judge each level on POOLED results from two or");
   Print("more separate date ranges before keeping or deleting it.");
   Print("===================================================================");
  }

//+------------------------------------------------------------------+
//| OnTick - everything is gated behind the new-bar check            |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_init_ok)
      return;

   SettleClosedPosition();

   if(!IsNewBar())
      return;

   ProcessNewBar();
  }
//+------------------------------------------------------------------+
