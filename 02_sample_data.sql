-- =====================================================================
-- Tenant-Aware Custom Attributes
-- Script : 02_sample_data.sql - catalog setup and example values
-- Run after 01_schema.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Example APPLICATION tables (the records attributes attach to).
--    These are your existing tables; they only need a tenant_id.
--    product uses a BIGINT key, customer uses a natural VARCHAR key,
--    showing why attribute_value.entity_id is VARCHAR.
-- ---------------------------------------------------------------------
CREATE TABLE product (
    tenant_id     INT          NOT NULL REFERENCES tenant(tenant_id),
    product_id    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku           VARCHAR(100) NOT NULL,
    product_name  VARCHAR(300) NOT NULL,
    product_type  VARCHAR(50)  NOT NULL,              -- 'LAPTOP', 'TSHIRT'
    UNIQUE (tenant_id, sku)
);

CREATE TABLE customer (
    tenant_id     INT          NOT NULL REFERENCES tenant(tenant_id),
    customer_no   VARCHAR(30)  NOT NULL,              -- natural key, e.g. 'C-1001'
    full_name     VARCHAR(200) NOT NULL,
    PRIMARY KEY (tenant_id, customer_no)
);

CREATE TABLE supplier (
    tenant_id     INT          NOT NULL REFERENCES tenant(tenant_id),
    supplier_id   BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_name VARCHAR(200) NOT NULL
);

-- Orphan cleanup: deleting a record deletes its attribute values
CREATE TRIGGER trg_product_attr_cleanup AFTER DELETE ON product
FOR EACH ROW EXECUTE FUNCTION fn_entity_attribute_cleanup('PRODUCT', 'product_id');
CREATE TRIGGER trg_customer_attr_cleanup AFTER DELETE ON customer
FOR EACH ROW EXECUTE FUNCTION fn_entity_attribute_cleanup('CUSTOMER', 'customer_no');
CREATE TRIGGER trg_supplier_attr_cleanup AFTER DELETE ON supplier
FOR EACH ROW EXECUTE FUNCTION fn_entity_attribute_cleanup('SUPPLIER', 'supplier_id');

-- ---------------------------------------------------------------------
-- 2. Tenants and entity types
-- ---------------------------------------------------------------------
INSERT INTO tenant (tenant_code, tenant_name) VALUES
  ('ACME', 'Acme Retail'),
  ('BETA', 'Beta Outfitters');

INSERT INTO entity_type (entity_type, display_name, source_table, pk_column) VALUES
  ('PRODUCT',  'Product',  'product',  'product_id'),
  ('CUSTOMER', 'Customer', 'customer', 'customer_no'),
  ('SUPPLIER', 'Supplier', 'supplier', 'supplier_id');

-- ---------------------------------------------------------------------
-- 3. Domains and subdomains (per tenant)
-- ---------------------------------------------------------------------
INSERT INTO attribute_domain (tenant_id, domain_code, domain_name)
SELECT t.tenant_id, v.code, v.name
FROM (VALUES ('ACME','SALES','Sales & Catalog'),
             ('ACME','CRM',  'Customer Relationship'),
             ('BETA','SALES','Sales & Catalog')) v(tenant, code, name)
JOIN tenant t ON t.tenant_code = v.tenant;

INSERT INTO attribute_subdomain (tenant_id, domain_id, subdomain_code, subdomain_name)
SELECT d.tenant_id, d.domain_id, v.code, v.name
FROM (VALUES ('ACME','SALES','PRODUCT_SPECS','Product Specifications'),
             ('ACME','SALES','APPAREL',      'Apparel'),
             ('ACME','CRM',  'LOYALTY',      'Loyalty Program'),
             ('ACME','CRM',  'CONTACT',      'Contact & Location'),
             ('BETA','SALES','APPAREL',      'Apparel')) v(tenant, dom, code, name)
JOIN tenant t           ON t.tenant_code = v.tenant
JOIN attribute_domain d ON d.tenant_id = t.tenant_id AND d.domain_code = v.dom;

-- ---------------------------------------------------------------------
-- 4. Attribute definitions
-- ---------------------------------------------------------------------
INSERT INTO attribute_definition
      (tenant_id, domain_id, subdomain_id, attribute_code, display_name, data_type,
       is_multi_valued, unit_of_measure, min_value, max_value, max_length,
       regex_pattern, is_filterable)
SELECT t.tenant_id, d.domain_id, s.subdomain_id, v.code, v.name, v.dtype,
       v.multi, v.uom, v.minv, v.maxv, v.maxlen, v.rx, v.filt
FROM (VALUES
  -- tenant, domain, subdomain,       code,               name,               type,      multi, uom,    min,  max,   maxlen, regex,                         filterable
  ('ACME','SALES','PRODUCT_SPECS','ram_gb',            'RAM',              'INTEGER', FALSE, 'GB',   1,    1024,  NULL,   NULL,                          TRUE),
  ('ACME','SALES','PRODUCT_SPECS','screen_size',       'Screen Size',      'DECIMAL', FALSE, 'inch', 5,    40,    NULL,   NULL,                          TRUE),
  ('ACME','SALES','PRODUCT_SPECS','warranty_end',      'Warranty End',     'DATE',    FALSE, NULL,   NULL, NULL,  NULL,   NULL,                          FALSE),
  ('ACME','SALES','APPAREL',      'size',              'Size',             'OPTION',  FALSE, NULL,   NULL, NULL,  NULL,   NULL,                          TRUE),
  ('ACME','SALES', NULL,          'color',             'Color',            'OPTION',  TRUE,  NULL,   NULL, NULL,  NULL,   NULL,                          TRUE),
  ('ACME','CRM',  'LOYALTY',      'loyalty_tier',      'Loyalty Tier',     'OPTION',  FALSE, NULL,   NULL, NULL,  NULL,   NULL,                          TRUE),
  ('ACME','CRM',  'LOYALTY',      'loyalty_points',    'Loyalty Points',   'INTEGER', FALSE, 'pts',  0,    NULL,  NULL,   NULL,                          TRUE),
  ('ACME','CRM',  'CONTACT',      'email',             'Email',            'TEXT',    FALSE, NULL,   NULL, NULL,  254,    '^[^@\s]+@[^@\s]+\.[^@\s]+$',  FALSE),
  ('ACME','CRM',  'CONTACT',      'region',            'Region',           'TEXT',    FALSE, NULL,   NULL, NULL,  100,    NULL,                          TRUE),
  ('ACME','CRM',  'CONTACT',      'marketing_opt_in',  'Marketing Opt-in', 'BOOLEAN', FALSE, NULL,   NULL, NULL,  NULL,   NULL,                          TRUE),
  -- BETA defines its own "color" with its own options: fully isolated from ACME
  ('BETA','SALES','APPAREL',      'color',             'Colour',           'OPTION',  TRUE,  NULL,   NULL, NULL,  NULL,   NULL,                          TRUE)
) v(tenant, dom, sub, code, name, dtype, multi, uom, minv, maxv, maxlen, rx, filt)
JOIN tenant t                    ON t.tenant_code = v.tenant
JOIN attribute_domain d          ON d.tenant_id = t.tenant_id AND d.domain_code = v.dom
LEFT JOIN attribute_subdomain s  ON s.tenant_id = t.tenant_id AND s.domain_id = d.domain_id
                                AND s.subdomain_code = v.sub;

-- ---------------------------------------------------------------------
-- 5. Options for OPTION attributes
-- ---------------------------------------------------------------------
INSERT INTO attribute_option (tenant_id, attribute_id, option_code, option_label, sort_order)
SELECT a.tenant_id, a.attribute_id, v.code, v.label, v.ord
FROM (VALUES
  ('ACME','SALES','color','BLK','Black',1), ('ACME','SALES','color','SLV','Silver',2),
  ('ACME','SALES','color','RED','Red',3),
  ('ACME','SALES','size','S','Small',1),    ('ACME','SALES','size','M','Medium',2),
  ('ACME','SALES','size','L','Large',3),
  ('ACME','CRM','loyalty_tier','SILVER','Silver',1), ('ACME','CRM','loyalty_tier','GOLD','Gold',2),
  ('ACME','CRM','loyalty_tier','PLAT','Platinum',3),
  ('BETA','SALES','color','OLIVE','Olive',1), ('BETA','SALES','color','SAND','Sand',2)
) v(tenant, dom, attr, code, label, ord)
JOIN tenant t               ON t.tenant_code = v.tenant
JOIN attribute_domain d     ON d.tenant_id = t.tenant_id AND d.domain_code = v.dom
JOIN attribute_definition a ON a.tenant_id = t.tenant_id AND a.domain_id = d.domain_id
                           AND a.attribute_code = v.attr;

-- ---------------------------------------------------------------------
-- 6. Applicability: which attributes each entity type may use
--    (region is shared by CUSTOMER and SUPPLIER)
-- ---------------------------------------------------------------------
INSERT INTO attribute_entity_type
      (tenant_id, attribute_id, entity_type, is_required, attribute_group, sort_order)
SELECT a.tenant_id, a.attribute_id, v.etype, v.req, v.grp, v.ord
FROM (VALUES
  ('ACME','SALES','ram_gb',          'PRODUCT',  FALSE,'Specs',   1),
  ('ACME','SALES','screen_size',     'PRODUCT',  FALSE,'Specs',   2),
  ('ACME','SALES','warranty_end',    'PRODUCT',  FALSE,'Warranty',3),
  ('ACME','SALES','size',            'PRODUCT',  FALSE,'Apparel', 4),
  ('ACME','SALES','color',           'PRODUCT',  TRUE, 'General', 5),
  ('ACME','CRM',  'loyalty_tier',    'CUSTOMER', TRUE, 'Loyalty', 1),
  ('ACME','CRM',  'loyalty_points',  'CUSTOMER', FALSE,'Loyalty', 2),
  ('ACME','CRM',  'email',           'CUSTOMER', TRUE, 'Contact', 3),
  ('ACME','CRM',  'region',          'CUSTOMER', FALSE,'Contact', 4),
  ('ACME','CRM',  'marketing_opt_in','CUSTOMER', FALSE,'Contact', 5),
  ('ACME','CRM',  'region',          'SUPPLIER', TRUE, 'Location',1),
  ('BETA','SALES','color',           'PRODUCT',  TRUE, 'General', 1)
) v(tenant, dom, attr, etype, req, grp, ord)
JOIN tenant t               ON t.tenant_code = v.tenant
JOIN attribute_domain d     ON d.tenant_id = t.tenant_id AND d.domain_code = v.dom
JOIN attribute_definition a ON a.tenant_id = t.tenant_id AND a.domain_id = d.domain_id
                           AND a.attribute_code = v.attr;

-- ---------------------------------------------------------------------
-- 7. Application records
-- ---------------------------------------------------------------------
INSERT INTO product (tenant_id, sku, product_name, product_type) VALUES
  (1, 'LAP-001', 'ProBook 15',  'LAPTOP'),     -- product_id 1
  (1, 'LAP-002', 'AirLite 13',  'LAPTOP'),     -- product_id 2
  (1, 'TSH-001', 'Classic Tee', 'TSHIRT'),     -- product_id 3
  (2, 'TRL-100', 'Trail Shirt', 'TSHIRT');     -- product_id 4 (tenant BETA)

INSERT INTO customer (tenant_id, customer_no, full_name) VALUES
  (1, 'C-1001', 'Jane Smith'),
  (1, 'C-1002', 'Raj Patel');

INSERT INTO supplier (tenant_id, supplier_name) VALUES
  (1, 'Gulf Coast Textiles');                  -- supplier_id 1

-- ---------------------------------------------------------------------
-- 8. Attribute values, written through set_attribute()
--    set_attribute(tenant_id, entity_type, entity_id, domain, attribute, values[])
-- ---------------------------------------------------------------------
SELECT set_attribute(1, 'PRODUCT', '1', 'SALES', 'ram_gb',       ARRAY['16']);
SELECT set_attribute(1, 'PRODUCT', '1', 'SALES', 'screen_size',  ARRAY['15.6']);
SELECT set_attribute(1, 'PRODUCT', '1', 'SALES', 'color',        ARRAY['SLV']);
SELECT set_attribute(1, 'PRODUCT', '1', 'SALES', 'warranty_end', ARRAY['2027-12-31']);

SELECT set_attribute(1, 'PRODUCT', '2', 'SALES', 'ram_gb',       ARRAY['8']);
SELECT set_attribute(1, 'PRODUCT', '2', 'SALES', 'screen_size',  ARRAY['13.3']);
SELECT set_attribute(1, 'PRODUCT', '2', 'SALES', 'color',        ARRAY['BLK','SLV']);  -- multi-valued

SELECT set_attribute(1, 'PRODUCT', '3', 'SALES', 'size',         ARRAY['M']);
-- product 3 deliberately has no color (required) -> shows up in the data-quality check

SELECT set_attribute(1, 'CUSTOMER', 'C-1001', 'CRM', 'loyalty_tier',     ARRAY['GOLD']);
SELECT set_attribute(1, 'CUSTOMER', 'C-1001', 'CRM', 'loyalty_points',   ARRAY['4200']);
SELECT set_attribute(1, 'CUSTOMER', 'C-1001', 'CRM', 'email',            ARRAY['jane@example.com']);
SELECT set_attribute(1, 'CUSTOMER', 'C-1001', 'CRM', 'region',           ARRAY['Florida']);
SELECT set_attribute(1, 'CUSTOMER', 'C-1001', 'CRM', 'marketing_opt_in', ARRAY['true']);

SELECT set_attribute(1, 'CUSTOMER', 'C-1002', 'CRM', 'loyalty_tier',     ARRAY['SILVER']);
SELECT set_attribute(1, 'CUSTOMER', 'C-1002', 'CRM', 'region',           ARRAY['Georgia']);
-- C-1002 has no email (required) -> shows up in the data-quality check

SELECT set_attribute(1, 'SUPPLIER', '1', 'CRM', 'region', ARRAY['Florida']);

SELECT set_attribute(2, 'PRODUCT', '4', 'SALES', 'color', ARRAY['OLIVE','SAND']);

-- A later change: AirLite 13 RAM upgraded from 8 to 12 GB.
-- Recorded in attribute_value_history as an UPDATE (old 8, new 12).
SELECT set_attribute(1, 'PRODUCT', '2', 'SALES', 'ram_gb', ARRAY['12'], 'catalog_admin');
-- Re-sending the same colors changes nothing and writes no history.
SELECT set_attribute(1, 'PRODUCT', '2', 'SALES', 'color',  ARRAY['BLK','SLV'], 'catalog_admin');

-- Equivalent plain INSERT (what set_attribute does under the hood):
-- INSERT INTO attribute_value (tenant_id, entity_type, entity_id, attribute_id, value_int)
-- VALUES (1, 'PRODUCT', '1', <ram_gb attribute_id>, 16);
