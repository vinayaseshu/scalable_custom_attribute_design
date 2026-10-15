-- =====================================================================
-- Tenant-Aware Custom Attributes
-- Script : 04_validation_tests.sql - proves the guardrails reject bad data
-- Run after 02_sample_data.sql (as the table owner, before or without
-- 05_row_level_security.sql, or with app.tenant_id set to 1).
-- Each test should print "OK: ... rejected".
-- =====================================================================

CREATE OR REPLACE PROCEDURE expect_error(p_label TEXT, p_sql TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'FAIL: % was accepted', p_label;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'OK: % rejected -> %', p_label, SQLERRM;
END $$;

-- 1. Wrong typed column: ram_gb is INTEGER, text supplied
CALL expect_error('text value for INTEGER attribute', $q$
  INSERT INTO attribute_value (tenant_id, entity_type, entity_id, attribute_id, value_text)
  SELECT 1, 'PRODUCT', '3', attribute_id, '16GB'
  FROM attribute_definition WHERE tenant_id = 1 AND attribute_code = 'ram_gb' $q$);

-- 2. Out of range: ram_gb max is 1024
CALL expect_error('ram_gb above maximum', $q$
  SELECT set_attribute(1, 'PRODUCT', '3', 'SALES', 'ram_gb', ARRAY['4096']) $q$);

-- 3. Unknown option code for a dropdown
CALL expect_error('option not in list', $q$
  SELECT set_attribute(1, 'PRODUCT', '3', 'SALES', 'color', ARRAY['Slvr']) $q$);

-- 4. Option from ANOTHER tenant (BETA's OLIVE on an ACME product)
CALL expect_error('cross-tenant option', $q$
  INSERT INTO attribute_value (tenant_id, entity_type, entity_id, attribute_id, option_id)
  SELECT 1, 'PRODUCT', '3', a.attribute_id, o.option_id
  FROM attribute_definition a, attribute_option o
  WHERE a.tenant_id = 1 AND a.attribute_code = 'color'
    AND o.tenant_id = 2 AND o.option_code = 'OLIVE' $q$);

-- 5. Option from ANOTHER attribute of the same tenant (size 'M' as a color)
CALL expect_error('option of a different attribute', $q$
  INSERT INTO attribute_value (tenant_id, entity_type, entity_id, attribute_id, option_id)
  SELECT 1, 'PRODUCT', '3', a.attribute_id, o.option_id
  FROM attribute_definition a
  JOIN attribute_option o ON o.tenant_id = 1 AND o.option_code = 'M'
  WHERE a.tenant_id = 1 AND a.attribute_code = 'color' $q$);

-- 6. Attribute not allowed for this entity type (loyalty_tier on a PRODUCT)
CALL expect_error('attribute not mapped to entity type', $q$
  SELECT set_attribute(1, 'PRODUCT', '3', 'CRM', 'loyalty_tier', ARRAY['GOLD']) $q$);

-- 7. Second value for a single-valued attribute
CALL expect_error('two values for single-valued attribute', $q$
  SELECT set_attribute(1, 'PRODUCT', '3', 'SALES', 'size', ARRAY['S','M']) $q$);

-- 8. Regex rule: invalid email
CALL expect_error('email failing regex', $q$
  SELECT set_attribute(1, 'CUSTOMER', 'C-1002', 'CRM', 'email', ARRAY['raj-at-example']) $q$);

-- 9. Two value columns filled at once
CALL expect_error('two value columns', $q$
  INSERT INTO attribute_value (tenant_id, entity_type, entity_id, attribute_id, value_int, value_text)
  SELECT 1, 'PRODUCT', '3', attribute_id, 16, '16'
  FROM attribute_definition WHERE tenant_id = 1 AND attribute_code = 'ram_gb' $q$);

-- 10. Subdomain that belongs to a different domain
CALL expect_error('subdomain from another domain', $q$
  INSERT INTO attribute_definition (tenant_id, domain_id, subdomain_id, attribute_code, display_name, data_type)
  SELECT 1, d.domain_id, s.subdomain_id, 'bad_attr', 'Bad', 'TEXT'
  FROM attribute_domain d, attribute_subdomain s
  WHERE d.tenant_id = 1 AND d.domain_code = 'SALES'
    AND s.tenant_id = 1 AND s.subdomain_code = 'LOYALTY' $q$);

-- 11. Unknown entity type
CALL expect_error('unknown entity type', $q$
  INSERT INTO attribute_value (tenant_id, entity_type, entity_id, attribute_id, value_int)
  SELECT 1, 'INVOICE', '9', attribute_id, 16
  FROM attribute_definition WHERE tenant_id = 1 AND attribute_code = 'ram_gb' $q$);

-- 12. Positive check: valid write succeeds, then orphan cleanup works
DO $$
DECLARE n INT;
BEGIN
    INSERT INTO product (tenant_id, sku, product_name, product_type)
    VALUES (1, 'TMP-001', 'Temp Laptop', 'LAPTOP');
    PERFORM set_attribute(1, 'PRODUCT', currval(pg_get_serial_sequence('product','product_id'))::text,
                          'SALES', 'ram_gb', ARRAY['32']);
    DELETE FROM product WHERE tenant_id = 1 AND sku = 'TMP-001';
    SELECT COUNT(*) INTO n FROM attribute_value v
    WHERE v.entity_type = 'PRODUCT'
      AND NOT EXISTS (SELECT 1 FROM product p WHERE p.product_id::text = v.entity_id);
    RAISE NOTICE '%', CASE WHEN n = 0 THEN 'OK: valid write accepted and orphan values cleaned up'
                           ELSE 'FAIL: ' || n || ' orphan values left' END;
END $$;

DROP PROCEDURE expect_error(TEXT, TEXT);
