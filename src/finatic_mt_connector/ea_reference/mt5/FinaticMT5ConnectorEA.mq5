#property strict
#property version   "0.3.0"
#property description "Finatic MT5 Connector — heartbeat, snapshot bootstrap, and account snapshot to Finatic Background."

input string FinaticPlatform = "mt5";
input string FinaticConnectorId = "";
input string FinaticConnectorSecret = "";
input string FinaticIngestUrl = "";
input int    FinaticSigningSchemeVersion = 1;
input int    FinaticTimestampSkewSeconds = 300;
input bool   FinaticSnapshotRequired = true;
input int    FinaticHeartbeatSeconds = 15;
input int    FinaticSecretVersion = 1;

long  g_ingestSequence = 0;
bool  g_ingestConfigurationValid = false;
string g_ingestBaseUrl = "";

void OnInit()
  {
   g_ingestConfigurationValid = finaticValidateIngestConfiguration();
   if(!g_ingestConfigurationValid)
     return(INIT_FAILED);
   g_ingestBaseUrl = finaticTrimBaseUrl(FinaticIngestUrl);
   if(FinaticSnapshotRequired)
      finaticPushSnapshot();
   EventSetTimer(FinaticHeartbeatSeconds);
   Print("Finatic MT5 Connector: timer=", FinaticHeartbeatSeconds, "s base=", g_ingestBaseUrl);
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
      ordersJson +=
         "{\"order_id\":\"" + IntegerToString((long)orderTicket) +
         "\",\"symbol\":\"" + orderSymbol +
         "\",\"volume_current\":" + DoubleToString(orderVolume, 4) +
         ",\"login\":\"" + login + "\"}";
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
   finaticPostMinimalRoute("snapshot", innerPayload);
  }

bool finaticResponseRequestsSnapshot(string responseBody)
  {
   return(
      StringFind(responseBody, "\"should_send_snapshot\":true", 0) >= 0 ||
      StringFind(responseBody, "\"should_send_snapshot\": true", 0) >= 0
   );
  }

string finaticPostMinimalRoute(string routeSuffix, string innerPayloadJson)
  {
   if(StringLen(g_ingestBaseUrl) < 8)
      return("");
   string requestUrl = finaticBuildRouteUrl(routeSuffix);
   string jsonBody =
      "{\"sequence\":" + IntegerToString(g_ingestSequence) +
      ",\"secret_version\":" + IntegerToString(FinaticSecretVersion) +
      ",\"platform\":\"" + FinaticPlatform +
      "\",\"payload\":" + innerPayloadJson + "}";
   uchar  postData[];
   StringToCharArray(jsonBody, postData, 0, WHOLE_ARRAY, CP_UTF8);
   string httpHeaders = "Content-Type: application/json\r\n";
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
