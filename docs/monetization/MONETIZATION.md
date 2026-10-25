# SubMac Agent — Monetization & Payments (working context)

Owner of this doc: monetization/payments lead (Hark). Last updated: 2026-10-20 (EAT), pricing locked. Read this before touching billing, allowance, pricing, or the finance dashboard.

## 1. Current state (as of 2026-10-20)
- No payments in the app. Users get a free daily allowance plus referral/bot-hire rewards.
- Allowance is metered in **weighted tokens**: `ceil(0.3 × uncached input + 0.1 × cached input + 1.0 × output)` (`supabase/functions/ai-chat/index.ts`).
- Live DB settings: daily cap **500k** weighted (+40k grace; repo still says 200k). Past cap → `submac-lite`, 400 output tokens max. Images flat 4,000. 40 RPM per user.
- Live voice metered separately in minutes (15 min/day free, `live_user_limits`).
- Rewards: 30k/day for 7 days per referral or bot hire; max 150k/day bonus; 20 lifetime, 5/day.
- Real usage (4 users, 2026-10-18 → 10-20): avg reply 12.9k input (14% cached), 181 output ≈ **3,700 weighted**. **1M weighted ≈ 270 replies.** Median user-day 62k, p90 466k, max 610k. Bots/Offices = 69% of usage; `submac-smart` = 83%.
- Routing runs on free keys (33 keys, 9 providers). 87% of smart traffic is one free NVIDIA NIM key — NIM has no paid tier; replace first.
- Hooks already present: `ai_user_cap()` (override + rewards + admin grants), `ai_user_limits`, `reward_ledger`, `live_user_limits`, cap check in `ai-chat`, app reads `x-submac-usage/state/window` headers.
- Missing: products/purchases/wallet/entitlement tables, Sifalo verification for the Agent, non-expiring balance, tier in `/status`, per-tier model access/rate limits, deployed `ai-chat` v21 source in repo.

## 2. Cost model (paid APIs, real request shape)
| Model | $ per 1M weighted |
|---|---|
| GPT-6 Luna (OpenAI) | 0.33 |
| DeepSeek Flash off-peak / peak | 0.48 / 0.96 |
| gpt-oss-120b (Groq) | 0.52 |
| Gemini 3.1 Flash-Lite | 0.84 |
| Nemotron 3 Ultra (OpenRouter) | 1.98 |
| Gemini 3.8 Flash (doubles 1 Jan 2027) | 2.48 → 4.95 |
| DeepSeek V4 Pro peak | 4.19 |
- Blend (smart DeepSeek Flash + fast Luna) ≈ $0.70. **Plan at $1.00 per 1M weighted.**
- Gemini 3.8 Live ≈ $0.023/min.
- Exposure at today's free settings: maxed free user ≈ $16/month tokens + ≈ $10/month Live. Free cap must drop when keys go paid.
- Proposed stack: smart DeepSeek Flash (direct) → Luna → OpenRouter; fast Luna → Haiku 5.5 → gpt-oss-120b; vision Gemini 3.1 Flash-Lite → Luna; live Gemini 3.8 Live → OpenAI gpt-live-1. Direct providers primary, OpenRouter as fallback layer (5.5% top-up fee; accepts USDC).

## 3. Decisions made (owner, 2026-10-20)
- **Launch distribution: direct APK** (not Play Store) → no Play Billing at launch.
- **Payment rail: Sifalo Pay**, same merchant account and same integration as submac.site (`lib/sifalo.js`, `functions/api/pay/{webhook,reconcile,return}.js` in submac-owner/submac; env `SIFALO_API_USER`, `SIFALO_API_KEY`, `SIFALO_ENV`). Every payment re-verified with Sifalo; credit granted once. Sifalo has no auto-recurring.
- **Currency: SubMac Coins**, closed-loop. USD → coins at a fixed price; coins sit in a wallet until the user exchanges them for tokens. No cash-out, transfers or refunds of coins. Not a crypto token.
- **Monthly plan = monthly pool pass**: one-time payment, 30 days, bucket of tokens with a daily ceiling; partial rollover only on renewal (rolled tokens never roll again).
- **Token packs**: 1M, 5M, 10M, up to 15M.
- **Finance dashboard** at `finemanagedash.submac.site`, isolated Worker, owner + accountant roles, ledger-based.

## 4. LOCKED PLAN (approved by owner 2026-10-20)
Margins below = worst case (all tokens used) at $1.00 per 1M weighted cost and an ASSUMED 3% Sifalo fee.

### Free tier (when paid keys go live)
- 60k weighted/day (~16 replies), hard cap 1M/month. Standard models only. 10 Live minutes/month.

### SubMac Coins (1 coin = $0.01, closed-loop)
| Top-up | Coins | Bonus |
|---|---|---|
| $1 | 100 | - |
| $2 | 200 | - |
| $5 | 525 | +5% |
| $10 | 1,100 | +10% |
| $20 | 2,200 | +10% (max) |
- First top-up doubled (max +100 coins), once per verified phone.
- No cash value, no transfer, refunds only where law requires, clawback on payment reversal. Coins sit in wallet until exchanged; optional auto-exchange.

### Token packs (200 coins = 1M weighted ≈ 270 replies), valid 12 months
| Pack | Coins | Margin |
|---|---|---|
| 1M | 200 | 48% |
| 5M | 950 | ~44% |
| 10M | 1,850 | ~40% |
| 15M | 2,700 | 36% (bonuses stacked) |

### Passes (one-time payment; pool + daily ceiling)
| Pass | Price | Pool | Daily ceiling | Validity | Margin |
|---|---|---|---|---|---|
| Day | $0.25 (25 coins) | 120k | - | 24h | 50% |
| Week | $1.25 (125 coins) | 700k | 200k | 7 days | 42% |
| Starter | $1.99 (199 coins) | 1M | 100k | 30 days | 48% |
| Plus (hero) | $4.99 (499 coins) | 3M | 250k | 30 days | 38% |
| Pro | $9.99 (999 coins) | 6M | 500k | 30 days | 38% |

### Rules
- Burn order: free daily -> pass pool (within daily ceiling) -> pack/exchanged tokens. Soonest-expiring balance first; app shows it.
- Rollover: renew within 7 days of expiry -> up to 25% of new pool size carries over; expires with that period; never stacks.
- Model multipliers: Standard 1x, Advanced 2.5x, Premium 5x (Gemini 3.8 Flash -> 5x from 2027-01-01).
- Live voice draws from the same balance at 40k weighted/minute (~68% margin).
- Bots/background capped at 50% of a pass's daily ceiling.
- UI shows replies (≈270 per 1M), never "unlimited".
- Referrals reward only on invitee's first purchase; one per verified phone; capped.
- Coin->token rate may change for future exchanges if provider prices change; held coins keep their value.
- Everything ships behind a `billing_enabled` flag; live limits change only when the owner flips it.

### Pre-launch checks
- Sifalo fee schedule (if fixed fee >= ~$0.05, sell Day/Week only via coins).
- Local counsel: closed-loop coins vs e-money rules in Somalia.
- Re-tune pool sizes after 30 days of paid usage data.

## 5. Accounting rules
- Append-only ledger (`finance.ledger`); corrections = reversing entries.
- Unexchanged coins and unused pools = **deferred revenue (liability)**, not profit.
- Revenue recognized when tokens are consumed / pass period elapses (accountant to confirm policy).
- Day boundary: East Africa Time (Africa/Mogadishu).

## 6. Open items
- Sifalo fee schedule (unpublished; ask Sifalo).
- Whether Somali cards are accepted by OpenAI/Google/DeepSeek billing (else OpenRouter via USDC).
- DeepSeek data terms; OpenAI/Anthropic retention.
- Commit deployed `ai-chat` v21 + 2026-10-19 migrations to repo before building billing on top.
- Security prerequisites before charging money: replace debug signing key, close `app_settings` approval-mode loophole, tighten sign-up (verification/captcha) to stop free-tier farming.
