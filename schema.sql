-- 원료 구매관리 (hg) — Supabase 스키마
-- 같은 프로젝트의 다른 앱과 섞이지 않도록 모든 객체에 hg_ 접두어를 붙입니다.
-- 모든 테이블은 RLS 를 켜고 정책을 두지 않습니다(직접 접근 불가).
-- 화면은 PIN 로그인으로 받은 토큰을 넘겨 아래 hg_* 함수로만 읽고 씁니다.

-- ───────────── 테이블 ─────────────
create table if not exists hg_settings (
  key   text primary key,          -- pin_hash, fail_count, locked_until
  value text
);

create table if not exists hg_sessions (
  token      uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create table if not exists hg_suppliers (            -- 거래처
  id               bigserial primary key,
  code             text not null unique,             -- 거래처코드
  name             text not null,
  pay_month_offset smallint,                         -- 결제조건: 마감월 +1, +2
  pay_day          smallint,                         -- 5, 15
  bank_name        text,
  account_no       text,
  contact          text,                             -- 담당자·연락처
  report_section   smallint,                         -- 업체별 보고서 구분: 1 원료·첨가제, 2 포장지, 3 운송비
  report_order     int,                              -- 업체별 보고서 행 순서
  rep_item         text,                             -- 업체별 보고서 '대표 품명'
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);

create table if not exists hg_materials (            -- 품목 (SAP 코드 단위)
  id         bigserial primary key,
  sap_code   text not null default '',
  name       text not null,                          -- 품목명
  group_name text,                                   -- 분류
  shelf_life text,                                   -- 유통기한
  unique (sap_code, name)
);

create table if not exists hg_supplier_items (       -- 원료명 = 품목 × 거래처
  id          bigserial primary key,
  material_id bigint not null references hg_materials(id),
  supplier_id bigint not null references hg_suppliers(id),
  raw_name    text not null,                         -- 원료명
  category    text not null check (category in ('주원료','부원료','첨가제','첨가제(액상)','포장재','운반비')),
  tax_code    text not null default 'V1' check (tax_code in ('V1','V6')),
  is_active   boolean not null default true,
  unique (material_id, supplier_id, raw_name)
);

create table if not exists hg_import_batches (       -- 일괄 입력 기록
  id           bigserial primary key,
  target       text not null check (target in ('receipts','master')),
  file_name    text,
  total_rows   int not null default 0,
  ok_rows      int not null default 0,
  skipped_rows int not null default 0,
  created_at   timestamptz not null default now(),
  reverted_at  timestamptz
);

create table if not exists hg_price_history (        -- 단가 이력 (바뀐 시점만)
  id               bigserial primary key,
  supplier_item_id bigint not null references hg_supplier_items(id) on delete cascade,
  unit_price       numeric(12,2) not null,
  valid_from       date not null,
  import_batch_id  bigint references hg_import_batches(id),
  created_at       timestamptz not null default now(),
  unique (supplier_item_id, valid_from)
);

create table if not exists hg_import_lots (          -- 주원료 모선
  id            bigserial primary key,
  material_id   bigint not null references hg_materials(id),
  vessel_name   text not null,                       -- 원료명: 옥수수(PEGASUS)
  inbound_po_no text not null default '',
  tax_code      text not null default 'V1' check (tax_code in ('V1','V6')),
  is_closed     boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (vessel_name, inbound_po_no)
);

create table if not exists hg_receipts (             -- 입고 내역 (계근 1건 = 1행)
  id                bigserial primary key,
  receipt_date      date not null,
  supplier_item_id  bigint references hg_supplier_items(id),
  import_lot_id     bigint references hg_import_lots(id),
  category          text not null,
  tax_code          text not null,
  gross_kg          numeric(12,1),                   -- 계근표
  packaging         text,                            -- 'T/B' 또는 null
  tb_count          int,
  tare_kg           numeric(8,1),                    -- T/B 무게
  net_kg            numeric(12,1),                   -- 수량 = 실중량 (주원료는 계근 전이면 비워 둘 수 있음)
  unit_price        numeric(12,2),                   -- 입고 시점 단가
  supply_amount     numeric(14,0),
  vat_amount        numeric(14,0),
  purchase_order_no text,
  inbound_po_no     text,
  import_batch_id   bigint references hg_import_batches(id),
  created_at        timestamptz not null default now(),
  voided_at         timestamptz,                     -- 삭제 대신 취소 표시
  check (supplier_item_id is not null or import_lot_id is not null)
);
alter table hg_receipts alter column net_kg drop not null;   -- 기존 DB 반영용
create index if not exists hg_receipts_date_idx  on hg_receipts (receipt_date);
create index if not exists hg_receipts_item_idx  on hg_receipts (supplier_item_id, receipt_date);
create index if not exists hg_receipts_lot_idx   on hg_receipts (import_lot_id);
create index if not exists hg_receipts_batch_idx on hg_receipts (import_batch_id);
create index if not exists hg_items_supplier_idx on hg_supplier_items (supplier_id);
create index if not exists hg_price_batch_idx    on hg_price_history (import_batch_id);
create index if not exists hg_lots_material_idx  on hg_import_lots (material_id);

create table if not exists hg_settlements (          -- 월 지급 (전표NO, 지급일 수정)
  yyyymm      char(4) not null,                      -- '2606'
  supplier_id bigint not null references hg_suppliers(id),
  voucher_no  text,
  due_date    date,                                  -- 비어 있으면 결제조건으로 계산
  amount      numeric(14,0),                         -- 입고 내역이 없는 항목(운송비)의 직접 입력 금액
  primary key (yyyymm, supplier_id)
);

create table if not exists hg_report_items (         -- 품목별 보고서 양식 (행 순서·품명·거래처 표기)
  id           bigserial primary key,
  sort_order   int not null,
  sap_code     text not null,
  label        text not null,
  vendor_label text
);

do $$ declare t text; begin
  foreach t in array array['hg_settings','hg_sessions','hg_suppliers','hg_materials','hg_supplier_items',
    'hg_import_batches','hg_price_history','hg_import_lots','hg_receipts','hg_settlements','hg_report_items'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- 초기 PIN 1234
insert into hg_settings(key, value) values
  ('pin_hash', extensions.crypt('1234', extensions.gen_salt('bf'))),
  ('fail_count', '0'), ('locked_until', '')
on conflict (key) do nothing;

-- ───────────── 로그인 / PIN ─────────────
create or replace function hg_auth(p_token uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is null or not exists (select 1 from hg_sessions where token = p_token and expires_at > now()) then
    raise exception 'HG_AUTH' using hint = '로그인이 필요합니다';
  end if;
end $$;

create or replace function hg_login(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_fail int; v_lock timestamptz; v_token uuid;
begin
  select value into v_hash from hg_settings where key = 'pin_hash';
  select coalesce(nullif(value,'')::int, 0) into v_fail from hg_settings where key = 'fail_count';
  select nullif(value,'')::timestamptz into v_lock from hg_settings where key = 'locked_until';
  if v_lock is not null and v_lock > now() then
    return json_build_object('ok', false, 'msg', '여러 번 틀려 잠겼습니다. ' || ceil(extract(epoch from v_lock - now()) / 60)::int || '분 뒤 다시 시도하세요.');
  end if;
  if p_pin is null or crypt(p_pin, v_hash) <> v_hash then
    v_fail := v_fail + 1;
    if v_fail >= 5 then
      update hg_settings set value = (now() + interval '5 minutes')::text where key = 'locked_until';
      update hg_settings set value = '0' where key = 'fail_count';
      return json_build_object('ok', false, 'msg', '5회 틀려 5분간 잠깁니다.');
    end if;
    update hg_settings set value = v_fail::text where key = 'fail_count';
    return json_build_object('ok', false, 'msg', 'PIN이 맞지 않습니다. (' || v_fail || '/5)');
  end if;
  update hg_settings set value = '0' where key = 'fail_count';
  update hg_settings set value = '' where key = 'locked_until';
  delete from hg_sessions where expires_at < now();
  insert into hg_sessions(expires_at) values (now() + interval '12 hours') returning token into v_token;
  return json_build_object('ok', true, 'token', v_token, 'is_default', crypt('1234', v_hash) = v_hash);
end $$;

create or replace function hg_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$
  delete from hg_sessions where token = p_token;
$$;

create or replace function hg_change_pin(p_token uuid, p_old text, p_new text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  perform hg_auth(p_token);
  select value into v_hash from hg_settings where key = 'pin_hash';
  if crypt(coalesce(p_old,''), v_hash) <> v_hash then
    return json_build_object('ok', false, 'msg', '현재 PIN이 맞지 않습니다.');
  end if;
  if p_new !~ '^[0-9]{4,8}$' then
    return json_build_object('ok', false, 'msg', '새 PIN은 숫자 4~8자리여야 합니다.');
  end if;
  update hg_settings set value = crypt(p_new, gen_salt('bf')) where key = 'pin_hash';
  delete from hg_sessions where token <> p_token;      -- 다른 기기는 로그아웃
  return json_build_object('ok', true);
end $$;

-- ───────────── 조회 ─────────────
create or replace function hg_load(p_token uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v json;
begin
  perform hg_auth(p_token);
  select json_build_object(
    'is_default', (select crypt('1234', value) = value from hg_settings where key = 'pin_hash'),
    'vendors', (select coalesce(json_agg(json_build_object('code', code, 'name', name, 'off', pay_month_offset, 'day', pay_day,
                  'bank', bank_name, 'acct', account_no, 'contact', contact, 'sec', report_section, 'ord', report_order, 'rep', rep_item,
                  'del', not is_active) order by name), '[]')
                from hg_suppliers s0 where is_active      -- 삭제한 거래처도 입고 내역이 남아 있으면 보고서용으로 함께 보냄
                   or exists (select 1 from hg_receipts r join hg_supplier_items si on si.id = r.supplier_item_id
                              where si.supplier_id = s0.id and r.voided_at is null)),
    'items', (select coalesce(json_agg(json_build_object('id', si.id, 'sap', m.sap_code, 'name', m.name, 'raw', si.raw_name, 'grp', m.group_name,
                  'cat', si.category, 'tax', si.tax_code, 'shelf', m.shelf_life, 'v', s.code,
                  'hist', (select coalesce(json_agg(json_build_array(ph.valid_from, ph.unit_price) order by ph.valid_from), '[]')
                           from hg_price_history ph where ph.supplier_item_id = si.id)) order by m.sap_code, si.raw_name), '[]')
              from hg_supplier_items si join hg_materials m on m.id = si.material_id join hg_suppliers s on s.id = si.supplier_id
              where si.is_active),
    -- 모선: 이름 하나에 한 줄(입고PO는 입고 건마다 따로 저장). 최근 입고한 모선부터.
    'lots', (select coalesce(json_agg(json_build_object('id', x.id, 'sap', x.sap_code, 'name', x.name, 'raw', x.vessel_name,
                  'inpo', '', 'tax', x.tax_code, 'last', x.last) order by x.last desc nulls last, x.id desc), '[]')
             from (select distinct on (l.vessel_name) l.id, l.vessel_name, l.tax_code, m.sap_code, m.name,
                          (select max(r.receipt_date) from hg_receipts r join hg_import_lots l2 on l2.id = r.import_lot_id
                           where l2.vessel_name = l.vessel_name and r.voided_at is null) as last
                   from hg_import_lots l join hg_materials m on m.id = l.material_id
                   order by l.vessel_name, (l.inbound_po_no = '') desc, l.id desc) x),
    'tx', (select coalesce(json_agg(x order by x.date, x.id), '[]') from (
             select r.id, r.receipt_date as date, r.category as cat,
                    coalesce(m.sap_code, lm.sap_code) as sap, coalesce(m.name, lm.name) as name,
                    coalesce(si.raw_name, l.vessel_name) as raw, r.tax_code as tax,
                    r.net_kg as qty, r.unit_price as price, coalesce(s.code, '') as v, coalesce(s.name, '') as vname,
                    coalesce(r.purchase_order_no, '') as po, coalesce(r.inbound_po_no, '') as inpo,
                    coalesce(r.packaging, '') as tb, r.tb_count as tbcnt, r.tare_kg as tare, r.gross_kg as gross,
                    r.import_batch_id as batch
             from hg_receipts r
             left join hg_supplier_items si on si.id = r.supplier_item_id
             left join hg_materials m on m.id = si.material_id
             left join hg_suppliers s on s.id = si.supplier_id
             left join hg_import_lots l on l.id = r.import_lot_id
             left join hg_materials lm on lm.id = l.material_id
             where r.voided_at is null) x),
    'batches', (select coalesce(json_agg(json_build_object('id', id, 'type', target, 'src', file_name, 'at', created_at,
                  'n', ok_rows, 'skip', skipped_rows) order by id desc), '[]')
                from (select * from hg_import_batches where reverted_at is null order by id desc limit 20) b),
    'settle', (select coalesce(json_agg(json_build_object('ym', st.yyyymm, 'v', s.code, 'voucher', st.voucher_no, 'due', st.due_date, 'amount', st.amount)), '[]')
               from hg_settlements st join hg_suppliers s on s.id = st.supplier_id),
    'ritems', (select coalesce(json_agg(json_build_object('sap', sap_code, 'label', label, 'vlabel', vendor_label) order by sort_order, id), '[]') from hg_report_items)
  ) into v;
  return v;
end $$;

-- ───────────── 입고 등록 ─────────────
-- p_rows: [{item_id | lot_id, date, qty, gross, tare, tbcnt, price, po, inpo}]
-- p_batch: null(낱건) 또는 {file, total, skipped} (일괄 입력)
create or replace function hg_add_receipts(p_token uuid, p_rows jsonb, p_batch jsonb default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; v_batch bigint; v_n int := 0; v_item_id bigint; v_lot_id bigint; v_lot_po text;
        v_date date; v_qty numeric; v_price numeric; v_cat text; v_tax text; v_supply numeric; v_tare numeric; v_cnt int;
begin
  perform hg_auth(p_token);
  if p_batch is not null then
    insert into hg_import_batches(target, file_name, total_rows, ok_rows, skipped_rows)
    values ('receipts', p_batch->>'file', coalesce((p_batch->>'total')::int, 0), jsonb_array_length(p_rows), coalesce((p_batch->>'skipped')::int, 0))
    returning id into v_batch;
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_date := (r->>'date')::date; v_qty := nullif(r->>'qty','')::numeric;
    v_tare := nullif(r->>'tare','')::numeric; v_cnt := nullif(r->>'tbcnt','')::int;
    if v_qty is not null and v_qty <= 0 then raise exception '수량은 0보다 커야 합니다'; end if;
    if v_qty is null and nullif(r->>'item_id','') is not null then raise exception '수량을 입력하세요'; end if;
    v_price := nullif(r->>'price','')::numeric;
    if nullif(r->>'item_id','') is not null then
      v_lot_id := null; v_lot_po := null;
      select id, category, tax_code into strict v_item_id, v_cat, v_tax from hg_supplier_items where id = (r->>'item_id')::bigint;
      if v_price is null then
        select unit_price into v_price from hg_price_history
        where supplier_item_id = v_item_id and valid_from <= v_date order by valid_from desc limit 1;
      end if;
    else
      v_item_id := null; v_cat := '주원료';
      select id, tax_code, inbound_po_no into strict v_lot_id, v_tax, v_lot_po from hg_import_lots where id = (r->>'lot_id')::bigint;
    end if;
    v_supply := case when v_price is null or v_qty is null then null else round(v_qty * v_price) end;
    insert into hg_receipts(receipt_date, supplier_item_id, import_lot_id, category, tax_code, gross_kg, packaging, tb_count, tare_kg,
                            net_kg, unit_price, supply_amount, vat_amount, purchase_order_no, inbound_po_no, import_batch_id)
    values (v_date, v_item_id, v_lot_id, v_cat, v_tax,
            nullif(r->>'gross','')::numeric, case when v_cnt is not null or coalesce(v_tare, 0) > 0 then 'T/B' end, v_cnt, v_tare,
            v_qty, v_price, v_supply, case when v_supply is null then null when v_tax = 'V1' then round(v_supply * 0.1) else 0 end,
            nullif(r->>'po',''), nullif(r->>'inpo',''), v_batch);   -- 입고PO는 입고 건마다 (모선에 묶지 않음)
    v_n := v_n + 1;
  end loop;
  return json_build_object('ok', true, 'n', v_n, 'batch', v_batch);
end $$;

-- 입고 내역 수정. p_data: {date, item_id(같은 거래처 안에서 원료 변경), qty, gross, tbcnt, tare, price, po, inpo}
create or replace function hg_update_receipt(p_token uuid, p_id bigint, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_old hg_receipts; v_item bigint; v_cat text; v_tax text; v_qty numeric; v_price numeric; v_supply numeric; v_tare numeric; v_cnt int;
begin
  perform hg_auth(p_token);
  select * into v_old from hg_receipts where id = p_id and voided_at is null;
  if not found then raise exception '수정할 입고 내역을 찾을 수 없습니다'; end if;
  v_item := v_old.supplier_item_id; v_cat := v_old.category; v_tax := v_old.tax_code;
  if v_old.supplier_item_id is not null and nullif(p_data->>'item_id','') is not null
     and (p_data->>'item_id')::bigint <> v_old.supplier_item_id then
    select id, category, tax_code into strict v_item, v_cat, v_tax from hg_supplier_items where id = (p_data->>'item_id')::bigint;
  end if;
  v_qty := nullif(p_data->>'qty','')::numeric;
  if v_qty is not null and v_qty <= 0 then raise exception '수량은 0보다 커야 합니다'; end if;
  if v_qty is null and v_item is not null then raise exception '수량을 입력하세요'; end if;
  if nullif(p_data->>'date','') is null then raise exception '날짜가 필요합니다'; end if;
  v_price := nullif(p_data->>'price','')::numeric;
  v_tare := nullif(p_data->>'tare','')::numeric; v_cnt := nullif(p_data->>'tbcnt','')::int;
  v_supply := case when v_price is null or v_qty is null then null else round(v_qty * v_price) end;
  update hg_receipts set receipt_date = (p_data->>'date')::date, supplier_item_id = v_item, category = v_cat, tax_code = v_tax,
    gross_kg = nullif(p_data->>'gross','')::numeric,
    packaging = case when v_cnt is not null or coalesce(v_tare, 0) > 0 then 'T/B' end, tb_count = v_cnt, tare_kg = v_tare,
    net_kg = v_qty, unit_price = v_price, supply_amount = v_supply,
    vat_amount = case when v_supply is null then null when v_tax = 'V1' then round(v_supply * 0.1) else 0 end,
    purchase_order_no = nullif(p_data->>'po',''), inbound_po_no = nullif(p_data->>'inpo',''),
    import_lot_id = case when v_old.import_lot_id is not null and nullif(p_data->>'lot_id','') is not null
                         then (select id from hg_import_lots where id = (p_data->>'lot_id')::bigint) else v_old.import_lot_id end
  where id = p_id;
end $$;

-- 주원료 입고 일괄 수정. p_data: {ids:[…], inpo?: '5000…'(빈 문자열 = PO 지움), lot_id?: 모선}
-- 키가 없는 항목은 바꾸지 않습니다. 주원료(모선) 입고만 대상입니다.
create or replace function hg_update_main_bulk(p_token uuid, p_data jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform hg_auth(p_token);
  if p_data ? 'lot_id' and not exists (select 1 from hg_import_lots where id = (p_data->>'lot_id')::bigint) then
    raise exception '모선을 찾을 수 없습니다';
  end if;
  update hg_receipts set
    inbound_po_no = case when p_data ? 'inpo' then nullif(trim(p_data->>'inpo'),'') else inbound_po_no end,
    import_lot_id = case when p_data ? 'lot_id' then (p_data->>'lot_id')::bigint else import_lot_id end
  where id in (select (e#>>'{}')::bigint from jsonb_array_elements(p_data->'ids') e)
    and import_lot_id is not null and voided_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function hg_void_receipt(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform hg_auth(p_token);
  update hg_receipts set voided_at = now() where id = p_id and voided_at is null;
end $$;

create or replace function hg_revert_batch(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform hg_auth(p_token);
  update hg_receipts set voided_at = now() where import_batch_id = p_id and voided_at is null;
  update hg_import_batches set reverted_at = now() where id = p_id;
end $$;

create or replace function hg_add_lot(p_token uuid, p_sap text, p_name text, p_vessel text, p_inpo text, p_tax text default 'V1') returns bigint
language plpgsql security definer set search_path = public as $$
declare v_mat bigint; v_id bigint;
begin
  perform hg_auth(p_token);
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_vessel),'') = '' then raise exception '품목명과 모선명(원료명)이 필요합니다'; end if;
  select id into v_mat from hg_materials where sap_code = coalesce(p_sap,'') and name = p_name;
  if v_mat is null then insert into hg_materials(sap_code, name) values (coalesce(p_sap,''), p_name) returning id into v_mat; end if;
  insert into hg_import_lots(material_id, vessel_name, inbound_po_no, tax_code)
  values (v_mat, trim(p_vessel), coalesce(trim(p_inpo),''), coalesce(p_tax,'V1'))
  on conflict (vessel_name, inbound_po_no) do update set is_closed = false returning id into v_id;
  return v_id;
end $$;

-- ───────────── 기초자료 ─────────────
-- p_rows: [{sap, name, raw, grp, cat, tax, shelf, vcode, vname, price, from}]
-- 거래처코드 + 원료명(+SAP)이 같으면 같은 품목. 단가가 다르면 이력에 추가.
create or replace function hg_upsert_master(p_token uuid, p_rows jsonb, p_batch jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_batch bigint; v_sup bigint; v_mat bigint; v_item bigint; v_cnt int; v_cur numeric; v_price numeric;
        v_new int := 0; v_upd int := 0; v_sap text;
begin
  perform hg_auth(p_token);
  if p_batch is not null then
    insert into hg_import_batches(target, file_name, total_rows, ok_rows, skipped_rows)
    values ('master', p_batch->>'file', coalesce((p_batch->>'total')::int, 0), jsonb_array_length(p_rows), coalesce((p_batch->>'skipped')::int, 0))
    returning id into v_batch;
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_sap := coalesce(trim(r->>'sap'), '');
    if coalesce(trim(r->>'vcode'),'') = '' or coalesce(trim(r->>'name'),'') = '' or coalesce(trim(r->>'raw'),'') = '' then
      raise exception '거래처코드·품목명·원료명은 필수입니다';
    end if;
    select id into v_sup from hg_suppliers where code = trim(r->>'vcode');
    if v_sup is null then
      insert into hg_suppliers(code, name) values (trim(r->>'vcode'), coalesce(nullif(trim(r->>'vname'),''), trim(r->>'vcode'))) returning id into v_sup;
    end if;
    select id into v_mat from hg_materials where sap_code = v_sap and name = trim(r->>'name');
    if v_mat is null then
      insert into hg_materials(sap_code, name, group_name, shelf_life)
      values (v_sap, trim(r->>'name'), nullif(r->>'grp',''), nullif(r->>'shelf','')) returning id into v_mat;
    else
      update hg_materials set group_name = coalesce(nullif(r->>'grp',''), group_name), shelf_life = coalesce(nullif(r->>'shelf',''), shelf_life) where id = v_mat;
    end if;
    v_item := null;
    select si.id into v_item from hg_supplier_items si join hg_materials m on m.id = si.material_id
    where si.supplier_id = v_sup and si.raw_name = trim(r->>'raw') and m.sap_code = v_sap limit 1;
    if v_item is null then
      select count(*), min(id) into v_cnt, v_item from hg_supplier_items where supplier_id = v_sup and raw_name = trim(r->>'raw');
      if v_cnt <> 1 then v_item := null; end if;
    end if;
    if v_item is null then
      insert into hg_supplier_items(material_id, supplier_id, raw_name, category, tax_code)
      values (v_mat, v_sup, trim(r->>'raw'), r->>'cat', coalesce(nullif(r->>'tax',''), 'V1')) returning id into v_item;
      v_new := v_new + 1;
    else
      update hg_supplier_items set material_id = v_mat, category = r->>'cat', tax_code = coalesce(nullif(r->>'tax',''), tax_code), is_active = true where id = v_item;
      v_upd := v_upd + 1;
    end if;
    v_price := nullif(r->>'price','')::numeric;
    if v_price is not null then
      select unit_price into v_cur from hg_price_history where supplier_item_id = v_item order by valid_from desc limit 1;
      if v_cur is distinct from v_price then
        insert into hg_price_history(supplier_item_id, unit_price, valid_from, import_batch_id)
        values (v_item, v_price, coalesce(nullif(r->>'from','')::date, current_date), v_batch)
        on conflict (supplier_item_id, valid_from) do update set unit_price = excluded.unit_price, import_batch_id = excluded.import_batch_id;
      end if;
    end if;
    v_cur := null;
  end loop;
  return json_build_object('ok', true, 'new', v_new, 'upd', v_upd, 'batch', v_batch);
end $$;

create or replace function hg_save_supplier(p_token uuid, p_code text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform hg_auth(p_token);
  if coalesce(trim(p_code),'') = '' or coalesce(trim(p_data->>'name'),'') = '' then raise exception '거래처코드와 거래처명이 필요합니다'; end if;
  insert into hg_suppliers(code, name, pay_month_offset, pay_day, bank_name, account_no, contact, report_section, report_order, rep_item)
  values (trim(p_code), trim(p_data->>'name'), nullif(p_data->>'off','')::smallint, nullif(p_data->>'day','')::smallint,
          nullif(p_data->>'bank',''), nullif(p_data->>'acct',''), nullif(p_data->>'contact',''),
          nullif(p_data->>'sec','')::smallint, nullif(p_data->>'ord','')::int, nullif(p_data->>'rep',''))
  on conflict (code) do update set name = excluded.name, pay_month_offset = excluded.pay_month_offset, pay_day = excluded.pay_day,
          bank_name = excluded.bank_name, account_no = excluded.account_no, contact = excluded.contact,
          report_section = excluded.report_section, report_order = excluded.report_order, rep_item = excluded.rep_item,
          is_active = true;
end $$;

-- 거래처 삭제. 입고·정산 기록이 없으면 품목·단가 이력과 함께 완전히 지우고,
-- 기록이 있으면 과거 보고서가 맞도록 '사용중지'(목록에서 숨김)로 처리합니다.
create or replace function hg_delete_supplier(p_token uuid, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare v_sup bigint; v_used boolean;
begin
  perform hg_auth(p_token);
  select id into v_sup from hg_suppliers where code = p_code;
  if v_sup is null then raise exception '거래처를 찾을 수 없습니다'; end if;
  v_used := exists (select 1 from hg_receipts r join hg_supplier_items si on si.id = r.supplier_item_id where si.supplier_id = v_sup)
         or exists (select 1 from hg_settlements where supplier_id = v_sup);
  if v_used then
    update hg_supplier_items set is_active = false where supplier_id = v_sup;
    update hg_suppliers set is_active = false where id = v_sup;
    return json_build_object('ok', true, 'mode', 'hidden');
  end if;
  delete from hg_price_history where supplier_item_id in (select id from hg_supplier_items where supplier_id = v_sup);
  delete from hg_supplier_items where supplier_id = v_sup;
  delete from hg_suppliers where id = v_sup;
  return json_build_object('ok', true, 'mode', 'deleted');
end $$;

create or replace function hg_set_settlement(p_token uuid, p_ym text, p_code text, p_voucher text, p_due date, p_amount numeric default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_sup bigint;
begin
  perform hg_auth(p_token);
  select id into strict v_sup from hg_suppliers where code = p_code;
  insert into hg_settlements(yyyymm, supplier_id, voucher_no, due_date, amount) values (p_ym, v_sup, nullif(p_voucher,''), p_due, p_amount)
  on conflict (yyyymm, supplier_id) do update set voucher_no = excluded.voucher_no, due_date = excluded.due_date, amount = excluded.amount;
end $$;

-- 품목별 보고서 양식 전체 교체. p_rows: [{sap, label, vlabel}] (배열 순서 = 보고서 순서)
create or replace function hg_save_report_items(p_token uuid, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform hg_auth(p_token);
  delete from hg_report_items where true;
  insert into hg_report_items(sort_order, sap_code, label, vendor_label)
  select ord::int, trim(r->>'sap'), trim(r->>'label'), nullif(trim(r->>'vlabel'),'')
  from jsonb_array_elements(p_rows) with ordinality as t(r, ord)
  where coalesce(trim(r->>'sap'),'') <> '' and coalesce(trim(r->>'label'),'') <> '';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- 화면(anon 키)에서 부를 수 있는 함수만 열어 둠. hg_auth 는 내부용.
revoke all on function hg_auth(uuid) from public, anon, authenticated;
grant execute on function hg_login(text), hg_logout(uuid), hg_change_pin(uuid, text, text), hg_load(uuid),
  hg_add_receipts(uuid, jsonb, jsonb), hg_update_receipt(uuid, bigint, jsonb), hg_update_main_bulk(uuid, jsonb), hg_void_receipt(uuid, bigint), hg_revert_batch(uuid, bigint),
  hg_add_lot(uuid, text, text, text, text, text), hg_upsert_master(uuid, jsonb, jsonb),
  hg_save_supplier(uuid, text, jsonb), hg_delete_supplier(uuid, text), hg_set_settlement(uuid, text, text, text, date, numeric),
  hg_save_report_items(uuid, jsonb) to anon, authenticated;
