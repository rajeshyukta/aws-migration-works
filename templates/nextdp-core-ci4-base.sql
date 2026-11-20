-- Base schema for brand-new NextDP Core PostgreSQL databases.
-- Represents the pre-F45 CI4 / Shield / F22-UUID tables that NextDP Core's Go
-- migrations assume already exist when `./nextdp migrate` runs against a fresh DB.
-- Applied ONLY when `public.email_layouts` does not yet exist; never drops or
-- alters existing production tables.

CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    username VARCHAR(64),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    last_active TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_users_brand_id ON users (brand_id);

CREATE TABLE IF NOT EXISTS auth_identities (
    id BIGSERIAL PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    type VARCHAR(64) NOT NULL,
    secret VARCHAR(255) NOT NULL,
    secret2 VARCHAR(255),
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    CONSTRAINT auth_identities_type_secret UNIQUE (type, secret)
);
CREATE INDEX IF NOT EXISTS idx_auth_identities_user_id ON auth_identities (user_id);

CREATE TABLE IF NOT EXISTS auth_groups_users (
    id BIGSERIAL PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    "group" VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_auth_groups_users_user_id ON auth_groups_users (user_id);

CREATE TABLE IF NOT EXISTS user_profiles (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    display_name VARCHAR(255),
    phone VARCHAR(64),
    timezone VARCHAR(64),
    company VARCHAR(255),
    job_title VARCHAR(255),
    bio TEXT,
    website VARCHAR(255),
    linkedin VARCHAR(255),
    twitter VARCHAR(255),
    facebook VARCHAR(255),
    instagram VARCHAR(255),
    youtube VARCHAR(255),
    sessions_revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_profiles_user_id ON user_profiles (user_id);

CREATE TABLE IF NOT EXISTS activity_logs (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    user_id VARCHAR(36),
    user_email VARCHAR(255),
    area VARCHAR(64) NOT NULL DEFAULT '',
    action VARCHAR(120),
    method VARCHAR(16) NOT NULL DEFAULT '',
    path VARCHAR(255) NOT NULL DEFAULT '',
    status_code INTEGER,
    ip_address VARCHAR(64),
    user_agent TEXT,
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_activity_logs_user_id ON activity_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_activity_logs_brand_id ON activity_logs (brand_id);

CREATE TABLE IF NOT EXISTS login_otps (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    code_hash VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    resend_count INTEGER NOT NULL DEFAULT 0,
    last_sent_at TIMESTAMPTZ NOT NULL,
    locked_until TIMESTAMPTZ,
    requested_ip VARCHAR(64),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_login_otps_user_id ON login_otps (user_id);

CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    token_hash VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    requested_ip VARCHAR(64),
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_user_id ON password_reset_tokens (user_id);

CREATE TABLE IF NOT EXISTS twofa_settings (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    enabled SMALLINT NOT NULL DEFAULT 1,
    updated_by VARCHAR(36),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_twofa_settings_user_id ON twofa_settings (user_id);

CREATE TABLE IF NOT EXISTS twofa_bypasses (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    source VARCHAR(64) NOT NULL DEFAULT '',
    granted_by VARCHAR(36),
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_twofa_bypasses_user_id ON twofa_bypasses (user_id);

CREATE TABLE IF NOT EXISTS totp_secrets (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    secret VARCHAR(64) NOT NULL,
    confirmed_at TIMESTAMPTZ,
    is_default SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_totp_secrets_user_id ON totp_secrets (user_id);

CREATE TABLE IF NOT EXISTS impersonation_tokens (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    admin_id VARCHAR(36) NOT NULL,
    token_hash VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS impersonation_tokens_hash_uq ON impersonation_tokens (token_hash);

CREATE TABLE IF NOT EXISTS applications (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    name VARCHAR(255) NOT NULL DEFAULT '',
    email VARCHAR(255) NOT NULL DEFAULT '',
    phone VARCHAR(64) NOT NULL DEFAULT '',
    victim_name VARCHAR(255) NOT NULL DEFAULT '',
    desired_domain VARCHAR(255) NOT NULL DEFAULT '',
    relationship VARCHAR(120) NOT NULL DEFAULT '',
    referral_source VARCHAR(120) NOT NULL DEFAULT '',
    referral_detail TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL DEFAULT '',
    status VARCHAR(32) NOT NULL DEFAULT 'new',
    terms_accepted_at TIMESTAMPTZ,
    reviewed_by VARCHAR(36),
    reviewed_at TIMESTAMPTZ,
    created_user_id VARCHAR(36),
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_applications_brand_id ON applications (brand_id);

CREATE TABLE IF NOT EXISTS email_layouts (
    id VARCHAR(36) PRIMARY KEY,
    key VARCHAR(64) NOT NULL,
    name VARCHAR(120) NOT NULL,
    category VARCHAR(32) NOT NULL DEFAULT 'transactional',
    description VARCHAR(255),
    html TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    CONSTRAINT email_layouts_key UNIQUE (key)
);

CREATE TABLE IF NOT EXISTS email_templates (
    id VARCHAR(36) PRIMARY KEY,
    key VARCHAR(96) NOT NULL,
    name VARCHAR(120) NOT NULL,
    layout_id VARCHAR(36) REFERENCES email_layouts(id) ON DELETE SET NULL,
    subject VARCHAR(255) NOT NULL,
    preheader VARCHAR(255) NOT NULL DEFAULT '',
    body_html TEXT NOT NULL,
    body_text TEXT NOT NULL DEFAULT '',
    from_name VARCHAR(120) NOT NULL DEFAULT '',
    from_email VARCHAR(255) NOT NULL DEFAULT '',
    category VARCHAR(32) NOT NULL DEFAULT 'transactional',
    variables TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    CONSTRAINT email_templates_key UNIQUE (key)
);

CREATE TABLE IF NOT EXISTS email_logs (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    to_email VARCHAR(255) NOT NULL,
    to_name VARCHAR(160),
    subject VARCHAR(255) NOT NULL DEFAULT '',
    template_key VARCHAR(120),
    context VARCHAR(60),
    status VARCHAR(12) NOT NULL DEFAULT 'sent',
    status_code INTEGER,
    provider_message_id VARCHAR(160),
    error TEXT,
    html_body TEXT,
    text_body TEXT,
    from_email VARCHAR(255),
    from_name VARCHAR(120),
    sent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_email_logs_status ON email_logs (status);
CREATE INDEX IF NOT EXISTS idx_email_logs_template_key ON email_logs (template_key);
CREATE INDEX IF NOT EXISTS idx_email_logs_created_at ON email_logs (created_at);
CREATE INDEX IF NOT EXISTS idx_email_logs_brand_id ON email_logs (brand_id);

CREATE TABLE IF NOT EXISTS blog_sites (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    user_id VARCHAR(36) NOT NULL,
    blog_id VARCHAR(64),
    sid VARCHAR(120),
    title VARCHAR(255) NOT NULL DEFAULT '',
    tagline VARCHAR(255),
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    host VARCHAR(255),
    domain_source VARCHAR(32),
    domain_ref VARCHAR(64),
    dns_status VARCHAR(32),
    dns_checked_at TIMESTAMPTZ,
    provision_error TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_blog_sites_user_id ON blog_sites (user_id);
CREATE INDEX IF NOT EXISTS idx_blog_sites_brand_id ON blog_sites (brand_id);

CREATE TABLE IF NOT EXISTS service_providers (
    id VARCHAR(36) PRIMARY KEY,
    key VARCHAR(64) NOT NULL,
    name VARCHAR(120) NOT NULL,
    kind VARCHAR(64) NOT NULL,
    active SMALLINT NOT NULL DEFAULT 1,
    config TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    CONSTRAINT service_providers_key UNIQUE (key)
);

CREATE TABLE IF NOT EXISTS dns_zones (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    fqdn VARCHAR(255) NOT NULL,
    source VARCHAR(32) NOT NULL,
    domain_id VARCHAR(36),
    external_domain_id VARCHAR(36),
    status VARCHAR(32) NOT NULL DEFAULT 'awaiting_ns',
    zone_created_at TIMESTAMPTZ,
    delegated_at TIMESTAMPTZ,
    armed_at TIMESTAMPTZ,
    last_checked_at TIMESTAMPTZ,
    next_check_at TIMESTAMPTZ,
    check_count INTEGER NOT NULL DEFAULT 0,
    pass_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS dns_zones_fqdn_uq ON dns_zones (fqdn);
CREATE INDEX IF NOT EXISTS idx_dns_zones_user_id ON dns_zones (user_id);

CREATE TABLE IF NOT EXISTS handcraft_sites (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    user_id VARCHAR(36) NOT NULL,
    title VARCHAR(255) NOT NULL DEFAULT '',
    host VARCHAR(255),
    domain_source VARCHAR(32),
    domain_ref VARCHAR(64),
    dns_status VARCHAR(32) NOT NULL DEFAULT 'none',
    dns_checked_at TIMESTAMPTZ,
    status VARCHAR(32) NOT NULL DEFAULT 'crafting',
    completed_at TIMESTAMPTZ,
    notes TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_handcraft_sites_user_id ON handcraft_sites (user_id);
CREATE INDEX IF NOT EXISTS idx_handcraft_sites_brand_id ON handcraft_sites (brand_id);

CREATE TABLE IF NOT EXISTS carts (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'open',
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_carts_user_id ON carts (user_id);

CREATE TABLE IF NOT EXISTS cart_items (
    id VARCHAR(36) PRIMARY KEY,
    cart_id VARCHAR(36) NOT NULL,
    service_type VARCHAR(64) NOT NULL,
    label VARCHAR(255) NOT NULL DEFAULT '',
    term_years INTEGER,
    unit_price DOUBLE PRECISION,
    currency VARCHAR(16) NOT NULL DEFAULT 'USD',
    payload TEXT,
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_cart_items_cart_id ON cart_items (cart_id);

CREATE TABLE IF NOT EXISTS orders (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    order_no VARCHAR(32),
    user_id VARCHAR(36) NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    currency VARCHAR(16) NOT NULL DEFAULT 'USD',
    total DOUBLE PRECISION,
    notes TEXT,
    cancel_reason TEXT,
    price_confirmed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_brand_id ON orders (brand_id);

CREATE TABLE IF NOT EXISTS order_items (
    id VARCHAR(36) PRIMARY KEY,
    order_id VARCHAR(36) NOT NULL,
    service_type VARCHAR(64) NOT NULL,
    label VARCHAR(255) NOT NULL DEFAULT '',
    term_years INTEGER,
    unit_price DOUBLE PRECISION,
    currency VARCHAR(16) NOT NULL DEFAULT 'USD',
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    reference_type VARCHAR(64),
    reference_id VARCHAR(36),
    meta TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items (order_id);

CREATE TABLE IF NOT EXISTS domain_providers (
    id VARCHAR(36) PRIMARY KEY,
    key VARCHAR(64) NOT NULL,
    name VARCHAR(120) NOT NULL,
    kind VARCHAR(64) NOT NULL,
    is_default SMALLINT NOT NULL DEFAULT 0,
    active SMALLINT NOT NULL DEFAULT 1,
    config JSON,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    CONSTRAINT domain_providers_key UNIQUE (key)
);

CREATE TABLE IF NOT EXISTS domains (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    user_id VARCHAR(36) NOT NULL,
    provider_id VARCHAR(36),
    fqdn VARCHAR(255) NOT NULL,
    unicode_name VARCHAR(255),
    tld VARCHAR(64) NOT NULL,
    class_key VARCHAR(64),
    status VARCHAR(32) NOT NULL DEFAULT 'pending_register',
    registered_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    auto_renew SMALLINT NOT NULL DEFAULT 1,
    transfer_lock SMALLINT NOT NULL DEFAULT 1,
    epp_statuses TEXT,
    auth_code VARCHAR(255),
    notes TEXT,
    vendor_order_id VARCHAR(120),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domains_user_id ON domains (user_id);
CREATE INDEX IF NOT EXISTS idx_domains_fqdn ON domains (fqdn);
CREATE INDEX IF NOT EXISTS idx_domains_brand_id ON domains (brand_id);

CREATE TABLE IF NOT EXISTS domain_contacts (
    id VARCHAR(36) PRIMARY KEY,
    domain_id VARCHAR(36) NOT NULL,
    type VARCHAR(32) NOT NULL,
    name VARCHAR(255),
    org VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(64),
    address1 VARCHAR(255),
    address2 VARCHAR(255),
    city VARCHAR(120),
    state VARCHAR(120),
    postal_code VARCHAR(32),
    country VARCHAR(8),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domain_contacts_domain_id ON domain_contacts (domain_id);

CREATE TABLE IF NOT EXISTS domain_nameservers (
    id VARCHAR(36) PRIMARY KEY,
    domain_id VARCHAR(36) NOT NULL,
    host VARCHAR(255) NOT NULL,
    sort_order SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domain_nameservers_domain_id ON domain_nameservers (domain_id);

CREATE TABLE IF NOT EXISTS domain_glue (
    id VARCHAR(36) PRIMARY KEY,
    domain_id VARCHAR(36) NOT NULL,
    host VARCHAR(255) NOT NULL,
    ipv4 VARCHAR(64),
    ipv6 VARCHAR(128),
    created_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domain_glue_domain_id ON domain_glue (domain_id);

CREATE TABLE IF NOT EXISTS domain_change_requests (
    id VARCHAR(36) PRIMARY KEY,
    brand_id VARCHAR(36) NOT NULL DEFAULT '01900000-0000-7000-8000-000000000001',
    domain_id VARCHAR(36) NOT NULL,
    type VARCHAR(32) NOT NULL,
    payload TEXT,
    status VARCHAR(16) NOT NULL DEFAULT 'pending',
    requested_by VARCHAR(36),
    handled_by VARCHAR(36),
    admin_note TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domain_change_requests_domain_id ON domain_change_requests (domain_id);
CREATE INDEX IF NOT EXISTS idx_domain_change_requests_brand_id ON domain_change_requests (brand_id);

CREATE TABLE IF NOT EXISTS domain_contact_book (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    label VARCHAR(120) NOT NULL,
    name VARCHAR(255),
    org VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(64),
    address1 VARCHAR(255),
    address2 VARCHAR(255),
    city VARCHAR(120),
    state VARCHAR(120),
    postal_code VARCHAR(32),
    country VARCHAR(8),
    is_default SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domain_contact_book_user_id ON domain_contact_book (user_id);

CREATE TABLE IF NOT EXISTS domain_contact_book_roles (
    id VARCHAR(36) PRIMARY KEY,
    contact_book_id VARCHAR(36) NOT NULL,
    type VARCHAR(32) NOT NULL,
    name VARCHAR(255),
    org VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(64),
    address1 VARCHAR(255),
    address2 VARCHAR(255),
    city VARCHAR(120),
    state VARCHAR(120),
    postal_code VARCHAR(32),
    country VARCHAR(8),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_domain_contact_book_roles_book_id ON domain_contact_book_roles (contact_book_id);

CREATE TABLE IF NOT EXISTS domain_user_settings (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    ns_mode VARCHAR(32) NOT NULL DEFAULT 'default',
    nameservers TEXT,
    default_years SMALLINT NOT NULL DEFAULT 1,
    auto_renew SMALLINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_domain_user_settings_user_id ON domain_user_settings (user_id);

CREATE TABLE IF NOT EXISTS domain_notifications_log (
    id VARCHAR(36) PRIMARY KEY,
    dedupe_key VARCHAR(255) NOT NULL,
    domain_id VARCHAR(36),
    user_id VARCHAR(36),
    kind VARCHAR(64) NOT NULL,
    email VARCHAR(255),
    success BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_domain_notifications_log_dedupe_key ON domain_notifications_log (dedupe_key);

CREATE TABLE IF NOT EXISTS domain_contact_vendor_map (
    id VARCHAR(36) PRIMARY KEY,
    provider_id VARCHAR(36) NOT NULL,
    contact_book_id VARCHAR(36) NOT NULL,
    role_key VARCHAR(64) NOT NULL,
    contact_type VARCHAR(32) NOT NULL,
    vendor_contact_id VARCHAR(120) NOT NULL,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS external_domains (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    fqdn VARCHAR(255) NOT NULL,
    unicode_name VARCHAR(255),
    tld VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    verify_token VARCHAR(128),
    verified_at TIMESTAMPTZ,
    last_checked_at TIMESTAMPTZ,
    notes TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_external_domains_user_id ON external_domains (user_id);

CREATE TABLE IF NOT EXISTS go_jobs (
    id BIGSERIAL PRIMARY KEY,
    queue VARCHAR(255) NOT NULL,
    type VARCHAR(255) NOT NULL,
    payload TEXT NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 3,
    available_at TIMESTAMP NOT NULL,
    reserved_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS go_jobs_queue_idx ON go_jobs (queue);
CREATE INDEX IF NOT EXISTS go_jobs_available_idx ON go_jobs (available_at);
CREATE INDEX IF NOT EXISTS go_jobs_reserved_idx ON go_jobs (reserved_at);

CREATE TABLE IF NOT EXISTS go_failed_jobs (
    id BIGSERIAL PRIMARY KEY,
    queue VARCHAR(255) NOT NULL,
    type VARCHAR(255) NOT NULL,
    payload TEXT NOT NULL,
    error TEXT NOT NULL,
    failed_at TIMESTAMP NOT NULL
);
