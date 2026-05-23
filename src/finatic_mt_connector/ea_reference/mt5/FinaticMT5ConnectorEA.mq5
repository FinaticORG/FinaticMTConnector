#property version   "1.00"
#property description "Finatic MT5 Connector v0.1.5 — signed heartbeat/snapshot/events, enriched pending orders, order.fill events."

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
      long sideType = (long)PositionGetInteger(POSITION_TYPE);
      string side = (sideType == POSITION_TYPE_SELL) ? "sell" : "buy";
      positionsJson +=
         "{\"position_id\":\"" + IntegerToString((long)ticket) +
         "\",\"symbol\":\"" + symbol +
         "\",\"volume\":" + DoubleToString(volume, 4) +
         ",\"price_open\":" + DoubleToString(priceOpen, 5) +
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
      int objectEnd = StringFind(commandsBlock, "}", objectStart);
      if(objectEnd < 0)
         break;
      string commandObject = StringSubstr(commandsBlock, objectStart, objectEnd - objectStart + 1);
      string commandKind = finaticExtractJsonStringField(commandObject, "kind");
      if(commandKind == "sync_history")
         finaticExecuteSyncHistoryCommand(commandObject);
      else
        {
         string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
         if(StringLen(commandIdentifier) > 0)
            finaticPostCommandResult(commandIdentifier);
        }
      commandCursor = objectEnd + 1;
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
   string innerPayload =
      "{\"command_id\":\"" + commandIdentifier +
      "\",\"accepted\":true,\"ea_result\":{\"received_at_ms\":" + IntegerToString((long)GetTickCount()) + "}}";
   finaticPostMinimalRoute("command-result", innerPayload);
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
