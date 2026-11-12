-- Detection rules and fix types for the Chinook stand-in ERP.
--
-- A detection rule is a view in schema `detect` whose rows are the current discrepancies,
-- keyed by `key`. A fix type is a branch of fix.run(). The executor's database role can
-- execute fix.dry_run() and fix.commit() and nothing else, so "the model proposes a typed
-- fix, something else applies it" is enforced here and not only in application code.
\c chinook

CREATE SCHEMA detect;
CREATE SCHEMA fix;

CREATE VIEW detect.invoice_total_mismatch AS
SELECT i.invoice_id AS key, i.total, COALESCE(SUM(l.unit_price * l.quantity), 0) AS lines_total
FROM invoice i
LEFT JOIN invoice_line l USING (invoice_id)
GROUP BY i.invoice_id
HAVING i.total <> COALESCE(SUM(l.unit_price * l.quantity), 0);

CREATE TABLE fix.audit (
    proposal_hash text PRIMARY KEY, -- one proposed fix is applied at most once
    rule          text NOT NULL,
    key           int NOT NULL,
    fix_type      text NOT NULL,
    params        jsonb NOT NULL,
    approver      text NOT NULL,
    committed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION fix.is_open(p_rule text, p_key int) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE found boolean;
BEGIN
    -- %I quotes the rule as an identifier; an unknown rule fails as "relation does not exist".
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM detect.%I WHERE key = $1)', p_rule) INTO found USING p_key;
    RETURN found;
END $$;

-- The declared fix types. Anything else raises, whatever the caller was told to ask for.
CREATE FUNCTION fix.run(p_rule text, p_key int, p_fix_type text, p_params jsonb) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    IF p_rule = 'invoice_total_mismatch' AND p_fix_type = 'set_invoice_total_from_lines' THEN
        UPDATE invoice SET total = (SELECT COALESCE(SUM(unit_price * quantity), 0) FROM invoice_line WHERE invoice_id = p_key)
        WHERE invoice_id = p_key;
    ELSIF p_rule = 'invoice_total_mismatch' AND p_fix_type = 'set_line_price_from_track' THEN
        UPDATE invoice_line l SET unit_price = t.unit_price FROM track t
        WHERE t.track_id = l.track_id AND l.invoice_line_id = (p_params->>'invoice_line_id')::int AND l.invoice_id = p_key;
        IF NOT FOUND THEN RAISE EXCEPTION 'invoice line % is not on invoice %', p_params->>'invoice_line_id', p_key; END IF;
    ELSIF p_rule = 'invoice_total_mismatch' AND p_fix_type = 'set_line_quantity' THEN
        IF (p_params->>'quantity')::int <= 0 THEN RAISE EXCEPTION 'quantity must be positive'; END IF;
        UPDATE invoice_line SET quantity = (p_params->>'quantity')::int
        WHERE invoice_line_id = (p_params->>'invoice_line_id')::int AND invoice_id = p_key;
        IF NOT FOUND THEN RAISE EXCEPTION 'invoice line % is not on invoice %', p_params->>'invoice_line_id', p_key; END IF;
    ELSE
        RAISE EXCEPTION 'fix type % is not declared for rule %', p_fix_type, p_rule;
    END IF;
END $$;

-- Applies the fix, reports whether the discrepancy is gone, and always rolls the change back.
CREATE FUNCTION fix.dry_run(p_rule text, p_key int, p_fix_type text, p_params jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE resolves boolean := false; err text;
BEGIN
    BEGIN
        PERFORM fix.run(p_rule, p_key, p_fix_type, p_params);
        resolves := NOT fix.is_open(p_rule, p_key); -- plpgsql variables survive the rollback below
        RAISE EXCEPTION USING ERRCODE = 'ADP01';
    EXCEPTION
        WHEN SQLSTATE 'ADP01' THEN NULL;
        WHEN OTHERS THEN err := SQLERRM;
    END;
    RETURN jsonb_build_object('resolves', resolves, 'error', err);
END $$;

-- One statement, so one transaction: idempotent on the proposal hash, a no-op if the
-- discrepancy is already gone, and rolled back if the fix no longer resolves it.
CREATE FUNCTION fix.commit(p_rule text, p_key int, p_fix_type text, p_params jsonb, p_hash text, p_approver text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF p_hash IS NULL OR p_hash = '' OR p_approver IS NULL OR p_approver = '' THEN
        RAISE EXCEPTION 'a commit needs a proposal hash and an approver';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext(p_hash));
    IF EXISTS (SELECT 1 FROM fix.audit WHERE proposal_hash = p_hash) THEN
        RETURN jsonb_build_object('status', 'committed', 'replayed', true);
    END IF;
    IF NOT fix.is_open(p_rule, p_key) THEN
        RETURN jsonb_build_object('status', 'resolved_elsewhere');
    END IF;
    BEGIN
        PERFORM fix.run(p_rule, p_key, p_fix_type, p_params);
        IF fix.is_open(p_rule, p_key) THEN RAISE EXCEPTION USING ERRCODE = 'ADP02'; END IF;
    EXCEPTION WHEN OTHERS THEN
        -- The data changed after the check and approval; nothing is applied.
        RETURN jsonb_build_object('status', 'stale', 'error', CASE WHEN SQLSTATE = 'ADP02' THEN 'fix no longer resolves the discrepancy' ELSE SQLERRM END);
    END;
    INSERT INTO fix.audit (proposal_hash, rule, key, fix_type, params, approver)
    VALUES (p_hash, p_rule, p_key, p_fix_type, p_params, p_approver);
    RETURN jsonb_build_object('status', 'committed', 'replayed', false);
END $$;
