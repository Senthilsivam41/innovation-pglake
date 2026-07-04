\set ON_ERROR_STOP on

INSERT INTO aetherlake.events (tenant_id, event_type, payload)
VALUES
    (1001, 'account.created', '{"account_id":"A-1001","plan":"enterprise"}'),
    (1001, 'invoice.issued', '{"invoice_id":"I-1001","amount":1250.00}');

