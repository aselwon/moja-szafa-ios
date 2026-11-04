-- Synthetic envelope only for disposable test databases; never a product price.
INSERT INTO api_private.ai_cost_policy(singleton,enabled,monthly_user_units,budget_microunits,currency,pricing_version,request_cap_microunits)
VALUES(true,true,100000,100000000,'PLN','test-only',10) ON CONFLICT DO NOTHING;
