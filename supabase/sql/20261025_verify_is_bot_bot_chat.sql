-- S-2 (CB-45): read-only check. No schema change is needed: billing.is_bot already returns false for 'bot-chat'
-- and there is no CHECK constraint on ai_usage.source / billing.usage_ledger.source. Expected: bot_chat=false, bot=true, agent=false, constraints=0.
select billing.is_bot('bot-chat') as bot_chat, billing.is_bot('BOT-CHAT') as bot_chat_upper, billing.is_bot('bot') as bot, billing.is_bot('agent') as agent,
  (select count(*) from pg_constraint where conrelid in ('public.ai_usage'::regclass, 'billing.usage_ledger'::regclass)
     and contype = 'c' and pg_get_constraintdef(oid) ilike '%source%') as source_check_constraints;
