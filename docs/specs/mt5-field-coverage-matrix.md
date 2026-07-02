# MT5 → `integration.*` field coverage matrix

| Domain | Source (MT5 EA payload) | Target (`integration.*`) | Status |
|---|---|---|---|
| account.login | `accounts[].login` | `accounts.broker_provided_account_id` | covered |
| account.balance | `accounts[].balance` | `balances.balance` (latest row) | covered |
| account.equity | `accounts[].equity` | `balances.equity` | covered |
| account.margin | `accounts[].margin` | `balances.margin_used` | covered |
| account.free_margin | `accounts[].free_margin` | `balances.cash_available_for_trading` | covered |
| account.currency | `accounts[].currency` | `accounts.currency` | covered |
| order.id | `orders[].order_id` / `events[].payload.order_id` | `orders.broker_order_id` | covered |
| order.symbol | `orders[].symbol` | `orders.symbol` | covered |
| order.side | events.order.upsert.side | `orders.side` | covered |
| order.status | events.order.upsert.status (`working`/`canceled`) | `orders.status` | covered (canceled/working) |
| order.price | events.order.upsert.price | `orders.limit_price` (limit) / `orders.stop_price` (stop) | partial |
| order.volume | events.order.upsert.volume | `orders.quantity_total` | covered |
| fill.deal_id | `events[].payload.deal_id` | `order_fills.broker_fill_id` | covered |
| fill.price | `events[].payload.price` | `order_fills.price` | covered |
| fill.volume | `events[].payload.volume` | `order_fills.quantity_filled` | covered |
| fill.order_id | `events[].payload.order_id` | `order_fills.order_id` (FK) | covered |
| position.symbol | `positions[].symbol` | `positions.symbol` | covered |
| position.volume | `positions[].volume` | `positions.quantity_open` | covered |
| position.price_open | `positions[].price_open` | `positions.average_open_price` | covered |
| position.side | `positions[].side` | `positions.side` | covered |
| transactions | (not emitted by EA today) | `transactions.*` | gap — derive from balance deltas + fills |

Gaps to close in mapping.py:
- Map MT5 stop/limit price into the correct field based on order kind.
- Synthesize `transactions` rows from balance delta + fill streams (no MT5 deposits/withdrawals event).
- Surface broker symbol → standard symbol mapping for instruments not auto-resolved.
