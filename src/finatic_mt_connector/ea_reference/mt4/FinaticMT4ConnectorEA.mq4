#property version   "1.01"
#property description "Finatic MT4 Connector v0.1.6 — place/modify/cancel trading, Mode A/C SL/TP, signed ingest."

input string FinaticPlatform = "mt4";
input string FinaticConnectorId = "";
input string FinaticConnectorSecret = "";
input string FinaticIngestUrl = "";
input int    FinaticSigningSchemeVersion = 1;
input int    FinaticTimestampSkewSeconds = 300;
input bool   FinaticSnapshotRequired = true;
input int    FinaticHeartbeatSeconds = 15;
input int    FinaticSecretVersion = 1;
input bool   FinaticSignEnvelopes = true;
input int    FinaticHistoryMaxRows = 80;

int    g_ingestSequence = 0;
bool   g_ingestConfigurationValid = false;
string g_ingestBaseUrl = "";
string g_webRequestAllowlistOrigin = "";

int OnInit()
  {
   g_ingestConfigurationValid = finaticValidateIngestConfiguration();
   if(!g_ingestConfigurationValid)
      return(INIT_FAILED);
   g_ingestBaseUrl = finaticTrimBaseUrl(FinaticIngestUrl);
   g_webRequestAllowlistOrigin = finaticExtractWebRequestAllowlistOrigin(g_ingestBaseUrl);
   if(FinaticSnapshotRequired)
      finaticPushSnapshot();
   EventSetTimer(FinaticHeartbeatSeconds);
   Print(
      "Finatic MT4 Connector v0.1.5: timer=",
      FinaticHeartbeatSeconds,
      "s base=",
      g_ingestBaseUrl,
      " signed=",
      FinaticSignEnvelopes,
      " allowlist=",
      g_webRequestAllowlistOrigin
   );
   finaticWarnIfIngestUrlUsesCustomPort();
   return(INIT_SUCCEEDED);
  }

void finaticWarnIfIngestUrlUsesCustomPort()
  {
   // MQL4 WebRequest maps http->:80 and https->:443 only; explicit :8001 etc. yields err 5200
   // even when curl/PowerShell and MT5 (WinInet) reach the same URL. See metatrader.mdoc.
   if(StringFind(FinaticIngestUrl, "://", 0) < 0)
      return;
   int hostStart = StringFind(FinaticIngestUrl, "://", 0) + 3;
   int portColon = StringFind(FinaticIngestUrl, ":", hostStart);
   if(portColon < 0)
      return;
   int pathSlash = StringFind(FinaticIngestUrl, "/", portColon);
   int portEnd = (pathSlash < 0) ? StringLen(FinaticIngestUrl) : pathSlash;
   string portToken = StringSubstr(FinaticIngestUrl, portColon + 1, portEnd - portColon - 1);
   if(portToken == "80" || portToken == "443")
      return;
   Print(
      "Finatic WARNING: MT4 WebRequest cannot use custom port :",
      portToken,
      " (err 5200). curl/MT5 may still work. For local dev use https://api-staging.finatic.dev ingest URL, or proxy port 80->Background."
   );
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

void OnTrade()
  {
   if(!g_ingestConfigurationValid)
      return;
   string eventJson = finaticBuildTradeEventJson();
   if(StringLen(eventJson) < 2)
      return;
   string innerPayload = "{\"events\":[" + eventJson + "]}";
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
   if(StringLen(FinaticConnectorId) < 8)
     {
      Print("Finatic: set FinaticConnectorId from the Connect portal.");
      return(false);
     }
   if(FinaticSignEnvelopes && StringLen(FinaticConnectorSecret) < 8)
     {
      Print("Finatic: signed envelopes require FinaticConnectorSecret.");
      return(false);
     }
   return(true);
  }

string finaticExtractWebRequestAllowlistOrigin(string ingestBaseUrl)
  {
   int protocolEnd = StringFind(ingestBaseUrl, "://", 0);
   if(protocolEnd < 0)
      return(ingestBaseUrl);
   int pathStart = StringFind(ingestBaseUrl, "/", protocolEnd + 3);
   if(pathStart < 0)
      return(ingestBaseUrl);
   return(StringSubstr(ingestBaseUrl, 0, pathStart));
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

bool finaticIsMarketPositionOrderType(int orderType)
  {
   return(orderType == OP_BUY || orderType == OP_SELL);
  }

string finaticMt4OrderTypeName(int orderType)
  {
   if(orderType == OP_BUYLIMIT || orderType == OP_SELLLIMIT)
      return("limit");
   if(orderType == OP_BUYSTOP || orderType == OP_SELLSTOP)
      return("stop");
   return("market");
  }

string finaticMt4OrderSide(int orderType)
  {
   if(orderType == OP_SELL || orderType == OP_SELLLIMIT || orderType == OP_SELLSTOP)
      return("sell");
   return("buy");
  }

string finaticBuildSnapshotInnerPayload()
  {
   string login = IntegerToString(AccountNumber());
   string currency = finaticJsonEscape(AccountCurrency());
   double balance = AccountBalance();
   double equity = AccountEquity();
   double margin = AccountMargin();
   double freeMargin = AccountFreeMargin();

   string accountsJson =
      "[{\"login\":\"" + login +
      "\",\"currency\":\"" + currency +
      "\",\"balance\":" + DoubleToString(balance, 2) +
      ",\"equity\":" + DoubleToString(equity, 2) +
      ",\"margin\":" + DoubleToString(margin, 2) +
      ",\"free_margin\":" + DoubleToString(freeMargin, 2) + "}]";

   string positionsJson = "[";
   string ordersJson = "[";
   int orderCount = OrdersTotal();
   for(int j = orderCount - 1; j >= 0; j--)
     {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES))
         continue;
      string orderSymbol = finaticJsonEscape(OrderSymbol());
      double orderVolume = OrderLots();
      int orderTicket = OrderTicket();
      int orderType = OrderType();
      if(finaticIsMarketPositionOrderType(orderType))
        {
         if(StringLen(positionsJson) > 1)
            positionsJson += ",";
         string side = (orderType == OP_SELL) ? "sell" : "buy";
         positionsJson +=
            "{\"position_id\":\"" + IntegerToString(orderTicket) +
            "\",\"symbol\":\"" + orderSymbol +
            "\",\"volume\":" + DoubleToString(orderVolume, 4) +
            ",\"price_open\":" + DoubleToString(OrderOpenPrice(), 5) +
            ",\"stop_loss\":" + DoubleToString(OrderStopLoss(), 5) +
            ",\"take_profit\":" + DoubleToString(OrderTakeProfit(), 5) +
            ",\"side\":\"" + side +
            "\",\"login\":\"" + login + "\"}";
         if(StringLen(ordersJson) > 1)
            ordersJson += ",";
         ordersJson +=
            "{\"order_id\":\"" + IntegerToString(orderTicket) +
            "\",\"symbol\":\"" + orderSymbol +
            "\",\"volume_current\":" + DoubleToString(orderVolume, 4) +
            ",\"order_type\":\"market\",\"side\":\"" + side +
            "\",\"status\":\"filled\",\"limit_price\":" + DoubleToString(OrderOpenPrice(), 5) +
            ",\"login\":\"" + login + "\"}";
        }
      else
        {
         if(StringLen(ordersJson) > 1)
            ordersJson += ",";
         ordersJson +=
            "{\"order_id\":\"" + IntegerToString(orderTicket) +
            "\",\"symbol\":\"" + orderSymbol +
            "\",\"volume_current\":" + DoubleToString(orderVolume, 4) +
            ",\"order_type\":\"" + finaticMt4OrderTypeName(orderType) +
            "\",\"side\":\"" + finaticMt4OrderSide(orderType) +
            "\",\"status\":\"new\",\"limit_price\":" + DoubleToString(OrderOpenPrice(), 5) +
            ",\"stop_price\":" + DoubleToString(OrderStopLoss(), 5) +
            ",\"time_setup\":\"" + TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS) +
            "\",\"login\":\"" + login + "\"}";
        }
     }
   positionsJson += "]";
   ordersJson += "]";

   return(
      "{\"accounts\":" + accountsJson +
      ",\"positions\":" + positionsJson +
      ",\"orders\":" + ordersJson +
      ",\"balances\":[]}"
   );
  }

string finaticBuildTradeEventJson()
  {
   string side;
   if(!OrderSelect(OrdersTotal() - 1, SELECT_BY_POS, MODE_TRADES))
      return("");
   string login = IntegerToString(AccountNumber());
   string symbol = finaticJsonEscape(OrderSymbol());
   int orderTicket = OrderTicket();
   int orderType = OrderType();
   if(finaticIsMarketPositionOrderType(orderType))
     {
      side = (orderType == OP_SELL) ? "sell" : "buy";
      return(
         "{\"event_type\":\"order.fill\",\"payload\":{\"deal_id\":\"" + IntegerToString(orderTicket) +
         "\",\"order_id\":\"" + IntegerToString(orderTicket) +
         "\",\"symbol\":\"" + symbol +
         "\",\"volume\":" + DoubleToString(OrderLots(), 4) +
         ",\"price\":" + DoubleToString(OrderOpenPrice(), 5) +
         ",\"side\":\"" + finaticMt4OrderSide(orderType) +
         ",\"login\":\"" + login + "\"}}"
      );
     }
   side = finaticMt4OrderSide(orderType);
   return(
      "{\"event_type\":\"order.upsert\",\"payload\":{\"order_id\":\"" + IntegerToString(orderTicket) +
      "\",\"symbol\":\"" + symbol +
      "\",\"side\":\"" + side +
      "\",\"status\":\"new\",\"order_type\":\"" + finaticMt4OrderTypeName(orderType) +
      "\",\"limit_price\":" + DoubleToString(OrderOpenPrice(), 5) +
      ",\"volume\":" + DoubleToString(OrderLots(), 4) +
      ",\"login\":\"" + login + "\"}}"
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
   return(StrToInteger(tail));
  }

void finaticExecuteSyncHistoryCommand(string commandObject)
  {
   bool initialSync = (StringFind(commandObject, "\"initial\":true", 0) >= 0);
   int maxRows = finaticExtractJsonIntField(commandObject, "max_rows", FinaticHistoryMaxRows);
   if(maxRows < 20)
      maxRows = 20;
   if(maxRows > 3000)
      maxRows = 3000;
   int lookbackDays = finaticExtractJsonIntField(commandObject, "lookback_days", 3);
   if(lookbackDays < 1)
      lookbackDays = 1;
   if(lookbackDays > 365)
      lookbackDays = 365;
   string historyPhase = finaticExtractJsonStringField(commandObject, "history_phase");
   if(StringLen(historyPhase) < 1)
      historyPhase = "orders";
   int dealOffset = finaticExtractJsonIntField(commandObject, "deal_offset", 0);
   int orderOffset = finaticExtractJsonIntField(commandObject, "order_offset", 0);
   datetime toTime = TimeCurrent();
   datetime fromTime = initialSync ? (datetime)0 : (toTime - lookbackDays * 86400);
   string login = IntegerToString(AccountNumber());
   string ordersJson = "[";
   int orderRows = 0;
   int historyTotal = OrdersHistoryTotal();
   int dealTotal = 0;
   datetime earliestHistoryAt = 0;
   bool hasMoreDeals = false;
   bool hasMoreOrders = false;
   int j;
   int orderEnd;
   int historyStart;
   string orderSymbol;
   int orderType;
   if(orderOffset == 0)
     {
      for(j = 0; j < historyTotal; j++)
        {
         if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY))
            continue;
         datetime rowTime = OrderCloseTime();
         if(rowTime <= 0)
            rowTime = OrderOpenTime();
         if(earliestHistoryAt == 0 || (rowTime > 0 && rowTime < earliestHistoryAt))
            earliestHistoryAt = rowTime;
        }
     }
   if(initialSync && historyPhase == "deals")
     {
      dealTotal = 0;
      hasMoreDeals = false;
     }
   else if(initialSync && historyPhase == "orders")
     {
      orderEnd = historyTotal;
      if(orderEnd > orderOffset + maxRows)
         orderEnd = orderOffset + maxRows;
      for(j = orderOffset; j < orderEnd; j++)
        {
         if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY))
            continue;
         if(orderRows > 0)
            ordersJson += ",";
         orderSymbol = finaticJsonEscape(OrderSymbol());
         orderType = OrderType();
         ordersJson +=
            "{\"order_id\":\"" + IntegerToString(OrderTicket()) +
            "\",\"symbol\":\"" + orderSymbol +
            "\",\"side\":\"" + finaticMt4OrderSide(orderType) +
            "\",\"status\":\"filled\",\"order_type\":\"" + finaticMt4OrderTypeName(orderType) +
            "\",\"volume\":" + DoubleToString(OrderLots(), 4) +
            ",\"close_price\":" + DoubleToString(OrderClosePrice(), 5) +
            ",\"profit\":" + DoubleToString(OrderProfit(), 2) +
            ",\"comment\":\"" + finaticJsonEscape(OrderComment()) +
            ",\"close_time\":\"" + TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS) +
            "\",\"login\":\"" + login + "\"}";
         orderRows++;
        }
      hasMoreOrders = (orderOffset + orderRows) < historyTotal;
     }
   else if(!initialSync)
     {
      historyStart = MathMax(0, historyTotal - maxRows);
      for(j = historyStart; j < historyTotal; j++)
        {
         if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY))
            continue;
         if(OrderCloseTime() < fromTime && OrderOpenTime() < fromTime)
            continue;
         if(orderRows > 0)
            ordersJson += ",";
         orderSymbol = finaticJsonEscape(OrderSymbol());
         orderType = OrderType();
         ordersJson +=
            "{\"order_id\":\"" + IntegerToString(OrderTicket()) +
            "\",\"symbol\":\"" + orderSymbol +
            "\",\"side\":\"" + finaticMt4OrderSide(orderType) +
            "\",\"status\":\"filled\",\"order_type\":\"" + finaticMt4OrderTypeName(orderType) +
            "\",\"volume\":" + DoubleToString(OrderLots(), 4) +
            ",\"close_price\":" + DoubleToString(OrderClosePrice(), 5) +
            ",\"profit\":" + DoubleToString(OrderProfit(), 2) +
            ",\"comment\":\"" + finaticJsonEscape(OrderComment()) +
            ",\"close_time\":\"" + TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS) +
            "\",\"login\":\"" + login + "\"}";
         orderRows++;
        }
     }
   ordersJson += "]";
   string historyPayload =
      "{\"login\":\"" + login +
      "\",\"initial\":" + (initialSync ? "true" : "false") +
      ",\"from_timestamp_ms\":" + IntegerToString((int)fromTime * 1000) +
      ",\"earliest_available_ms\":" + IntegerToString((int)earliestHistoryAt * 1000) +
      ",\"history_phase\":\"" + historyPhase +
      "\",\"deal_offset\":" + IntegerToString(dealOffset) +
      ",\"deal_page_rows\":0" +
      ",\"history_total_deals\":" + IntegerToString(dealTotal) +
      ",\"has_more_deals\":" + (hasMoreDeals ? "true" : "false") +
      ",\"order_offset\":" + IntegerToString(orderOffset) +
      ",\"order_page_rows\":" + IntegerToString(orderRows) +
      ",\"history_total_orders\":" + IntegerToString(historyTotal) +
      ",\"has_more_orders\":" + (hasMoreOrders ? "true" : "false") +
      ",\"pagination\":{\"phase\":\"" + historyPhase +
      "\",\"deal_offset\":" + IntegerToString(dealOffset) +
      ",\"deal_page_rows\":0,\"deal_total\":" + IntegerToString(dealTotal) +
      ",\"has_more_deals\":" + (hasMoreDeals ? "true" : "false") +
      ",\"order_offset\":" + IntegerToString(orderOffset) +
      ",\"order_page_rows\":" + IntegerToString(orderRows) +
      ",\"order_total\":" + IntegerToString(historyTotal) +
      ",\"has_more_orders\":" + (hasMoreOrders ? "true" : "false") + "}" +
      ",\"deals\":[],\"orders\":" + ordersJson + "}";
   string innerPayload =
      "{\"events\":[{\"event_type\":\"history.batch\",\"payload\":{\"history\":" + historyPayload + "}}]}";
   finaticPostMinimalRoute("events", innerPayload);
   string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
   if(StringLen(commandIdentifier) > 0)
     {
      string resultPayload =
         "{\"command_id\":\"" + commandIdentifier +
         "\",\"accepted\":true,\"ea_result\":{\"order_rows\":" + IntegerToString(orderRows) + "}}";
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
      int character = StringGetCharacter(text, index);
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
      int character = StringGetCharacter(jsonObjectText, valueStart);
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
   int ticket,
   int retcode,
   string commentText
  )
  {
   string escapedComment = finaticJsonEscape(commentText);
   string eaResult =
      "{\"received_at_ms\":" + IntegerToString(GetTickCount()) +
      ",\"retcode\":" + IntegerToString(retcode) +
      ",\"comment\":\"" + escapedComment + "\"";
   if(ticket > 0)
      eaResult = eaResult + ",\"ticket\":" + IntegerToString(ticket) +
                 ",\"order_id\":\"" + IntegerToString(ticket) + "\"";
   eaResult = eaResult + "}";
   string acceptedLiteral = accepted ? "true" : "false";
   string innerPayload =
      "{\"command_id\":\"" + commandIdentifier +
      "\",\"accepted\":" + acceptedLiteral +
      ",\"ea_result\":" + eaResult + "}";
   finaticPostMinimalRoute("command-result", innerPayload);
  }

int finaticResolveMt4OrderCommand(string actionValue, string orderTypeValue)
  {
   bool isBuy = (actionValue == "buy");
   if(orderTypeValue == "market")
      return(isBuy ? OP_BUY : OP_SELL);
   if(orderTypeValue == "limit")
      return(isBuy ? OP_BUYLIMIT : OP_SELLLIMIT);
   return(isBuy ? OP_BUYSTOP : OP_SELLSTOP);
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
   if(orderTypeValue != "market" && orderTypeValue != "limit" && orderTypeValue != "stop")
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "unsupported order_type");
      return;
     }

   int orderCommand = finaticResolveMt4OrderCommand(actionValue, orderTypeValue);
   double sendPrice = 0.0;
   if(orderTypeValue == "market")
      sendPrice = (actionValue == "buy") ? MarketInfo(symbolValue, MODE_ASK) : MarketInfo(symbolValue, MODE_BID);
   else if(orderTypeValue == "limit")
      sendPrice = limitPrice;
   else
      sendPrice = stopEntryPrice;
   if(sendPrice <= 0.0)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "price required");
      return;
     }

   ResetLastError();
   int ticket = OrderSend(
      symbolValue,
      orderCommand,
      volumeLots,
      sendPrice,
      20,
      stopLossPrice,
      takeProfitPrice,
      "finatic",
      FINATIC_EA_MAGIC,
      0,
      CLR_NONE
   );
   if(ticket < 0)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, GetLastError(), "OrderSend failed");
      return;
     }
   finaticPostCommandResultDetailed(commandIdentifier, true, ticket, 0, "ok");
  }

void finaticExecuteCancelOrderCommand(string commandObject)
  {
   string commandIdentifier = finaticExtractJsonStringField(commandObject, "command_id");
   string payloadObject = finaticExtractJsonObjectField(commandObject, "payload");
   string orderIdText = finaticExtractJsonStringField(payloadObject, "order_id");
   if(StringLen(orderIdText) < 1)
      orderIdText = finaticExtractJsonStringField(payloadObject, "orderId");
   int orderTicket = (int)StringToInteger(orderIdText);
   if(orderTicket <= 0)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "order_id required");
      return;
     }
   if(!OrderSelect(orderTicket, SELECT_BY_TICKET))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, orderTicket, GetLastError(), "order not found");
      return;
     }
   ResetLastError();
   if(!OrderDelete(orderTicket))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, orderTicket, GetLastError(), "OrderDelete failed");
      return;
     }
   finaticPostCommandResultDetailed(commandIdentifier, true, orderTicket, 0, "ok");
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

   int targetTicket = 0;
   if(modifyTarget == "position_risk")
     {
      string positionIdText = finaticExtractJsonStringField(payloadObject, "position_id");
      targetTicket = (int)StringToInteger(positionIdText);
     }
   else
     {
      string orderIdText = finaticExtractJsonStringField(payloadObject, "order_id");
      targetTicket = (int)StringToInteger(orderIdText);
     }
   if(targetTicket <= 0)
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, 0, 0, "ticket required");
      return;
     }
   if(!OrderSelect(targetTicket, SELECT_BY_TICKET))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, targetTicket, GetLastError(), "order/position not found");
      return;
     }

   double nextPrice = OrderOpenPrice();
   if(modifyTarget != "position_risk")
     {
      double requestedPrice = finaticExtractJsonDoubleField(payloadObject, "price", -1.0);
      double stopTrigger = finaticExtractJsonDoubleField(payloadObject, "stop_price", -1.0);
      if(requestedPrice >= 0.0)
         nextPrice = requestedPrice;
      if(stopTrigger >= 0.0)
         nextPrice = stopTrigger;
     }
   double nextStopLoss = clearStopLoss ? 0.0 : (stopLossPrice >= 0.0 ? stopLossPrice : OrderStopLoss());
   double nextTakeProfit = clearTakeProfit ? 0.0 : (takeProfitPrice >= 0.0 ? takeProfitPrice : OrderTakeProfit());

   ResetLastError();
   if(!OrderModify(targetTicket, nextPrice, nextStopLoss, nextTakeProfit, 0, CLR_NONE))
     {
      finaticPostCommandResultDetailed(commandIdentifier, false, targetTicket, GetLastError(), "OrderModify failed");
      return;
     }
   finaticPostCommandResultDetailed(commandIdentifier, true, targetTicket, 0, "ok");
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
   finaticPostCommandResultDetailed(commandIdentifier, true, 0, 0, "ack");
  }

string finaticBuildCanonicalPayloadJson(
   int sequenceNumber,
   int secretVersion,
   string platformValue,
   string innerPayloadJson
)
  {
   // Must match Python json.dumps(..., sort_keys=True): payload, platform, secret_version, sequence.
   return(
      "{\"payload\":" + innerPayloadJson +
      ",\"platform\":\"" + platformValue +
      "\",\"secret_version\":" + IntegerToString(secretVersion) +
      ",\"sequence\":" + IntegerToString(sequenceNumber) + "}"
   );
  }

string finaticHmacSha256Hex(string secretValue, string messageValue)
  {
   int i;
   int j;
   char secretBytes[];
   StringToCharArray(secretValue, secretBytes, 0, WHOLE_ARRAY);
   if(ArraySize(secretBytes) > 0 && secretBytes[ArraySize(secretBytes) - 1] == 0)
      ArrayResize(secretBytes, ArraySize(secretBytes) - 1);

   char keyBlock[];
   ArrayResize(keyBlock, 64);
   ArrayInitialize(keyBlock, 0);
   if(ArraySize(secretBytes) > 64)
     {
      char hashedKey[];
      char empty[];
      CryptEncode(CRYPT_HASH_SHA256, secretBytes, empty, hashedKey);
      for(i = 0; i < 32 && i < ArraySize(hashedKey); i++)
         keyBlock[i] = hashedKey[i];
     }
   else
     {
      for(i = 0; i < ArraySize(secretBytes); i++)
         keyBlock[i] = secretBytes[i];
     }

   char innerKeyPad[];
   char outerKeyPad[];
   ArrayResize(innerKeyPad, 64);
   ArrayResize(outerKeyPad, 64);
   for(i = 0; i < 64; i++)
     {
      innerKeyPad[i] = (char)(keyBlock[i] ^ 0x36);
      outerKeyPad[i] = (char)(keyBlock[i] ^ 0x5c);
     }

   char messageBytes[];
   StringToCharArray(messageValue, messageBytes, 0, WHOLE_ARRAY);
   if(ArraySize(messageBytes) > 0 && messageBytes[ArraySize(messageBytes) - 1] == 0)
      ArrayResize(messageBytes, ArraySize(messageBytes) - 1);

   char innerInput[];
   ArrayResize(innerInput, 64 + ArraySize(messageBytes));
   for(i = 0; i < 64; i++)
      innerInput[i] = innerKeyPad[i];
   for(j = 0; j < ArraySize(messageBytes); j++)
      innerInput[64 + j] = messageBytes[j];

   char innerHash[];
   char emptyKey[];
   CryptEncode(CRYPT_HASH_SHA256, innerInput, emptyKey, innerHash);

   char outerInput[];
   ArrayResize(outerInput, 64 + ArraySize(innerHash));
   for(i = 0; i < 64; i++)
      outerInput[i] = outerKeyPad[i];
   for(j = 0; j < ArraySize(innerHash); j++)
      outerInput[64 + j] = innerHash[j];

   char outerHash[];
   CryptEncode(CRYPT_HASH_SHA256, outerInput, emptyKey, outerHash);

   string hexResult = "";
   for(i = 0; i < ArraySize(outerHash); i++)
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
   char postData[];
   int postLen = StringToCharArray(canonicalBody, postData, 0, WHOLE_ARRAY);
   if(postLen > 0)
      postLen -= 1;
   ArrayResize(postData, postLen);

   string httpHeaders = "Content-Type: application/json\r\n";
   httpHeaders += "X-Finatic-Connector-Id: " + FinaticConnectorId + "\r\n";
   httpHeaders += "X-Finatic-Secret-Version: " + IntegerToString(FinaticSecretVersion) + "\r\n";
   httpHeaders += "X-Finatic-Scheme-Version: " + IntegerToString(FinaticSigningSchemeVersion) + "\r\n";
   httpHeaders += "X-Finatic-Timestamp: " + IntegerToString(TimeGMT()) + "\r\n";
   if(FinaticSignEnvelopes)
     {
      string signatureHex = finaticHmacSha256Hex(FinaticConnectorSecret, canonicalBody);
      httpHeaders += "X-Finatic-Signature: " + signatureHex + "\r\n";
     }

   char responseData[];
   string responseHeaders;
   ResetLastError();
   int httpCode = WebRequest(
      "POST",
      requestUrl,
      httpHeaders,
      12000,
      postData,
      responseData,
      responseHeaders
   );
   if(httpCode == -1)
     {
      int lastErrorCode = GetLastError();
      Print(
         "Finatic WebRequest failed route=",
         routeSuffix,
         " err=",
         lastErrorCode,
         " url=",
         requestUrl
      );
      if(lastErrorCode == 4060)
         Print(
            "Finatic err 4060: URL not allowed. Add ",
            g_webRequestAllowlistOrigin,
            " under Tools->Options->Expert Advisors, then restart MT4."
         );
      else if(lastErrorCode == 5200)
         Print(
            "Finatic err 5200: TCP connect failed (allowlist is OK). Confirm FinaticBackground is running at ",
            g_webRequestAllowlistOrigin,
            ". Test in cmd: curl ",
            g_webRequestAllowlistOrigin,
            "/docs — broker-branded MT4 builds may block external WebRequest entirely."
         );
      return("");
     }
   string responseText = CharArrayToString(responseData, 0, WHOLE_ARRAY);
   if(httpCode < 200 || httpCode > 299)
     {
      Print("Finatic HTTP ", httpCode, " route=", routeSuffix, " body=", responseText);
      return("");
     }
   g_ingestSequence++;
   return(responseText);
  }
