-- =====================================================================
-- Tenant-Aware Custom Attributes
-- Script : 03_queries.sql - common read patterns
-- Run after 02_sample_data.sql. Every query is scoped by tenant_id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) All attributes of one entity, human-readable
-- ---------------------------------------------------------------------
SELECT domain_code, subdomain_code, display_name, value_display, unit_of_measure
FROM v_attribute_value
WHERE tenant_id = 1 AND entity_type = 'PRODUCT' AND entity_id = '1'
ORDER BY domain_code, subdomain_code NULLS FIRST, attribute_code, value_seq;

-- ---------------------------------------------------------------------
-- (b) Filter: tenant 1 products with RAM >= 16 GB AND color = Silver
--     One EXISTS per condition; each uses a partial typed index.
-- ---------------------------------------------------------------------
SELECT p.product_id, p.sku, p.product_name
FROM product p
WHERE p.tenant_id = 1
  AND EXISTS (SELECT 1
              FROM attribute_value v
              JOIN attribute_definition a ON a.attribute_id = v.attribute_id
              WHERE v.tenant_id = p.tenant_id AND v.entity_type = 'PRODUCT'
                AND v.entity_id = p.product_id::text
                AND a.attribute_code = 'ram_gb' AND v.value_int >= 16)
  AND EXISTS (SELECT 1
              FROM attribute_value v
              JOIN attribute_definition a ON a.attribute_id = v.attribute_id
              JOIN attribute_option o     ON o.option_id = v.option_id
              WHERE v.tenant_id = p.tenant_id AND v.entity_type = 'PRODUCT'
                AND v.entity_id = p.product_id::text
                AND a.attribute_code = 'color' AND o.option_code = 'SLV');

-- ---------------------------------------------------------------------
-- (c) Pivot one entity type to a wide row (reporting / exports)
-- ---------------------------------------------------------------------
SELECT p.product_id, p.sku,
       MAX(v.value_int)     FILTER (WHERE a.attribute_code = 'ram_gb')       AS ram_gb,
       MAX(trim_scale(v.value_decimal)) FILTER (WHERE a.attribute_code = 'screen_size')  AS screen_size,
       MAX(v.value_date)    FILTER (WHERE a.attribute_code = 'warranty_end') AS warranty_end,
       STRING_AGG(o.option_label, ', ' ORDER BY v.value_seq)
                            FILTER (WHERE a.attribute_code = 'color')        AS colors,
       MAX(o.option_label)  FILTER (WHERE a.attribute_code = 'size')         AS size
FROM product p
LEFT JOIN attribute_value v       ON v.tenant_id = p.tenant_id
                                 AND v.entity_type = 'PRODUCT'
                                 AND v.entity_id = p.product_id::text
LEFT JOIN attribute_definition a  ON a.attribute_id = v.attribute_id
LEFT JOIN attribute_option o      ON o.option_id = v.option_id
WHERE p.tenant_id = 1
GROUP BY p.product_id, p.sku
ORDER BY p.product_id;

-- ---------------------------------------------------------------------
-- (d) Cross-entity search: everything in Florida, any entity type
-- ---------------------------------------------------------------------
SELECT v.entity_type, v.entity_id
FROM attribute_value v
JOIN attribute_definition a ON a.attribute_id = v.attribute_id
WHERE v.tenant_id = 1
  AND a.attribute_code = 'region'
  AND v.value_text = 'Florida'
ORDER BY v.entity_type, v.entity_id;

-- ---------------------------------------------------------------------
-- (e) Form metadata: attributes to show on a CUSTOMER edit screen,
--     grouped by domain / subdomain, with options for dropdowns
-- ---------------------------------------------------------------------
SELECT dm.domain_code, sd.subdomain_code, aet.attribute_group,
       a.attribute_code, a.display_name, a.data_type, aet.is_required,
       a.unit_of_measure,
       (SELECT STRING_AGG(o.option_label, ' | ' ORDER BY o.sort_order)
        FROM attribute_option o
        WHERE o.tenant_id = a.tenant_id AND o.attribute_id = a.attribute_id
          AND o.is_active) AS options
FROM attribute_entity_type aet
JOIN attribute_definition a      ON a.tenant_id = aet.tenant_id AND a.attribute_id = aet.attribute_id
JOIN attribute_domain dm         ON dm.domain_id = a.domain_id
LEFT JOIN attribute_subdomain sd ON sd.subdomain_id = a.subdomain_id
WHERE aet.tenant_id = 1 AND aet.entity_type = 'CUSTOMER' AND a.is_active
ORDER BY aet.sort_order;

-- ---------------------------------------------------------------------
-- (f) Catalog inventory: attribute count per domain / subdomain
-- ---------------------------------------------------------------------
SELECT t.tenant_code, dm.domain_code, COALESCE(sd.subdomain_code, '(none)') AS subdomain_code,
       COUNT(*) AS attributes
FROM attribute_definition a
JOIN tenant t                    ON t.tenant_id = a.tenant_id
JOIN attribute_domain dm         ON dm.domain_id = a.domain_id
LEFT JOIN attribute_subdomain sd ON sd.subdomain_id = a.subdomain_id
GROUP BY t.tenant_code, dm.domain_code, sd.subdomain_code
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- (g) Data quality: required attributes that are missing.
--     Joins the real source table so records with NO values are caught.
-- ---------------------------------------------------------------------
SELECT 'PRODUCT' AS entity_type, p.product_id::text AS entity_id, a.attribute_code
FROM product p
JOIN attribute_entity_type aet ON aet.tenant_id = p.tenant_id
                              AND aet.entity_type = 'PRODUCT' AND aet.is_required
JOIN attribute_definition a    ON a.attribute_id = aet.attribute_id
WHERE NOT EXISTS (SELECT 1 FROM attribute_value v
                  WHERE v.tenant_id = p.tenant_id AND v.entity_type = 'PRODUCT'
                    AND v.entity_id = p.product_id::text
                    AND v.attribute_id = aet.attribute_id)
UNION ALL
SELECT 'CUSTOMER', c.customer_no, a.attribute_code
FROM customer c
JOIN attribute_entity_type aet ON aet.tenant_id = c.tenant_id
                              AND aet.entity_type = 'CUSTOMER' AND aet.is_required
JOIN attribute_definition a    ON a.attribute_id = aet.attribute_id
WHERE NOT EXISTS (SELECT 1 FROM attribute_value v
                  WHERE v.tenant_id = c.tenant_id AND v.entity_type = 'CUSTOMER'
                    AND v.entity_id = c.customer_no
                    AND v.attribute_id = aet.attribute_id)
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- (h) Orphan check: values whose entity_id no longer exists in its
--     source table (catches rows written before cleanup triggers
--     existed, or bulk deletes that bypassed them)
-- ---------------------------------------------------------------------
SELECT v.tenant_id, v.entity_type, v.entity_id, COUNT(*) AS orphan_values
FROM attribute_value v
WHERE (v.entity_type = 'PRODUCT'
       AND NOT EXISTS (SELECT 1 FROM product p
                       WHERE p.tenant_id = v.tenant_id AND p.product_id::text = v.entity_id))
   OR (v.entity_type = 'CUSTOMER'
       AND NOT EXISTS (SELECT 1 FROM customer c
                       WHERE c.tenant_id = v.tenant_id AND c.customer_no = v.entity_id))
   OR (v.entity_type = 'SUPPLIER'
       AND NOT EXISTS (SELECT 1 FROM supplier s
                       WHERE s.tenant_id = v.tenant_id AND s.supplier_id::text = v.entity_id))
GROUP BY v.tenant_id, v.entity_type, v.entity_id;

-- ---------------------------------------------------------------------
-- (i) One JSON document per entity (for APIs or a cache column)
-- ---------------------------------------------------------------------
SELECT entity_type, entity_id, attributes
FROM v_entity_attributes_json
WHERE tenant_id = 1
ORDER BY entity_type, entity_id;

-- ---------------------------------------------------------------------
-- (j) Audit trail for one entity
-- ---------------------------------------------------------------------
--     Keeps only the typed value column that was filled.
SELECT h.changed_at::timestamp(0) AS changed_at, a.attribute_code, h.value_seq, h.change_type,
       jsonb_strip_nulls(h.old_value) - ARRAY['tenant_id','value_id','entity_type','entity_id',
                                              'attribute_id','value_seq','updated_by'] AS old_value,
       jsonb_strip_nulls(h.new_value) - ARRAY['tenant_id','value_id','entity_type','entity_id',
                                              'attribute_id','value_seq','updated_by'] AS new_value,
       h.changed_by
FROM attribute_value_history h
JOIN attribute_definition a ON a.attribute_id = h.attribute_id
WHERE h.tenant_id = 1 AND h.entity_type = 'PRODUCT' AND h.entity_id = '2'
ORDER BY h.history_id;
