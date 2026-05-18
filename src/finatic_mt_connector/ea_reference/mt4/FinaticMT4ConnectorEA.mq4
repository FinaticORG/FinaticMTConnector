#property strict
#property version   "0.3.0"
#property description "Finatic MT4 Connector — heartbeat, snapshot bootstrap, and account snapshot to Finatic Background."

input string FinaticPlatform = "mt4";
input string FinaticConnectorId = "";
input string FinaticConnectorSecret = "";
input string FinaticIngestUrl = "";
input int    FinaticSigningSchemeVersion = 1;
input int    FinaticTimestampSkewSeconds = 300;
input bool   FinaticSnapshotRequired = true;
input int    FinaticHeartbeatSeconds = 15;
input int    FinaticSecretVersion = 1;

int   g_ingestSequence = 0;
bool  g_ingestConfigurationValid = false;
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
   Print("Finatic MT4 Connector: timer=", FinaticHeartbeatSeconds, "s base=", g_ingestBaseUrl);
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

   string ordersJson = "[";
   int orderCount = OrdersTotal();
   for(int j = orderCount - 1; j >= 0; j--)
     {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(StringLen(ordersJson) > 1)
         ordersJson += ",";
      string orderSymbol = finaticJsonEscape(OrderSymbol());
      double orderVolume = OrderLots();
      int orderTicket = OrderTicket();
      ordersJson +=
         "{\"order_id\":\"" + IntegerToString(orderTicket) +
         "\",\"symbol\":\"" + orderSymbol +
         "\",\"volume_current\":" + DoubleToString(orderVolume, 4) +
         ",\"login\":\"" + login + "\"}";
     }
   ordersJson += "]";

   return(
      "{\"accounts\":" + accountsJson +
      ",\"positions\":[]" +
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
   char  postData[];
   int postLen = StringToCharArray(jsonBody, postData, 0, WHOLE_ARRAY);
   if(postLen > 0)
      postLen -= 1;
   string httpHeaders = "Content-Type: application/json\r\n";
   char  responseData[];
   string responseHeaders;
   ResetLastError();
   int httpCode = WebRequest("POST", requestUrl, httpHeaders, 12000, postData, postLen, responseData, responseHeaders);
   if(httpCode == -1)
     {
      Print("Finatic WebRequest failed route=", routeSuffix, " err=", GetLastError());
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
