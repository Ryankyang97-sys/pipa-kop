-- ── KS PRODUCTS (D365 Released Products, filtered to kitchen-relevant) ──
create table if not exists ks_products (
  id bigint generated always as identity primary key,
  d365_id text,
  adaco_id text,
  name text not null,
  macrofamily text
);

create index if not exists ks_products_d365_idx on ks_products (d365_id);
create index if not exists ks_products_adaco_idx on ks_products (adaco_id);
create index if not exists ks_products_name_idx on ks_products using gin (to_tsvector('english', name));

alter table ks_products enable row level security;
create policy "Public read" on ks_products for select using (true);

-- ── KS ADACO INGREDIENTS (Adaco purchasing DB, food items only) ────────
create table if not exists ks_adaco_ingredients (
  id bigint generated always as identity primary key,
  product_number text,
  description text not null,
  category text
);

create index if not exists ks_adaco_pn_idx on ks_adaco_ingredients (product_number);
create index if not exists ks_adaco_desc_idx on ks_adaco_ingredients using gin (to_tsvector('english', description));

alter table ks_adaco_ingredients enable row level security;
create policy "Public read" on ks_adaco_ingredients for select using (true);

-- ── KS ACTIVATIONS ──────────────────────────────────────────────────────
create table if not exists ks_activations (
  id bigint generated always as identity primary key,
  name text not null,
  launch_date date,
  department text,
  items jsonb default '[]'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table ks_activations enable row level security;
create policy "Public read" on ks_activations for select using (true);
create policy "Public insert" on ks_activations for insert with check (true);
create policy "Public update" on ks_activations for update using (true);
create policy "Public delete" on ks_activations for delete using (true);
