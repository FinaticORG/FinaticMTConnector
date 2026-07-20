#property version   "1.01"
#property description "Finatic MT5 Connector v0.1.6 — place/modify/cancel trading, Mode A/C SL/TP, signed ingest."

input string FinaticPlatform = "mt5";
input string FinaticConnectorId = "";
input string FinaticConnectorSecret = "";
input string FinaticIngestUrl = "";
input int    FinaticSigningSchemeVersion = 1;
input int    FinaticTimestampSkewSeconds = 300;
input bool   FinaticSnapshotRequired = true;
input int    FinaticHeartbeatSeconds = 15;
input int    FinaticSecretVersion = 1;
input bool   FinaticSignEnvelopes = true;
input int    FinaticHistoryMaxRows = 1500;

long   g_ingestSequence = 0;
bool   g_ingestConfigurationValid = false;
string g_ingestBaseUrl = "";

int OnInit()
  {
   g_ingestConfigurationValid = finaticValidateIngestConfiguration();
   if(!g_ingestConfigurationValid)
     return(INIT_FAILED);
   g_ingestBaseUrl = finaticTrimBaseUrl(FinaticIngestUrl);
   if(FinaticSnapshotRequired)
      finaticPushSnapshot();
   EventSetTimer(FinaticHeartbeatSeconds);
   Print("Finatic MT5 Connector v0.1.5: timer=", FinaticHeartbeatSeconds, "s base=", g_ingestBaseUrl, " signed=", FinaticSignEnvelopes);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTick()
  {
  }

void OnTimer()
  {
   if(!g_ingestConfigurationValid)
     return;
   string responseBody = finaticPostMinimalRoute("heartbeat", "{}");
   if(StringLen(responseBody) == 0)
      return;
   if(finaticResponseRequestsSnapshot(responseBody))
      finaticPushSnapshot();
   finaticDrainPendingCommands(responseBody);
  }

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
  {
   if(!g_ingestConfigurationValid)
     return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD && trans.type != TRADE_TRANSACTION_ORDER_ADD &&
      trans.type != TRADE_TRANSACTION_ORDER_UPDATE && trans.type != TRADE_TRANSACTION_ORDER_DELETE)
     return;

   string eventsJson = "[" + finaticBuildTransactionEventJson(trans) + "]";
   string innerPayload = "{\"events\":" + eventsJson + "}";
   finaticPostMinimalRoute("events", innerPayload);
  }

bool finaticValidateIngestConfiguration()
  {
   if(StringLen(FinaticIngestUrl) < 12)
     {
      Print("Finatic: set FinaticIngestUrl from the Connect portal.");
      return(false);
     }
   if(StringFind(FinaticIngestUrl, "http://", 0) != 0 && StringFind(FinaticIngestUrl, "https://", 0) != 0)
     {
      Print("Finatic: FinaticIngestUrl must start with http:// or https://");
      return(false);
     }
   if(StringLen(FinaticPlatform) < 2)
     return(false);
   if(FinaticSecretVersion < 1)
      return(false);
   if(FinaticSignEnvelopes && StringLen(FinaticConnectorSecret) < 8)
     {
      Print("Finatic: signed envelopes require FinaticConnectorSecret.");
      return(false);
     }
   return(true);
  }

string finaticTrimBaseUrl(string baseUrl)
  {
   string trimmed = baseUrl;
   StringTrimLeft(trimmed);
   StringTrimRight(trimmed);
   while(StringLen(trimmed) > 0 && StringGetCharacter(trimmed, StringLen(trimmed) - 1) == '/')
      trimmed = StringSubstr(trimmed, 0, StringLen(trimmed) - 1);
   return(trimmed);
  }

string finaticBuildRouteUrl(string routeSuffix)
  {
   return(g_ingestBaseUrl + "/" + routeSuffix);
  }

string finaticJsonEscape(string value)
  {
   string out = value;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   return(out);
  }

string finaticMt5OrderTypeName(long orderType)
  {
   if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT)
      return("limit");
   if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)
      return("stop");
   if(orderType == ORDER_TYPE_BUY_STOP_LIMIT || orderType == ORDER_TYPE_SELL_STOP_LIMIT)
      return("stop_limit");
   return("market");
  }

string finaticMt5OrderSide(long orderType)
  {
   if(orderType == ORDER_TYPE_SELL || orderType == ORDER_TYPE_SELL_LIMIT ||
      orderType == ORDER_TYPE_SELL_STOP || orderType == ORDER_TYPE_SELL_STOP_LIMIT)
      return("sell");
   return("buy");
  }

string finaticMt5OrderStateName(long orderState)
  {
   if(orderState == ORDER_STATE_CANCELED)
      return("cancelled");
   if(orderState == ORDER_STATE_PARTIAL)
      return("partially_filled");
   if(orderState == ORDER_STATE_FILLED)
      return("filled");
   return("new");
  }

string finaticBuildSnapshotInnerPayload()
  {
   string login = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   string currency = finaticJsonEscape(AccountInfoString(ACCOUNT_CURRENCY));
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   string accountsJson =
      "[{\"login\":\"" + login +
      "\",\"currency\":\"" + currency +
      "\",\"balance\":" + DoubleToString(balance, 2) +
      ",\"equity\":" + DoubleToString(equity, 2) +
      ",\"margin\":" + DoubleToString(margin, 2) +
      ",\"free_margin\":" + DoubleToString(freeMargin, 2) + "}]";

   string positionsJson = "[";
   int positionCount = PositionsTotal();
   for(int i = 0; i < positionCount; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(StringLen(positionsJson) > 1)
         positionsJson += ",";
      string symbol = finaticJsonEscape(PositionGetString(POSITION_SYMBOL));
      double volume = PositionGetDouble(POSITION_VOLUME);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss = PositionGetDouble(POSITION_SL);
      double takeProfit = PositionGetDouble(POSITION_TP);
      long sideType = (long)PositionGetInteger(POSITION_TYPE);
      string side = (sideType == POSITION_TYPE_SELL) ? "sell" : "buy";
      positionsJson +=
         "{\"position_id\":\"" + IntegerToString((long)ticket) +
         "\",\"symbol\":\"" + symbol +
         "\",\"volume\":" + DoubleToString(volume, 4) +
         ",\"price_open\":" + DoubleToString(priceOpen, 5) +
         ",\"stop_loss\":" + DoubleToString(stopLoss, 5) +
         ",\"take_profit\":" + DoubleToString(takeProfit, 5) +
         ",\"side\":\"" + side +
         "\",\"login\":\"" + login + "\"}";
     }
   positionsJson += "]";

   string ordersJson = "[";
   int orderCount = OrdersTotal();
   for(int j = 0; j < orderCount; j++)
     {
      ulong orderTicket = OrderGetTicket(j);
      if(orderTicket == 0)
         continue;
      if(StringLen(ordersJson) > 1)
         ordersJson += ",";
      string orderSymbol = finaticJsonEscape(OrderGetString(ORDER_SYMBOL));
      double orderVolume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      long orderType = (long)OrderGetInteger(ORDER_TYPE);
      long orderState = (long)OrderGetInteger(ORDER_STATE);
      double orderPriceOpen = OrderGetDouble(ORDER_PRICE_OPEN);
      double stopLoss = OrderGetDouble(ORDER_SL);
      double stopLimitPrice = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
      double limitPrice = orderPriceOpen;
      double stopPrice = stopLoss;
      if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP)
        {
         stopPrice = orderPriceOpen;
         limitPrice = 0.0;
        }
      else if(orderType == ORDER_TYPE_BUY_STOP_LIMIT || orderType == ORDER_TYPE_SELL_STOP_LIMIT)
        {
         stopPrice = orderPriceOpen;
         limitPrice = stopLimitPrice;
        }
      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      ordersJson +=
         "{\"order_id\":\"" + IntegerToString((long)orderTicket) +
         "\",\"symbol\":\"" + orderSymbol +
         "\",\"volume_current\":" + DoubleToString(orderVolume, 4) +
         ",\"order_type\":\"" + finaticMt5OrderTypeName(orderType) +
         "\",\"side\":\"" + finaticMt5OrderSide(orderType) +
         "\",\"status\":\"" + finaticMt5OrderStateName(orderState) +
         "\",\"limit_price\":" + DoubleToString(limitPrice, 5) +
         ",\"stop_price\":" + DoubleToString(stopPrice, 5) +
         ",\"time_setup\":\"" + TimeToString(setupTime, TIME_DATE|TIME_SECONDS) +
         "\",\"login\":\"" + login + "\"}";
     }
   ordersJson += "]";

   return(
      "{\"accounts\":" + accountsJson +
      ",\"positions\":" + positionsJson +
      ",\"orders\":" + ordersJson +
      ",\"balances\":[]}"
   );
  }

void finaticPushSnapshot()
  {
   string innerPayload = finaticBuildSnapshotInnerPayload();
   string responseBody = finaticPostMinimalRoute("snapshot", innerPayload);
   // sync_history is enqueued on snapshot ingest; drain here (not only heartbeat).
   if(StringLen(responseBody) > 0)
      finaticDrainPendingCommands(responseBody);
  }

string finaticBuildTransactionEventJson(const MqlTradeTransaction& trans)
  {
   string login = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      string symbol = finaticJsonEscape(trans.symbol);
      return(
         "{\"event_type\":\"order.fill\",\"payload\":{\"deal_id\":\"" + IntegerToString((long)trans.deal) +
         "\",\"order_id\":\"" + IntegerToString((long)trans.order) +
         "\",\"symbol\":\"" + symbol +
         "\",\"volume\":" + DoubleToString(trans.volume, 4) +
         ",\"price\":" + DoubleToString(trans.price, 5) +
         ",\"side\":\"" + finaticMt5OrderSide((long)trans.order_type) +
         ",\"login\":\"" + login + "\"}}"
      );
     }
   string side = finaticMt5OrderSide((long)trans.order_type);
   string status = "new";
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
      status = "cancelled";
   string symbol2 = finaticJsonEscape(trans.symbol);
   return(
      "{\"event_type\":\"order.upsert\",\"payload\":{\"order_id\":\"" + IntegerToString((long)trans.order) +
      "\",\"symbol\":\"" + symbol2 +
      "\",\"side\":\"" + side +
      "\",\"status\":\"" + status +
      "\",\"order_type\":\"" + finaticMt5OrderTypeName((long)trans.order_type) +
      "\",\"limit_price\":" + DoubleToString(trans.price, 5) +
      ",\"volume\":" + DoubleToString(trans.volume, 4) +
      ",\"login\":\"" + login + "\"}}"
   );
  }

bool finaticResponseRequestsSnapshot(string responseBody)
  {
   return(
      StringFind(responseBody, "\"should_send_snapshot\":true", 0) >= 0 ||
      StringFind(responseBody, "\"should_send_snapshot\": true", 0) >= 0
   );
  }

int finaticExtractJsonIntField(string jsonObjectText, string fieldName, int defaultValue)
  {
   string needle = "\"" + fieldName + "\":";
   int needlePosition = StringFind(jsonObjectText, needle, 0);
   if(needlePosition < 0)
      return(defaultValue);
   int valueStart = needlePosition + StringLen(needle);
   string tail = StringSubstr(jsonObjectText, valueStart);
   return((int)StringToInteger(tail));
  }

void finaticExecuteSyncHistoryCommand(string commandObject)
  {
   bool initialSync = (StringFind(commandObject, "\"initial\":true", 0) >= 0);
   int maxRows = finaticExtractJsonIntField(commandObject, "max_rows", FinaticHistoryMaxRows);
   if(maxRows < 100)
      maxRows = 100;
   if(maxRows > 3000)
      maxRows = 3000;
   int lookbackDays = finaticExtractJsonIntField(commandObject, "lookback_days", 3);
   if(lookbackDays < 1)
      lookbackDays = 1;
   if(lookbackDays > 365)
      lookbackDays = 365;
   string historyPhase = finaticExtractJsonStringField(commandObject, "history_phase");
   if(StringLen(historyPhase) < 1)
      historyPhase = "deals";
   int dealOffset = finaticExtractJsonIntField(commandObject, "deal_offset", 0);
   int orderOffset = finaticExtractJsonIntField(commandObject, "order_offset", 0);
   datetime toTime = TimeCurrent();
   datetime fromTime = initialSync ? (datetime)0 : (toTime - (datetime)(lookbackDays * 86400));
   string login = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   string dealsJson = "[";
   string ordersJson = "[";
   int dealRows = 0;
   int orderRows = 0;
   int dealTotal = 0;
   int orderTotal = 0;
   datetime earliestHistoryAt = 0;
   bool hasMoreDeals = false;
   bool hasMoreOrders = false;
   if(HistorySelect(fromTime, toTime))
     {
      dealTotal = HistoryDealsTotal();
      orderTotal = HistoryOrdersTotal();
      if(dealOffset == 0)
        {
         for(int scanIndex = 0; scanIndex < dealTotal; scanIndex++)
           {
            ulong scanTicket = HistoryDealGetTicket(scanIndex);
            if(scanTicket == 0)
               continue;
            datetime scanTime = (datetime)HistoryDealGetInteger(scanTicket, DEAL_TIME);
            if(earliestHistoryAt == 0 || scanTime < earliestHistoryAt)
               earliestHistoryAt = scanTime;
           }
        }
      if(initialSync && historyPhase == "deals")
        {
         int dealEnd = MathMin(dealTotal, dealOffset + maxRows);
         for(int i = dealOffset; i < dealEnd; i++)
           {
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket == 0)
               continue;
            if(dealRows > 0)
               dealsJson += ",";
            string symbol = finaticJsonEscape(HistoryDealGetString(ticket, DEAL_SYMBOL));
            dealsJson +=
               "{\"deal_id\":\"" + IntegerToString((long)ticket) +
               "\",\"order_id\":\"" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_ORDER)) +
               "\",\"symbol\":\"" + symbol +
               "\",\"volume\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 4) +
               ",\"price\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PRICE), 5) +
               ",\"deal_type\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_TYPE)) +
               ",\"profit\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PROFIT), 2) +
               ",\"comment\":\"" + finaticJsonEscape(HistoryDealGetString(ticket, DEAL_COMMENT)) +
               "\",\"time\":\"" + TimeToString((datetime)HistoryDealGetInteger(ticket, DEAL_TIME), TIME_DATE|TIME_SECONDS) +
               "\",\"login\":\"" + login + "\"}";
            dealRows++;
           }
         hasMoreDeals = (dealOffset + dealRows) < dealTotal;
        }
      else if(initialSync && historyPhase == "orders")
        {
         int orderEnd = MathMin(orderTotal, orderOffset + maxRows);
         for(int j = orderOffset; j < orderEnd; j++)
           {
            ulong orderTicket = HistoryOrderGetTicket(j);
            if(orderTicket == 0)
               continue;
            if(orderRows > 0)
               ordersJson += ",";
            string orderSymbol = finaticJsonEscape(HistoryOrderGetString(orderTicket, ORDER_SYMBOL));
            long orderType = HistoryOrderGetInteger(orderTicket, ORDER_TYPE);
            ordersJson +=
               "{\"order_id\":\"" + IntegerToString((long)orderTicket) +
               "\",\"symbol\":\"" + orderSymbol +
               "\",\"side\":\"" + finaticMt5OrderSide(orderType) +
               "\",\"status\":\"filled\",\"order_type\":\"" + finaticMt5OrderTypeName(orderType) +
               "\",\"limit_price\":" + DoubleToString(HistoryOrderGetDouble(orderTicket, ORDER_PRICE_OPEN), 5) +
               ",\"volume_current\":" + DoubleToString(HistoryOrderGetDouble(orderTicket, ORDER_VOLUME_CURRENT), 4) +
               ",\"login\":\"" + login + "\"}";
            orderRows++;
           }
         hasMoreOrders = (orderOffset + orderRows) < orderTotal;
        }
      else if(!initialSync)
        {
         int dealStart = MathMax(0, dealTotal - maxRows);
         for(int i = dealStart; i < dealTotal; i++)
           {
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket == 0)
               continue;
            if(dealRows > 0)
               dealsJson += ",";
            string symbol = finaticJsonEscape(HistoryDealGetString(ticket, DEAL_SYMBOL));
            dealsJson +=
               "{\"deal_id\":\"" + IntegerToString((long)ticket) +
               "\",\"order_id\":\"" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_ORDER)) +
               "\",\"symbol\":\"" + symbol +
               "\",\"volume\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_VOLUME), 4) +
               ",\"price\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PRICE), 5) +
               ",\"deal_type\":" + IntegerToString((long)HistoryDealGetInteger(ticket, DEAL_TYPE)) +
               ",\"profit\":" + DoubleToString(HistoryDealGetDouble(ticket, DEAL_PROFIT), 2) +
               ",\"comment\":\"" + finaticJsonEscape(HistoryDealGetString(ticket, DEAL_COMMENT)) +
               "\",\"time\":\"" + TimeToString((datetime)HistoryDealGetInteger(ticket, DEAL_TIME), TIME_DATE|TIME_SECONDS) +
               "\",\"login\":\"" + login + "\"}";
            dealRows++;
           }
         int orderStart = MathMax(0, orderTotal - maxRows);
         for(int k = orderStart; k < orderTotal; k++)
           {
            ulong orderTicket = HistoryOrderGetTicket(k);
            if(orderTicket == 0)
               continue;
            if(orderRows > 0)
               ordersJson += ",";
            string orderSymbol = finaticJsonEscape(HistoryOrderGetString(orderTicket, ORDER_SYMBOL));
            long orderType = HistoryOrderGetInteger(orderTicket, ORDER_TYPE);
            ordersJson +=
               "{\"order_id\":\"" + IntegerToString((long)orderTicket) +
               "\",\"symbol\":\"" + orderSymbol +
               "\",\"side\":\"" + finaticMt5OrderSide(orderType) +
               "\",\"status\":\"filled\",\"order_type\":\"" + finaticMt5OrderTypeName(orderType) +
               "\",\"limit_price\":" + DoubleToString(HistoryOrderGetDouble(orderTicket, ORDER_PRICE_OPEN), 5) +
               ",\"volume_current\":" + DoubleToString(HistoryOrderGetDouble(orderTicket, ORDER_VOLUME_CURRENT), 4) +
               ",\"login\":\"" + login + "\"}";
            orderRows++;
           }
        }
     }
   dealsJson += "]";
   ordersJson += "]";
   string historyPayload =
      "{\"login\":\"" + login +
      "\",\"initial\":" + (initialSync ? "true" : "false") +
      ",\"from_timestamp_ms\":" + IntegerToString((long)fromTime * 1000) +
      ",\"earliest_available_ms\":" + IntegerToString((long)earliestHistoryAt * 1000) +
      ",\"history_phase\":\"" + historyPhase +
      "\",\"deal_offset\":" + IntegerToString(dealOffset) +
      ",\"deal_page_rows\":" + IntegerToString(dealRows) +
      ",\"history_total_deals\":" + IntegerToString(dealTotal) +
      ",\"has_more_deals\":" + (hasMoreDeals ? "true" : "false") +
      ",\"order_offset\":" + IntegerToString(orderOffset) +
      ",\"order_page_rows\":" + IntegerToString(orderRows) +
      ",\"history_total_orders\":" + IntegerToString(orderTotal) +
      ",\"has_more_orders\":" + (hasMoreOrders ? "true" : "false") +
      ",\"pagination\":{\"phase\":\"" + historyPhase +
      "\",\"deal_offset\":" + IntegerToString(dealOffset) +
      ",\"deal_page_rows\":" + IntegerToString(dealRows) +
      ",\"deal_total\":" + IntegerToString(dealTotal) +
      ",\"has_more_deals\":" + (hasMoreDeals ? "true" : "false") +
      ",\"order_offset\":" + IntegerToString(orderOffset) +
      ",\"order_page_rows\":" + IntegerToString(orderRows) +
      ",\"order_total\":" + IntegerToString(orderTotal) +
      ",\"has_more_orders\":" + (hasMoreOrders ? "true" : "false") + "}" +
      ",\"deals\":" + dealsJson +
      ",\"orders\":" + ordersJson + "}";
   string innerPayload =
      "{\"events\":[{\"event_type\":\"history.batch\",\"payload\":{\"history\":" + historyPayload + "}}]}";
   finaticPostMinimalRoute("events", innerPayload);
   string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
   if(StringLen(commandIdentifier) > 0)
     {
      string resultPayload =
         "{\"command_id\":\"" + commandIdentifier +
         "\",\"accepted\":true,\"ea_result\":{\"deal_rows\":" + IntegerToString(dealRows) +
         ",\"order_rows\":" + IntegerToString(orderRows) +
         ",\"history_phase\":\"" + historyPhase +
         "\",\"has_more_deals\":" + (hasMoreDeals ? "true" : "false") +
         ",\"has_more_orders\":" + (hasMoreOrders ? "true" : "false") + "}}";
      finaticPostMinimalRoute("command-result", resultPayload);
     }
  }

#define FINATIC_EA_MAGIC 26071201

string finaticExtractBalancedJsonObject(string text, int startPosition)
  {
   if(startPosition < 0 || startPosition >= StringLen(text))
      return("");
   if(StringGetCharacter(text, startPosition) != '{')
      return("");
   int depth = 0;
   bool inString = false;
   for(int index = startPosition; index < StringLen(text); index++)
     {
      ushort character = StringGetCharacter(text, index);
      if(character == '\\' && inString)
        {
         index++;
         continue;
        }
      if(character == '"')
        {
         inString = !inString;
         continue;
        }
      if(inString)
         continue;
      if(character == '{')
         depth++;
      else if(character == '}')
        {
         depth--;
         if(depth == 0)
            return(StringSubstr(text, startPosition, index - startPosition + 1));
        }
     }
   return("");
  }

string finaticExtractJsonObjectField(string jsonObjectText, string fieldName)
  {
   string needle = "\"" + fieldName + "\"";
   int needlePosition = StringFind(jsonObjectText, needle, 0);
   if(needlePosition < 0)
      return("");
   int colonPosition = StringFind(jsonObjectText, ":", needlePosition + StringLen(needle));
   if(colonPosition < 0)
      return("");
   int objectStart = StringFind(jsonObjectText, "{", colonPosition);
   if(objectStart < 0)
      return("");
   return(finaticExtractBalancedJsonObject(jsonObjectText, objectStart));
  }

double finaticExtractJsonDoubleField(string jsonObjectText, string fieldName, double defaultValue)
  {
   string needle = "\"" + fieldName + "\":";
   int needlePosition = StringFind(jsonObjectText, needle, 0);
   if(needlePosition < 0)
      return(defaultValue);
   int valueStart = needlePosition + StringLen(needle);
   while(valueStart < StringLen(jsonObjectText))
     {
      ushort character = StringGetCharacter(jsonObjectText, valueStart);
      if(character == ' ' || character == '\t' || character == '\r' || character == '\n')
        {
         valueStart++;
         continue;
        }
      break;
     }
   string tail = StringSubstr(jsonObjectText, valueStart);
   return(StringToDouble(tail));
  }

bool finaticExtractJsonBoolField(string jsonObjectText, string fieldName, bool defaultValue)
  {
   string needle = "\"" + fieldName + "\":";
   int needlePosition = StringFind(jsonObjectText, needle, 0);
   if(needlePosition < 0)
      return(defaultValue);
   int valueStart = needlePosition + StringLen(needle);
   string tail = StringSubstr(jsonObjectText, valueStart);
   StringTrimLeft(tail);
   if(StringFind(tail, "true", 0) == 0)
      return(true);
   if(StringFind(tail, "false", 0) == 0)
      return(false);
   return(defaultValue);
  }

void finaticPostCommandResultDetailed(
   string commandIdentifier,
   bool accepted,
   long ticket,
   uint retcode,
   string commentText
  )
  {
   string escapedComment = finaticJsonEscape(commentText);
   string eaResult =
      "{\"received_at_ms\":" + IntegerToString((long)GetTickCount()) +
      ",\"retcode\":" + IntegerToString((long)retcode) +
      ",\"comment\":\"" + escapedComment + "\"";
   if(ticket > 0)
      eaResult += ",\"ticket\":" + IntegerToString(ticket) +
                  ",\"order_id\":\"" + IntegerToString(ticket) + "\"";
   eaResult += "}";
   string acceptedLiteral = accepted ? "true" : "false";
   string innerPayload =
      "{\"command_id\":\"" + commandIdentifier +
      "\",\"accepted\":" + acceptedLiteral +
      ",\"ea_result\":" + eaResult + "}";
   finaticPostMinimalRoute("command-result", innerPayload);
  }

ENUM_ORDER_TYPE finaticResolveMt5PendingOrderType(string actionValue, string orderTypeValue)
  {
   bool isBuy = (actionValue == "buy");
   if(orderTypeValue == "limit")
      return(isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   return(isBuy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
  }

ENUM_ORDER_TYPE_FILLING finaticResolveMt5FillingMode(string symbolValue)
  {
   // Unset / RETURN filling under Market Execution yields retcode 10030
   // ("Unsupported filling mode"). Pick a mode advertised on the symbol.
   long fillingMode = SymbolInfoInteger(symbolValue, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return(ORDER_FILLING_IOC);
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return(ORDER_FILLING_FOK);
   // RETURN is always available except under SYMBOL_TRADE_EXECUTION_MARKET.
   if(SymbolInfoInteger(symbolValue, SYMBOL_TRADE_EXEMODE) != SYMBOL_TRADE_EXECUTION_MARKET)
      return(ORDER_FILLING_RETURN);
   return(ORDER_FILLING_IOC);
  }

double finaticNormalizeMt5Price(string symbolValue, double rawPrice)
  {
   if(rawPrice <= 0.0)
      return(rawPrice);
   double tickSize = SymbolInfoDouble(symbolValue, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
     {
      double ticks = MathRound(rawPrice / tickSize);
      return(NormalizeDouble(ticks * tickSize, (int)SymbolInfoInteger(symbolValue, SYMBOL_DIGITS)));
     }
   return(NormalizeDouble(rawPrice, (int)SymbolInfoInteger(symbolValue, SYMBOL_DIGITS)));
  }

void finaticExecutePlaceOrderCommand(string commandObject)
  {
   string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
   string payloadObject = finaticExtractJsonObjectField(commandObject, "payload");
   if(StringLen(commandIdentifier) < 1 || StringLen(payloadObject) < 2)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "missing command_id or payload");
      return;
     }

   string symbolValue = finaticExtractJsonStringField(payloadObject, "symbol");
   string actionValue = finaticExtractJsonStringField(payloadObject, "action");
   string orderTypeValue = finaticExtractJsonStringField(payloadObject, "order_type");
   double volumeLots = finaticExtractJsonDoubleField(payloadObject, "order_qty", 0.0);
   double limitPrice = finaticExtractJsonDoubleField(payloadObject, "price", 0.0);
   double stopEntryPrice = finaticExtractJsonDoubleField(payloadObject, "stop_price", 0.0);
   double stopLossPrice = finaticExtractJsonDoubleField(payloadObject, "stop_loss", 0.0);
   double takeProfitPrice = finaticExtractJsonDoubleField(payloadObject, "take_profit", 0.0);

   if(StringLen(symbolValue) < 1 || volumeLots <= 0.0 || (actionValue != "buy" && actionValue != "sell"))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "invalid place payload");
      return;
     }
   if(!SymbolSelect(symbolValue, true))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, GetLastError(), "symbol select failed");
      return;
     }

   MqlTradeRequest tradeRequest;
   MqlTradeResult tradeResult;
   ZeroMemory(tradeRequest);
   ZeroMemory(tradeResult);
   tradeRequest.symbol = symbolValue;
   tradeRequest.volume = volumeLots;
   tradeRequest.deviation = 20;
   tradeRequest.magic = FINATIC_EA_MAGIC;
   tradeRequest.sl = finaticNormalizeMt5Price(symbolValue, stopLossPrice);
   tradeRequest.tp = finaticNormalizeMt5Price(symbolValue, takeProfitPrice);
   tradeRequest.type_filling = finaticResolveMt5FillingMode(symbolValue);

   if(orderTypeValue == "market")
     {
      tradeRequest.action = TRADE_ACTION_DEAL;
      tradeRequest.type = (actionValue == "buy") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      tradeRequest.price = (actionValue == "buy")
         ? SymbolInfoDouble(symbolValue, SYMBOL_ASK)
         : SymbolInfoDouble(symbolValue, SYMBOL_BID);
      tradeRequest.price = finaticNormalizeMt5Price(symbolValue, tradeRequest.price);
     }
   else if(orderTypeValue == "limit" || orderTypeValue == "stop")
     {
      tradeRequest.action = TRADE_ACTION_PENDING;
      tradeRequest.type = finaticResolveMt5PendingOrderType(actionValue, orderTypeValue);
      tradeRequest.price = finaticNormalizeMt5Price(
         symbolValue,
         (orderTypeValue == "limit") ? limitPrice : stopEntryPrice
      );
      if(tradeRequest.price <= 0.0)
        {
         finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "pending price required");
         return;
        }
     }
   else
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "unsupported order_type");
      return;
     }

   ResetLastError();
   bool sent = OrderSend(tradeRequest, tradeResult);
   long ticket = (long)tradeResult.order;
   if(ticket <= 0)
      ticket = (long)tradeResult.deal;
   if(!sent || (tradeResult.retcode != TRADE_RETCODE_DONE && tradeResult.retcode != TRADE_RETCODE_PLACED &&
      tradeResult.retcode != TRADE_RETCODE_DONE_PARTIAL))
     {
      string failureComment = tradeResult.comment;
      if(StringLen(failureComment) < 1)
         failureComment = "OrderSend failed";
      finaticPostCommandResultDetailed(
         commandIdentifier,
         false,
         ticket,
         tradeResult.retcode != 0 ? tradeResult.retcode : (uint)GetLastError(),
         failureComment
      );
      return;
     }
   finaticPostCommandResultDetailed(commandIdentifier, true, ticket, tradeResult.retcode, tradeResult.comment);
  }

void finaticExecuteCancelOrderCommand(string commandObject)
  {
   string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
   string payloadObject = finaticExtractJsonObjectField(commandObject, "payload");
   string orderIdText = finaticExtractJsonStringField(payloadObject, "order_id");
   if(StringLen(orderIdText) < 1)
      orderIdText = finaticExtractJsonStringField(payloadObject, "orderId");
   long orderTicket = StringToInteger(orderIdText);
   if(orderTicket <= 0)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "order_id required");
      return;
     }

   MqlTradeRequest tradeRequest;
   MqlTradeResult tradeResult;
   ZeroMemory(tradeRequest);
   ZeroMemory(tradeResult);
   tradeRequest.action = TRADE_ACTION_REMOVE;
   tradeRequest.order = (ulong)orderTicket;
   tradeRequest.magic = FINATIC_EA_MAGIC;
   ResetLastError();
   bool sent = OrderSend(tradeRequest, tradeResult);
   if(!sent || (tradeResult.retcode != TRADE_RETCODE_DONE && tradeResult.retcode != TRADE_RETCODE_PLACED))
     {
      string failureComment = tradeResult.comment;
      if(StringLen(failureComment) < 1)
         failureComment = "cancel failed";
      finaticPostCommandResultDetailed(
         commandIdentifier,
         false,
         orderTicket,
         tradeResult.retcode != 0 ? tradeResult.retcode : (uint)GetLastError(),
         failureComment
      );
      return;
     }
   finaticPostCommandResultDetailed(commandIdentifier, true, orderTicket, tradeResult.retcode, tradeResult.comment);
  }

void finaticExecuteModifyOrderCommand(string commandObject)
  {
   string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
   string payloadObject = finaticExtractJsonObjectField(commandObject, "payload");
   string modifyTarget = finaticExtractJsonStringField(payloadObject, "modify_target");
   if(StringLen(modifyTarget) < 1)
      modifyTarget = "order";

   double stopLossPrice = finaticExtractJsonDoubleField(payloadObject, "stop_loss", -1.0);
   double takeProfitPrice = finaticExtractJsonDoubleField(payloadObject, "take_profit", -1.0);
   bool clearStopLoss = finaticExtractJsonBoolField(payloadObject, "clear_stop_loss", false);
   bool clearTakeProfit = finaticExtractJsonBoolField(payloadObject, "clear_take_profit", false);

   if(modifyTarget == "position_risk")
     {
      string positionIdText = finaticExtractJsonStringField(payloadObject, "position_id");
      long positionTicket = StringToInteger(positionIdText);
      if(positionTicket <= 0)
        {
         finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "position_id required");
         return;
        }
      if(!PositionSelectByTicket((ulong)positionTicket))
        {
         finaticPostCommandResultDetailed(commandIdentifier, false, positionTicket, GetLastError(), "position not found");
         return;
        }
      string positionSymbol = PositionGetString(POSITION_SYMBOL);
      double currentStopLoss = PositionGetDouble(POSITION_SL);
      double currentTakeProfit = PositionGetDouble(POSITION_TP);
      double nextStopLoss = clearStopLoss ? 0.0 : (stopLossPrice >= 0.0 ? stopLossPrice : currentStopLoss);
      double nextTakeProfit = clearTakeProfit ? 0.0 : (takeProfitPrice >= 0.0 ? takeProfitPrice : currentTakeProfit);

      MqlTradeRequest tradeRequest;
      MqlTradeResult tradeResult;
      ZeroMemory(tradeRequest);
      ZeroMemory(tradeResult);
      tradeRequest.action = TRADE_ACTION_SLTP;
      tradeRequest.position = (ulong)positionTicket;
      tradeRequest.symbol = positionSymbol;
      tradeRequest.sl = nextStopLoss;
      tradeRequest.tp = nextTakeProfit;
      tradeRequest.magic = FINATIC_EA_MAGIC;
      ResetLastError();
      bool sent = OrderSend(tradeRequest, tradeResult);
      if(!sent || tradeResult.retcode != TRADE_RETCODE_DONE)
        {
         string failureComment = tradeResult.comment;
         if(StringLen(failureComment) < 1)
            failureComment = "position SL/TP modify failed";
         finaticPostCommandResultDetailed(
            commandIdentifier,
            false,
            positionTicket,
            tradeResult.retcode != 0 ? tradeResult.retcode : (uint)GetLastError(),
            failureComment
         );
         return;
        }
      finaticPostCommandResultDetailed(commandIdentifier, true, positionTicket, tradeResult.retcode, tradeResult.comment);
      return;
     }

   string orderIdText = finaticExtractJsonStringField(payloadObject, "order_id");
   long orderTicket = StringToInteger(orderIdText);
   if(orderTicket <= 0)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "order_id required");
      return;
     }
   if(!OrderSelect(orderTicket))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, orderTicket, GetLastError(), "pending order not found");
      return;
     }

   double nextPrice = finaticExtractJsonDoubleField(payloadObject, "price", OrderGetDouble(ORDER_PRICE_OPEN));
   double nextStopLoss = clearStopLoss ? 0.0 : (stopLossPrice >= 0.0 ? stopLossPrice : OrderGetDouble(ORDER_SL));
   double nextTakeProfit = clearTakeProfit ? 0.0 : (takeProfitPrice >= 0.0 ? takeProfitPrice : OrderGetDouble(ORDER_TP));
   double nextVolume = finaticExtractJsonDoubleField(payloadObject, "order_qty", OrderGetDouble(ORDER_VOLUME_CURRENT));
   double stopTrigger = finaticExtractJsonDoubleField(payloadObject, "stop_price", -1.0);
   if(stopTrigger >= 0.0)
      nextPrice = stopTrigger;

   MqlTradeRequest tradeRequest;
   MqlTradeResult tradeResult;
   ZeroMemory(tradeRequest);
   ZeroMemory(tradeResult);
   tradeRequest.action = TRADE_ACTION_MODIFY;
   tradeRequest.order = (ulong)orderTicket;
   tradeRequest.price = nextPrice;
   tradeRequest.sl = nextStopLoss;
   tradeRequest.tp = nextTakeProfit;
   tradeRequest.volume = nextVolume;
   tradeRequest.magic = FINATIC_EA_MAGIC;
   tradeRequest.symbol = OrderGetString(ORDER_SYMBOL);
   tradeRequest.type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   ResetLastError();
   bool sent = OrderSend(tradeRequest, tradeResult);
   if(!sent || tradeResult.retcode != TRADE_RETCODE_DONE)
     {
      string failureComment = tradeResult.comment;
      if(StringLen(failureComment) < 1)
         failureComment = "pending modify failed";
      finaticPostCommandResultDetailed(
         commandIdentifier,
         false,
         orderTicket,
         tradeResult.retcode != 0 ? tradeResult.retcode : (uint)GetLastError(),
         failureComment
      );
      return;
     }
   finaticPostCommandResultDetailed(commandIdentifier, true, orderTicket, tradeResult.retcode, tradeResult.comment);
  }

void finaticDrainPendingCommands(string heartbeatResponseBody)
  {
   int searchPosition = StringFind(heartbeatResponseBody, "\"pending_commands\"", 0);
   if(searchPosition < 0)
      return;
   int openBracket = StringFind(heartbeatResponseBody, "[", searchPosition);
   if(openBracket < 0)
      return;
   int closeBracket = StringFind(heartbeatResponseBody, "]", openBracket);
   if(closeBracket <= openBracket + 1)
      return;
   string commandsBlock = StringSubstr(heartbeatResponseBody, openBracket + 1, closeBracket - openBracket - 1);
   if(StringLen(commandsBlock) < 2)
      return;
   int commandCursor = 0;
   while(commandCursor < StringLen(commandsBlock))
     {
      int objectStart = StringFind(commandsBlock, "{", commandCursor);
      if(objectStart < 0)
         break;
      string commandObject = finaticExtractBalancedJsonObject(commandsBlock, objectStart);
      if(StringLen(commandObject) < 2)
         break;
      string commandKind = finaticExtractJsonStringField(commandObject, "kind");
      if(commandKind == "sync_history")
         finaticExecuteSyncHistoryCommand(commandObject);
      else if(commandKind == "place_order")
         finaticExecutePlaceOrderCommand(commandObject);
      else if(commandKind == "cancel_order")
         finaticExecuteCancelOrderCommand(commandObject);
      else if(commandKind == "modify_order")
         finaticExecuteModifyOrderCommand(commandObject);
      else
        {
         string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
         if(StringLen(commandIdentifier) > 0)
            finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "unsupported command kind");
        }
      commandCursor = objectStart + StringLen(commandObject);
     }
  }

string finaticExtractJsonStringField(string jsonObjectText, string fieldName)
  {
   string needle = "\"" + fieldName + "\"";
   int needlePosition = StringFind(jsonObjectText, needle, 0);
   if(needlePosition < 0)
      return("");
   int firstQuote = StringFind(jsonObjectText, "\"", needlePosition + StringLen(needle));
   if(firstQuote < 0)
      return("");
   int closingQuote = StringFind(jsonObjectText, "\"", firstQuote + 1);
   if(closingQuote < 0)
      return("");
   return(StringSubstr(jsonObjectText, firstQuote + 1, closingQuote - firstQuote - 1));
  }

void finaticPostCommandResult(string commandIdentifier)
  {
   // Legacy helper kept for sync_history callers that still use the simple ACK.
   finaticPostCommandResultDetailed(commandIdentifier, true, 0, 0, "ack");
  }

string finaticBuildCanonicalPayloadJson(long sequenceNumber, int secretVersion, string platformValue, string innerPayloadJson)
  {
   // Canonical JSON: keys sorted alphabetically, no spaces.
   return(
      "{\"payload\":" + innerPayloadJson +
      ",\"platform\":\"" + platformValue +
      "\",\"secret_version\":" + IntegerToString(secretVersion) +
      ",\"sequence\":" + IntegerToString(sequenceNumber) + "}"
   );
  }

string finaticHmacSha256Hex(string secretValue, string messageValue)
  {
   uchar secretBytes[];
   StringToCharArray(secretValue, secretBytes, 0, WHOLE_ARRAY, CP_UTF8);
   // StringToCharArray appends terminating null when WHOLE_ARRAY used; trim it.
   if(ArraySize(secretBytes) > 0 && secretBytes[ArraySize(secretBytes) - 1] == 0)
      ArrayResize(secretBytes, ArraySize(secretBytes) - 1);

   uchar keyBlock[];
   ArrayResize(keyBlock, 64);
   ArrayInitialize(keyBlock, 0);
   if(ArraySize(secretBytes) > 64)
     {
      uchar hashedKey[];
      uchar empty[];
      CryptEncode(CRYPT_HASH_SHA256, secretBytes, empty, hashedKey);
      for(int i = 0; i < 32 && i < ArraySize(hashedKey); i++)
         keyBlock[i] = hashedKey[i];
     }
   else
     {
      for(int i = 0; i < ArraySize(secretBytes); i++)
         keyBlock[i] = secretBytes[i];
     }

   uchar innerKeyPad[];
   uchar outerKeyPad[];
   ArrayResize(innerKeyPad, 64);
   ArrayResize(outerKeyPad, 64);
   for(int i = 0; i < 64; i++)
     {
      innerKeyPad[i] = (uchar)(keyBlock[i] ^ 0x36);
      outerKeyPad[i] = (uchar)(keyBlock[i] ^ 0x5c);
     }

   uchar messageBytes[];
   StringToCharArray(messageValue, messageBytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(messageBytes) > 0 && messageBytes[ArraySize(messageBytes) - 1] == 0)
      ArrayResize(messageBytes, ArraySize(messageBytes) - 1);

   uchar innerInput[];
   ArrayResize(innerInput, 64 + ArraySize(messageBytes));
   for(int i = 0; i < 64; i++)
      innerInput[i] = innerKeyPad[i];
   for(int j = 0; j < ArraySize(messageBytes); j++)
      innerInput[64 + j] = messageBytes[j];

   uchar innerHash[];
   uchar emptyKey[];
   CryptEncode(CRYPT_HASH_SHA256, innerInput, emptyKey, innerHash);

   uchar outerInput[];
   ArrayResize(outerInput, 64 + ArraySize(innerHash));
   for(int i = 0; i < 64; i++)
      outerInput[i] = outerKeyPad[i];
   for(int j = 0; j < ArraySize(innerHash); j++)
      outerInput[64 + j] = innerHash[j];

   uchar outerHash[];
   CryptEncode(CRYPT_HASH_SHA256, outerInput, emptyKey, outerHash);

   string hexResult = "";
   for(int i = 0; i < ArraySize(outerHash); i++)
     {
      string byteHex = StringFormat("%02x", outerHash[i]);
      hexResult += byteHex;
     }
   return(hexResult);
  }

string finaticPostMinimalRoute(string routeSuffix, string innerPayloadJson)
  {
   if(StringLen(g_ingestBaseUrl) < 8)
      return("");
   string requestUrl = finaticBuildRouteUrl(routeSuffix);
   string canonicalBody = finaticBuildCanonicalPayloadJson(
      g_ingestSequence,
      FinaticSecretVersion,
      FinaticPlatform,
      innerPayloadJson
   );
   uchar  postData[];
   StringToCharArray(canonicalBody, postData, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(postData) > 0 && postData[ArraySize(postData) - 1] == 0)
      ArrayResize(postData, ArraySize(postData) - 1);

   string httpHeaders = "Content-Type: application/json\r\n";
   httpHeaders += "X-Finatic-Connector-Id: " + FinaticConnectorId + "\r\n";
   httpHeaders += "X-Finatic-Secret-Version: " + IntegerToString(FinaticSecretVersion) + "\r\n";
   httpHeaders += "X-Finatic-Scheme-Version: " + IntegerToString(FinaticSigningSchemeVersion) + "\r\n";
   httpHeaders += "X-Finatic-Timestamp: " + IntegerToString((long)TimeGMT()) + "\r\n";
   if(FinaticSignEnvelopes)
     {
      string signatureHex = finaticHmacSha256Hex(FinaticConnectorSecret, canonicalBody);
      httpHeaders += "X-Finatic-Signature: " + signatureHex + "\r\n";
     }

   uchar  responseData[];
   string responseHeaders;
   ResetLastError();
   int httpCode = WebRequest("POST", requestUrl, httpHeaders, 12000, postData, responseData, responseHeaders);
   if(httpCode == -1)
     {
      Print("Finatic WebRequest failed route=", routeSuffix, " err=", GetLastError());
      return("");
     }
   string responseText = CharArrayToString(responseData, 0, WHOLE_ARRAY, CP_UTF8);
   if(httpCode < 200 || httpCode > 299)
     {
      Print("Finatic HTTP ", httpCode, " route=", routeSuffix, " body=", responseText);
      return("");
     }
   g_ingestSequence++;
   return(responseText);
  }
