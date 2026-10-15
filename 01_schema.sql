-- =====================================================================
-- Tenant-Aware Custom Attributes
-- Pattern : Typed EAV with a metadata catalog, polymorphic entity link
-- Dialect : PostgreSQL 14+ (tested on 16)
-- Script  : 01_schema.sql  - tables, constraints, indexes, triggers
-- =====================================================================
--
-- Core idea
--   * Attributes are defined per TENANT and classified by DOMAIN and
--     SUBDOMAIN (e.g. SALES > PRODUCT_SPECS, CRM > LOYALTY).
--   * Values attach to ANY business record through
--     (entity_type, entity_id): entity_type says which table the record
--     lives in, entity_id holds that record's primary key.
--   * Composite foreign keys that lead with tenant_id make it impossible
--     for one tenant's value to point at another tenant's attribute or
--     option.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TENANT
--    Each business / organization that owns its own attribute catalog.
-- ---------------------------------------------------------------------
CREATE TABLE tenant (
    tenant_id       INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_code     VARCHAR(50)  NOT NULL UNIQUE,
    tenant_name     VARCHAR(200) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. ENTITY TYPE  (global, system-level)
--    The kinds of records attributes can attach to. One row per
--    application table. Shared by all tenants because the physical
--    tables are shared.
-- ---------------------------------------------------------------------
CREATE TABLE entity_type (
    entity_type     VARCHAR(50)  PRIMARY KEY,          -- 'PRODUCT', 'CUSTOMER'
    display_name    VARCHAR(200) NOT NULL,
    source_table    VARCHAR(200) NOT NULL,             -- 'product'
    pk_column       VARCHAR(100) NOT NULL,             -- 'product_id'
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- 3. ATTRIBUTE DOMAIN  (tenant-specific)
--    Top-level business area that groups attributes: SALES, CRM, CLINICAL.
-- ---------------------------------------------------------------------
CREATE TABLE attribute_domain (
    tenant_id       INT          NOT NULL REFERENCES tenant(tenant_id),
    domain_id       INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    domain_code     VARCHAR(50)  NOT NULL,
    domain_name     VARCHAR(200) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    UNIQUE (tenant_id, domain_code),
    UNIQUE (tenant_id, domain_id)                      -- target for composite FKs
);

-- ---------------------------------------------------------------------
-- 4. ATTRIBUTE SUBDOMAIN  (tenant-specific, belongs to one domain)
--    Finer grouping inside a domain: SALES > PRODUCT_SPECS, SALES > APPAREL.
-- ---------------------------------------------------------------------
CREATE TABLE attribute_subdomain (
    tenant_id       INT          NOT NULL,
    subdomain_id    INT          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    domain_id       INT          NOT NULL,
    subdomain_code  VARCHAR(50)  NOT NULL,
    subdomain_name  VARCHAR(200) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    UNIQUE (tenant_id, domain_id, subdomain_code),
    UNIQUE (tenant_id, domain_id, subdomain_id),       -- target for composite FK
    FOREIGN KEY (tenant_id, domain_id)
        REFERENCES attribute_domain(tenant_id, domain_id)
);

-- ---------------------------------------------------------------------
-- 5. ATTRIBUTE DEFINITION  (the catalog, tenant-specific)
--    Each attribute is defined once per tenant + domain, with its data
--    type and validation rules.
-- ---------------------------------------------------------------------
CREATE TABLE attribute_definition (
    tenant_id       INT          NOT NULL,
    attribute_id    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    domain_id       INT          NOT NULL,
    subdomain_id    INT,                               -- optional finer grouping
    attribute_code  VARCHAR(100) NOT NULL,             -- 'ram_gb', 'color'
    display_name    VARCHAR(200) NOT NULL,
    data_type       VARCHAR(20)  NOT NULL
                    CHECK (data_type IN ('TEXT','INTEGER','DECIMAL','BOOLEAN',
                                         'DATE','DATETIME','OPTION','JSON')),
    is_multi_valued BOOLEAN      NOT NULL DEFAULT FALSE,
    unit_of_measure VARCHAR(30),
    min_value       NUMERIC,
    max_value       NUMERIC,
    max_length      INT,
    regex_pattern   VARCHAR(500),
    is_searchable   BOOLEAN      NOT NULL DEFAULT FALSE,
    is_filterable   BOOLEAN      NOT NULL DEFAULT FALSE,
    description     TEXT,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

    UNIQUE (tenant_id, domain_id, attribute_code),     -- same code may exist in two domains
    UNIQUE (tenant_id, attribute_id),                  -- target for composite FKs
    FOREIGN KEY (tenant_id, domain_id)
        REFERENCES attribute_domain(tenant_id, domain_id),
    -- subdomain must belong to the same tenant AND the same domain
    -- (MATCH SIMPLE: skipped when subdomain_id is NULL)
    FOREIGN KEY (tenant_id, domain_id, subdomain_id)
        REFERENCES attribute_subdomain(tenant_id, domain_id, subdomain_id),
    CHECK (min_value IS NULL OR max_value IS NULL OR min_value <= max_value)
);
CREATE INDEX ix_ad_domain ON attribute_definition (tenant_id, domain_id, subdomain_id);

-- ---------------------------------------------------------------------
-- 6. ATTRIBUTE OPTION  (allowed values for OPTION attributes)
-- ---------------------------------------------------------------------
CREATE TABLE attribute_option (
    tenant_id       INT          NOT NULL,
    option_id       BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attribute_id    BIGINT       NOT NULL,
    option_code     VARCHAR(100) NOT NULL,
    option_label    VARCHAR(200) NOT NULL,
    sort_order      INT          NOT NULL DEFAULT 0,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    UNIQUE (tenant_id, attribute_id, option_code),
    UNIQUE (tenant_id, attribute_id, option_id),       -- lets values prove the option
                                                       -- belongs to their attribute
    FOREIGN KEY (tenant_id, attribute_id)
        REFERENCES attribute_definition(tenant_id, attribute_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 7. ATTRIBUTE ENTITY TYPE  (applicability)
--    Which attributes may be used on which entity types, with
--    per-entity-type rules. A value row must match a row here.
-- ---------------------------------------------------------------------
CREATE TABLE attribute_entity_type (
    tenant_id       INT          NOT NULL,
    attribute_id    BIGINT       NOT NULL,
    entity_type     VARCHAR(50)  NOT NULL REFERENCES entity_type(entity_type),
    is_required     BOOLEAN      NOT NULL DEFAULT FALSE,
    default_value   TEXT,
    attribute_group VARCHAR(100),                      -- UI section: 'Specs', 'Shipping'
    sort_order      INT          NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, attribute_id, entity_type),
    FOREIGN KEY (tenant_id, attribute_id)
        REFERENCES attribute_definition(tenant_id, attribute_id) ON DELETE CASCADE
);
CREATE INDEX ix_aet_entity_type ON attribute_entity_type (tenant_id, entity_type);

-- ---------------------------------------------------------------------
-- 8. ATTRIBUTE VALUE  (the data, strongly typed)
--    entity_type + entity_id identify the owning record in any table.
--    entity_id is VARCHAR so it can hold BIGINT, UUID or natural keys
--    (SKU, MRN). If every source PK is BIGINT, switch it to BIGINT.
-- ---------------------------------------------------------------------
CREATE TABLE attribute_value (
    tenant_id       INT          NOT NULL,
    value_id        BIGINT       GENERATED ALWAYS AS IDENTITY,
    entity_type     VARCHAR(50)  NOT NULL,
    entity_id       VARCHAR(100) NOT NULL,
    attribute_id    BIGINT       NOT NULL,
    value_seq       SMALLINT     NOT NULL DEFAULT 1 CHECK (value_seq >= 1),
    value_text      TEXT,
    value_int       BIGINT,
    value_decimal   NUMERIC(18,6),
    value_bool      BOOLEAN,
    value_date      DATE,
    value_datetime  TIMESTAMPTZ,
    option_id       BIGINT,
    value_json      JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_by      VARCHAR(100),

    PRIMARY KEY (tenant_id, value_id),                 -- tenant-leading: partition-ready
    UNIQUE (tenant_id, entity_type, entity_id, attribute_id, value_seq),

    -- the attribute must be allowed for this entity type (and tenant)
    FOREIGN KEY (tenant_id, attribute_id, entity_type)
        REFERENCES attribute_entity_type(tenant_id, attribute_id, entity_type),
    -- the option must belong to this attribute (and tenant)
    FOREIGN KEY (tenant_id, attribute_id, option_id)
        REFERENCES attribute_option(tenant_id, attribute_id, option_id),

    -- exactly one value column is filled
    CONSTRAINT ck_av_one_value CHECK (
        (value_text     IS NOT NULL)::int + (value_int      IS NOT NULL)::int +
        (value_decimal  IS NOT NULL)::int + (value_bool     IS NOT NULL)::int +
        (value_date     IS NOT NULL)::int + (value_datetime IS NOT NULL)::int +
        (option_id      IS NOT NULL)::int + (value_json     IS NOT NULL)::int = 1)
);

-- "All attributes of entity X" is served by the UNIQUE index above.
-- Filtering / faceted search: one partial index per typed column.
CREATE INDEX ix_av_text     ON attribute_value (tenant_id, attribute_id, value_text)     WHERE value_text     IS NOT NULL;
CREATE INDEX ix_av_int      ON attribute_value (tenant_id, attribute_id, value_int)      WHERE value_int      IS NOT NULL;
CREATE INDEX ix_av_decimal  ON attribute_value (tenant_id, attribute_id, value_decimal)  WHERE value_decimal  IS NOT NULL;
CREATE INDEX ix_av_bool     ON attribute_value (tenant_id, attribute_id, value_bool)     WHERE value_bool     IS NOT NULL;
CREATE INDEX ix_av_date     ON attribute_value (tenant_id, attribute_id, value_date)     WHERE value_date     IS NOT NULL;
CREATE INDEX ix_av_datetime ON attribute_value (tenant_id, attribute_id, value_datetime) WHERE value_datetime IS NOT NULL;
CREATE INDEX ix_av_option   ON attribute_value (tenant_id, attribute_id, option_id)      WHERE option_id      IS NOT NULL;
CREATE INDEX ix_av_json     ON attribute_value USING GIN (value_json)                    WHERE value_json     IS NOT NULL;

-- ---------------------------------------------------------------------
-- 9. ATTRIBUTE VALUE HISTORY  (optional audit trail)
-- ---------------------------------------------------------------------
CREATE TABLE attribute_value_history (
    history_id      BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       INT          NOT NULL,
    entity_type     VARCHAR(50)  NOT NULL,
    entity_id       VARCHAR(100) NOT NULL,
    attribute_id    BIGINT       NOT NULL,
    value_seq       SMALLINT     NOT NULL,
    change_type     VARCHAR(10)  NOT NULL CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
    old_value       JSONB,
    new_value       JSONB,
    changed_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    changed_by      VARCHAR(100)
);
CREATE INDEX ix_avh_entity ON attribute_value_history (tenant_id, entity_type, entity_id, changed_at);


-- =====================================================================
-- TRIGGERS
-- =====================================================================

-- ---------------------------------------------------------------------
-- T1. Validate each value against its definition.
--     Enforces what constraints alone cannot: the filled column matches
--     data_type, single-valued attributes have value_seq = 1, and
--     min / max / max_length / regex rules hold.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_attribute_value_validate()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    d      attribute_definition%ROWTYPE;
    filled TEXT;
    num    NUMERIC;
BEGIN
    SELECT * INTO d
    FROM attribute_definition
    WHERE tenant_id = NEW.tenant_id AND attribute_id = NEW.attribute_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Attribute % does not exist for tenant %', NEW.attribute_id, NEW.tenant_id;
    END IF;
    IF NOT d.is_active THEN
        RAISE EXCEPTION 'Attribute "%" is inactive', d.attribute_code;
    END IF;

    filled := CASE
        WHEN NEW.value_text     IS NOT NULL THEN 'TEXT'
        WHEN NEW.value_int      IS NOT NULL THEN 'INTEGER'
        WHEN NEW.value_decimal  IS NOT NULL THEN 'DECIMAL'
        WHEN NEW.value_bool     IS NOT NULL THEN 'BOOLEAN'
        WHEN NEW.value_date     IS NOT NULL THEN 'DATE'
        WHEN NEW.value_datetime IS NOT NULL THEN 'DATETIME'
        WHEN NEW.option_id      IS NOT NULL THEN 'OPTION'
        WHEN NEW.value_json     IS NOT NULL THEN 'JSON'
    END;
    IF filled IS DISTINCT FROM d.data_type THEN
        RAISE EXCEPTION 'Attribute "%" is %, but a % value was supplied',
                        d.attribute_code, d.data_type, filled;
    END IF;

    IF NOT d.is_multi_valued AND NEW.value_seq <> 1 THEN
        RAISE EXCEPTION 'Attribute "%" is single-valued; value_seq must be 1', d.attribute_code;
    END IF;

    num := COALESCE(NEW.value_int::numeric, NEW.value_decimal);
    IF num IS NOT NULL THEN
        IF d.min_value IS NOT NULL AND num < d.min_value THEN
            RAISE EXCEPTION 'Attribute "%": % is below minimum %', d.attribute_code, num, d.min_value;
        END IF;
        IF d.max_value IS NOT NULL AND num > d.max_value THEN
            RAISE EXCEPTION 'Attribute "%": % is above maximum %', d.attribute_code, num, d.max_value;
        END IF;
    END IF;

    IF NEW.value_text IS NOT NULL THEN
        IF d.max_length IS NOT NULL AND length(NEW.value_text) > d.max_length THEN
            RAISE EXCEPTION 'Attribute "%": text longer than % characters', d.attribute_code, d.max_length;
        END IF;
        IF d.regex_pattern IS NOT NULL AND NEW.value_text !~ d.regex_pattern THEN
            RAISE EXCEPTION 'Attribute "%": "%" does not match pattern %',
                            d.attribute_code, NEW.value_text, d.regex_pattern;
        END IF;
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER trg_attribute_value_validate
BEFORE INSERT OR UPDATE ON attribute_value
FOR EACH ROW EXECUTE FUNCTION fn_attribute_value_validate();

-- ---------------------------------------------------------------------
-- T2. Write every change to the history table.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_attribute_value_audit()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r attribute_value;
BEGIN
    r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    INSERT INTO attribute_value_history
        (tenant_id, entity_type, entity_id, attribute_id, value_seq,
         change_type, old_value, new_value, changed_by)
    VALUES
        (r.tenant_id, r.entity_type, r.entity_id, r.attribute_id, r.value_seq, TG_OP,
         CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) - 'created_at' - 'updated_at' END,
         CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) - 'created_at' - 'updated_at' END,
         COALESCE(r.updated_by, current_user));
    RETURN NULL;
END $$;

CREATE TRIGGER trg_attribute_value_audit
AFTER INSERT OR UPDATE OR DELETE ON attribute_value
FOR EACH ROW EXECUTE FUNCTION fn_attribute_value_audit();

-- ---------------------------------------------------------------------
-- T3. Generic orphan cleanup for SOURCE tables.
--     entity_id cannot have a real FK (it points at many tables), so
--     attach this trigger to each source table. It deletes the record's
--     attribute values when the record is deleted.
--       TG_ARGV[0] = entity_type, TG_ARGV[1] = PK column name
--     The source table must have a tenant_id column.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_entity_attribute_cleanup()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM attribute_value
    WHERE tenant_id   = (to_jsonb(OLD) ->> 'tenant_id')::int
      AND entity_type = TG_ARGV[0]
      AND entity_id   = to_jsonb(OLD) ->> TG_ARGV[1];
    RETURN OLD;
END $$;

-- Usage (see 02_sample_data.sql):
-- CREATE TRIGGER trg_product_attr_cleanup AFTER DELETE ON product
-- FOR EACH ROW EXECUTE FUNCTION fn_entity_attribute_cleanup('PRODUCT', 'product_id');


-- =====================================================================
-- WRITE API
-- =====================================================================

-- ---------------------------------------------------------------------
-- set_attribute: set all values of one attribute on one entity.
--   Values come in as text; the function puts each into the right typed
--   column based on the attribute's data_type (OPTION values are given
--   as option_code). Pass an empty array to clear the attribute.
--   Upserts by value_seq, so unchanged values are not rewritten and a
--   change is recorded in history as an UPDATE, not DELETE + INSERT.
--   Validation is still done by trg_attribute_value_validate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_attribute(
    p_tenant_id      INT,
    p_entity_type    VARCHAR,
    p_entity_id      VARCHAR,
    p_domain_code    VARCHAR,
    p_attribute_code VARCHAR,
    p_values         TEXT[],
    p_user           VARCHAR DEFAULT current_user
) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    d     attribute_definition%ROWTYPE;
    v     TEXT;
    seq   SMALLINT := 0;
    opt   BIGINT;
BEGIN
    SELECT a.* INTO d
    FROM attribute_definition a
    JOIN attribute_domain dm ON dm.domain_id = a.domain_id
    WHERE a.tenant_id = p_tenant_id
      AND dm.domain_code = p_domain_code
      AND a.attribute_code = p_attribute_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown attribute %.% for tenant %', p_domain_code, p_attribute_code, p_tenant_id;
    END IF;

    FOREACH v IN ARRAY COALESCE(p_values, '{}') LOOP
        seq := seq + 1;
        IF d.data_type = 'OPTION' THEN
            SELECT option_id INTO opt FROM attribute_option
            WHERE tenant_id = p_tenant_id AND attribute_id = d.attribute_id
              AND option_code = v AND is_active;
            IF opt IS NULL THEN
                RAISE EXCEPTION 'Attribute "%": "%" is not an allowed option', d.attribute_code, v;
            END IF;
        END IF;

        INSERT INTO attribute_value
            (tenant_id, entity_type, entity_id, attribute_id, value_seq,
             value_text, value_int, value_decimal, value_bool,
             value_date, value_datetime, option_id, value_json, updated_by)
        VALUES
            (p_tenant_id, p_entity_type, p_entity_id, d.attribute_id, seq,
             CASE WHEN d.data_type = 'TEXT'     THEN v END,
             CASE WHEN d.data_type = 'INTEGER'  THEN v::bigint END,
             CASE WHEN d.data_type = 'DECIMAL'  THEN v::numeric END,
             CASE WHEN d.data_type = 'BOOLEAN'  THEN v::boolean END,
             CASE WHEN d.data_type = 'DATE'     THEN v::date END,
             CASE WHEN d.data_type = 'DATETIME' THEN v::timestamptz END,
             CASE WHEN d.data_type = 'OPTION'   THEN opt END,
             CASE WHEN d.data_type = 'JSON'     THEN v::jsonb END,
             p_user)
        ON CONFLICT (tenant_id, entity_type, entity_id, attribute_id, value_seq)
        DO UPDATE SET
            value_text     = EXCLUDED.value_text,
            value_int      = EXCLUDED.value_int,
            value_decimal  = EXCLUDED.value_decimal,
            value_bool     = EXCLUDED.value_bool,
            value_date     = EXCLUDED.value_date,
            value_datetime = EXCLUDED.value_datetime,
            option_id      = EXCLUDED.option_id,
            value_json     = EXCLUDED.value_json,
            updated_by     = EXCLUDED.updated_by
        -- skip the write (and the history row) when nothing changed
        WHERE (attribute_value.value_text, attribute_value.value_int,
               attribute_value.value_decimal, attribute_value.value_bool,
               attribute_value.value_date, attribute_value.value_datetime,
               attribute_value.option_id, attribute_value.value_json)
              IS DISTINCT FROM
              (EXCLUDED.value_text, EXCLUDED.value_int, EXCLUDED.value_decimal,
               EXCLUDED.value_bool, EXCLUDED.value_date, EXCLUDED.value_datetime,
               EXCLUDED.option_id, EXCLUDED.value_json);
    END LOOP;

    -- remove values beyond the new list (e.g. 3 colors reduced to 1)
    DELETE FROM attribute_value
    WHERE tenant_id = p_tenant_id AND entity_type = p_entity_type
      AND entity_id = p_entity_id AND attribute_id = d.attribute_id
      AND value_seq > seq;

    RETURN seq;                                        -- number of values now set
END $$;


-- =====================================================================
-- VIEWS
-- =====================================================================

-- Human-readable, one row per value (good for APIs, exports, debugging)
CREATE OR REPLACE VIEW v_attribute_value AS
SELECT v.tenant_id,
       t.tenant_code,
       v.entity_type,
       v.entity_id,
       dm.domain_code,
       sd.subdomain_code,
       a.attribute_code,
       a.display_name,
       a.data_type,
       v.value_seq,
       COALESCE(v.value_text, v.value_int::text, trim_scale(v.value_decimal)::text,
                v.value_bool::text, v.value_date::text, v.value_datetime::text,
                o.option_label, v.value_json::text) AS value_display,
       o.option_code,
       a.unit_of_measure,
       v.updated_at
FROM attribute_value v
JOIN tenant t                   ON t.tenant_id = v.tenant_id
JOIN attribute_definition a     ON a.tenant_id = v.tenant_id AND a.attribute_id = v.attribute_id
JOIN attribute_domain dm        ON dm.domain_id = a.domain_id
LEFT JOIN attribute_subdomain sd ON sd.subdomain_id = a.subdomain_id
LEFT JOIN attribute_option o    ON o.option_id = v.option_id;

-- One JSON document per entity (replaces a per-table JSONB cache).
-- Keys are attribute_code. If one entity can carry the same code from two
-- domains, key on domain_code || '.' || attribute_code instead.
CREATE OR REPLACE VIEW v_entity_attributes_json AS
WITH per_attr AS (
    SELECT v.tenant_id, v.entity_type, v.entity_id, a.attribute_code,
           CASE WHEN a.is_multi_valued
                THEN jsonb_agg(COALESCE(to_jsonb(v.value_text), to_jsonb(v.value_int),
                                        to_jsonb(trim_scale(v.value_decimal)), to_jsonb(v.value_bool),
                                        to_jsonb(v.value_date), to_jsonb(v.value_datetime),
                                        to_jsonb(o.option_code), v.value_json)
                               ORDER BY v.value_seq)
                ELSE (array_agg(COALESCE(to_jsonb(v.value_text), to_jsonb(v.value_int),
                                         to_jsonb(trim_scale(v.value_decimal)), to_jsonb(v.value_bool),
                                         to_jsonb(v.value_date), to_jsonb(v.value_datetime),
                                         to_jsonb(o.option_code), v.value_json)))[1]
           END AS val
    FROM attribute_value v
    JOIN attribute_definition a  ON a.tenant_id = v.tenant_id AND a.attribute_id = v.attribute_id
    LEFT JOIN attribute_option o ON o.option_id = v.option_id
    GROUP BY v.tenant_id, v.entity_type, v.entity_id, a.attribute_code, a.is_multi_valued
)
SELECT tenant_id, entity_type, entity_id,
       jsonb_object_agg(attribute_code, val) AS attributes
FROM per_attr
GROUP BY tenant_id, entity_type, entity_id;


-- =====================================================================
-- DIALECT NOTES
--  SQL Server : IDENTITY instead of GENERATED ALWAYS AS IDENTITY;
--               JSONB -> NVARCHAR(MAX) + ISJSON check; TIMESTAMPTZ ->
--               DATETIMEOFFSET; triggers become AFTER/INSTEAD OF triggers
--               on the inserted set; RLS via SECURITY POLICY + predicate
--               function on SESSION_CONTEXT(N'tenant_id').
--  Snowflake  : FKs, CHECKs and UNIQUE are not enforced -> run the
--               validation as data-quality queries in the load pipeline;
--               use ROW ACCESS POLICY for tenant isolation; cluster
--               attribute_value BY (tenant_id, entity_type, attribute_id);
--               for analytics, pivot to wide tables or a VARIANT column.
-- =====================================================================
