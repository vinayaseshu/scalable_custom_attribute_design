-- =====================================================================
-- Tenant-Aware Custom Attributes
-- Script : 05_row_level_security.sql - tenant isolation in the database
-- Run last (after 04_validation_tests.sql)
-- =====================================================================
--
-- The application connects as app_user and, at the start of every
-- request or transaction, runs:
--     SET app.tenant_id = '<tenant id>';
-- Every policy then filters on that value, so a missing WHERE tenant_id
-- in application code can never leak another tenant's data.
-- =====================================================================

CREATE ROLE app_user LOGIN;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_user;

-- Current tenant, or NULL when not set (NULL matches no rows)
CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.tenant_id', true), '')::int
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'attribute_domain', 'attribute_subdomain', 'attribute_definition',
        'attribute_option', 'attribute_entity_type', 'attribute_value',
        'attribute_value_history', 'product', 'customer', 'supplier']
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);   -- applies to the owner too
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I
                 USING (tenant_id = current_tenant_id())
                 WITH CHECK (tenant_id = current_tenant_id())', t);
    END LOOP;
END $$;

-- Administrative roles that must see all tenants (migrations, support):
--   ALTER ROLE platform_admin BYPASSRLS;

-- ---------------------------------------------------------------------
-- Demonstration
-- ---------------------------------------------------------------------
SET ROLE app_user;

SET app.tenant_id = '1';
SELECT 'tenant 1 sees' AS who, COUNT(*) AS attribute_values FROM attribute_value;

SET app.tenant_id = '2';
SELECT 'tenant 2 sees' AS who, COUNT(*) AS attribute_values FROM attribute_value;

-- Tenant 2 cannot write a row for tenant 1 (WITH CHECK rejects it)
DO $$
BEGIN
    INSERT INTO attribute_domain (tenant_id, domain_code, domain_name)
    VALUES (1, 'HACK', 'Cross-tenant write');
    RAISE NOTICE 'UNEXPECTED: cross-tenant insert succeeded';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK: cross-tenant insert blocked by RLS';
END $$;

RESET app.tenant_id;
SELECT 'no tenant set sees' AS who, COUNT(*) AS attribute_values FROM attribute_value;

RESET ROLE;
